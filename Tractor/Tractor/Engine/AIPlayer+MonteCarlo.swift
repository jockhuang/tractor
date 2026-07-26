import Foundation

// MARK: - AIPlayer Monte Carlo 模拟（结构性拆分，逻辑未改）

extension AIPlayer {


    // MARK: - Monte Carlo 候选重排

    struct MonteCarloRNG: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }


    static func monteCarloBestMove(
        from moves: [AIMove],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        mode: TacticalMode = .normal,
        heuristicScore: (AIMove) -> Double
    ) -> AIMove? {
        guard moves.count > 1 else { return moves.first }

        var bestMove: AIMove?
        var bestScore = -Double.infinity

        for move in moves {
            var total = 0.0
            for simulation in 0..<monteCarloSimulationCount {
                var rng = MonteCarloRNG(seed: monteCarloSeed(
                    position: position,
                    state: state,
                    simulation: simulation
                ))
                total += simulateCurrentTrick(
                    candidate: move,
                    position: position,
                    hand: hand,
                    state: state,
                    evaluator: evaluator,
                    mode: mode,
                    rng: &rng
                )
            }

            let average = total / Double(monteCarloSimulationCount)
            let score = average + heuristicScore(move) * 0.03
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
        }

        return bestMove
    }


    static func monteCarloSeed(
        position: PlayerPosition,
        state: GameState,
        simulation: Int
    ) -> UInt64 {
        var seed = UInt64(position.rawValue + 1) &* 0x9E37_79B9
        seed ^= UInt64(state.roundNumber + 1) &* 0x85EB_CA6B
        seed ^= UInt64(state.completedTricks.count + 1) &* 0xC2B2_AE35
        seed ^= UInt64(state.currentTrick.plays.count + 1) &* 0x27D4_EB2F
        seed ^= UInt64(simulation + 1) &* 0xD3A2_646C
        return seed
    }


    static func simulateCurrentTrick(
        candidate: AIMove,
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        mode: TacticalMode = .normal,
        rng: inout MonteCarloRNG
    ) -> Double {
        // 守分 / 抢分 / 逼牌前，记录我方出手前的当前赢家（用于"阻止对手得分"判定）
        let opponentWinningBefore = !state.currentTrick.plays.isEmpty
            && evaluator.winner(of: state.currentTrick).team != position.team

        var trick = state.currentTrick
        guard !trick.plays.contains(where: { $0.position == position }) else { return -1000 }
        trick.plays.append((position: position, cards: candidate.cards))

        var simulatedHands = sampleHiddenHands(
            currentPosition: position,
            currentHand: hand,
            playedCandidate: candidate.cards,
            state: state,
            rng: &rng
        )

        var next = nextPosition(after: position)
        var safety = 0
        while trick.plays.count < 4 && safety < 4 {
            safety += 1
            if trick.plays.contains(where: { $0.position == next }) {
                next = nextPosition(after: next)
                continue
            }

            let nextHand = simulatedHands[next] ?? []
            let play = monteCarloFollowCards(
                hand: nextHand,
                trick: trick,
                evaluator: evaluator,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                rng: &rng
            )
            guard !play.isEmpty else { return -1000 }
            trick.plays.append((position: next, cards: play))
            let usedIDs = Set(play.map { $0.id })
            simulatedHands[next] = nextHand.filter { !usedIDs.contains($0.id) }
            next = nextPosition(after: next)
        }

        guard trick.plays.count == 4 else { return -1000 }
        let winner = evaluator.winner(of: trick)
        let points = trick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let myTeamWon = winner.team == position.team
        let ownPoints = candidate.cards.reduce(0) { $0 + $1.pointValue }
        let remainingHand = handAfterPlaying(candidate.cards, from: hand)
        let capturedPoints = myTeamWon ? Double(points) : -Double(points)
        let wonTrickValue = winner == position ? 1.0 : (myTeamWon ? 0.35 : -0.6)
        let simContext = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)
        let initiative = initiativeNeed(position: position, hand: remainingHand, state: state, ctx: simContext)
        let assetValue = remainingAssetValue(position: position, hand: remainingHand, state: state, ctx: simContext)
        let earlyTrumpPenalty = usedBigTrumpEarlyPenalty(
            state: state,
            position: position,
            hand: hand,
            move: candidate
        )
        let pressure = pointPressureBonus(totalPoints: points)
        let preservationDamp = pointPressureDamping(totalPoints: points)

        // ── 守分 / 抢分 / 逼牌模式：切换目标函数 ──────────────────────────
        // 此时点数目标主导评分，资产 / 早出大主只作轻微 tie-breaker，
        // 避免 assetValue / usedBigTrumpEarlyPenalty 让 AI 为了"省大主"而丢掉有分的墩。
        if isPointContestMode(mode) {
            return pointContestSimulationScore(
                candidate: candidate,
                trick: trick,
                winner: winner,
                position: position,
                points: points,
                myTeamWon: myTeamWon,
                ownPoints: ownPoints,
                opponentWinningBefore: opponentWinningBefore,
                assetValue: assetValue,
                earlyTrumpPenalty: earlyTrumpPenalty,
                ts: state.trumpSuit,
                tr: state.trumpRank
            )
        }

        var score = capturedPoints * 8 * pressure
            + wonTrickValue * (points > 0 ? 1.0 : 0.6)
            + assetValue * preservationDamp
            + (myTeamWon ? initiative * 0.12 : -initiative * 0.18)
            - earlyTrumpPenalty * 3 * preservationDamp

        if !myTeamWon && ownPoints > 0 { score -= Double(ownPoints) * 3.0 * pressure }
        if myTeamWon && candidate.cards.allSatisfy({ $0.pointValue == 0 }) && points == 0 { score += 0.2 }
        // 先手只保留通用资产完整性调整，避免 Pair First / Tractor First 等局部规则
        // 在 Monte Carlo 中重新压过资产分层。
        if candidate.kind != .slam, state.currentTrick.plays.isEmpty {
            let fragmentation =
                structureFragmentationCost(
                    candidate.cards,
                    hand: hand,
                    ts: state.trumpSuit,
                    tr: state.trumpRank
                )
                + mixedSlamFragmentationCost(
                    cards: candidate.cards,
                    hand: hand,
                    position: position,
                    ts: state.trumpSuit,
                    tr: state.trumpRank,
                    ctx: simContext
                )
            score -= fragmentation * 16 * preservationDamp
            score += wholeStructureControlValue(
                candidate.cards,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: simContext
            ) * 4
            score += leadInitiativeValue(
                hand: remainingHand,
                position: position,
                state: state,
                ctx: simContext,
                security: myTeamWon ? 0.8 : 0.3
            ) * 2
        }
        return score
    }


    /// 守分 / 抢分 / 逼牌模式下的单次模拟评分目标函数。
    /// 与 NORMAL 不同：点数摆动 / 赢墩 / 阻止对手得分 / 迫使对手付出代价 为主导项，
    /// assetValue 与 usedBigTrumpEarlyPenalty 仅作极轻 tie-breaker（0.05 权重）。
    ///
    /// score = expectedPointSwing*1.0 + trickWinProbability*0.5 + opponentPointPrevented*1.0
    ///       + opponentCostForced*0.3 − unnecessaryOverkillPenalty*0.2
    ///       − assetValue*0.05 − usedBigTrumpEarlyPenalty*0.05
    static func pointContestSimulationScore(
        candidate: AIMove,
        trick: Trick,
        winner: PlayerPosition,
        position: PlayerPosition,
        points: Int,
        myTeamWon: Bool,
        ownPoints: Int,
        opponentWinningBefore: Bool,
        assetValue: Double,
        earlyTrumpPenalty: Double,
        ts: Suit?,
        tr: Rank
    ) -> Double {
        let pressure = pointPressureBonus(totalPoints: points)

        // expectedPointSwing：本墩点数的净摆动（赢则 +，输则 −），按分压放大。
        let expectedPointSwing = (myTeamWon ? Double(points) : -Double(points)) * pressure

        // trickWinProbability：单次模拟为确定结果，多次平均即概率。归一到 ~10 量级。
        let trickWinProbability = (myTeamWon ? 1.0 : 0.0) * 10.0

        // opponentPointPrevented：我方从"对手原本领先"的局面里抢回，等于阻止对手拿走这些分。
        let opponentPointPrevented = (myTeamWon && opponentWinningBefore) ? Double(points) * pressure : 0.0

        // 赢家的最大牌强度（用于 opponentCostForced / overkill）
        let winningCards = trick.plays.first { $0.position == winner }?.cards ?? []
        let winRep = winningCards.isEmpty ? nil : maxCard(in: winningCards, ts: ts, tr: tr)

        // opponentCostForced：输掉时，迫使对手用越大的牌赢，损失越小（逼牌是战略收益）。
        let opponentCostForced: Double = {
            guard !myTeamWon, let winRep else { return 0.0 }
            return trumpStrengthFraction(winRep, ts: ts, tr: tr) * 10.0
        }()

        // unnecessaryOverkillPenalty：我方亲自赢下时，赢牌比"次大牌"高出越多，浪费越大。
        let overkill: Double = {
            guard myTeamWon, winner == position, let winRep,
                  CardComparator.isTrump(winRep, trumpSuit: ts, trumpRank: tr) else { return 0.0 }
            let othersMax = trick.plays
                .filter { $0.position != position }
                .flatMap { $0.cards }
                .map { cardStrength($0, ts: ts, tr: tr) }
                .max() ?? 0
            let mine = cardStrength(winRep, ts: ts, tr: tr)
            return max(0.0, Double(mine - othersMax)) / 100.0 * 10.0
        }()

        var score =
              expectedPointSwing * 1.0
            + trickWinProbability * 0.5
            + opponentPointPrevented * 1.0
            + opponentCostForced * 0.3
            - overkill * 0.2
            - assetValue * 0.05
            - earlyTrumpPenalty * 0.05

        // 守分铁律：输墩时绝不往里送自己的分牌。
        if !myTeamWon && ownPoints > 0 { score -= Double(ownPoints) * 4.0 * pressure }
        return score
    }


    static func sampleHiddenHands(
        currentPosition: PlayerPosition,
        currentHand: [Card],
        playedCandidate: [Card],
        state: GameState,
        rng: inout MonteCarloRNG
    ) -> [PlayerPosition: [Card]] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        // 各玩家已暴露的绝门（逻辑花色 key）
        let voids = AIContext.build(state: state, ts: ts, tr: tr).voidSuits
        let others = PlayerPosition.allCases.filter { $0 != currentPosition }

        // 已知牌：自己手牌 + 所有已出的牌（已结算 + 本墩）
        var knownCards = currentHand
        knownCards += state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }
        knownCards += state.currentTrick.plays.flatMap(\.cards)
        let declaredKnownByPlayer = declarationKnownCardsByPlayer(
            state: state,
            currentPosition: currentPosition,
            currentHand: currentHand
        )
        knownCards += declaredKnownByPlayer.values.flatMap { $0 }

        // 只有庄家本人埋的底牌、知道其内容；其余玩家不知道，底牌进入未知池
        let knowsKitty = currentPosition == state.dealerPosition
        if knowsKitty {
            knownCards += state.kitty
        }

        var unknownDeck = removeKnownFaces(from: Deck.doubleDeck(), knownCards: knownCards)

        // 非庄家也能推断部分底牌：若其余三家都已绝某逻辑花色，
        // 则该花色所有未知牌只可能在底牌里，不应发给任何对手
        if !knowsKitty {
            let inferredKittyKeys = Set(
                unknownDeck
                    .map { AIContext.suitKey($0, ts: ts, tr: tr) }
                    .filter { key in others.allSatisfy { voids[$0]?.contains(key) ?? false } }
            )
            if !inferredKittyKeys.isEmpty {
                unknownDeck.removeAll {
                    inferredKittyKeys.contains(AIContext.suitKey($0, ts: ts, tr: tr))
                }
            }
        }

        var hands: [PlayerPosition: [Card]] = [:]
        let playedIDs = Set(playedCandidate.map(\.id))
        hands[currentPosition] = currentHand.filter { !playedIDs.contains($0.id) }
        for pos in others {
            hands[pos] = declaredKnownByPlayer[pos] ?? []
        }

        var need: [PlayerPosition: Int] = [:]
        for pos in others {
            need[pos] = max(0, state.player(pos).hand.count - (hands[pos]?.count ?? 0))
        }

        // 非庄家视角中未知池还包含底牌。把底牌作为一个有明确容量、可接收
        // 任意花色的合法接收方，而不是在玩家约束冲突时才临时丢牌。
        let totalPlayerNeed = need.values.reduce(0, +)
        var kittyNeed = max(0, unknownDeck.count - totalPlayerNeed)

        // 绝门约束只依赖逻辑花色。按花色成组分配，把问题缩小成最多五组牌
        // 对三家手牌容量和底牌容量的整数分配；回溯保证不会为了终止而违约。
        let groupedDeck = Dictionary(grouping: unknownDeck) {
            AIContext.suitKey($0, ts: ts, tr: tr)
        }
        var suitGroups = groupedDeck.map { key, cards in
            (key: key, cards: cards)
        }
        suitGroups.sort { lhs, rhs in
            let lhsEligible = others.filter {
                !(voids[$0]?.contains(lhs.key) ?? false)
            }.count
            let rhsEligible = others.filter {
                !(voids[$0]?.contains(rhs.key) ?? false)
            }.count
            if lhsEligible != rhsEligible { return lhsEligible < rhsEligible }
            if lhs.cards.count != rhs.cards.count { return lhs.cards.count > rhs.cards.count }
            return lhs.key < rhs.key
        }
        for index in suitGroups.indices {
            suitGroups[index].cards.shuffle(using: &rng)
        }

        func possibleDistributions(
            cardCount: Int,
            eligiblePlayers: [PlayerPosition],
            kittyCapacity: Int
        ) -> [[Int]] {
            let recipientCount = eligiblePlayers.count + (kittyCapacity > 0 ? 1 : 0)
            guard recipientCount > 0 else { return [] }
            var result: [[Int]] = []
            var current = Array(repeating: 0, count: recipientCount)

            func build(_ recipientIndex: Int, _ remaining: Int) {
                if recipientIndex == recipientCount {
                    if remaining == 0 { result.append(current) }
                    return
                }

                let isKitty = recipientIndex == eligiblePlayers.count
                    && kittyCapacity > 0
                let capacity = isKitty
                    ? kittyCapacity
                    : (need[eligiblePlayers[recipientIndex]] ?? 0)
                let remainingCapacity = ((recipientIndex + 1)..<recipientCount).reduce(0) {
                    partial, index in
                    let indexIsKitty = index == eligiblePlayers.count
                        && kittyCapacity > 0
                    return partial + (indexIsKitty
                        ? kittyCapacity
                        : (need[eligiblePlayers[index]] ?? 0))
                }
                let minimum = max(0, remaining - remainingCapacity)
                let maximum = min(capacity, remaining)
                guard minimum <= maximum else { return }
                for amount in minimum...maximum {
                    current[recipientIndex] = amount
                    build(recipientIndex + 1, remaining - amount)
                }
                current[recipientIndex] = 0
            }

            build(0, cardCount)
            result.shuffle(using: &rng)
            return result
        }

        func assignGroup(_ groupIndex: Int) -> Bool {
            if groupIndex == suitGroups.count {
                return others.allSatisfy { (need[$0] ?? 0) == 0 } && kittyNeed == 0
            }

            let group = suitGroups[groupIndex]
            let eligiblePlayers = others.filter {
                (need[$0] ?? 0) > 0 && !(voids[$0]?.contains(group.key) ?? false)
            }
            let distributions = possibleDistributions(
                cardCount: group.cards.count,
                eligiblePlayers: eligiblePlayers,
                kittyCapacity: kittyNeed
            )

            for distribution in distributions {
                var cursor = 0
                for (index, player) in eligiblePlayers.enumerated() {
                    let amount = distribution[index]
                    if amount > 0 {
                        hands[player, default: []].append(
                            contentsOf: group.cards[cursor..<(cursor + amount)]
                        )
                        need[player, default: 0] -= amount
                        cursor += amount
                    }
                }

                let kittyIndex = eligiblePlayers.count
                let kittyAmount = distribution.count > kittyIndex
                    ? distribution[kittyIndex]
                    : 0
                kittyNeed -= kittyAmount

                if assignGroup(groupIndex + 1) { return true }

                kittyNeed += kittyAmount
                for (index, player) in eligiblePlayers.enumerated().reversed() {
                    let amount = distribution[index]
                    if amount > 0 {
                        hands[player]?.removeLast(amount)
                        need[player, default: 0] += amount
                    }
                }
            }
            return false
        }

        _ = assignGroup(0)

        return hands
    }


    static func declarationKnownCardsByPlayer(
        state: GameState,
        currentPosition: PlayerPosition,
        currentHand: [Card]
    ) -> [PlayerPosition: [Card]] {
        let playedIDs = Set(
            state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }.map(\.id)
                + state.currentTrick.plays.flatMap(\.cards).map(\.id)
        )
        let currentHandIDs = Set(currentHand.map(\.id))
        var result: [PlayerPosition: [Card]] = [:]
        var seen = Set<UUID>()

        for event in state.declarationEvents {
            for card in event.revealedCards {
                guard !playedIDs.contains(card.id),
                      !(event.declarer == currentPosition && currentHandIDs.contains(card.id)),
                      seen.insert(card.id).inserted else {
                    continue
                }
                result[event.declarer, default: []].append(card)
            }
        }
        return result
    }


    static func removeKnownFaces(from deck: [Card], knownCards: [Card]) -> [Card] {
        var remainingKnownCounts: [String: Int] = [:]
        for card in knownCards {
            remainingKnownCounts[faceKey(card), default: 0] += 1
        }

        var result: [Card] = []
        for card in deck {
            let key = faceKey(card)
            if let count = remainingKnownCounts[key], count > 0 {
                remainingKnownCounts[key] = count - 1
            } else {
                result.append(card)
            }
        }
        return result
    }


    static func faceKey(_ card: Card) -> String {
        "\(card.suit?.rawValue ?? "J")_\(card.rank.rawValue)"
    }


    static func monteCarloFollowCards(
        hand: [Card],
        trick: Trick,
        evaluator: TrickEvaluator,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        guard let leadCards = trick.leadCards else {
            return randomCards(from: hand, count: 1, rng: &rng)
        }

        let count = leadCards.count
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }

        let selected: [Card]
        if suitCards.count >= count {
            if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                let options = tractors(in: suitCards, pairCount: leadTractor.pairCount,
                                       trumpSuit: ts, trumpRank: tr)
                selected = options.randomElement(using: &rng)
                    ?? structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: leadTractor.pairCount,
                                                 trumpSuit: ts, trumpRank: tr)
            } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
                let options = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
                selected = options.randomElement(using: &rng)
                    ?? randomCards(from: suitCards, count: count, rng: &rng)
            } else if let slam = evaluator.slamInfo(of: leadCards) {
                selected = monteCarloSlamFollowCards(slam: slam, suitCards: suitCards,
                                                     count: count, ts: ts, tr: tr, rng: &rng)
            } else {
                selected = randomCards(from: suitCards, count: count, rng: &rng)
            }
        } else {
            let suitIDs = Set(suitCards.map(\.id))
            let rest = hand.filter { !suitIDs.contains($0.id) }
            selected = suitCards + randomCards(from: rest, count: count - suitCards.count, rng: &rng)
        }

        if evaluator.isValidPlay(selected: selected, hand: hand, leadCards: leadCards) {
            return selected
        }
        return monteCarloFallbackLegalFollow(hand: hand, leadCards: leadCards,
                                             evaluator: evaluator, ts: ts, tr: tr, rng: &rng)
    }


    static func monteCarloSlamFollowCards(
        slam: TrickEvaluator.SlamInfo,
        suitCards: [Card],
        count: Int,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        let pairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 } + slam.pairs.count
        let handPairs = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
        let requiredPairs = min(handPairs, pairSlots)
        guard requiredPairs > 0 else {
            return randomCards(from: suitCards, count: count, rng: &rng)
        }

        var selected = structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: requiredPairs,
                                                 trumpSuit: ts,
                                                 trumpRank: tr)
        if selected.count < count {
            let usedIDs = Set(selected.map(\.id))
            let rest = suitCards.filter { !usedIDs.contains($0.id) }
            selected += randomCards(from: rest, count: count - selected.count, rng: &rng)
        }
        return Array(selected.prefix(count))
    }


    static func monteCarloFallbackLegalFollow(
        hand: [Card],
        leadCards: [Card],
        evaluator: TrickEvaluator,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        let count = leadCards.count
        var samples: [[Card]] = []
        samples.append(weakestCards(from: hand, count: count, trumpSuit: ts, trumpRank: tr))
        samples.append(randomCards(from: hand, count: count, rng: &rng))

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }
        if suitCards.count >= count {
            samples.append(weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr))
            if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                samples.append(structuredSuitFollowCards(suitCards: suitCards,
                                                        neededPairs: leadTractor.pairCount,
                                                        trumpSuit: ts,
                                                        trumpRank: tr))
            }
            if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil,
               let pair = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).first {
                samples.append(pair)
            }
        } else {
            let suitIDs = Set(suitCards.map(\.id))
            let rest = hand.filter { !suitIDs.contains($0.id) }
            samples.append(suitCards + weakestCards(from: rest, count: count - suitCards.count,
                                                    trumpSuit: ts, trumpRank: tr))
        }

        return samples.first {
            $0.count == count && evaluator.isValidPlay(selected: $0, hand: hand, leadCards: leadCards)
        } ?? Array(hand.prefix(count))
    }


    static func randomCards(
        from cards: [Card],
        count: Int,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.shuffled(using: &rng).prefix(count))
    }


    static func nextPosition(after position: PlayerPosition) -> PlayerPosition {
        PlayerPosition(rawValue: (position.rawValue + 1) % 4)!
    }
}
