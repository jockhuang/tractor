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
        let samplingMemo = HiddenSamplingMemo()
        let context = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)

        // 所有候选共用同一组合法世界，结构约束拒绝抽样只做一次。
        let worlds = (0..<monteCarloSimulationCount).compactMap { simulation -> [PlayerPosition: [Card]]? in
            var rng = MonteCarloRNG(seed: monteCarloSeed(position: position, state: state, simulation: simulation))
            let hands = sampleHiddenHands(currentPosition: position, currentHand: hand,
                playedCandidate: [], state: state, rng: &rng, maximumAttempts: 16, memo: samplingMemo)
            return hands.isEmpty ? nil : hands
        }
        guard !worlds.isEmpty else { return moves.max { heuristicScore($0) < heuristicScore($1) } }

        for move in moves {
            var total = 0.0
            for (simulation, world) in worlds.enumerated() {
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
                    rng: &rng,
                    sampledHands: world
                )
            }

            let average = total / Double(worlds.count)
            let score = average + heuristicScore(move) * 0.03
                + fallbackTrumpTransferPreference(move, position: position, hand: hand, state: state, ctx: context)
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
        rng: inout MonteCarloRNG,
        sampledHands: [PlayerPosition: [Card]]? = nil
    ) -> Double {
        // 守分 / 抢分 / 逼牌前，记录我方出手前的当前赢家（用于"阻止对手得分"判定）
        let opponentWinningBefore = !state.currentTrick.plays.isEmpty
            && evaluator.winner(of: state.currentTrick).team != position.team
        let baseContext = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)

        var trick = state.currentTrick
        guard !trick.plays.contains(where: { $0.position == position }) else { return -1000 }
        trick.plays.append((position: position, cards: candidate.cards))

        var simulatedHands = sampledHands ?? sampleHiddenHands(
            currentPosition: position,
            currentHand: hand,
            playedCandidate: candidate.cards,
            state: state,
            rng: &rng
        )
        simulatedHands[position] = handAfterPlaying(candidate.cards, from: hand)

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
                position: next,
                evaluator: evaluator,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                rng: &rng,
                context: baseContext.observing(trick, ts: state.trumpSuit, tr: state.trumpRank)
            )
            guard !play.isEmpty else { return -1000 }
            trick.plays.append((position: next, cards: play))
            let usedIDs = Set(play.map { $0.id })
            simulatedHands[next] = nextHand.filter { !usedIDs.contains($0.id) }
            next = nextPosition(after: next)
        }

        guard trick.plays.count == 4 else { return -1000 }
        let winner = evaluator.winner(of: trick)
        var points = trick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let myTeamWon = winner.team == position.team
        let ownPoints = candidate.cards.reduce(0) { $0 + $1.pointValue }
        let remainingHand = handAfterPlaying(candidate.cards, from: hand)
        if remainingHand.isEmpty && simulatedHands.values.allSatisfy({ $0.isEmpty }),
           winner.team != state.dealerTeamIdx {
            // 非庄家只能用本次抽样世界的剩余牌推导底牌，不能读取真实底牌。
            let kitty: [Card]
            if position == state.dealerPosition { kitty = state.kitty }
            else {
                let played = state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }
                    + trick.plays.flatMap(\.cards)
                kitty = removeKnownFaces(from: referenceDeck, knownCards: played)
            }
            if kitty.count == 8 { points += kitty.reduce(0) { $0 + $1.pointValue } * 2 }
        }
        let capturedPoints = myTeamWon ? Double(points) : -Double(points)
        let wonTrickValue = winner == position ? 1.0 : (myTeamWon ? 0.35 : -0.6)
        let simContext = baseContext.observing(trick, ts: state.trumpSuit, tr: state.trumpRank)
        let continuation = simulateContinuation(hands: simulatedHands, leader: winner,
            position: position, state: state, context: simContext, rng: &rng)
        let futureHand = continuation.hands[position] ?? remainingHand
        let initiative = initiativeNeed(position: position, hand: futureHand, state: state, ctx: continuation.context)
        let assetValue = remainingAssetValue(position: position, hand: futureHand, state: state, ctx: continuation.context)
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
            let fragmentation = structureFragmentationCost(candidate.cards, hand: hand,
                ts: state.trumpSuit, tr: state.trumpRank, ctx: baseContext)
            let structureDamp = myTeamWon ? preservationDamp : 1.0
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
            ) - fragmentation * 2 * structureDamp + continuation.score / 8
        }

        var score = capturedPoints * 8 * pressure + continuation.score
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
        } else if !state.currentTrick.plays.isEmpty {
            // 跟牌同样支付当前拆结构成本。仅靠续演结束后的剩余资产，
            // 会把“现在拆对”与“假想两墩后才拆对”视为相同，抹掉这次损耗。
            // 与争分模式中的 fragmentation×2（分数单位）保持相同量级；
            // 大分墩仍按压力衰减，允许为得分牺牲结构。
            // 对手收走更多分不能成为廉价拆对的理由；仅在本队拿到收益的
            // 世界中放宽成本，避免对手后手垫分把无效跟牌的损耗也打折。
            let structureDamp = myTeamWon ? preservationDamp : 1.0
            score -= structureFragmentationCost(candidate.cards, hand: hand,
                ts: state.trumpSuit, tr: state.trumpRank, ctx: baseContext) * 16 * structureDamp
        }
        return score
    }

    struct ContinuationResult {
        let score: Double
        let hands: [PlayerPosition: [Card]]
        let context: AIContext
    }

    /// 有限两墩续演：包含对家接手后领副牌、失去牌权后的回合及末墩底分。
    /// 每位模拟玩家的选择只读自己的牌与公开记忆，不偷看抽样世界中别人的手牌。
    static func simulateContinuation(
        hands initialHands: [PlayerPosition: [Card]], leader initialLeader: PlayerPosition,
        position: PlayerPosition, state: GameState, context initialContext: AIContext,
        rng: inout MonteCarloRNG, depth: Int = 2
    ) -> ContinuationResult {
        var hands = initialHands
        var leader = initialLeader
        var context = initialContext
        var score = 0.0
        let evaluator = TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        for step in 0..<max(0, depth) {
            let counts = PlayerPosition.allCases.map { hands[$0]?.count ?? 0 }
            // 稀疏测试局面不代表真实的后续手牌，不能凭空续演。
            guard let count = counts.first, count > 0, counts.allSatisfy({ $0 == count }) else { break }
            var trick = Trick(leadPosition: leader)
            let lead = monteCarloLeadCards(hand: hands[leader] ?? [], position: leader,
                context: context, ts: state.trumpSuit, tr: state.trumpRank)
            guard evaluator.isValidLead(lead) else { break }
            trick.plays.append((leader, lead))
            hands[leader] = handAfterPlaying(lead, from: hands[leader] ?? [])
            var next = nextPosition(after: leader)
            for _ in 0..<3 {
                let hand = hands[next] ?? []
                let play = monteCarloFollowCards(hand: hand, trick: trick, position: next,
                    evaluator: evaluator, ts: state.trumpSuit, tr: state.trumpRank, rng: &rng,
                    context: context.observing(trick, ts: state.trumpSuit, tr: state.trumpRank))
                guard evaluator.isValidPlay(selected: play, hand: hand, leadCards: lead) else {
                    return ContinuationResult(score: score, hands: initialHands, context: initialContext)
                }
                trick.plays.append((next, play))
                hands[next] = handAfterPlaying(play, from: hand)
                next = nextPosition(after: next)
            }
            leader = evaluator.winner(of: trick)
            context = context.observing(trick, ts: state.trumpSuit, tr: state.trumpRank)
            var points = trick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
            if hands.values.allSatisfy({ $0.isEmpty }), leader.team != state.dealerTeamIdx {
                let kitty = position == state.dealerPosition ? state.kitty
                    : removeKnownFaces(from: referenceDeck, knownCards: context.playedCards)
                if kitty.count == 8 { points += kitty.reduce(0) { $0 + $1.pointValue } * 2 }
            }
            let discount = pow(0.65, Double(step + 1))
            score += (leader.team == position.team ? 1 : -1)
                * Double(points) * 8 * pointPressureBonus(totalPoints: points) * discount
        }
        return ContinuationResult(score: score, hands: hands, context: context)
    }

    static func monteCarloLeadCards(
        hand: [Card], position: PlayerPosition, context: AIContext, ts: Suit?, tr: Rank
    ) -> [Card] {
        guard !hand.isEmpty else { return [] }
        let paired = pairedCardIDs(in: hand, trumpSuit: ts, trumpRank: tr)
        var options = hand.filter { !paired.contains($0.id) }.map { [$0] }
        options += pairs(in: hand, trumpSuit: ts, trumpRank: tr)
        for suit in Set(hand.map({ CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) })) {
            let suited = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            let pairCount = pairs(in: suited, trumpSuit: ts, trumpRank: tr).count
            if pairCount >= 2 {
                for count in 2...pairCount { options += tractors(in: suited, pairCount: count, trumpSuit: ts, trumpRank: tr) }
            }
        }
        options += findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: position.team,
            ctx: context, position: position)
        let protected = options.filter { cards in
            !(hand.count > 6 && cards.contains { isBigTrump($0, ts: ts, tr: tr) })
        }
        if !protected.isEmpty { options = protected }
        func value(_ cards: [Card]) -> Double {
            let first = cards[0]
            let trump = CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr)
            let points = Double(cards.reduce(0) { $0 + $1.pointValue })
            let whole = wholeStructureControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: context)
            let knownWinner = trump
                ? noUnknownHigherTrumpThan(maxCard(in: cards, ts: ts, tr: tr), hand: hand, ts: ts, tr: tr, ctx: context)
                : (cards.count == 1 ? context.isEffectivelyBiggest(first, ts: ts, tr: tr, hand: hand)
                    : isEffectivelyBiggestPair(maxCard(in: cards, ts: ts, tr: tr), hand: hand, ctx: context, ts: ts, tr: tr))
            var score = whole * 22 + Double(cards.count) * 4
                + (knownWinner ? 45 + points * 4 : -points * 2)
                - structureFragmentationCost(cards, hand: hand, ts: ts, tr: tr) * 18
            if trump {
                score -= Double(cards.reduce(0) { $0 + cardStrength($1, ts: ts, tr: tr) }) * 0.18
                if cards.count == 1 && !isBigTrump(first, ts: ts, tr: tr) {
                    let partner = PlayerPosition(rawValue: (position.rawValue + 2) % 4)!
                    if !context.isVoid(partner, key: "TRUMP") { score += 12 }
                }
            } else {
                score += Double(first.rank.rawValue) * 0.7
                score += clearsSideSuitForLead(cards, hand: hand, ts: ts, tr: tr) ? 10 : 0
                let voids = context.voidEnemies(myTeam: position.team, key: first.suit!.rawValue)
                    .filter { !context.isVoid($0, key: "TRUMP") }.count
                score -= Double(voids) * (cards.count == 1 ? 40 : 24)
            }
            return score
        }
        return options.map { (cards: $0, value: value($0)) }.max { $0.value < $1.value }?.cards
            ?? [hand.min { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }!]
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
            + assetValue * 0.05
            - earlyTrumpPenalty * 0.05

        // 守分铁律：输墩时绝不往里送自己的分牌。
        if !myTeamWon && ownPoints > 0 { score -= Double(ownPoints) * 4.0 * pressure }
        return score
    }


    struct PublicFollowConstraint {
        let position: PlayerPosition
        let lead: [Card]
        let selected: [Card]
        let laterCards: [Card]
    }

    /// 单次决策内复用条件分布的组合计数，不保存跨局或跨玩家的可变状态。
    final class HiddenSamplingMemo {
        var signature = ""
        var ways: [String: Double] = [:]
    }

    static func publicFollowConstraints(state: GameState) -> [PublicFollowConstraint] {
        let evaluator = TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        var later: [PlayerPosition: [Card]] = [:]
        var constraints: [PublicFollowConstraint] = []
        for trick in (state.completedTricks + [state.currentTrick]).reversed() {
            if let lead = trick.leadCards, lead.count > 1 {
                for play in trick.plays.dropFirst() {
                    // 完整跟上同型对子/拖拉机并未暴露结构短缺；其他情况用
                    // 规则验证历史手牌，涵盖无对、连对不足、甩牌对子槽不足。
                    let fullPair = isPairMove(lead, ts: state.trumpSuit, tr: state.trumpRank)
                        && isPairMove(play.cards, ts: state.trumpSuit, tr: state.trumpRank)
                    let fullTractor = tractorInfo(of: lead, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) != nil
                        && tractorInfo(of: play.cards, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) != nil
                    if !fullPair && !fullTractor,
                       play.cards.filter({ evaluator.cardSuit($0) == evaluator.dominantSuit(of: lead) }).count == lead.count {
                        constraints.append(PublicFollowConstraint(position: play.position,
                            lead: lead, selected: play.cards, laterCards: later[play.position] ?? []))
                    }
                }
            }
            for play in trick.plays { later[play.position, default: []] += play.cards }
        }
        return constraints
    }

    static func respectsPublicFollowConstraints(
        _ hands: [PlayerPosition: [Card]], constraints: [PublicFollowConstraint],
        excluding position: PlayerPosition, evaluator: TrickEvaluator
    ) -> Bool {
        constraints.filter { $0.position != position }.allSatisfy { constraint in
            evaluator.isValidPlay(selected: constraint.selected,
                hand: (hands[constraint.position] ?? []) + constraint.laterCards + constraint.selected,
                leadCards: constraint.lead)
        }
    }

    static func sampleHiddenHands(
        currentPosition: PlayerPosition, currentHand: [Card], playedCandidate: [Card],
        state: GameState, rng: inout MonteCarloRNG, maximumAttempts: Int = 128,
        memo: HiddenSamplingMemo? = nil
    ) -> [PlayerPosition: [Card]] {
        let constraints = publicFollowConstraints(state: state)
        let evaluator = TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        let memo = memo ?? HiddenSamplingMemo()
        for _ in 0..<(constraints.isEmpty ? 1 : max(1, maximumAttempts)) {
            let hands = sampleVoidConstrainedHands(currentPosition: currentPosition,
                currentHand: currentHand, playedCandidate: playedCandidate, state: state, rng: &rng, memo: memo)
            if hands.isEmpty { return [:] }
            if respectsPublicFollowConstraints(hands, constraints: constraints,
                excluding: currentPosition, evaluator: evaluator) { return hands }
        }
        // 不伪造违反公开信息的世界；预算耗尽时由调用者使用启发式兜底。
        return [:]
    }

    static func sampleVoidConstrainedHands(
        currentPosition: PlayerPosition,
        currentHand: [Card],
        playedCandidate: [Card],
        state: GameState,
        rng: inout MonteCarloRNG,
        memo sharedMemo: HiddenSamplingMemo? = nil
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

        var unknownDeck = removeKnownFaces(from: referenceDeck, knownCards: knownCards)

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
            need[pos] = max(0, state.handCount(for: pos) - (hands[pos]?.count ?? 0))
        }

        // 非庄家视角中未知池还包含底牌。把底牌作为一个有明确容量、可接收
        // 任意花色的合法接收方，而不是在玩家约束冲突时才临时丢牌。
        let totalPlayerNeed = need.values.reduce(0, +)
        let kittyNeed = max(0, unknownDeck.count - totalPlayerNeed)

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

        // 对每个“花色数量方案”按它对应的真实牌张排列数加权。
        // 组合计数 + 后续可行完成数确保有绝门约束时仍是条件均匀抽样。
        let initialCapacities = others.map { need[$0] ?? 0 } + [kittyNeed]
        var factorial = [1.0]
        for n in 1...108 { factorial.append(factorial[n - 1] * Double(n)) }
        func choose(_ n: Int, _ k: Int) -> Double {
            guard k >= 0 && k <= n else { return 0 }
            return factorial[n] / factorial[k] / factorial[n - k]
        }
        let memo = sharedMemo ?? HiddenSamplingMemo()
        let signature = initialCapacities.map(String.init).joined(separator: ",") + suitGroups.map { group in
            group.key + ":\(group.cards.count):" + others.map {
                (voids[$0]?.contains(group.key) ?? false) ? "0" : "1"
            }.joined()
        }.joined(separator: ";")
        if memo.signature != signature { memo.signature = signature; memo.ways.removeAll(keepingCapacity: true) }
        func distributions(_ group: Int, _ caps: [Int]) -> [[Int]] {
            let eligible = others.map { !(voids[$0]?.contains(suitGroups[group].key) ?? false) } + [true]
            var result: [[Int]] = []
            var allocation = Array(repeating: 0, count: caps.count)
            func build(_ seat: Int, _ left: Int) {
                if seat == caps.count {
                    if left == 0 { result.append(allocation) }
                    return
                }
                let maximum = eligible[seat] ? min(left, caps[seat]) : 0
                let restCapacity = caps.indices.dropFirst(seat + 1).reduce(0) {
                    $0 + (eligible[$1] ? caps[$1] : 0)
                }
                let minimum = max(0, left - restCapacity)
                guard minimum <= maximum else { return }
                for amount in minimum...maximum {
                    allocation[seat] = amount
                    build(seat + 1, left - amount)
                }
            }
            build(0, suitGroups[group].cards.count)
            return result
        }
        func ways(_ group: Int, _ caps: [Int]) -> Double {
            if group == suitGroups.count { return caps.allSatisfy { $0 == 0 } ? 1 : 0 }
            let key = "\(group):" + caps.map(String.init).joined(separator: ",")
            if let cached = memo.ways[key] { return cached }
            // 剩下花色都不受约束时，用多项式系数直接结算，避免展开无约束状态。
            let unrestricted = suitGroups[group...].allSatisfy { item in
                others.indices.allSatisfy { caps[$0] == 0 || !(voids[others[$0]]?.contains(item.key) ?? false) }
            }
            if unrestricted {
                let remaining = suitGroups[group...].reduce(0) { $0 + $1.cards.count }
                guard remaining == caps.reduce(0, +) else { return 0 }
                let result = suitGroups[group...].reduce(factorial[remaining]) { $0 / factorial[$1.cards.count] }
                memo.ways[key] = result
                return result
            }
            var total = 0.0
            for allocation in distributions(group, caps) {
                let next = zip(caps, allocation).map { $0 - $1 }
                let weight = caps.indices.reduce(1.0) { $0 * choose(caps[$1], allocation[$1]) }
                total += weight * ways(group + 1, next)
            }
            memo.ways[key] = total
            return total
        }
        var capacities = initialCapacities
        for group in suitGroups.indices {
            if suitGroups[group...].allSatisfy({ item in
                others.indices.allSatisfy { capacities[$0] == 0 || !(voids[others[$0]]?.contains(item.key) ?? false) }
            }) {
                var remaining = suitGroups[group...].flatMap(\.cards)
                remaining.shuffle(using: &rng)
                var cursor = 0
                for seat in others.indices {
                    let amount = capacities[seat]
                    hands[others[seat], default: []] += remaining[cursor..<(cursor + amount)]
                    cursor += amount
                }
                return hands
            }
            let allocations = distributions(group, capacities)
            let weights = allocations.map { allocation -> Double in
                let next = zip(capacities, allocation).map { $0 - $1 }
                return capacities.indices.reduce(1.0) {
                    $0 * choose(capacities[$1], allocation[$1])
                } * ways(group + 1, next)
            }
            let total = weights.reduce(0, +)
            guard total > 0 else { return [:] } // 不返回残缺的抽样手牌
            var draw = Double.random(in: 0..<total, using: &rng)
            var selected = weights.lastIndex(where: { $0 > 0 })!
            for index in weights.indices {
                draw -= weights[index]
                if draw < 0 { selected = index; break }
            }
            let allocation = allocations[selected]
            var cursor = 0
            for seat in others.indices {
                let amount = allocation[seat]
                hands[others[seat], default: []] += suitGroups[group].cards[cursor..<(cursor + amount)]
                cursor += amount
            }
            capacities = zip(capacities, allocation).map { $0 - $1 }
        }

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
        hand: [Card], trick: Trick, position: PlayerPosition? = nil,
        evaluator: TrickEvaluator, ts: Suit?, tr: Rank, rng: inout MonteCarloRNG,
        context: AIContext? = nil
    ) -> [Card] {
        guard let lead = trick.leadCards else { return Array(hand.prefix(1)) }
        let seat = position ?? nextPosition(after: trick.plays.last!.position)
        let count = lead.count
        let suit = evaluator.dominantSuit(of: lead)
        let suited = hand.filter { evaluator.cardSuit($0) == suit }
        var options: [[Card]] = []
        if count == 1 {
            options = (suited.isEmpty ? hand : suited).map { [$0] }
        } else if suited.count >= count {
            options.append(structuredSuitFollowCards(suitCards: suited, neededPairs: count / 2,
                                                      trumpSuit: ts, trumpRank: tr))
            if let tractor = tractorInfo(of: lead, trumpSuit: ts, trumpRank: tr) {
                options += tractors(in: suited, pairCount: tractor.pairCount, trumpSuit: ts, trumpRank: tr)
            } else if isPairMove(lead, ts: ts, tr: tr) {
                options += pairs(in: suited, trumpSuit: ts, trumpRank: tr)
            }
            if let slam = evaluator.slamInfo(of: lead) {
                options.append(monteCarloSlamFollowCards(slam: slam, suitCards: suited,
                                                         count: count, ts: ts, tr: tr, rng: &rng))
            }
            options.append(partnerSupportCards(from: suited, count: count, trumpSuit: ts, trumpRank: tr))
            options.append(supportingSuitFollowCards(from: suited, leadCards: lead, evaluator: evaluator, ts: ts, tr: tr))
        } else {
            let ids = Set(suited.map(\.id))
            let rest = hand.filter { !ids.contains($0.id) }
            options.append(suited + weakestCards(from: rest, count: count - suited.count, trumpSuit: ts, trumpRank: tr))
            options.append(suited + partnerSupportCards(from: rest, count: count - suited.count, trumpSuit: ts, trumpRank: tr))
            if suited.isEmpty {
                let trump = trumpCards(in: hand, ts: ts, tr: tr)
                if let tractor = tractorInfo(of: lead, trumpSuit: ts, trumpRank: tr) {
                    options += tractors(in: trump, pairCount: tractor.pairCount, trumpSuit: ts, trumpRank: tr)
                } else if isPairMove(lead, ts: ts, tr: tr) {
                    options += pairs(in: trump, trumpSuit: ts, trumpRank: tr)
                } else if let slam = evaluator.slamInfo(of: lead),
                          let winning = trick.plays.first(where: { $0.position == evaluator.winner(of: trick) })?.cards,
                          let combo = buildMatchingSlamTrump(slam: slam, trumpCards: trump,
                                                             winningCards: winning, ts: ts, tr: tr) {
                    options.append(combo)
                }
            }
        }
        let legal = options.filter { evaluator.isValidPlay(selected: $0, hand: hand, leadCards: lead) }
        let before = evaluator.winner(of: trick)
        let points = trick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let memory = (context ?? AIContext(playedCards: [], knownCards: [], knownCardsByPlayer: [:],
            voidSuits: [:], isLastPlayer: false)).observing(trick, ts: ts, tr: tr)
        func score(_ cards: [Card]) -> Double {
            var test = trick
            test.plays.append((position: seat, cards: cards))
            let winner = evaluator.winner(of: test)
            let ownPoints = cards.reduce(0) { $0 + $1.pointValue }
            let strength = cards.reduce(0) { $0 + cardStrength($1, ts: ts, tr: tr) }
            var keep = winner.team == seat.team ? 1.0 : 0.0
            if keep > 0 {
                let played = Set(test.plays.map(\.position))
                let winning = test.plays.first { $0.position == winner }!.cards
                for enemy in PlayerPosition.allCases where enemy.team != seat.team && !played.contains(enemy) {
                    let risk = count == 1
                        ? playerBeatProbability(winning[0], by: enemy, leadSuit: suit,
                            hand: hand, ts: ts, tr: tr, ctx: memory)
                        : structuredOvertakeProbability(trick: test, opponent: enemy, hand: hand,
                            position: seat, state: nil, evaluator: evaluator, ctx: memory)
                    keep *= 1 - risk
                }
            }
            var value = Double(points + ownPoints) * 8 * (2 * keep - 1) + keep * 6
                - Double(ownPoints) * 4 * (1 - keep)
            value -= Double(strength) * 0.12
            value -= structureFragmentationCost(cards, hand: hand, ts: ts, tr: tr) * 3
            if before.team == seat.team && winner == seat { value -= 12 }
            return value
        }
        return legal.map { (cards: $0, score: score($0)) }.max { $0.score < $1.score }?.cards
            ?? monteCarloFallbackLegalFollow(hand: hand, leadCards: lead, evaluator: evaluator,
                                              ts: ts, tr: tr, rng: &rng)
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
