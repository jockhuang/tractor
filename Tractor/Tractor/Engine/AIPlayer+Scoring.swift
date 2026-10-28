import Foundation

// MARK: - AIPlayer 评分 / 评估辅助（结构性拆分，逻辑未改）

extension AIPlayer {


    // ── 点数压力：跟牌与 Monte Carlo 共用的分数口径 ────────────────────
    static func pointPressureBonus(totalPoints: Int) -> Double {
        if totalPoints >= 25 { return 2.2 }
        if totalPoints >= 20 { return 1.8 }
        if totalPoints >= 15 { return 1.45 }
        if totalPoints >= 10 { return 1.2 }
        return 1.0
    }


    static func pointPressureDamping(totalPoints: Int) -> Double {
        if totalPoints >= 25 { return 0.25 }
        if totalPoints >= 20 { return 0.35 }
        if totalPoints >= 15 { return 0.50 }
        if totalPoints >= 10 { return 0.70 }
        if totalPoints >= 5 { return 0.85 }
        return 1.0
    }


    // ── 概念 3：Structure Integrity（统一的拆结构代价，取代 5 个旧拆罚函数）──
    static func structureFragmentationCost(
        _ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext? = nil
    ) -> Double {
        let sel = Set(cards.map(\.id))
        var cost = 0.0
        // 拆对子：按对子价值分级
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { sel.contains($0.id) }.count
            guard used == 1, let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            let knownSideControl = ctx.map {
                !CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr)
                    && isEffectivelyBiggestPair(rep, hand: hand, ctx: $0, ts: ts, tr: tr)
            } ?? false
            // 公开信息已证明最大时，33与KK都是控制对子，不能仍只按裸rank
            // 计一次性损耗。是否为大分牺牲该对，继续由点数压力衰减决定。
            cost += pairAssetWeight(rep, ts: ts, tr: tr) + (knownSideControl ? 2 : 0)
        }
        // 拆连对：额外代价，体现「AAKK 作为一个拖拉机」
        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { sel.contains($0.id) }.count
                if used > 0 && used < tractor.count { cost += 1.2 }
            }
        }
        return cost
    }


    /// 混合甩牌（如 AAK = 对子 + 单张）也是结构资产。
    /// 若只打出安全混合甩牌的一部分（例如从 AAK 中先出 AA），这里统一按结构碎片化扣分。
    static func mixedSlamFragmentationCost(
        cards: [Card],
        hand: [Card],
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        let selected = Set(cards.map(\.id))
        var cost = 0.0
        for slam in findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: position.team, ctx: ctx, position: position) {
            guard isMixedStructureSlam(slam, ts: ts, tr: tr) else { continue }
            let slamIDs = Set(slam.map(\.id))
            guard selected != slamIDs else { continue }
            let overlap = selected.intersection(slamIDs).count
            guard overlap > 0 && overlap < slam.count else { continue }

            let structureValue = max(
                mixedSlamControlValue(slam, hand: hand, ts: ts, tr: tr, ctx: ctx),
                0.8
            )
            let fractionUsed = Double(overlap) / Double(slam.count)
            cost = max(cost, structureValue * (0.55 + fractionUsed * 0.45))
        }
        return cost
    }


    /// 对子资产分级（统一口径：强对/分对/普通对）。
    static func pairAssetWeight(_ rep: Card, ts: Suit?, tr: Rank) -> Double {
        if rep.rank == .bigJoker || rep.rank == .smallJoker || rep.rank == tr || rep.rank == .ace { return 1.0 }
        if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) { return 0.9 }   // 主牌强对子
        return 0.25 + Double(rep.rank.rawValue) / 28.0
    }


    /// 整出完整结构（连对/对子）的正向控制价值；无主局更高。
    /// 关键：只有「绝对赢」的结构才算真正的控制——非绝对赢的对子/连对会被对手压住，
    /// 故大幅打折，避免 AI 先领一个非绝对赢的对子（再去出 A）这种浪费控制权的下法。
    static func wholeStructureControlValue(
        _ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext
    ) -> Double {
        let dominant = leadStructureDominant(cards, hand: hand, ts: ts, tr: tr, ctx: ctx)
        if tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) != nil {
            let base = ts == nil ? 1.6 : 1.0
            return dominant ? base : base * 0.35
        }
        if isPairMove(cards, ts: ts, tr: tr),
           let rep = pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) {
            let base = pairAssetWeight(rep, ts: ts, tr: tr)
            let value = ts == nil ? base * 1.2 : base * 0.7
            return dominant ? value : value * 0.3
        }
        return 0
    }


    /// 完整混合甩牌的结构控制价值。AAK 这类“对子 + 最大单张”不应被当作普通 slam 小加分，
    /// 而应和对子/连对一样作为完整结构参与 Structure Integrity。
    static func mixedSlamControlValue(_ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        guard isMixedStructureSlam(cards, ts: ts, tr: tr) else { return 0 }

        let pairedIDs = pairedCardIDs(in: cards, trumpSuit: ts, trumpRank: tr)
        let pairValue = pairs(in: cards, trumpSuit: ts, trumpRank: tr)
            .compactMap { pairRepresentative(of: $0, trumpSuit: ts, trumpRank: tr) }
            .reduce(0.0) { $0 + pairAssetWeight($1, ts: ts, tr: tr) }
        let tractorValue = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr)
            .map { Double($0.pairCount) * 0.8 } ?? 0
        let topSingleValue = cards
            .filter { !pairedIDs.contains($0.id) }
            .reduce(0.0) { partial, card in
                if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                    return partial + (isBigTrump(card, ts: ts, tr: tr) ? 0.45 : 0.2)
                }
                return partial + ((card.rank == .ace
                    || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand)) ? 0.35 : 0.1)
            }

        let noTrumpBoost = ts == nil ? 0.25 : 0
        return min(2.2, 0.35 + pairValue + tractorValue + topSingleValue + noTrumpBoost)
    }


    static func isMixedStructureSlam(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard cards.count >= 3,
              tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) == nil,
              !isPairMove(cards, ts: ts, tr: tr) else { return false }
        let pairSlots = pairs(in: cards, trumpSuit: ts, trumpRank: tr).count
        guard pairSlots > 0 else { return false }
        return pairSlots * 2 < cards.count
    }


    /// 该结构（对子/连对/单张）当前是否「绝对赢」：
    /// 副牌用对子级别的最大判定（`isEffectivelyBiggestPair`，KK 在一张 A 已现时也算最大对）；
    /// 主牌则要求大主或牌力 ≥ K。
    static func leadStructureDominant(
        _ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext
    ) -> Bool {
        guard let top = cards.max(by: { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }) else {
            return false
        }
        if CardComparator.isTrump(top, trumpSuit: ts, trumpRank: tr) {
            return isBigTrump(top, ts: ts, tr: tr)
                || CardComparator.trumpWeight(top, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue
        }
        return isEffectivelyBiggestPair(top, hand: hand, ctx: ctx, ts: ts, tr: tr)
    }


    // ── 概念 5：Initiative Value（能赢且有可续手资产时，保住出牌权才有意义）──
    static func leadInitiativeValue(
        hand: [Card], position: PlayerPosition, state: GameState, ctx: AIContext, security: Double
    ) -> Double {
        guard security >= 0.55 else { return 0 }
        return min(initiativeNeed(position: position, hand: hand, state: state, ctx: ctx) / 220.0, 1.0)
    }


    static func scoreFollow(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let partnerWinningBefore = currentWinner.team == position.team
        let trickPoints = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        let candidateWins = candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator)
        let winClass = classifyFollowMove(
            move.cards,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
        let usesTrump = move.cards.contains {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        let trickSecureBefore = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let trickSecureAfter = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator,
            ctx: ctx, candidateCards: move.cards
        )
        let breakPenalty = structureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr)
        let strongBreakPenalty = strongStructureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr)
        let clearsSuit = clearsLogicalSuit(cards: move.cards, hand: hand, evaluator: evaluator)
        let totalPoints = trickPoints + playedPoints
        let preservationDamp = pointPressureDamping(totalPoints: totalPoints)
        let opponentCapture = opponentTrickWinProbability(
            move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
        )

        var score = 0.0
        // 自己不能压过队友，不等于本队不能拿分。未严格锁定的支持牌按预期
        // 团队得分计算，避免把“无法亲自赢墩”误当成“垫分必丢”。
        if partnerWinningBefore && !candidateWins && !trickSecureBefore {
            score += Double(playedPoints) * 5.5 * pointPressureBonus(totalPoints: totalPoints)
                * (1 - 2 * opponentCapture)
        } else {
            score += followPointSwingScore(
                winClass: winClass,
                partnerWinningBefore: partnerWinningBefore,
                trickSecureBefore: trickSecureBefore,
                trickSecureAfter: trickSecureAfter,
                trickPoints: trickPoints,
                playedPoints: playedPoints,
                isLastPlayer: ctx.isLastPlayer
            )
        }

        // ── 统一的「用主控墩」决策（Trump Control）──────────────────────
        // 吊主跟牌 / 绝门将吃 / 盖吃对手将牌 / 帮队友锁定 / 抢回出牌权——
        // 所有「是否花主牌去拿、保、抢这一墩」的判断都走同一个模型，避免各处零散加减分互相冲突。
        // 非主走法才用通用赢墩分类分，避免与模型重复计分。
        if usesTrump {
            score += trumpControlScore(
                move, leadCards: leadCards, hand: hand,
                position: position, state: state, evaluator: evaluator, ctx: ctx
            )
        } else if !partnerWinningBefore || candidateWins {
            score += followWinClassScore(winClass, trickPoints: trickPoints, playedPoints: playedPoints)
        }

        // ── 通用项（主/非主都适用）：垫分、清门、拆结构 ──────────────────
        if partnerWinningBefore {
            score += Double(playedPoints) * (4 * (1 - opponentCapture) - 8 * opponentCapture)
            score += clearsSuit ? 8 : 0
            if candidateWins && !usesTrump { score -= 30 }   // 非主盖队友：罚（主牌盖队友由模型判断）
            score -= breakPenalty * 18 * preservationDamp
            score -= strongBreakPenalty * 24 * preservationDamp
            if playedPoints == 0 { score += 4 }
            if !trickSecureBefore && move.kind == .followSupport {
                score -= (trickPoints >= 15 ? 80 : 35) * opponentCapture
            }
        } else {
            if !usesTrump {
                if candidateWins {
                    if trickSecureAfter {
                        score += 48 + Double(trickPoints + playedPoints) * 4
                    } else {
                        score += 18 + Double(trickPoints) * 1.2 - Double(playedPoints) * 4
                        if trickPoints + playedPoints >= 15 && !ctx.isLastPlayer { score -= 90 }
                    }
                    score += ctx.isLastPlayer ? 10 : 0
                    if trickPoints >= 10 && state.attackScore > 60 { score += ctx.isLastPlayer ? 8 : 18 }
                } else {
                    score -= Double(playedPoints) * 5
                    score += move.cards.allSatisfy { $0.pointValue == 0 } ? 8 : 0
                }
                score += initiativeGainScore(
                    move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
                )
            }
            score += clearsSuit ? 5 : 0
            score -= breakPenalty * 16 * preservationDamp
            score -= strongBreakPenalty * 22 * preservationDamp
        }

        switch move.kind {
        case .followBaseline:
            score += 5
        case .followSupport:
            score += partnerWinningBefore ? 8 : 0
        case .followDiscard:
            score += partnerWinningBefore ? 0 : 4
        case .followWin:
            if !usesTrump { score += candidateWins ? 8 : -12 }   // 主牌赢由模型给分
        default:
            break
        }

        // ── Point Exposure Risk（点数暴露风险，团队级）────────────────────
        // 不在"打出分牌"时给分，而在"分可能被对手拿走"时扣分：
        //   risk = (本墩已有分 + 本走法带入的分) × P(对手最终赢下本墩)
        // 由此：把主 10/K 丢进未锁定的墩会被显著惩罚；墩内分越多、越不安全，惩罚越大；
        // 而锁定墩 / 队友稳赢墩（P(对手)=0）则不罚，可放心垫分。
        let exposedPoints = Double(trickPoints + playedPoints)
        if exposedPoints > 0 {
            score -= exposedPoints * opponentCapture * pointExposureWeight
        }

        // A secure partner trick is an opportunity to remove future losers, not a
        // blanket instruction to contribute points that can be cashed later.
        if partnerWinningBefore && trickSecureBefore {
            let trickContext = TrickContext(
                position: position, hand: hand, state: state,
                evaluator: evaluator, memory: ctx
            )
            score += move.cards.reduce(0.0) { partial, card in
                let combination = CardCombination(cards: [card], pattern: .single(card))
                return partial + partnerWonDiscardScore(
                    candidate: combination, hand: hand,
                    gameState: state, trickContext: trickContext
                )
            }
        }

        return score
    }


    // MARK: - Point Exposure Risk（点数暴露风险估计）

    /// 估计：在本玩家打出 `move` 后，本墩最终被**对方**赢下（即墩内分被对手拿走）的概率（0...1）。
    /// - 我方已锁定 → 0；我方暂时领先但未锁定 → 后手对手反超的概率；
    /// - 对手领先且我方后手可能救回 → 1 − 队友救回概率；后手无队友 → 1。
    static func opponentTrickWinProbability(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard let leadCards = state.currentTrick.leadCards else { return 0 }

        var trick = state.currentTrick
        if !trick.plays.contains(where: { $0.position == position }) {
            trick.plays.append((position: position, cards: move.cards))
        }
        let winner = evaluator.winner(of: trick)
        let ourTeamLeads = winner.team == position.team
        let subsequent = unplayedSubsequentPositions(after: position, in: state)

        // 末位出牌：胜负已定
        if subsequent.isEmpty { return ourTeamLeads ? 0.0 : 1.0 }

        let winningCards = trick.plays.first(where: { $0.position == winner })?.cards ?? leadCards
        let winRep = maxCard(in: winningCards, ts: ts, tr: tr)
        let leadSuit = evaluator.dominantSuit(of: leadCards)

        if ourTeamLeads {
            // 已锁定（后手对手无法反超）→ 对手 0 概率
            if isTrickSecureForTeam(
                position: position, hand: hand, state: state,
                evaluator: evaluator, ctx: ctx, candidateCards: move.cards
            ) {
                return 0.0
            }
            // 暂时领先：至少一名后手对手反超的概率
            var pKeep = 1.0
            for opp in subsequent where opp.team != position.team {
                if leadCards.count > 1 {
                    pKeep *= 1 - structuredOvertakeProbability(
                        trick: trick, opponent: opp, hand: hand, position: position,
                        state: state, evaluator: evaluator, ctx: ctx
                    )
                } else { pKeep *= (1 - playerBeatProbability(
                    winRep, by: opp, leadSuit: leadSuit, hand: hand, ts: ts, tr: tr, ctx: ctx,
                    state: state, position: position
                )) }
            }
            return 1 - pKeep
        } else {
            // 对手领先：后手队友能救回则降低对手概率（忽略救回后再被反超的二阶情况）
            let partnersAfter = subsequent.filter { $0.team == position.team }
            if partnersAfter.isEmpty { return 1.0 }
            var pRescue = 0.0
            for p in partnersAfter {
                let rescue = leadCards.count > 1
                    ? structuredOvertakeProbability(trick: trick, opponent: p, hand: hand,
                        position: position, state: state, evaluator: evaluator, ctx: ctx)
                    : playerBeatProbability(winRep, by: p, leadSuit: leadSuit, hand: hand,
                        ts: ts, tr: tr, ctx: ctx, state: state, position: position)
                pRescue = max(pRescue, rescue)
            }
            return 1 - pRescue
        }
    }

    /// 多张组合的盖牌概率：对手既要持有完整组合，将吃时还必须绝掉领出花色。
    /// 用已出牌、本人手牌和本人知道的底牌构造剩余池，以超几何概率估算；
    /// 副牌前几次领出时“绝门且有完整主结构”的概率自然较低，自己的主牌也会
    /// 阻断外面的主对子/拖拉机。多种压制组合用并集上界，保持风险估计偏保守。
    static func structuredOvertakeProbability(
        trick: Trick, opponent: PlayerPosition, hand: [Card], position: PlayerPosition,
        state: GameState?, evaluator: TrickEvaluator, ctx: AIContext
    ) -> Double {
        guard let lead = trick.leadCards else { return 0 }
        let ts = evaluator.trumpSuit
        let tr = evaluator.trumpRank
        let suit = evaluator.dominantSuit(of: lead)
        var known = ctx.playedCards + hand
        if let state, position == state.dealerPosition { known += state.kitty }
        var ids = Set<UUID>()
        known = known.filter { ids.insert($0.id).inserted }
        let revealed = (ctx.knownCardsByPlayer[opponent] ?? []).filter { !ids.contains($0.id) }
        known += ctx.knownCardsByPlayer.filter { $0.key != opponent }.values.flatMap { $0 }
            .filter { ids.insert($0.id).inserted }
        let pool = removeKnownFaces(from: referenceDeck, knownCards: known).filter {
            !ctx.isVoid(opponent, key: AIContext.suitKey($0, ts: ts, tr: tr))
        }
        let unknown = removeKnownFaces(from: pool, knownCards: revealed)
        let reportedCount = state?.handCount(for: opponent) ?? 0
        let draws = min(max(0, (reportedCount > 0 ? reportedCount : hand.count) - revealed.count), unknown.count)
        func choose(_ n: Int, _ k: Int) -> Double {
            guard n >= 0, k >= 0, k <= n else { return 0 }
            let k = min(k, n - k)
            if k == 0 { return 1 }
            return (1...k).reduce(1.0) { $0 * Double(n - k + $1) / Double($1) }
        }
        let denominator = choose(unknown.count, draws)
        guard denominator > 0 else { return 1 }
        var groups = [pool.filter { evaluator.cardSuit($0) == suit }]
        if suit != nil { groups.append(pool.filter { evaluator.cardSuit($0) == nil }) }
        var probability = 0.0
        for group in groups where group.count >= lead.count {
            let ruff = suit != nil && group.allSatisfy { evaluator.cardSuit($0) == nil }
            if ruff && revealed.contains(where: { evaluator.cardSuit($0) == suit }) { continue }
            let options: [[Card]]
            if let tractor = tractorInfo(of: lead, trumpSuit: ts, trumpRank: tr) {
                options = tractors(in: group, pairCount: tractor.pairCount, trumpSuit: ts, trumpRank: tr)
            } else if isPairMove(lead, ts: ts, tr: tr) {
                options = pairs(in: group, trumpSuit: ts, trumpRank: tr)
            } else if let slam = evaluator.slamInfo(of: lead), slam.pairs.isEmpty && slam.tractors.isEmpty {
                guard ruff else { continue }
                // 纯散牌甩N张：必须绝门并持有至少N张主；不能把“有一张主”
                // 按固定60%当成能将吃整组。多张主可以不成对。
                let knownTrumps = revealed.filter { evaluator.cardSuit($0) == nil }
                let unknownTrumps = unknown.filter { evaluator.cardSuit($0) == nil }
                let forbidden = unknown.filter { evaluator.cardSuit($0) == suit }.count
                let needed = max(0, lead.count - knownTrumps.count)
                let maximum = min(draws, unknownTrumps.count)
                guard needed <= maximum else { continue }
                let winning = trick.plays.first { $0.position == evaluator.winner(of: trick) }!.cards
                let high = maxCard(in: winning, ts: ts, tr: tr)
                let winningIsTrump = evaluator.cardSuit(high) == nil
                let knownHigher = knownTrumps.contains { CardComparator.beats($0, high, trumpSuit: ts, trumpRank: tr) }
                let higher = unknownTrumps.filter { CardComparator.beats($0, high, trumpSuit: ts, trumpRank: tr) }.count
                let rest = unknown.count - forbidden - unknownTrumps.count
                for count in needed...maximum {
                    var ways = choose(unknownTrumps.count, count)
                    if winningIsTrump && !knownHigher {
                        ways -= choose(unknownTrumps.count - higher, count)
                    }
                    probability += ways * choose(rest, draws - count) / denominator
                }
                continue
            } else {
                // 混合甩牌的多组件概率由后续模拟处理，沿用保守上界。
                if let state {
                    return opponentCouldBeat(trick: trick, opponent: opponent, position: position,
                        hand: hand, state: state, evaluator: evaluator, ctx: ctx) ? 0.6 : 0
                }
                // 续演没有完整GameState；合法甩牌不能被同门反超，但不能
                // 检查完同门池便直接返回0，漏掉后面的首次绝门将吃。
                guard ruff, let slam = evaluator.slamInfo(of: lead),
                      let winning = trick.plays.first(where: { $0.position == evaluator.winner(of: trick) })?.cards,
                      let match = buildMatchingSlamTrump(slam: slam, trumpCards: group,
                        winningCards: winning, ts: ts, tr: tr, stopAtFirstWinner: true),
                      removeKnownFaces(from: match, knownCards: revealed).count <= draws else { continue }
                let forbidden = unknown.filter { evaluator.cardSuit($0) == suit }.count
                // 混合组件联合持有概率复杂，使用“绝门”概率作为保守上界；
                // 仍需牌池中确实存在匹配的主结构。
                probability = max(probability, choose(unknown.count - forbidden, draws) / denominator)
                continue
            }
            for option in options {
                var test = trick
                test.plays.append((position: opponent, cards: option))
                guard evaluator.winner(of: test) == opponent else { continue }
                let missing = removeKnownFaces(from: option, knownCards: revealed).count
                let forbidden = ruff ? unknown.filter { evaluator.cardSuit($0) == suit }.count : 0
                probability += choose(unknown.count - missing - forbidden, draws - missing) / denominator
            }
        }
        return min(1, probability)
    }


    /// 估计某后手玩家用更大的牌反超当前赢牌 `winRep` 的概率（0...1）。
    /// 综合：是否已绝先手花色（能否将吃）、是否绝主、场上还有多少更大的未知牌。
    static func playerBeatProbability(
        _ winRep: Card,
        by player: PlayerPosition,
        leadSuit: Suit?,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext,
        state: GameState? = nil,
        position: PlayerPosition? = nil
    ) -> Double {
        let evaluator = TrickEvaluator(trumpSuit: ts, trumpRank: tr)
        var known = ctx.playedCards + hand
        if let state, position == state.dealerPosition { known += state.kitty }
        var ids = Set<UUID>()
        known = known.filter { ids.insert($0.id).inserted }
        let revealed = ctx.knownCardsByPlayer[player] ?? []
        let allRevealed = ctx.knownCardsByPlayer.values.flatMap { $0 }
            .filter { !ids.contains($0.id) }
        let unknown = removeKnownFaces(from: referenceDeck, knownCards: known + allRevealed)
            .filter { !ctx.isVoid(player, key: AIContext.suitKey($0, ts: ts, tr: tr)) }
        let reportedCount = state?.handCount(for: player) ?? 0
        let draws = min(unknown.count, max(0, (reportedCount > 0 ? reportedCount : hand.count) - revealed.count))
        func choose(_ n: Int, _ k: Int) -> Double {
            guard n >= 0, k >= 0, k <= n else { return 0 }
            let k = min(k, n - k)
            if k == 0 { return 1 }
            return (1...k).reduce(1.0) { $0 * Double(n - k + $1) / Double($1) }
        }
        let denominator = choose(unknown.count, draws)
        guard denominator > 0 else { return 0 }
        let same = unknown.filter { evaluator.cardSuit($0) == leadSuit }
        let higher = same.filter { CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr) }
        let revealedLead = revealed.filter { evaluator.cardSuit($0) == leadSuit }
        if revealedLead.contains(where: { CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr) }) { return 1 }
        let sameSuitBeat = 1 - choose(unknown.count - higher.count, draws) / denominator
        guard leadSuit != nil, revealedLead.isEmpty else { return min(1, max(0, sameSuitBeat)) }

        // “第一次绝门且持有可将吃的主”与“跟门大牌反超”是互斥事件。
        // 未暴露绝门不能当作必须跟门，也不能把所有未知主都视为必在此人手中。
        let higherTrumps = unknown.filter {
            evaluator.cardSuit($0) == nil && CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr)
        }
        let knownRuff = revealed.contains {
            evaluator.cardSuit($0) == nil && CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr)
        }
        let noSuit = choose(unknown.count - same.count, draws)
        let noSuitOrTrump = knownRuff ? 0 : choose(unknown.count - same.count - higherTrumps.count, draws)
        return min(1, max(0, sameSuitBeat + (noSuit - noSuitOrTrump) / denominator))
    }


    /// 未知（不在已出牌 + 自己手牌中）的、比 `card` 更大的主牌张数。
    static func unknownHigherTrumpCopies(_ card: Card, hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        let higherFaces = uniqueCardFaces(
            referenceDeck.filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && CardComparator.beats($0, card, trumpSuit: ts, trumpRank: tr)
            }
        )
        var count = 0
        for face in higherFaces {
            let total = referenceDeck.filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            count += max(0, total - known)
        }
        return count
    }


    /// 未知的、比 `card` 更大的同副花色（非主）牌张数。
    static func unknownHigherSideCopies(_ card: Card, suit: Suit, hand: [Card], tr: Rank, ctx: AIContext) -> Int {
        let higherRanks = Rank.allCases.filter { !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue }
        var count = 0
        for rank in higherRanks {
            let known = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
                + hand.filter { $0.suit == suit && $0.rank == rank }.count
            count += max(0, 2 - known)   // 双副牌：每个 face 共 2 张
        }
        return count
    }


    /// 未知更大牌张数 → 后手反超概率。张数越多越可能落在某个后手手里。
    static func overtakeChance(_ unknownCopies: Int) -> Double {
        guard unknownCopies > 0 else { return 0 }
        return min(0.7, 0.18 * Double(unknownCopies))
    }


    /// 该模式下，点数相关目标是否应主导评分（资产 / 早出大主仅作轻微 tie-breaker）。
    static func isPointContestMode(_ mode: TacticalMode) -> Bool {
        switch mode {
        case .pointDenial, .pointCapture, .forceOpponentCost: return true
        case .normal, .safeDiscard: return false
        }
    }


    /// 确定性战术识别层（TacticalModeDetector）。在 Monte Carlo 之前判断本手属于哪种战术场景，
    /// 据此让 Monte Carlo 切换目标函数，避免被 assetValue / usedBigTrumpEarlyPenalty 等保主偏置带偏。
    ///
    /// Point Denial Mode 触发：我是本队最后行动者（后手没有队友）且后面仍有对手——
    /// **无论本墩当前是否已有分**。目标层级（由候选分级 A>B>C>D 与阻分目标函数共同实现）：
    ///   1) 合理时锁定本墩；2) 阻止后手对手用分牌(K/10/5)赢墩；
    ///   3) 若对手仍可能赢，逼其付出更高的非分/控制牌成本；
    ///   4) 不追加不安全的分；5) 阻分满足后才考虑结构保留。
    static func detectTacticalMode(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        legalMoves: [AIMove],
        ctx: AIContext
    ) -> TacticalMode {
        // 聚合本墩公共上下文（派生量统一从 TrickContext 取，逻辑不变）。
        let tc = TrickContext(position: position, hand: hand, state: state, evaluator: evaluator, memory: ctx)

        // 先手 / 本墩还没有人出牌：无当前墩争夺，按常规。
        guard !tc.isLeading else { return .normal }

        let opponentAfter = tc.subsequentPositions.contains { $0.team != position.team }
        let lastChance = tc.isLastEffectiveChanceForTeam   // 后手没有队友

        // Point Denial Mode：我是本队最后行动者 且 后手仍有对手（无论本墩是否已有分）。
        if lastChance && opponentAfter {
            return .pointDenial
        }

        // 非最后行动者：仍有队友在后，按是否能赢/逼牌走原有判断（仅本墩有分时才进入争夺模式）。
        guard tc.trickPoints > 0 else { return .normal }
        let classifiedMoves = legalMoves.map { move in
            (
                move: move,
                winClass: classifyFollowMove(
                    move.cards,
                    position: position,
                    hand: hand,
                    state: state,
                    evaluator: evaluator,
                    ctx: ctx
                )
            )
        }
        if classifiedMoves.contains(where: {
            if case .finalWin = $0.winClass { return true }
            return false
        }) {
            return .pointCapture
        }
        // 当前能抬过对手、但后手仍可能再盖回来时属于逼牌，不应在前一个
        // “当前暂时领先”判断中提前吞掉这个分支。
        if classifiedMoves.contains(where: {
            guard case .temporaryWin = $0.winClass else { return false }
            return currentWinnerOpponentBeaten(
                $0.move,
                position: position,
                state: state,
                evaluator: evaluator
            )
        }) {
            return .forceOpponentCost
        }
        return .normal
    }


    /// 候选是否真正"压过了当前（对手）赢家"——用于区分"赢墩"与"队友本就领先我只是跟牌"。
    static func currentWinnerOpponentBeaten(
        _ move: AIMove,
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        let before = evaluator.winner(of: state.currentTrick)
        guard before.team != position.team else { return false }   // 当前是队友领先，不算"压过对手"
        var trick = state.currentTrick
        guard !trick.plays.contains(where: { $0.position == position }) else { return false }
        trick.plays.append((position: position, cards: move.cards))
        return evaluator.winner(of: trick) == position
    }


    static func classifyPointDenialMove(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> PointDenialClass {
        // A：能锁定本墩（含我方稳赢 / 队友已稳且本走法不破坏）
        if isTrickSecureForTeam(
            position: position, hand: hand, state: state,
            evaluator: evaluator, ctx: ctx, candidateCards: move.cards
        ) {
            return .secureWinner
        }
        // D：未锁定却往墩里再加分牌（含拆分对子凑牌）
        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        if playedPoints > 0 {
            return .riskyExposure
        }
        // B：未锁定、不加分，但当前能压住（抬高对手赢墩成本）
        if candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator) {
            return .strongContest
        }
        // C：被动跟牌
        return .passive
    }


    /// 争分模式保留带分候选，风险通过评分表达，避免在模拟前删除值得争的走法。
    static func tacticalCandidateFilter(
        _ moves: [AIMove],
        mode: TacticalMode,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        // 带分的争墩走法仍须与认输比较预期分差，不在模拟前一刀切删除。
        return moves
    }


    /// 主牌强度归一化到 0...1（大王=1.0）。用于"逼对手付出代价"与"过度杀伤"评估。
    static func trumpStrengthFraction(_ card: Card, ts: Suit?, tr: Rank) -> Double {
        let w = CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? Double(CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr))
            : Double(card.rank.rawValue)
        return min(1.0, max(0.0, w / 100.0))
    }


    static func isTrumpPullWithUnknownOpponentBehind(
        leadCards: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Bool {
        guard evaluator.dominantSuit(of: leadCards) == nil else { return false }
        return unplayedSubsequentPositions(after: position, in: state)
            .contains { $0.team != position.team && !ctx.isVoid($0, key: "TRUMP") }
    }


    /// 跟吊主且后手仍有未知对手时的出牌权需求。这里度量的是"赢下本墩后是否有东西可兑现"，
    /// 不是主牌强度本身：副牌 A、已知最大副牌、安全甩牌、强结构、长套和待兑现分牌都会提高需求。
    static func leadControlNeed(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        let cashableSideAces = sideCards.filter { card in
            card.rank == .ace
                && (card.suit.map { !ctx.allEnemiesVoid(myTeam: position.team, key: $0.rawValue) } ?? false)
        }.count

        let knownSideWinners = sideCards.filter {
            $0.rank != .ace && ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
        }.count

        let slamCount = findSlamLeadCandidates(
            in: hand,
            ts: ts,
            tr: tr,
            myTeam: position.team,
            ctx: ctx,
            position: position,
            state: state
        ).count

        let strongPairs = pairs(in: hand, trumpSuit: ts, trumpRank: tr).filter { pair in
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { return false }
            if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) {
                return isBigTrump(rep, ts: ts, tr: tr)
            }
            return isStrongPairAsset(rep, ts: ts, tr: tr)
                || isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr)
        }.count

        var tractorCount = 0
        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            tractorCount += tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr).count
        }

        let longSuitPotential = Suit.allCases.reduce(0.0) { partial, suit in
            let count = sideCards.filter { $0.suit == suit }.count
            if count >= 6 { return partial + 2.0 }
            if count >= 4 { return partial + 1.0 }
            return partial
        }

        let pendingPointAssets = Double(sideCards.reduce(0) { $0 + $1.pointValue }) / 10.0

        return Double(cashableSideAces)
            + Double(knownSideWinners)
            + Double(slamCount) * 2.0
            + Double(strongPairs) * 1.5
            + Double(tractorCount) * 2.0
            + longSuitPotential
            + pendingPointAssets
    }


    static func trumpPullWinConfidence(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        guard candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator) else {
            return 0
        }
        if isSecureWinningTrumpFollow(
            move.cards,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        ) {
            return 1
        }
        let opponentCapture = opponentTrickWinProbability(
            move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
        )
        let highTrump = move.cards
            .filter { CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) }
            .max {
                CardComparator.beats($1, $0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
            }
        let strength = highTrump.map {
            trumpStrengthFraction($0, ts: state.trumpSuit, tr: state.trumpRank)
        } ?? 0
        return min(1.0, max(0.0, 1.0 - opponentCapture + strength * 0.25))
    }


    static func trumpPullPointExposureRisk(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        guard playedPoints > 0 else { return 0 }
        return opponentTrickWinProbability(
            move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
        )
    }


    static func trumpPullControlAdjustment(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext,
        cost: Double
    ) -> Double {
        guard isTrumpPullWithUnknownOpponentBehind(
            leadCards: leadCards,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        ) else { return 0 }

        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        let exposureRisk = trumpPullPointExposureRisk(
            move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
        )
        if playedPoints > 0 && exposureRisk > 0.05 {
            return -140 - Double(playedPoints) * 8 - exposureRisk * 80
        }

        let wins = candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator)
        let need = leadControlNeed(position: position, hand: hand, state: state, ctx: ctx)
        let winConfidence = trumpPullWinConfidence(
            move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
        )
        let breakPenalty = structureBreakPenalty(cards: move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank)
        var score = -breakPenalty * 55

        if wins && need >= 5.0 && winConfidence >= 0.62 && exposureRisk <= 0.20 && breakPenalty == 0 {
            score += need * 9.0 + winConfidence * 34.0 - cost * 1.2
            if playedPoints == 0 { score += 16 }
            if containsBigTrump(move.cards, ts: state.trumpSuit, tr: state.trumpRank) { score += 6 }
        } else if playedPoints == 0 && containsBigTrump(move.cards, ts: state.trumpSuit, tr: state.trumpRank) {
            score -= 38 + cost * 2.0
        }

        return score
    }


    // MARK: - 统一「用主控墩」决策（Trump Control Decision）

    /// 核心问题：为「拿到 / 保住 / 抢回」这一墩的控制权，值不值得花这张主牌？
    /// 覆盖所有用主跟牌的情形：吊主跟牌、绝门将吃、盖吃对手将牌、帮队友锁定、为抢出牌权而争墩。
    /// 仅在候选用到主牌时返回非零；否则返回 0（非主走法由通用赢墩分类分处理）。
    ///
    /// 决策输入：当前墩分（0/5/10/15 阶梯）、当前赢家（敌/友、是否已稳）、
    /// 拿墩安全分级（A=Secure / B=Contesting / C=Passive）、出牌权价值、主牌成本（高分/高价值时弱化）。
    static func trumpControlScore(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        trumpControlDecision(
            move,
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )?.score ?? 0
    }


    static func trumpControlDecision(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> TrumpControlDecision? {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard move.cards.contains(where: { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }) else {
            return nil
        }

        let currentWinner = evaluator.winner(of: state.currentTrick)
        let partnerWinning = currentWinner.team == position.team
        let trickPoints = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        let totalPoints = trickPoints + playedPoints
        let pts = Double(totalPoints)
        let pressure = pointPressureBonus(totalPoints: totalPoints)
        let leadIsTrump = evaluator.dominantSuit(of: leadCards) == nil
        // 拿墩安全分级：A=finalWin（终局也能赢）、B=temporaryWin（暂赢、后手或可盖）、C=cannotWin（赢不了）
        let winClass = classifyFollowMove(
            move.cards, position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let secureBefore = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let cost = trumpControlCost(move.cards, ts: ts, tr: tr)
        // 主牌成本权重：墩分越高越不该让“惜主”主导（高分/高价值时弱化成本）
        let costDamp = trumpCostDamping(trickPoints: totalPoints)
        // 抢回出牌权的价值：赢下后手上还有多少可兑现的资产（旁门A、对子/连对、甩牌、长门…）
        let leadControl = trumpLeadControlValue(move: move, hand: hand, position: position, state: state, ctx: ctx)
        let trumpPullAdjustment = trumpPullControlAdjustment(
            move,
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx,
            cost: cost
        )

        var score = 0.0
        let classification: TrumpControlClass

        if partnerWinning {
            // ── 队友领先 ──
            if secureBefore {
                // 已稳：不要盖队友，也不要白扔主牌
                classification = winClass == .cannotWin ? .passiveTrump : .contestingTrump
                if winClass != .cannotWin { score -= 35 + cost }
            } else if trickPoints > 0 {
                // 未稳且有分：可接管帮忙锁定（规则 D）；不要为无分墩抢队友
                switch winClass {
                case .finalWin:
                    classification = .secureWinner
                    score += 30 + pts * 5.5 * pressure - cost * costDamp
                case .temporaryWin:
                    classification = .contestingTrump
                    score += totalPoints >= 10 ? 10 + pts * 2.2 * pressure : -8
                case .cannotWin:
                    classification = .passiveTrump
                    score += 0
                }
            } else {
                classification = winClass == .cannotWin ? .passiveTrump : .contestingTrump
            }
            // 队友领先、无分、未稳：保守为主，交给通用项
        } else {
            // ── 对手领先（含对手已将吃 → 盖吃）──
            switch winClass {
            case .finalWin:                       // A：能锁定终局
                classification = .secureWinner
                score += 32 + Double(2 * trickPoints + playedPoints) * 5.2 * pressure - cost * costDamp + leadControl
            case .temporaryWin:                   // B：争墩 / 逼对手出更高主
                classification = .contestingTrump
                let contest: Double
                if totalPoints >= 15 { contest = 54 + Double(2 * trickPoints + playedPoints) * 3.2 * pressure }
                else if totalPoints >= 10 { contest = 40 + Double(2 * trickPoints + playedPoints) * 2.4 * pressure }
                else if totalPoints >= 5 { contest = 24 + Double(2 * trickPoints + playedPoints) * 1.8 }
                else { contest = ctx.isLastPlayer ? 6 : -12 }   // 无分/低分争墩意义有限
                score += contest - cost * costDamp + leadControl * 0.6
            case .cannotWin:                      // C：被动主牌（赢不了）
                classification = .passiveTrump
                if leadIsTrump {
                    // 跟主吊：可能只有小主、被迫跟；按墩分阶梯（15+ 由 filterTrumpPullPointContest 直接剔除）
                    score += passiveTrumpPenalty(totalPoints)
                } else {
                    // 绝门却扔个赢不了的主：纯浪费（本可垫副牌）→ 重罚
                    score -= 25 + pts * 5
                }
            }
        }
        score += trumpPullAdjustment
        return TrumpControlDecision(
            classification: classification,
            score: score,
            leadControlValue: leadControl,
            cost: cost
        )
    }


    /// 主牌成本：王 / 级牌 / 大主最贵，普通主按牌力。拆主对/主连对的成本由通用 structureBreakPenalty 统一处理。
    static func trumpControlCost(_ cards: [Card], ts: Suit?, tr: Rank) -> Double {
        var cost = 0.0
        for card in cards where CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
            if card.rank == .bigJoker || card.rank == .smallJoker { cost += 14 }
            else if card.rank == tr { cost += 11 }
            else if isBigTrump(card, ts: ts, tr: tr) { cost += 9 }      // 主花色 A
            else { cost += Double(CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)) / 18.0 }
        }
        return cost
    }


    /// 墩分越高，越不让“惜主成本”主导决策。
    static func trumpCostDamping(trickPoints: Int) -> Double {
        if trickPoints >= 25 { return 0.15 }
        if trickPoints >= 20 { return 0.22 }
        if trickPoints >= 15 { return 0.3 }
        if trickPoints >= 10 { return 0.5 }
        if trickPoints >= 5  { return 0.8 }
        return 1.0
    }


    /// 被动主牌（跟主吊却赢不了）的护分阶梯：0 分可接受；分越多越罚。
    static func passiveTrumpPenalty(_ trickPoints: Int) -> Double {
        let pts = Double(trickPoints)
        if trickPoints == 0  { return 2 }       // 无分被迫小主：可接受
        if trickPoints < 5   { return -pts * 2 }
        if trickPoints < 10  { return -(18 + pts * 3) }
        if trickPoints < 15  { return -(45 + pts * 4) }
        return -(95 + pts * 6)
    }


    /// 抢回出牌权的价值：赢下本墩后，手上仍可兑现的资产越多，赢这一墩越值。上限 25。
    static func trumpLeadControlValue(
        move: AIMove, hand: [Card], position: PlayerPosition, state: GameState, ctx: AIContext
    ) -> Double {
        let remaining = handAfterPlaying(move.cards, from: hand)
        return min(initiativeNeed(position: position, hand: remaining, state: state, ctx: ctx) / 12.0, 25.0)
    }


    static func bestTrumpControlFill(
        from extra: [Card],
        remaining: Int,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card]? {
        guard remaining > 0,
              let leadCards = state.currentTrick.leadCards else { return nil }

        let extraIDs = Set(extra.map(\.id))
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let opponentWinning = currentWinner.team != position.team

        let candidates = generateTrumpControlCandidates(
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        let usable = candidates.compactMap { move -> (cards: [Card], decision: TrumpControlDecision)? in
            let fillCards = move.cards.filter { extraIDs.contains($0.id) }
            guard !fillCards.isEmpty, fillCards.count <= remaining,
                  let decision = trumpControlDecision(
                    move,
                    leadCards: leadCards,
                    hand: hand,
                    position: position,
                    state: state,
                    evaluator: evaluator,
                    ctx: ctx
                  ) else { return nil }

            switch decision.classification {
            case .secureWinner:
                if decision.score > 0 || trickPoints >= 10 || decision.leadControlValue >= 12 {
                    return (fillCards, decision)
                }
            case .contestingTrump:
                if opponentWinning && (trickPoints >= 10 || decision.leadControlValue >= 16), decision.score > 0 {
                    return (fillCards, decision)
                }
            case .passiveTrump:
                return nil
            }
            return nil
        }

        return usable.sorted { lhs, rhs in
            if lhs.decision.classification != rhs.decision.classification {
                return lhs.decision.classification == .secureWinner
            }
            return lhs.decision.score > rhs.decision.score
        }.first?.cards
    }


    static func currentWinnerIsOpponent(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        evaluator.winner(of: state.currentTrick).team != position.team
    }


    static func initiativeNeed(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        let slamCount = findSlamLeadCandidates(
            in: hand,
            ts: ts,
            tr: tr,
            myTeam: position.team,
            ctx: ctx,
            position: position,
            state: state
        ).count
        let tractorCount = tractors(in: sideCards, pairCount: 2, trumpSuit: ts, trumpRank: tr).count
        let pairCount = pairs(in: sideCards, trumpSuit: ts, trumpRank: tr).count
        let sideAceCount = sideCards.filter { $0.rank == .ace }.count
        let safeBigSideCount = countSafeBigSideCards(in: hand, ts: ts, tr: tr, ctx: ctx)
        let pointCardCount = hand.filter { $0.pointValue > 0 }.count
        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count

        var score = 0.0
        score += Double(min(slamCount, 3)) * 40
        score += Double(min(tractorCount, 3)) * 35
        score += Double(min(pairCount, 5)) * 20
        score += Double(min(sideAceCount, 4)) * 15
        score += Double(min(safeBigSideCount, 5)) * 12
        score += Double(pointCardCount) * 8

        if sideCards.count > trumpCount {
            score += 25
        }

        return score
    }


    static func initiativeGainScore(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        guard currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator),
              candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator) else {
            return 0
        }

        let need = initiativeNeed(position: position, hand: hand, state: state, ctx: ctx)
        var score = need * 0.6 - moveCardCost(move.cards, hand: hand, state: state, ctx: ctx) * 0.8

        if need >= 80 {
            score += 70
        }
        if structureBreakPenalty(cards: move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank) > 0 {
            score -= 40
        }
        if containsBigTrump(move.cards, ts: state.trumpSuit, tr: state.trumpRank) {
            score -= 50
        }

        return score
    }


    static func moveCardCost(
        _ cards: [Card],
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        return cards.reduce(Double(cards.count) * 2) { partial, card in
            var cost = partial + Double(card.pointValue) * 0.8
            if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                cost += isBigTrump(card, ts: ts, tr: tr) ? 50 : 14
            } else {
                if card.rank == .ace { cost += 12 }
                if ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) { cost += 10 }
            }
            return cost
        } + structureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 20
            + strongStructureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 24
    }


    /// Cost of discarding a single card. Higher means "preserve this card".
    /// Point cards are not automatically protected: their value is immediate risk + future realization - future loss risk.
    static func discardCost(
        card: Card,
        hand: [Card],
        gameState: GameState,
        trickContext: TrickContext
    ) -> Double {
        let ts = trickContext.trumpSuit
        let tr = trickContext.trumpRank
        let point = Double(card.pointValue)

        var cost = 0.0
        cost += discardControlAssetValue(card, hand: hand, state: gameState, ctx: trickContext.memory)
        cost += discardStructureIntegrityValue(card: card, hand: hand, ts: ts, tr: tr)

        if point > 0 {
            var immediateRisk = point * immediatePointDiscardRiskMultiplier(
                card: card,
                gameState: gameState,
                trickContext: trickContext
            )
            if discardPointCardWouldLetOpponentReachCriticalScore(
                card: card,
                gameState: gameState,
                trickContext: trickContext
            ) {
                immediateRisk += 240 + point * 12
            }

            let futureRealization = futurePointRealizationValue(
                card: card,
                hand: hand,
                state: gameState,
                ctx: trickContext.memory
            )
            let futureLoss = futurePointLossRisk(
                card: card,
                hand: hand,
                state: gameState,
                position: trickContext.position,
                ctx: trickContext.memory
            )
            var pointCost = immediateRisk + futureRealization - futureLoss
            if trickContext.opponentWinning {
                pointCost = max(pointCost, point * 2.0)
            }
            cost += pointCost
        }

        if !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
           let suit = card.suit,
           trickContext.memory.allEnemiesVoid(myTeam: trickContext.position.team, key: suit.rawValue),
           !(trickContext.opponentWinning && card.pointValue > 0) {
            cost -= card.pointValue > 0 ? 18 : 6
        }

        return cost
    }


    /// A point-bearing holding whose points can be realized later without relying on
    /// the current partner-won trick. These cards should be banked while a riskier
    /// loser remains in hand.
    static func isSafeBankedPointWinner(
        candidate: CardCombination,
        hand: [Card],
        gameState: GameState
    ) -> Bool {
        guard candidate.cards.contains(where: { $0.pointValue > 0 }),
              hand.count > candidate.cards.count else { return false }

        let ts = gameState.trumpSuit
        let tr = gameState.trumpRank
        let position = gameState.currentTurn
        let ctx = AIContext.build(state: gameState, ts: ts, tr: tr)
        guard structureBreakPenalty(cards: candidate.cards, hand: hand, ts: ts, tr: tr) == 0,
              strongStructureBreakPenalty(cards: candidate.cards, hand: hand, ts: ts, tr: tr) == 0 else {
            return false
        }
        let enemiesOutOfTrump = ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP")
        let allTrump = candidate.cards.allSatisfy {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }

        if allTrump {
            let candidateIDs = Set(candidate.cards.map(\.id))
            let remainingTrump = hand.filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && !candidateIDs.contains($0.id)
            }
            let control = candidate.cards.contains { isBigTrump($0, ts: ts, tr: tr) }
                || strongTrumpCount(in: hand, ts: ts, tr: tr) >= 3
                || remainingTrump.count >= 3
            return enemiesOutOfTrump || control
        }

        guard candidate.cards.allSatisfy({
            !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }),
        let suit = candidate.cards.first?.suit,
        candidate.cards.allSatisfy({ $0.suit == suit }) else { return false }

        // A known void enemy can ruff this winner unless both enemies are known to
        // have exhausted trump. With no exposed void, the winner can be cashed on
        // the next initiative opportunity.
        let ruffThreat = !ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).isEmpty
            && !enemiesOutOfTrump
        guard !ruffThreat else { return false }

        switch candidate.pattern {
        case .single(let card):
            return card.rank == .ace
                || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand)
        case .pair(let first, _):
            return isEffectivelyBiggestPair(first, hand: hand, ctx: ctx, ts: ts, tr: tr)
        case .tractor:
            guard let high = candidate.cards.max(by: {
                CardComparator.pairOrderValue($0, trumpSuit: ts, trumpRank: tr)
                    < CardComparator.pairOrderValue($1, trumpSuit: ts, trumpRank: tr)
            }) else { return false }
            return isEffectivelyBiggestPair(high, hand: hand, ctx: ctx, ts: ts, tr: tr)
        case .mixed:
            return candidate.cards.allSatisfy {
                $0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
            }
        }
    }


    /// Relative urgency to remove a holding while a teammate has safely banked the
    /// current trick. Higher values mean the card is more likely to become a future loser.
    static func futureDiscardRisk(
        candidate: CardCombination,
        hand: [Card],
        gameState: GameState
    ) -> Double {
        guard !candidate.cards.isEmpty else { return 0 }
        let ts = gameState.trumpSuit
        let tr = gameState.trumpRank
        let position = gameState.currentTurn
        let ctx = AIContext.build(state: gameState, ts: ts, tr: tr)

        if isSafeBankedPointWinner(candidate: candidate, hand: hand, gameState: gameState) {
            return 0
        }

        var risk = 0.0
        for card in candidate.cards {
            if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                risk += isBigTrump(card, ts: ts, tr: tr) ? 0 : 4
                continue
            }

            risk += 24
            if card.rank.rawValue <= Rank.nine.rawValue { risk += 18 }
            if !ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) { risk += 20 }
            if let suit = card.suit {
                risk += Double(ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).count) * 16
            }
            if card.pointValue > 0 { risk -= 8 }
        }

        let breakCost = structureBreakPenalty(cards: candidate.cards, hand: hand, ts: ts, tr: tr)
            + strongStructureBreakPenalty(cards: candidate.cards, hand: hand, ts: ts, tr: tr)
        return max(0, risk / Double(candidate.cards.count) - breakCost * 24)
    }


    static func partnerWonDiscardScore(
        candidate: CardCombination,
        hand: [Card],
        gameState: GameState,
        trickContext: TrickContext
    ) -> Double {
        let points = candidate.cards.reduce(0) { $0 + $1.pointValue }
        let projectedAttackScore = gameState.attackScore + trickContext.trickPoints + points
        let currentTeamAttacks = trickContext.position.team != gameState.dealerTeamIdx
        let locksRound = currentTeamAttacks && gameState.attackScore < 80 && projectedAttackScore >= 80
        let cardsRequired = gameState.currentTrick.leadCards?.count ?? candidate.cards.count
        let finalHolding = hand.count <= max(candidate.cards.count, cardsRequired)
        let risk = futureDiscardRisk(candidate: candidate, hand: hand, gameState: gameState)
        let safeBanked = isSafeBankedPointWinner(candidate: candidate, hand: hand, gameState: gameState)
        let candidateIDs = Set(candidate.cards.map(\.id))
        let hasMoreDangerous = hand
            .filter { !candidateIDs.contains($0.id) }
            .contains {
                let single = CardCombination(cards: [$0], pattern: .single($0))
                return futureDiscardRisk(candidate: single, hand: hand, gameState: gameState) > risk + 8
            }
        let controlLoss = candidate.cards.reduce(0.0) {
            $0 + discardControlAssetValue($1, hand: hand, state: gameState, ctx: trickContext.memory)
        }

        var score = Double(points) * 2 + risk - controlLoss * 0.35
        if safeBanked && hasMoreDangerous && !locksRound && !finalHolding { score -= 120 }
        return score
    }


    static func immediatePointDiscardRiskMultiplier(
        card: Card,
        gameState: GameState,
        trickContext: TrickContext
    ) -> Double {
        guard card.pointValue > 0 else { return 0 }
        if trickContext.opponentWinning { return 5.0 }
        if trickContext.partnerWinning {
            return isTrickSecureForTeam(
                position: trickContext.position,
                hand: trickContext.hand,
                state: gameState,
                evaluator: trickContext.evaluator,
                ctx: trickContext.memory
            ) ? -2.0 : 1.5
        }
        return 1.0
    }


    static func discardControlAssetValue(
        _ card: Card,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else {
            if card.rank == .ace
                || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) { return 55 }
            return 0
        }

        if card.rank == .bigJoker { return 280 }
        if card.rank == .smallJoker { return 235 }
        if card.rank == tr { return 190 }
        if isBigTrump(card, ts: ts, tr: tr) { return 150 }
        return 45 + Double(CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)) * 2.0
    }


    static func discardStructureIntegrityValue(card: Card, hand: [Card], ts: Suit?, tr: Rank) -> Double {
        var value = 0.0
        value += structureBreakPenalty(cards: [card], hand: hand, ts: ts, tr: tr) * 55
        value += strongStructureBreakPenalty(cards: [card], hand: hand, ts: ts, tr: tr) * 70

        let pair = pairContaining(card, in: hand, ts: ts, tr: tr)
        if let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) {
            if rep.rank == tr || rep.rank == .bigJoker || rep.rank == .smallJoker { value += 90 }
            else if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) { value += 65 }
            else if rep.rank == .ace { value += 55 }
            else if rep.pointValue > 0 { value += 30 }
        }

        if isMixedSlamCore(card, hand: hand, ts: ts, tr: tr) { value += 70 }
        return value
    }


    static func pairContaining(_ card: Card, in hand: [Card], ts: Suit?, tr: Rank) -> [Card] {
        let key = CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr)
        return Array(hand.filter { CardComparator.pairKey($0, trumpSuit: ts, trumpRank: tr) == key }.prefix(2))
    }


    static func isMixedSlamCore(_ card: Card, hand: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        let hasAce = suitCards.contains { $0.rank == .ace }
        let hasKingPair = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).contains {
            pairRepresentative(of: $0, trumpSuit: ts, trumpRank: tr)?.rank == .king
        }
        return hasAce && hasKingPair && (card.rank == .ace || card.rank == .king)
    }


    static func futurePointRealizationValue(
        card: Card,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        guard card.pointValue > 0 else { return 0 }
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let point = Double(card.pointValue)

        if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
            if isBigTrump(card, ts: ts, tr: tr) { return point * 4 }
            return point * 1.2
        }

        guard let suit = card.suit else { return 0 }
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        let hasAce = suitCards.contains { $0.rank == .ace }
        let paired = pairContaining(card, in: hand, ts: ts, tr: tr).count >= 2
        let protectedStructure = hasAce || paired || isMixedSlamCore(card, hand: hand, ts: ts, tr: tr)
        if ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) || protectedStructure {
            return point * (paired ? 4.0 : 2.8)
        }
        return 0
    }


    static func futurePointLossRisk(
        card: Card,
        hand: [Card],
        state: GameState,
        position: PlayerPosition,
        ctx: AIContext
    ) -> Double {
        guard card.pointValue > 0 else { return 0 }
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let point = Double(card.pointValue)

        if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
            return isBigTrump(card, ts: ts, tr: tr) ? 0 : point * 0.8
        }

        guard let suit = card.suit else { return 0 }
        let paired = pairContaining(card, in: hand, ts: ts, tr: tr).count >= 2
        let enemyVoidCount = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).count
        var risk = point * (paired ? 0.8 : 3.0)
        if enemyVoidCount > 0 { risk += point * Double(enemyVoidCount) * 1.2 }
        if suitAwaitingTrumpPull(suit, position: position, hand: hand, state: state, ctx: ctx) {
            risk += point * 1.5
        }
        return risk
    }


    static func discardPointCardWouldLetOpponentReachCriticalScore(
        card: Card,
        gameState: GameState,
        trickContext: TrickContext
    ) -> Bool {
        guard card.pointValue > 0,
              trickContext.opponentWinning,
              let winner = trickContext.currentWinner,
              winner.team != gameState.dealerTeamIdx else { return false }

        let projected = gameState.attackScore + trickContext.trickPoints + card.pointValue
        return stride(from: 40, through: 240, by: 40).contains {
            gameState.attackScore < $0 && projected >= $0
        }
    }


    static func countSafeBigSideCards(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        hand.filter {
            !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                && ($0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand))
        }.count
    }


    static func aiIsVoidInLeadSuit(
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        guard let leadCards = state.currentTrick.leadCards else { return false }
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        return hand.allSatisfy { evaluator.cardSuit($0) != leadSuit }
    }


    static func shouldRuffToWin(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove,
        evaluator: TrickEvaluator
    ) -> Bool {
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints >= 10,
              currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator),
              aiIsVoidInLeadSuit(hand: hand, state: state, evaluator: evaluator),
              move.cards.allSatisfy({
                  CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
              }) else { return false }
        return candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator)
    }


    static func trumpMoveCost(_ cards: [Card], ts: Suit?, tr: Rank) -> Double {
        cards.reduce(0.0) { partial, card in
            guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return partial }
            return partial + (isBigTrump(card, ts: ts, tr: tr) ? 3.0 : 1.0)
        }
    }


    static func isPairMove(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) != nil
    }


    static func isLevelPair(_ cards: [Card], trumpRank: Rank) -> Bool {
        guard cards.count == 2 else { return false }
        return cards.allSatisfy { $0.rank == trumpRank }
    }


    static func isJokerPair(_ cards: [Card]) -> Bool {
        guard cards.count == 2 else { return false }
        return cards.allSatisfy { $0.rank == .smallJoker }
            || cards.allSatisfy { $0.rank == .bigJoker }
    }


    static func hasBigJoker(in hand: [Card]) -> Bool {
        hand.contains { $0.rank == .bigJoker }
    }


    static func isStrongNoTrumpPair(_ cards: [Card], trumpRank: Rank) -> Bool {
        guard let rep = pairRepresentative(of: cards, trumpSuit: nil, trumpRank: trumpRank) else {
            return false
        }
        return rep.rank == trumpRank
            || rep.rank == .smallJoker
            || rep.rank == .bigJoker
            || rep.rank == .ace
    }


    static func isTrumpLead(_ move: AIMove, ts: Suit?, tr: Rank) -> Bool {
        guard let first = move.cards.first else { return false }
        return CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr)
    }


    static func containsBigTrump(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        cards.contains { isBigTrump($0, ts: ts, tr: tr) }
    }


    static func isBigTrump(_ card: Card, ts: Suit?, tr: Rank) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        return card.rank == .bigJoker
            || card.rank == .smallJoker
            || card.rank == tr
            || (card.suit == ts && card.rank == .ace)
    }


    static func trumpCards(in hand: [Card], ts: Suit?, tr: Rank) -> [Card] {
        hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
    }


    static func sideCardsRemaining(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
    }


    static func remainingTricks(for hand: [Card]) -> Int {
        hand.count
    }


    static func strongTrumpCount(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        trumpCards(in: hand, ts: ts, tr: tr).filter {
            isBigTrump($0, ts: ts, tr: tr)
                || CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue
        }.count
    }


    static func exposedPointCardsToProtect(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            .reduce(0) { $0 + $1.pointValue }
    }


    static func sidePairProtectionValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let control = ownTrumpControlFactor(in: hand, ts: ts, tr: tr)
        guard control > 0 else { return 0 }

        var bestValue = 0.0
        for suit in Suit.allCases {
            let voidEnemies = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue)
                .filter { !ctx.isVoid($0, key: "TRUMP") }
            guard !voidEnemies.isEmpty else { continue }

            let pairValue = strongestProtectableSidePairValue(in: hand, suit: suit, ts: ts, tr: tr, ctx: ctx)
            guard pairValue > 0 else { continue }

            let threat = trumpThreatScore(
                from: voidEnemies,
                hand: hand,
                state: state,
                ts: ts,
                tr: tr,
                ctx: ctx
            )
            guard threat > 0 else { continue }

            bestValue = max(bestValue, Double(pairValue) * threat * control)
        }
        return bestValue
    }


    static func strongestProtectableSidePairValue(
        in hand: [Card],
        suit: Suit,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext? = nil
    ) -> Int {
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        return pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
            .compactMap { pair -> Int? in
                guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else {
                    return nil
                }
                if let ctx, !isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr) {
                    return nil
                }
                return protectableSidePairValue(rep, trumpRank: tr)
            }
            .max() ?? 0
    }


    static func protectableSidePairValue(_ rep: Card, trumpRank: Rank) -> Int {
        // 牌力与是否已成为最大对决定可恢复的控制价值，不按分牌分档。
        12 + rep.rank.rawValue * 2
    }


    static func ownTrumpControlFactor(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        let strongCount = strongTrumpCount(in: hand, ts: ts, tr: tr)
        guard trumpCount >= 4, strongCount >= 2 else { return 0 }
        if trumpCount >= 8 && strongCount >= 4 { return 1.25 }
        if trumpCount >= 6 && strongCount >= 3 { return 1.05 }
        return 0.75
    }


    // MARK: - Asset Lifecycle (side-suit winners can depreciate then appreciate again)
    //
    // A side-suit winner's value is dynamic (card strength / control probability /
    // ruff risk / future realization potential): when an opponent is void in the suit
    // and may still hold trump, cashing it now gets ruffed -> current realization value
    // drops (depreciates); if we have enough trump control to pull the opponents' trumps,
    // then after pulling it becomes an absolute winner again (appreciates).
    // So for such assets prefer "pull trump first, realize later" over blindly cashing.

    /// Whether any unknown trumps (possibly in opponents' hands) remain — used to judge
    /// whether pulling trump is still meaningful.
    static func unknownEnemyTrumpsRemain(hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Bool {
        let total = referenceDeck.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
        let known = ctx.playedCards.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
            + hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
        return total - known > 0
    }

    /// Whether a side suit is currently "awaiting trump pull": an opponent is void in it
    /// and may still hold trump (cashing now would be ruffed), and we have trump control
    /// with pullable opponent trumps remaining -> the suit's winners re-appreciate after pulling.
    static func suitAwaitingTrumpPull(
        _ suit: Suit, position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard ownTrumpControlFactor(in: hand, ts: ts, tr: tr) > 0 else { return false }
        let ruffers = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue)
            .filter { !ctx.isVoid($0, key: "TRUMP") }
        guard !ruffers.isEmpty else { return false }
        return unknownEnemyTrumpsRemain(hand: hand, ts: ts, tr: tr, ctx: ctx)
    }

    /// Value of the winner assets we hold in a side suit (A / current top single / strongest protectable pair).
    static func heldSideWinnerValue(in hand: [Card], suit: Suit, ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        guard !suitCards.isEmpty else { return 0 }
        var value = strongestProtectableSidePairValue(in: hand, suit: suit, ts: ts, tr: tr, ctx: ctx)
        for card in suitCards
            where card.rank == .ace
                || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) {
            value = max(value, card.rank == .ace ? 40 : 30)
        }
        return value
    }

    /// "Delayed realization" asset value: we hold side-suit winners that would be ruffed now,
    /// but have trump control to pull. After pulling they re-appreciate. > 0 means prefer
    /// pulling trump first and delaying realization.
    static func delayedSideRealizationValue(
        position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let control = ownTrumpControlFactor(in: hand, ts: ts, tr: tr)
        guard control > 0 else { return 0 }
        var best = 0.0
        for suit in Suit.allCases {
            let suited = hand.filter { $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            let pairedIDs = pairedCardIDs(in: suited, trumpSuit: ts, trumpRank: tr)
            for pair in pairs(in: suited, trumpSuit: ts, trumpRank: tr) {
                guard let rep = pair.first,
                      isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr),
                      moveSuitAwaitingTrumpPull(pair, position: position, hand: hand, state: state, ctx: ctx) else { continue }
                best = max(best, Double(protectableSidePairValue(rep, trumpRank: tr)) * control)
            }
            for card in suited where !pairedIDs.contains(card.id)
                && (card.rank == .ace || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand)) {
                if moveSuitAwaitingTrumpPull([card], position: position, hand: hand, state: state, ctx: ctx) {
                    best = max(best, Double(card.rank == .ace ? 40 : 30) * control)
                }
            }
        }
        return best
    }


    static func trumpThreatScore(
        from voidEnemies: [PlayerPosition],
        hand: [Card],
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        let unknownPairFactor = unknownTrumpPairThreatFactor(hand: hand, ts: ts, tr: tr, ctx: ctx)
        guard unknownPairFactor > 0 else { return 0 }

        let enemyThreat = voidEnemies.map {
            trumpThreatScore(for: $0, state: state, ts: ts, tr: tr, ctx: ctx)
        }.max() ?? 0
        guard enemyThreat > 0 else { return 0 }

        return min(1.0, unknownPairFactor * enemyThreat)
    }


    static func unknownTrumpPairThreatFactor(hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        let trumpFaces = uniqueCardFaces(referenceDeck.filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        })
        let pairFaces = trumpFaces.filter { face in
            referenceDeck.filter { sameFace($0, face) }.count >= 2
        }
        guard !pairFaces.isEmpty else { return 0 }

        let unknownPairFaces = pairFaces.filter { face in
            let total = referenceDeck.filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            return total - known >= 2
        }
        guard !unknownPairFaces.isEmpty else { return 0 }

        let highPairFaces = pairFaces.filter {
            CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) >= 12
        }
        let consumedHighPairs = highPairFaces.filter { face in
            let total = referenceDeck.filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            return known >= total
        }.count

        let depletion = highPairFaces.isEmpty
            ? 1.0
            : max(0.25, 1.0 - Double(consumedHighPairs) / Double(highPairFaces.count) * 0.65)
        let remainingDensity = min(1.0, Double(unknownPairFaces.count) / 5.0)
        return remainingDensity * depletion
    }


    static func trumpThreatScore(
        for position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        if ctx.isVoid(position, key: "TRUMP") { return 0 }
        if failedToFollowTrumpPair(position: position, state: state, ts: ts, tr: tr) {
            return 0
        }

        var score = 1.0
        let trumpPlayed = trumpCardsPlayed(by: position, state: state, ts: ts, tr: tr)
        if trumpPlayed >= 5 {
            score *= 0.35
        } else if trumpPlayed >= 3 {
            score *= 0.55
        } else if trumpPlayed >= 1 {
            score *= 0.8
        }

        return score
    }


    static func trumpCardsPlayed(by position: PlayerPosition, state: GameState, ts: Suit?, tr: Rank) -> Int {
        let completed = state.completedTricks.flatMap(\.plays)
        let current = state.currentTrick.plays
        return (completed + current)
            .filter { $0.position == position }
            .flatMap(\.cards)
            .filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            .count
    }


    static func failedToFollowTrumpPair(
        position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank
    ) -> Bool {
        for trick in state.completedTricks {
            guard let leadCards = trick.leadCards,
                  pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil,
                  leadCards.allSatisfy({ CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }),
                  let play = trick.plays.first(where: { $0.position == position }) else {
                continue
            }
            let followedWithTrump = play.cards.filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            if followedWithTrump.count >= 2,
               pairRepresentative(of: Array(followedWithTrump.prefix(2)), trumpSuit: ts, trumpRank: tr) == nil {
                return true
            }
        }
        return false
    }


    static func remainingAssetValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        var value = 0.0
        value += remainingTrumpValue(in: hand, ts: ts, tr: tr) * 2.0
        value += sideControlValue(in: hand, ts: ts, tr: tr, ctx: ctx) * 1.4
        value += structureAssetValue(in: hand, ts: ts, tr: tr) * (ts == nil ? 2.2 : 1.4)
        value += slamOpportunityValue(position: position, hand: hand, state: state, ctx: ctx) * 1.3
        value += clearSuitOpportunityValue(in: hand, ts: ts, tr: tr, ctx: ctx) * 1.1
        value += initiativeNeed(position: position, hand: hand, state: state, ctx: ctx) * 0.2

        return value
    }


    static func remainingTrumpValue(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        trumpCards(in: hand, ts: ts, tr: tr).reduce(0.0) { partial, card in
            let weight = CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)
            if isBigTrump(card, ts: ts, tr: tr) { return partial + 5.0 }
            if weight >= Rank.king.rawValue { return partial + 2.0 }
            if card.pointValue > 0 { return partial + 0.5 }
            return partial + 1.0
        }
    }


    static func structureAssetValue(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        var value = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            value += 2.0
            if isStrongPairAsset(rep, ts: ts, tr: tr) { value += 3.0 }
            if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) { value += 1.0 }
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let pairCount = tractor.count / 2
                value += Double(pairCount) * 4.0
                if ts == nil { value += 4.0 }
            }
        }

        return value
    }


    static func slamOpportunityValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let slams = findSlamLeadCandidates(
            in: hand,
            ts: state.trumpSuit,
            tr: state.trumpRank,
            myTeam: position.team,
            ctx: ctx,
            position: position,
            state: state
        )

        return slams.reduce(0.0) { partial, cards in
            let points = cards.reduce(0) { $0 + $1.pointValue }
            return partial + Double(cards.count) * 2.0 + Double(points) / 5.0
        }
    }


    static func clearSuitOpportunityValue(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        var value = 0.0

        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            guard !suitCards.isEmpty, suitCards.count <= 2 else { continue }

            let points = suitCards.reduce(0) { $0 + $1.pointValue }
            value += 2.0
            value += Double(points) / 5.0
            if suitCards.contains(where: {
                ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
            }) {
                value += 3.0
            }
        }

        return value
    }


    static func sideControlValue(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        var value = 0.0
        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            guard !suitCards.isEmpty else { continue }
            if suitCards.contains(where: {
                ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
            }) {
                value += 2.0
            }
            if suitCards.count >= 3 { value += 0.8 }
            value += Double(suitCards.reduce(0) { $0 + $1.pointValue }) / 20.0
        }
        return value
    }


    static func countUnclearedSideSuits(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        Suit.allCases.filter { suit in
            hand.contains {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
        }.count
    }


    static func usedBigTrumpEarlyPenalty(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard isTrumpLead(move, ts: ts, tr: tr) else { return 0 }
        // 低成本交牌权不是提前消耗大主，不应套用数百点的全局出主扣分。
        if state.currentTrick.plays.isEmpty, move.cards.count == 1,
           let card = move.cards.first, card.pointValue == 0, !isBigTrump(card, ts: ts, tr: tr),
           trumpCards(in: hand, ts: ts, tr: tr).count >= trumpTransferMinTrumpCount,
           structureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr) == 0 { return 0 }

        let remaining = remainingTricks(for: hand)
        let sideSuits = countUnclearedSideSuits(in: hand, ts: ts, tr: tr)
        var penalty = 0.0

        if remaining > 5 && sideSuits >= 2 {
            penalty += 30
        }

        if remaining > 5 && sideCardsRemaining(in: hand, ts: ts, tr: tr) > trumpCards(in: hand, ts: ts, tr: tr).count {
            penalty += 80
        }

        if state.dealerTeamIdx != position.team && remaining > 5 {
            penalty += 12
        }

        for card in move.cards {
            if isBigTrump(card, ts: ts, tr: tr) {
                penalty += 25
            } else if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                penalty += 8
            }
        }

        if containsBigTrump(move.cards, ts: ts, tr: tr) && remaining > 5 {
            penalty += 20
        }

        return penalty
    }


    static func structureBreakPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let selected = Set(cards.map(\.id))
        var penalty = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let count = pair.filter { selected.contains($0.id) }.count
            if count == 1 { penalty += 1 }
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { selected.contains($0.id) }.count
                if used > 0 && used < tractor.count { penalty += 1.5 }
            }
        }
        return penalty
    }


    static func strongStructureBreakPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let selected = Set(cards.map(\.id))
        var penalty = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { selected.contains($0.id) }.count
            guard used == 1,
                  let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            penalty += isStrongPairAsset(rep, ts: ts, tr: tr) ? 2.5 : 0.8
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { selected.contains($0.id) }.count
                guard used > 0 && used < tractor.count else { continue }
                penalty += ts == nil ? 3.5 : 2.8
            }
        }

        return penalty
    }


    static func candidateWinsTrick(
        _ cards: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        var trick = state.currentTrick
        trick.plays.append((position: position, cards: cards))
        return evaluator.winner(of: trick) == position
    }


    static func classifyFollowMove(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> FollowWinClass {
        guard candidateWinsTrick(cards, position: position, state: state, evaluator: evaluator) else {
            return .cannotWin
        }
        if cards.contains(where: {
            CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }) {
            return isSecureWinningTrumpFollow(
                cards,
                position: position,
                hand: hand,
                state: state,
                evaluator: evaluator,
                ctx: ctx
            ) ? .finalWin : .temporaryWin
        }
        return isTrickSecureForTeam(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx,
            candidateCards: cards
        ) ? .finalWin : .temporaryWin
    }


    static func followWinClassScore(
        _ winClass: FollowWinClass,
        trickPoints: Int,
        playedPoints: Int
    ) -> Double {
        let totalPoints = trickPoints + playedPoints
        let pressure = pointPressureBonus(totalPoints: totalPoints)
        switch winClass {
        case .finalWin:
            return 26 + Double(2 * trickPoints + playedPoints) * 3.2 * pressure
        case .temporaryWin:
            return 8 + Double(trickPoints) * 1.6 * pressure - Double(playedPoints) * 3
        case .cannotWin:
            return -Double(playedPoints) * 7 * pressure
        }
    }


    static func followPointSwingScore(
        winClass: FollowWinClass,
        partnerWinningBefore: Bool,
        trickSecureBefore: Bool,
        trickSecureAfter: Bool,
        trickPoints: Int,
        playedPoints: Int,
        isLastPlayer: Bool
    ) -> Double {
        let totalPoints = trickPoints + playedPoints
        guard totalPoints > 0 else { return 0 }
        let pressure = pointPressureBonus(totalPoints: totalPoints)

        if partnerWinningBefore {
            if trickSecureBefore {
                return Double(playedPoints) * 5.5 * pressure
            }
            if trickSecureAfter || winClass == .finalWin {
                return Double(totalPoints) * 5.0 * pressure + Double(trickPoints) * 1.5
            }
            if winClass == .temporaryWin {
                let unsafePenalty = isLastPlayer ? 0.0 : Double(totalPoints) * 1.8
                return Double(totalPoints) * 2.0 * pressure - unsafePenalty
            }
            return -Double(playedPoints) * 8.0 * pressure - Double(trickPoints) * 1.5
        }

        switch winClass {
        case .finalWin:
            // Taking points also denies the points the opponents were about to win.
            return Double(2 * trickPoints + playedPoints) * 5.5 * pressure
        case .temporaryWin:
            let exposurePenalty = isLastPlayer ? 0.0 : Double(totalPoints) * 2.5
            return Double(2 * trickPoints + playedPoints) * 2.0 * pressure - exposurePenalty
        case .cannotWin:
            return -Double(playedPoints) * 8.0 * pressure
        }
    }


    static func isSecureWinningTrumpFollow(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Bool {
        guard candidateWinsTrick(cards, position: position, state: state, evaluator: evaluator),
              state.currentTrick.leadCards != nil,
              cards.allSatisfy({
                  CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
              }) else { return false }

        return isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator,
            ctx: ctx, candidateCards: cards
        )
    }


    static func clearsLogicalSuit(cards: [Card], hand: [Card], evaluator: TrickEvaluator) -> Bool {
        guard let first = cards.first else { return false }
        let suit = evaluator.cardSuit(first)
        let handCount = hand.filter { evaluator.cardSuit($0) == suit }.count
        let selectedCount = cards.filter { evaluator.cardSuit($0) == suit }.count
        return handCount == selectedCount
    }


    // MARK: - 后手位置辅助

    /// 判断当前我方领先是否已被已知信息严格锁定。
    /// 主牌只有在所有更高主牌的两张副本都已打出或在自己手中时才算安全；
    /// 牌面类别本身（小王、级牌、主 A）不能替代这一证明。
    static func isTrickSecureForTeam(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext,
        candidateCards: [Card] = []
    ) -> Bool {
        var trick = state.currentTrick
        if !candidateCards.isEmpty,
           !trick.plays.contains(where: { $0.position == position }) {
            trick.plays.append((position: position, cards: candidateCards))
        }

        let currentWinner = evaluator.winner(of: trick)
        guard currentWinner.team == position.team, trick.leadCards != nil else { return false }

        let futureOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team }
        if futureOpponents.isEmpty { return true }

        return !futureOpponents.contains { opponent in
            opponentCouldBeat(
                trick: trick, opponent: opponent, position: position, hand: hand,
                state: state, evaluator: evaluator, ctx: ctx
            )
        }
    }

    /// “未证明绝门”仍可能首次绝门；只有公开手牌足够跟门时才排除将吃。
    /// 对子和连对按完整结构检查未知威胁，而不是按更大的单张检查。
    static func opponentCouldBeat(
        trick: Trick, opponent: PlayerPosition, position: PlayerPosition,
        hand: [Card], state: GameState, evaluator: TrickEvaluator, ctx: AIContext
    ) -> Bool {
        guard let lead = trick.leadCards else { return false }
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let leadSuit = evaluator.dominantSuit(of: lead)
        var known = ctx.playedCards + hand
        if position == state.dealerPosition { known += state.kitty }
        var ids = Set<UUID>()
        known = known.filter { ids.insert($0.id).inserted }
        let available = removeKnownFaces(from: referenceDeck, knownCards: known)
            .filter { !ctx.isVoid(opponent, key: AIContext.suitKey($0, ts: ts, tr: tr)) }
        let revealed = ctx.knownCardsByPlayer[opponent] ?? []
        let mustFollow = revealed.filter { evaluator.cardSuit($0) == leadSuit }.count >= lead.count
        var pools = [available.filter { evaluator.cardSuit($0) == leadSuit }]
        if leadSuit != nil && !mustFollow {
            pools.append(available.filter { evaluator.cardSuit($0) == nil })
        }
        let winner = evaluator.winner(of: trick)
        let winningCards = trick.plays.first { $0.position == winner }!.cards
        for pool in pools where pool.count >= lead.count {
            let options: [[Card]]
            if lead.count == 1 { options = pool.map { [$0] } }
            else if let tractor = tractorInfo(of: lead, trumpSuit: ts, trumpRank: tr) {
                options = tractors(in: pool, pairCount: tractor.pairCount, trumpSuit: ts, trumpRank: tr)
            } else if isPairMove(lead, ts: ts, tr: tr) {
                options = pairs(in: pool, trumpSuit: ts, trumpRank: tr)
            } else {
                // 混合甩牌安全证明保守处理：无同门压制，只检查可能的主牌结构。
                guard pool.allSatisfy({ evaluator.cardSuit($0) == nil }),
                      let slam = evaluator.slamInfo(of: lead) else { continue }
                if let combo = buildMatchingSlamTrump(slam: slam, trumpCards: pool,
                                                       winningCards: winningCards, ts: ts, tr: tr,
                                                       stopAtFirstWinner: true) {
                    options = [combo]
                } else { options = [] }
            }
            for option in options {
                var test = trick
                test.plays.append((position: opponent, cards: option))
                if evaluator.winner(of: test) == opponent { return true }
            }
        }
        return false
    }


    static func shouldRiskUnsafeWin(
        trickPoints: Int,
        playedPoints: Int,
        ctx: AIContext
    ) -> Bool {
        if ctx.isLastPlayer { return true }
        let totalPoints = trickPoints + playedPoints
        if totalPoints >= 15 { return false }
        if totalPoints >= 5 { return playedPoints == 0 }
        return true
    }


    static func isSafeTrump(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        // “安全”在调用方会被当作本墩已锁定，因此不能仅凭它属于王、级牌或
        // 主 A 就近似放行；小王仍会被大王盖，级牌和主 A 也仍有更高主牌。
        return noUnknownHigherTrumpThan(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }


    static func noUnknownHigherTrumpThan(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }

        let higherTrumpFaces = uniqueCardFaces(
            referenceDeck.filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && CardComparator.beats($0, card, trumpSuit: ts, trumpRank: tr)
            }
        )

        for face in higherTrumpFaces {
            let total = referenceDeck.filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            if known < total { return false }
        }
        return true
    }


    static func isSafeTrumpFiller(
        _ card: Card,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext,
        hand: [Card] = []
    ) -> Bool {
        isSafeTrump(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }


    static func uniqueCardFaces(_ cards: [Card]) -> [Card] {
        var seen = Set<String>()
        var result: [Card] = []
        for card in cards {
            let key = "\(card.suit?.rawValue ?? "J")-\(card.rank.rawValue)"
            if seen.insert(key).inserted {
                result.append(card)
            }
        }
        return result
    }


    /// 跟单牌时，如果后手对手可能用本门分牌反超，优先出能压住该分牌的最小牌。
    /// leadSuit == nil 表示主牌；本墩已有分时，候选牌还必须挡住更高牌的后手反超。
    static func pointGuardCard(
        from candidates: [Card],
        leadSuit: Suit?,
        winningRep: Card,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        trickPoints: Int,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Card? {
        guard !candidates.isEmpty, !ctx.isLastPlayer else { return nil }

        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let subsequent = unplayedSubsequentPositions(after: position, in: state)
        let opponentsAfter = subsequent.filter { $0.team != position.team && !ctx.isVoid($0, key: leadKey) }.count
        let partnersAfter = subsequent.filter { $0.team == position.team && !ctx.isVoid($0, key: leadKey) }.count
        guard opponentsAfter > partnersAfter else { return nil }

        for pointCard in pointThreatCards(leadSuit: leadSuit, ts: ts, tr: tr) {
            guard remainingUnknownCopies(of: pointCard, hand: hand, ctx: ctx) > 0 else { continue }
            guard CardComparator.beats(pointCard, winningRep, trumpSuit: ts, trumpRank: tr) else {
                continue
            }

            let guardCandidates = candidates
                .filter { CardComparator.beats($0, pointCard, trumpSuit: ts, trumpRank: tr) }
                .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard !guardCandidates.isEmpty else { continue }
            if trickPoints > 0 {
                if let safeCard = guardCandidates.first(where: {
                    isProtectedAgainstHigher($0, leadSuit: leadSuit, hand: hand, ts: ts, tr: tr, ctx: ctx)
                }) {
                    return safeCard
                }
                return guardCandidates.last
            }
            return guardCandidates.first
        }

        return nil
    }


    static func pointThreatCards(leadSuit: Suit?, ts: Suit?, tr: Rank) -> [Card] {
        let pointRanks: [Rank] = [.king, .ten, .five]
        let cards: [Card]

        if let suit = leadSuit {
            cards = pointRanks
                .filter { $0 != tr }
                .map { Card(suit: suit, rank: $0) }
        } else {
            var trumpPoints: [Card] = []
            for rank in pointRanks {
                if rank == tr {
                    trumpPoints += Suit.allCases.map { Card(suit: $0, rank: rank) }
                } else if let trumpSuit = ts {
                    trumpPoints.append(Card(suit: trumpSuit, rank: rank))
                }
            }
            cards = trumpPoints.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        }

        return cards.sorted {
            cardStrength($0, ts: ts, tr: tr) > cardStrength($1, ts: ts, tr: tr)
        }
    }


    static func remainingUnknownCopies(of card: Card, hand: [Card], ctx: AIContext) -> Int {
        let played = ctx.playedCards.filter { sameFace($0, card) }.count
        let inHand = hand.filter { sameFace($0, card) }.count
        return max(0, 2 - played - inHand)
    }


    static func isProtectedAgainstHigher(
        _ card: Card,
        leadSuit: Suit?,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        if let suit = leadSuit {
            return isSideSuitProtectedAgainstHigher(card, suit: suit, hand: hand, ts: ts, tr: tr, ctx: ctx)
        }
        return isTrumpProtectedAgainstHigher(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }


    static func isTrumpProtectedAgainstHigher(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        return noUnknownHigherTrumpThan(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }


    static func isSideSuitProtectedAgainstHigher(
        _ card: Card,
        suit: Suit,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              card.suit == suit else { return false }

        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { rank in
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            return played + inHand >= 2
        }
    }
}
