import Foundation

/// 真实决策走生产入口；完整隐藏手牌只供事后重放和规则裁判，不参与战术标记。
enum SelfPlayAudit {
    struct Play: Codable {
        let seat: Int
        let cards: [Card]
    }
    struct RecordedTrick: Codable {
        let leader: Int
        let plays: [Play]
        let winner: Int
        let points: Int
    }
    struct Finding: Codable {
        let reason: String
        let alternative: [Card]
        let security: Double
    }
    struct Decision: Codable {
        let trick: Int
        let seat: Int
        let hand: [Card]
        let played: [Card]
        let seconds: Double
        let findings: [Finding]
    }
    struct Round: Codable {
        let seed: UInt64
        let trump: Suit?
        let rank: Rank
        let dealer: Int
        let initialLeader: Int
        let initialHands: [[Card]]
        let kitty: [Card]
        let decisions: [Decision]
        let tricks: [RecordedTrick]
        let legal: Bool
        let attackPoints: Int
    }

    /// 从实际逐手记录恢复决策前状态，便于把发现的问题固定成回归。
    static func state(before decisionIndex: Int, round: Round) -> GameState {
        let state = makeState(trump: round.trump, rank: round.rank)
        state.dealerPosition = PlayerPosition(rawValue: round.dealer)!
        state.dealerTeamIdx = state.dealerPosition.team
        state.kitty = round.kitty
        for seat in PlayerPosition.allCases { state.player(seat).hand = round.initialHands[seat.rawValue] }
        var leader = PlayerPosition(rawValue: round.initialLeader)!
        setTrick(state, lead: leader, plays: [], turn: leader)
        let evaluator = TrickEvaluator(trumpSuit: round.trump, trumpRank: round.rank)
        for decision in round.decisions.prefix(decisionIndex) {
            let position = PlayerPosition(rawValue: decision.seat)!
            state.player(position).hand = AIPlayer.handAfterPlaying(decision.played, from: state.player(position).hand)
            state.currentTrick.plays.append((position, decision.played))
            if state.currentTrick.plays.count == 4 {
                leader = evaluator.winner(of: state.currentTrick)
                if leader.team != state.dealerTeamIdx {
                    state.attackScore += state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
                }
                state.completedTricks.append(state.currentTrick)
                setTrick(state, lead: leader, plays: [], turn: leader)
            } else { state.currentTurn = AIPlayer.nextPosition(after: position) }
        }
        return state
    }

    struct Regression: Decodable {
        struct Target: Decodable {
            let decisionIndex: Int
            let note: String
            let preserveFace: String?
            let preserveBigTrump: Bool?
            let allowedFaces: [String]?
            let plannedLead: Bool?
            let partnerVoidLead: Bool?
            let keepLeadCandidate: String?
        }
        let round: Round
        let targets: [Target]
    }

    static func runRegressions() {
        do {
            let fixtures = try ["self-play-1501-1510.json", "self-play-1511-1520.json", "self-play-1521-1530.json"].flatMap { name in
                try JSONDecoder().decode([Regression].self, from: Data(contentsOf:
                    URL(fileURLWithPath: "AITests/Fixtures/\(name)")))
            }
            for fixture in fixtures {
                for target in fixture.targets {
                    let state = state(before: target.decisionIndex, round: fixture.round)
                    let decision = fixture.round.decisions[target.decisionIndex]
                    let position = PlayerPosition(rawValue: decision.seat)!
                    let evaluator = TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
                    let hand = state.player(position).hand
                    let chosen = AIPlayer.chooseCards(position: position, state: state, evaluator: evaluator)
                    let legal = state.currentTrick.leadCards.map {
                        evaluator.isValidPlay(selected: chosen, hand: hand, leadCards: $0)
                    } ?? evaluator.isValidLead(chosen)
                    let ctx = AIContext.build(state: state.aiObservation(for: position), ts: state.trumpSuit, tr: state.trumpRank)
                    let expected: Bool
                    if let face = target.preserveFace {
                        expected = hand.filter { AIPlayer.faceKey($0) == face }.count == 2
                            && !chosen.contains { AIPlayer.faceKey($0) == face }
                    } else if let allowed = target.allowedFaces {
                        expected = chosen.count == 1 && allowed.contains(AIPlayer.faceKey(chosen[0]))
                    } else if target.partnerVoidLead == true {
                        let partner = PlayerPosition(rawValue: (position.rawValue + 2) % 4)!
                        expected = chosen.first?.suit.map { ctx.isVoid(partner, key: $0.rawValue) } ?? false
                    } else if let candidate = target.keepLeadCandidate {
                        let observation = state.aiObservation(for: position)
                        let assets = AIPlayer.buildLeadAssets(position: position, hand: hand, state: observation, ctx: ctx)
                        expected = AIPlayer.filterUnplannedSideFallback(assets, position: position,
                            hand: hand, state: observation, ctx: ctx).contains {
                                $0.move.cards.count == 1 && AIPlayer.faceKey($0.move.cards[0]) == candidate
                            }
                    } else if target.plannedLead == true {
                        expected = chosen.count > 1 || chosen.contains { CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) }
                            || chosen[0].rank.rawValue >= Rank.jack.rawValue
                            || AIPlayer.clearsSideSuitForLead(chosen, hand: hand, ts: state.trumpSuit, tr: state.trumpRank)
                            || ctx.isEffectivelyBiggest(chosen[0], ts: state.trumpSuit, tr: state.trumpRank, hand: hand)
                    } else {
                        expected = !chosen.contains { AIPlayer.isBigTrump($0, ts: state.trumpSuit, tr: state.trumpRank) }
                    }
                    check(legal && expected && (state.currentTrick.plays.isEmpty || chosen.allSatisfy { $0.pointValue == 0 }),
                        "SelfPlay \(fixture.round.seed)/\(decision.trick)/\(decision.seat) \(target.note)",
                        "chosen=\(chosen.map(\.shortDisplay))")
                    if !expected && !state.currentTrick.plays.isEmpty && ProcessInfo.processInfo.environment["TRACTOR_AI_AUDIT_DIAG"] == "1" {
                        diagnose(position: position, state: state, evaluator: evaluator)
                    }
                }
            }
        } catch { check(false, "SelfPlay 载入固定回归", "\(error)") }
    }

    static func diagnose(position: PlayerPosition, state: GameState, evaluator: TrickEvaluator) {
        let state = state.aiObservation(for: position)
        let hand = state.player(position).hand
        let ctx = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)
        let lead = state.currentTrick.leadCards!
        let candidates = AIPlayer.deduplicatedMoves(AIPlayer.generateFollowCandidates(leadCards: lead,
            hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx)).filter {
                evaluator.isValidPlay(selected: $0.cards, hand: hand, leadCards: lead)
            }
        let mode = AIPlayer.detectTacticalMode(position: position, hand: hand, state: state,
            evaluator: evaluator, legalMoves: candidates, ctx: ctx)
        let worlds = (0..<AIPlayer.monteCarloSimulationCount).compactMap { simulation -> [PlayerPosition: [Card]]? in
            var rng = AIPlayer.MonteCarloRNG(seed: AIPlayer.monteCarloSeed(position: position, state: state, simulation: simulation))
            let hands = AIPlayer.sampleHiddenHands(currentPosition: position, currentHand: hand,
                playedCandidate: [], state: state, rng: &rng, maximumAttempts: 16)
            return hands.isEmpty ? nil : hands
        }
        for move in candidates {
            let score = AIPlayer.scoreFollow(move, leadCards: lead, hand: hand, position: position,
                state: state, evaluator: evaluator, ctx: ctx)
            var simulationScore = 0.0
            for (index, hands) in worlds.enumerated() {
                var rng = AIPlayer.MonteCarloRNG(seed: AIPlayer.monteCarloSeed(position: position, state: state, simulation: index))
                simulationScore += AIPlayer.simulateCurrentTrick(candidate: move, position: position,
                    hand: hand, state: state, evaluator: evaluator, mode: mode, rng: &rng, sampledHands: hands)
            }
            print("Diagnostic \(move.cards.map(\.shortDisplay)) mode=\(mode) heuristic=\(score) sim=\(simulationScore / Double(max(1, worlds.count))) fragmentation=\(AIPlayer.structureFragmentationCost(move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank))")
        }
    }

    /// 只筛查值得人工复核的机会，不把可疑走法直接等同策略错误。
    static func findings(play: [Card], position: PlayerPosition, state: GameState,
                         evaluator: TrickEvaluator) -> [Finding] {
        let observation = state.aiObservation(for: position)
        let hand = observation.player(position).hand
        let ts = observation.trumpSuit, tr = observation.trumpRank
        let ctx = AIContext.build(state: observation, ts: ts, tr: tr)
        let points = play.reduce(0) { $0 + $1.pointValue }
        let fragmentation = AIPlayer.structureFragmentationCost(play, hand: hand, ts: ts, tr: tr)
        var result: [Finding] = []
        if observation.currentTrick.plays.isEmpty {
            let assets = AIPlayer.filterAllowedLeadAssets(AIPlayer.deduplicatedLeadAssets(
                AIPlayer.buildLeadAssets(position: position, hand: hand, state: observation, ctx: ctx)),
                position: position, hand: hand, state: observation)
            let cashing = AIPlayer.cashingWindowAssets(assets, position: position,
                hand: hand, state: observation, ctx: ctx) ?? []
            if !cashing.isEmpty && !cashing.contains(where: { AIPlayer.sameCardSet($0.move.cards, play) }) {
                result.append(Finding(reason: "cash-window-bypassed", alternative: cashing[0].move.cards, security: 1))
            }
            if fragmentation > 0, let whole = assets.first(where: {
                $0.move.cards.count > play.count && Set(play.map(\.id)).isSubset(of: Set($0.move.cards.map(\.id)))
                    && AIPlayer.leadTeamControlProbability($0.move.cards, position: position,
                        hand: hand, state: observation, ctx: ctx) >= 0.95
            }) {
                result.append(Finding(reason: "split-safe-lead-group", alternative: whole.move.cards, security: 0.95))
            }
            if play.count == 1 && points == 0 && !CardComparator.isTrump(play[0], trumpSuit: ts, trumpRank: tr),
               !AIPlayer.clearsSideSuitForLead(play, hand: hand, ts: ts, tr: tr),
               !ctx.isEffectivelyBiggest(play[0], ts: ts, tr: tr, hand: hand),
               let transfer = assets.first(where: { $0.move.kind == .trumpTransfer }),
               AIPlayer.fallbackTrumpTransferPreference(transfer.move, position: position,
                   hand: hand, state: observation, ctx: ctx) > 0 {
                result.append(Finding(reason: "weak-side-instead-of-transfer", alternative: transfer.move.cards, security: 0))
            }
            return result
        }
        guard let lead = observation.currentTrick.leadCards else { return result }
        var options = AIPlayer.generateFollowCandidates(leadCards: lead, hand: hand, position: position,
            state: observation, evaluator: evaluator, ctx: ctx)
        options += AIPlayer.generateTrumpControlCandidates(leadCards: lead, hand: hand, position: position,
            state: observation, evaluator: evaluator, ctx: ctx)
        if lead.count == 1 { options += hand.map { AIPlayer.AIMove(cards: [$0], kind: .followWin) } }
        options = AIPlayer.deduplicatedMoves(options).filter {
            evaluator.isValidPlay(selected: $0.cards, hand: hand, leadCards: lead)
        }
        var after = observation.currentTrick
        after.plays.append((position, play))
        let winner = evaluator.winner(of: after)
        if ctx.isLastPlayer && winner.team == position.team {
            let alternatives = options.filter { move in
                guard move.cards.reduce(0, { $0 + $1.pointValue }) > points,
                      !move.cards.contains(where: { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }),
                      AIPlayer.structureFragmentationCost(move.cards, hand: hand, ts: ts, tr: tr) <= fragmentation else { return false }
                var test = observation.currentTrick
                test.plays.append((position, move.cards))
                return evaluator.winner(of: test) == winner
            }
            if let alternative = alternatives.max(by: {
                $0.cards.reduce(0) { $0 + $1.pointValue } < $1.cards.reduce(0) { $0 + $1.pointValue }
            }) {
                result.append(Finding(reason: "deferred-secure-side-points", alternative: alternative.cards, security: 1))
            }
        }
        if fragmentation > 0 && points == 0, let alternative = options.first(where: { move in
            guard move.cards.allSatisfy({ $0.pointValue == 0 }),
                  AIPlayer.structureFragmentationCost(move.cards, hand: hand, ts: ts, tr: tr) == 0 else { return false }
            var test = observation.currentTrick
            test.plays.append((position, move.cards))
            return evaluator.winner(of: test) == winner
        }) {
            result.append(Finding(reason: "same-winner-unforced-structure-break", alternative: alternative.cards,
                security: 1 - AIPlayer.opponentTrickWinProbability(alternative, hand: hand,
                    position: position, state: observation, evaluator: evaluator, ctx: ctx)))
        }
        return result
    }

    struct SavedSeedIndex: Decodable {
        struct Batch: Decodable {
            let file: String
            let seeds: [UInt64]
        }
        let batches: [Batch]
    }

    static func verifySavedSeeds() {
        do {
            let root = URL(fileURLWithPath: "AITests/SelfPlay", isDirectory: true)
            let index = try JSONDecoder().decode(SavedSeedIndex.self, from:
                Data(contentsOf: root.appendingPathComponent("seeds.json")))
            for batch in index.batches {
                let rounds = try JSONDecoder().decode([Round].self, from:
                    Data(contentsOf: root.appendingPathComponent(batch.file)))
                var valid = batch.seeds == rounds.map(\.seed)
                for round in rounds {
                    var rng = AIPlayer.MonteCarloRNG(seed: round.seed)
                    let expectedDeck = Deck.doubleDeck().shuffled(using: &rng).map(AIPlayer.faceKey)
                    let savedDeck = (round.initialHands.flatMap { $0 } + round.kitty).map(AIPlayer.faceKey)
                    guard round.initialHands.count == 4, round.initialHands.allSatisfy({ $0.count == 25 }),
                          round.kitty.count == 8, savedDeck == expectedDeck else { valid = false; continue }
                    let state = state(before: 0, round: round)
                    let evaluator = TrickEvaluator(trumpSuit: round.trump, trumpRank: round.rank)
                    for decision in round.decisions {
                        guard let position = PlayerPosition(rawValue: decision.seat) else { valid = false; break }
                        let play = decision.played, hand = state.player(position).hand
                        let belongs = !play.isEmpty && Set(play.map(\.id)).count == play.count
                            && play.allSatisfy { hand.contains($0) }
                        let follows = state.currentTrick.leadCards.map {
                            evaluator.isValidPlay(selected: play, hand: hand, leadCards: $0)
                        } ?? evaluator.isValidLead(play)
                        guard belongs && follows && state.currentTurn == position
                            && decision.trick == state.completedTricks.count + 1 else { valid = false; break }
                        if state.currentTrick.plays.isEmpty, let slam = evaluator.slamInfo(of: play) {
                            let others = Dictionary(uniqueKeysWithValues: state.players.filter { $0.position != position }.map { ($0.position, $0.hand) })
                            if evaluator.slamFailure(slam: slam, opponentHands: others) != nil { valid = false }
                        }
                        state.player(position).hand = AIPlayer.handAfterPlaying(play, from: hand)
                        state.currentTrick.plays.append((position, play))
                        if state.currentTrick.plays.count == 4 {
                            let winner = evaluator.winner(of: state.currentTrick)
                            if winner.team != state.dealerTeamIdx {
                                state.attackScore += state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
                            }
                            state.completedTricks.append(state.currentTrick)
                            setTrick(state, lead: winner, plays: [], turn: winner)
                        } else { state.currentTurn = AIPlayer.nextPosition(after: position) }
                    }
                    let bottom = state.currentLeader.team != state.dealerTeamIdx
                        ? state.kitty.reduce(0) { $0 + $1.pointValue } * 2 : 0
                    valid = valid && state.players.allSatisfy { $0.hand.isEmpty }
                        && state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }.count == 100
                        && state.attackScore + bottom == round.attackPoints
                }
                check(valid, "SavedSeeds \(batch.file) 种子发牌一致且历史合法重放")
            }
        } catch { check(false, "SavedSeeds 载入保存种子", "\(error)") }
    }

    static func run(roundCount: Int, seed: UInt64, reportPath: String?, replayPath: String? = nil, replaySeed: UInt64? = nil) {
        let suits: [Suit?] = [.diamonds, nil, .spades, .hearts, .clubs]
        let ranks: [Rank] = [.five, .five, .two, .seven, .ten, .ace, .three, .nine, .queen, .king]
        let archived: [Round]
        do {
            archived = try replayPath.map { path in
                try JSONDecoder().decode([Round].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                    .filter { replaySeed == nil || $0.seed == replaySeed }
            } ?? []
        } catch { check(false, "SelfPlay 读取重跑牌局", "\(error)"); return }
        if replayPath != nil && archived.isEmpty { check(false, "SelfPlay 保存批次中找不到指定种子"); return }
        var rounds: [Round] = []
        for index in 0..<(replayPath == nil ? roundCount : archived.count) {
            let saved = replayPath == nil ? nil : archived[index]
            let trump: Suit? = saved == nil ? suits[index % suits.count] : saved!.trump
            let rank = saved?.rank ?? ranks[index % ranks.count]
            let state = makeState(trump: trump, rank: rank)
            state.dealerPosition = PlayerPosition(rawValue: saved?.dealer ?? index % 4)!
            state.dealerTeamIdx = state.dealerPosition.team
            let roundSeed = saved?.seed ?? seed + UInt64(index)
            var rng = AIPlayer.MonteCarloRNG(seed: roundSeed)
            let deck = Deck.doubleDeck().shuffled(using: &rng)
            for seat in PlayerPosition.allCases {
                state.player(seat).hand = saved?.initialHands[seat.rawValue]
                    ?? Array(deck[(seat.rawValue * 25)..<((seat.rawValue + 1) * 25)])
            }
            state.kitty = saved?.kitty ?? Array(deck.suffix(8))
            let initialHands = state.players.map(\.hand)
            let initialLeader = saved.map { PlayerPosition(rawValue: $0.initialLeader)! } ?? state.dealerPosition
            let evaluator = TrickEvaluator(trumpSuit: trump, trumpRank: rank)
            var leader = initialLeader, legal = true
            var decisions: [Decision] = [], tricks: [RecordedTrick] = []
            while !state.player(.south).hand.isEmpty && state.completedTricks.count < 26 {
                setTrick(state, lead: leader, plays: [], turn: leader)
                for _ in 0..<4 {
                    let position = state.currentTurn
                    let hand = state.player(position).hand
                    let start = Date()
                    let play = AIPlayer.chooseCards(position: position, state: state, evaluator: evaluator)
                    let duration = Date().timeIntervalSince(start)
                    let flags = reportPath == nil ? [] : findings(play: play, position: position, state: state, evaluator: evaluator)
                    decisions.append(Decision(trick: state.completedTricks.count + 1, seat: position.rawValue,
                        hand: hand, played: play, seconds: duration, findings: flags))
                    if !flags.isEmpty {
                        print("Audit seed=\(roundSeed) trick=\(state.completedTricks.count + 1) seat=\(position.rawValue) play=\(play.map(\.shortDisplay)) flags=\(flags.map(\.reason))")
                    }
                    let belongs = Set(play.map(\.id)).count == play.count
                        && play.allSatisfy { card in hand.contains { $0.id == card.id } }
                    let valid = state.currentTrick.plays.isEmpty ? evaluator.isValidLead(play)
                        : evaluator.isValidPlay(selected: play, hand: hand, leadCards: state.currentTrick.leadCards!)
                    var slamSafe = true
                    if state.currentTrick.plays.isEmpty, let slam = evaluator.slamInfo(of: play) {
                        let others = Dictionary(uniqueKeysWithValues: state.players.filter { $0.position != position }.map { ($0.position, $0.hand) })
                        slamSafe = evaluator.slamFailure(slam: slam, opponentHands: others) == nil
                    }
                    guard belongs && valid && slamSafe && !play.isEmpty else {
                        legal = false
                        print("Illegal seed=\(roundSeed) trick=\(state.completedTricks.count + 1) seat=\(position.rawValue) belongs=\(belongs) valid=\(valid) slam=\(slamSafe)")
                        break
                    }
                    state.player(position).hand = AIPlayer.handAfterPlaying(play, from: hand)
                    state.currentTrick.plays.append((position, play))
                    state.currentTurn = AIPlayer.nextPosition(after: position)
                }
                if !legal { break }
                leader = evaluator.winner(of: state.currentTrick)
                let points = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
                if leader.team != state.dealerTeamIdx { state.attackScore += points }
                tricks.append(RecordedTrick(leader: state.currentLeader.rawValue,
                    plays: state.currentTrick.plays.map { Play(seat: $0.position.rawValue, cards: $0.cards) },
                    winner: leader.rawValue, points: points))
                state.completedTricks.append(state.currentTrick)
            }
            legal = legal && state.players.allSatisfy { $0.hand.isEmpty }
                && state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }.count == 100
            check(legal, "SelfPlay seed=\(roundSeed) 完整一局合法结束（\(trump?.rawValue ?? "无主")\(rank.display)）")
            let bottom = leader.team != state.dealerTeamIdx ? state.kitty.reduce(0) { $0 + $1.pointValue } * 2 : 0
            rounds.append(Round(seed: roundSeed, trump: trump, rank: rank, dealer: state.dealerPosition.rawValue,
                initialLeader: initialLeader.rawValue, initialHands: initialHands, kitty: state.kitty,
                decisions: decisions, tricks: tricks, legal: legal, attackPoints: state.attackScore + bottom))
            let total = decisions.reduce(0.0) { $0 + $1.seconds }
            print("Full-round \(index): seed=\(roundSeed), \(decisions.count) decisions, attack=\(state.attackScore + bottom), mean=\(total / Double(max(1, decisions.count)))s, max=\(decisions.map(\.seconds).max() ?? 0)s")
        }
        if let reportPath {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rounds).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                print("Self-play audit saved: \(reportPath)")
            } catch { check(false, "SelfPlay 写入审计重放记录", "\(error)") }
        }
    }
}
