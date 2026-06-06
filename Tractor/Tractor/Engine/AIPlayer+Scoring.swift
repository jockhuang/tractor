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
    static func structureFragmentationCost(_ cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let sel = Set(cards.map(\.id))
        var cost = 0.0
        // 拆对子：按对子价值分级
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { sel.contains($0.id) }.count
            guard used == 1, let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            cost += pairAssetWeight(rep, ts: ts, tr: tr)
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
        for slam in findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: position.team, ctx: ctx) {
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
        if rep.rank == .king || rep.rank == .ten { return 0.7 }
        if rep.pointValue > 0 { return 0.6 }
        return 0.4
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
                return partial + ((card.rank == .ace || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr)) ? 0.35 : 0.1)
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

        var score = 0.0
        score += followPointSwingScore(
            winClass: winClass,
            partnerWinningBefore: partnerWinningBefore,
            trickSecureBefore: trickSecureBefore,
            trickSecureAfter: trickSecureAfter,
            trickPoints: trickPoints,
            playedPoints: playedPoints,
            isLastPlayer: ctx.isLastPlayer
        )

        // ── 统一的「用主控墩」决策（Trump Control）──────────────────────
        // 吊主跟牌 / 绝门将吃 / 盖吃对手将牌 / 帮队友锁定 / 抢回出牌权——
        // 所有「是否花主牌去拿、保、抢这一墩」的判断都走同一个模型，避免各处零散加减分互相冲突。
        // 非主走法才用通用赢墩分类分，避免与模型重复计分。
        if usesTrump {
            score += trumpControlScore(
                move, leadCards: leadCards, hand: hand,
                position: position, state: state, evaluator: evaluator, ctx: ctx
            )
        } else {
            score += followWinClassScore(winClass, trickPoints: trickPoints, playedPoints: playedPoints)
        }

        // ── 通用项（主/非主都适用）：垫分、清门、拆结构 ──────────────────
        if partnerWinningBefore {
            score += trickSecureBefore ? Double(playedPoints) * 4 : -Double(playedPoints) * 8
            score += clearsSuit ? 8 : 0
            if candidateWins && !usesTrump { score -= 30 }   // 非主盖队友：罚（主牌盖队友由模型判断）
            score -= breakPenalty * 18 * preservationDamp
            score -= strongBreakPenalty * 24 * preservationDamp
            if playedPoints == 0 { score += 4 }
            if !trickSecureBefore && move.kind == .followSupport {
                score -= trickPoints >= 15 ? 80 : 35
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
            let opponentCapture = opponentTrickWinProbability(
                move, hand: hand, position: position,
                state: state, evaluator: evaluator, ctx: ctx
            )
            score -= exposedPoints * opponentCapture * pointExposureWeight
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
                pKeep *= (1 - playerBeatProbability(
                    winRep, by: opp, leadSuit: leadSuit, hand: hand, ts: ts, tr: tr, ctx: ctx
                ))
            }
            return 1 - pKeep
        } else {
            // 对手领先：后手队友能救回则降低对手概率（忽略救回后再被反超的二阶情况）
            let partnersAfter = subsequent.filter { $0.team == position.team }
            if partnersAfter.isEmpty { return 1.0 }
            var pRescue = 0.0
            for p in partnersAfter {
                pRescue = max(pRescue, playerBeatProbability(
                    winRep, by: p, leadSuit: leadSuit, hand: hand, ts: ts, tr: tr, ctx: ctx
                ))
            }
            return 1 - pRescue
        }
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
        ctx: AIContext
    ) -> Double {
        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let leadIsTrump = leadSuit == nil
        let winIsTrump = CardComparator.isTrump(winRep, trumpSuit: ts, trumpRank: tr)
        let voidInLead = ctx.isVoid(player, key: leadKey)
        let voidInTrump = ctx.isVoid(player, key: "TRUMP")

        if !voidInLead {
            // 必须跟先手花色
            if leadIsTrump {
                if noUnknownHigherTrumpThan(winRep, hand: hand, ts: ts, tr: tr, ctx: ctx) { return 0 }
                return overtakeChance(unknownHigherTrumpCopies(winRep, hand: hand, ts: ts, tr: tr, ctx: ctx))
            }
            // 先手是副牌：当前赢家已是主（有人将吃）时，跟副牌者无法反超
            if winIsTrump { return 0 }
            guard let suit = winRep.suit else { return 0 }
            if isSideSuitProtectedAgainstHigher(winRep, suit: suit, hand: hand, ts: ts, tr: tr, ctx: ctx) { return 0 }
            return overtakeChance(unknownHigherSideCopies(winRep, suit: suit, hand: hand, tr: tr, ctx: ctx))
        }

        // 已绝先手花色
        if voidInTrump { return 0 }            // 同时绝主 → 无法反超
        if winIsTrump {
            // 当前赢家已是主，需要更大的主才能盖吃
            if noUnknownHigherTrumpThan(winRep, hand: hand, ts: ts, tr: tr, ctx: ctx) { return 0 }
            return overtakeChance(unknownHigherTrumpCopies(winRep, hand: hand, ts: ts, tr: tr, ctx: ctx))
        }
        // 当前赢家是副牌，绝门玩家可用任意主将吃
        return 0.6
    }


    /// 未知（不在已出牌 + 自己手牌中）的、比 `card` 更大的主牌张数。
    static func unknownHigherTrumpCopies(_ card: Card, hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        let higherFaces = uniqueCardFaces(
            Deck.doubleDeck().filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && CardComparator.beats($0, card, trumpSuit: ts, trumpRank: tr)
            }
        )
        var count = 0
        for face in higherFaces {
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
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
        let canWinTrick = legalMoves.contains {
            candidateWinsTrick($0.cards, position: position, state: state, evaluator: evaluator)
        }
        if canWinTrick { return .pointCapture }
        let canBeatCurrentWinner = legalMoves.contains {
            candidateWinsTrick($0.cards, position: position, state: state, evaluator: evaluator)
                && currentWinnerOpponentBeaten($0, position: position, state: state, evaluator: evaluator)
        }
        if canBeatCurrentWinner { return .forceOpponentCost }
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


    /// 战术候选过滤（不直接选牌，只裁掉明显违背当前战术的动作，最终仍交给 Monte Carlo）。
    /// 阻分 / 抢分模式下：若存在非 D 类动作，则裁掉 D 类（往未锁定墩追加分牌，如用 K 争抢）。
    static func tacticalCandidateFilter(
        _ moves: [AIMove],
        mode: TacticalMode,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        guard isPointContestMode(mode), moves.count > 1 else { return moves }
        let nonRisky = moves.filter {
            classifyPointDenialMove($0, hand: hand, position: position,
                                    state: state, evaluator: evaluator, ctx: ctx) != .riskyExposure
        }
        return nonRisky.isEmpty ? moves : nonRisky
    }


    /// 主牌强度归一化到 0...1（大王=1.0）。用于"逼对手付出代价"与"过度杀伤"评估。
    static func trumpStrengthFraction(_ card: Card, ts: Suit?, tr: Rank) -> Double {
        let w = CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? Double(CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr))
            : Double(card.rank.rawValue)
        return min(1.0, max(0.0, w / 100.0))
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
            ctx: ctx
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
                if ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) { cost += 10 }
            }
            return cost
        } + structureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 20
            + strongStructureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 24
    }


    static func countSafeBigSideCards(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        hand.filter {
            !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                && ($0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr))
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

            let pairValue = strongestProtectableSidePairValue(in: hand, suit: suit, ts: ts, tr: tr)
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
        tr: Rank
    ) -> Int {
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        return pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
            .compactMap { pair -> Int? in
                guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else {
                    return nil
                }
                return protectableSidePairValue(rep, trumpRank: tr)
            }
            .max() ?? 0
    }


    static func protectableSidePairValue(_ rep: Card, trumpRank: Rank) -> Int {
        var value = 0
        switch rep.rank {
        case .ace:
            value += 40
        case .king:
            value += 30
        case .ten:
            value += 20
        default:
            break
        }
        if rep.rank == trumpRank { value += 50 }
        if rep.pointValue > 0 { value += 20 }
        return value
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
        let total = Deck.doubleDeck().filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
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
        var value = strongestProtectableSidePairValue(in: hand, suit: suit, ts: ts, tr: tr)
        for card in suitCards where card.rank == .ace || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) {
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
        for suit in Suit.allCases
            where suitAwaitingTrumpPull(suit, position: position, hand: hand, state: state, ctx: ctx) {
            best = max(best, Double(heldSideWinnerValue(in: hand, suit: suit, ts: ts, tr: tr, ctx: ctx)) * control)
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
        let trumpFaces = uniqueCardFaces(Deck.doubleDeck().filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        })
        let pairFaces = trumpFaces.filter { face in
            Deck.doubleDeck().filter { sameFace($0, face) }.count >= 2
        }
        guard !pairFaces.isEmpty else { return 0 }

        let unknownPairFaces = pairFaces.filter { face in
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            return known < total
        }
        guard !unknownPairFaces.isEmpty else { return 0 }

        let highPairFaces = pairFaces.filter {
            CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) >= 12
        }
        let consumedHighPairs = highPairFaces.filter { face in
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
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
            ctx: ctx
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
            if suitCards.contains(where: { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) {
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
            if suitCards.contains(where: { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) {
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
              let leadCards = state.currentTrick.leadCards,
              cards.allSatisfy({
                  CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
              }) else { return false }

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let futureOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team }
        if futureOpponents.isEmpty { return true }

        let trumpThreatOpponents: [PlayerPosition]
        if leadSuit == nil {
            trumpThreatOpponents = futureOpponents.filter { !ctx.isVoid($0, key: "TRUMP") }
        } else {
            trumpThreatOpponents = futureOpponents.filter {
                ctx.isVoid($0, key: leadKey) && !ctx.isVoid($0, key: "TRUMP")
            }
        }
        if trumpThreatOpponents.isEmpty { return true }

        guard let highTrump = cards.max(by: {
            CardComparator.beats($1, $0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }) else { return false }
        return noUnknownHigherTrumpThan(highTrump, hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx)
    }


    static func clearsLogicalSuit(cards: [Card], hand: [Card], evaluator: TrickEvaluator) -> Bool {
        guard let first = cards.first else { return false }
        let suit = evaluator.cardSuit(first)
        let handCount = hand.filter { evaluator.cardSuit($0) == suit }.count
        let selectedCount = cards.filter { evaluator.cardSuit($0) == suit }.count
        return handCount == selectedCount
    }


    // MARK: - 后手位置辅助

    /// 判断某张主牌是否适合在「我方绝牌且后手对手也绝花色」时用作安全垫牌
    /// 安全：大小王、级牌（逻辑强度高，压不走）/ 主花色 A
    /// 不安全：主花色 K 及以下（容易被后手稍大的主牌截走）
    /// 判断一张主牌是否"安全"（出了不容易被后手对手用更大主牌顺手截分）
    /// 始终安全：大王 / 小王 / 级牌 / 主花色 A 及以上
    /// 动态安全：比该牌大的主花色分牌（K/10/5，排除级牌）已全部出完（双副牌各 2 张）
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
        guard currentWinner.team == position.team,
              let winningCards = trick.plays.first(where: { $0.position == currentWinner })?.cards,
              let leadCards = trick.leadCards else { return false }

        let futureOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team }
        if futureOpponents.isEmpty { return true }

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let winningRep = maxCard(in: winningCards, ts: state.trumpSuit, tr: state.trumpRank)

        if CardComparator.isTrump(winningRep, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank),
           isSafeTrump(winningRep, hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx) {
            return true
        }

        let allFutureOpponentsMustFollow = futureOpponents.allSatisfy {
            !ctx.isVoid($0, key: leadKey)
        }
        if allFutureOpponentsMustFollow {
            return isProtectedAgainstHigher(
                winningRep,
                leadSuit: leadSuit,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: ctx
            )
        }

        let allFutureOpponentsNoTrump = futureOpponents.allSatisfy {
            ctx.isVoid($0, key: "TRUMP")
        }
        if allFutureOpponentsNoTrump {
            if CardComparator.isTrump(winningRep, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) {
                return true
            }
            return isProtectedAgainstHigher(
                winningRep,
                leadSuit: leadSuit,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: ctx
            )
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
        if card.rank == .bigJoker || card.rank == .smallJoker { return true }
        if card.rank == tr { return true }
        if card.rank.rawValue >= Rank.ace.rawValue { return true }   // 主花色 A（不含 K）

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
            Deck.doubleDeck().filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && CardComparator.beats($0, card, trumpSuit: ts, trumpRank: tr)
            }
        )

        for face in higherTrumpFaces {
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
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
        if card.rank == .bigJoker || card.rank == .smallJoker { return true }
        if card.rank == tr { return true }

        guard let suit = card.suit, suit == ts else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { rank in
            let higherCard = Card(suit: suit, rank: rank)
            return remainingUnknownCopies(of: higherCard, hand: hand, ctx: ctx) == 0
        }
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
