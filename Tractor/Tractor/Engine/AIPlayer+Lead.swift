import Foundation

// MARK: - AIPlayer 先手（领牌）策略（结构性拆分，逻辑未改）

extension AIPlayer {


    // MARK: - 先手策略

    static func leadCards(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        let assets = filterAllowedLeadAssets(
            deduplicatedLeadAssets(buildLeadAssets(position: position, hand: hand, state: state, ctx: ctx)),
            position: position, hand: hand, state: state
        )
        // 先识别会随绝门而贬值的兑现窗口，再考虑保底/清门。保留最后主控
        // 不能把安全副A降成杂牌，短期抽样也不能假定留到以后仍能兑现。
        if let cashing = cashingWindowAssets(assets, position: position, hand: hand, state: state, ctx: ctx) {
            return bestLeadAssetCards(cashing, position: position, hand: hand,
                state: state, evaluator: evaluator, ctx: ctx)
        }

        if let bottomControlLead = knownPointKittyEndgameLead(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        ) {
            return bottomControlLead
        }

        if let preserved = endgameControlPreservationLead(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        ) {
            return preserved
        }

        guard !assets.isEmpty else {
            return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
        }

        return bestLeadAssetCards(assets, position: position, hand: hand,
            state: state, evaluator: evaluator, ctx: ctx)
    }

    /// 时效性机会约束，而不是“所有A无条件先出”。窗口内允许多个副A、
    /// 已知最大对与完整控制组共同择优；其他有明确目标的方案在窗口外照常比较。
    static func cashingWindowAssets(
        _ assets: [LeadAsset], position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> [LeadAsset]? {
        // 对手已绝主后，副牌控制不再因将吃而贬值，可以先跑分/安排末墩。
        guard !ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP") else { return nil }
        let cashing = assets.filter { asset in
            guard asset.tier == .cashingWinner || asset.tier == .safeControlGroup,
                  !isTrumpLead(asset.move, ts: state.trumpSuit, tr: state.trumpRank),
                  !moveSuitAwaitingTrumpPull(asset.move.cards, position: position,
                    hand: hand, state: state, ctx: ctx) else { return false }
            let security = leadTeamControlProbability(asset.move.cards, position: position,
                hand: hand, state: state, ctx: ctx)
            let key = AIContext.suitKey(asset.move.cards[0], ts: state.trumpSuit, tr: state.trumpRank)
            let knownRuffer = ctx.voidEnemies(myTeam: position.team, key: key)
                .contains { !ctx.isVoid($0, key: "TRUMP") }
            // 首次绝门的低概率不等于严格锁定；已知有将吃者时只兑现近乎
            // 无法将吃的完整结构，不拿裸A冒险。
            return security >= (knownRuffer ? 0.95 : 0.8)
        }
        return cashing.isEmpty ? nil : cashing
    }

    static func bestLeadAssetCards(
        _ assets: [LeadAsset], position: PlayerPosition, hand: [Card], state: GameState,
        evaluator: TrickEvaluator, ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let plan = leadControlPlan(position: position, hand: hand, state: state, ctx: ctx)
        let purposefulAssets = filterUnplannedSideFallback(assets, position: position, hand: hand, state: state, ctx: ctx)
        let assetPool = selectLeadAssetPool(purposefulAssets, preferTrumpTransfer: plan != .reassessSideAssets)
        let rankedAssets = assetPool.sorted {
            if $0.tier.rawValue != $1.tier.rawValue { return $0.tier.rawValue < $1.tier.rawValue }
            if $0.score != $1.score { return $0.score > $1.score }
            return leadAssetTieBreakScore($0.move, hand: hand, state: state, ctx: ctx)
                > leadAssetTieBreakScore($1.move, hand: hand, state: state, ctx: ctx)
        }

        let topAssets = Array(rankedAssets.prefix(monteCarloTopMoveCount))
        let heuristicScores = Dictionary(
            uniqueKeysWithValues: topAssets.map { (moveKey($0.move.cards), $0.score) }
        )
        let topMoves = topAssets.map(\.move)
        return monteCarloBestMove(
            from: topMoves,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            heuristicScore: { heuristicScores[moveKey($0.cards)] ?? 0 }
        )?.cards ?? rankedAssets.first?.move.cards ?? weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }


    static func leadCardsRuleBased(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let myTeam = position.team

        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        // ── 0. 甩牌：同一花色有 2+ 张最大牌时一起甩出 ─────────────
        if let slamCards = findSlamLead(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx) {
            return slamCards
        }

        // ── 1. 当前"已是最大"的非主牌中，优先出对子 ──────────────
        // 按花色分组，找有"当前最大"牌的花色（且不是敌方已绝的花色）
        var biggestBySuit: [Suit: [Card]] = [:]
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) {
            guard let suit = card.suit else { continue }
            let key = AIContext.suitKey(card, ts: ts, tr: tr)
            // 敌方已全绝此花色，领出无意义（对方会将吃）
            if ctx.allEnemiesVoid(myTeam: myTeam, key: key) { continue }
            biggestBySuit[suit, default: []].append(card)
        }

        // 找"最大"牌里有对子的花色 → 出对子
        for (_, cards) in biggestBySuit {
            var grouped: [String: [Card]] = [:]
            for c in cards {
                grouped[CardComparator.pairKey(c, trumpSuit: ts, trumpRank: tr), default: []].append(c)
            }
            if let pair = grouped.values.first(where: { $0.count >= 2 }) {
                return Array(pair.prefix(2))
            }
        }

        // 找"最大"单牌，优先出最大的
        if let best = biggestBySuit.values.flatMap({ $0 })
            .sorted(by: { $0.rank.rawValue > $1.rank.rawValue }).first {
            return [best]
        }

        // ── 2. 旁门 Ace（且敌方未绝此花色）─────────────────────
        if let sideAce = bestSideAce(in: hand, trumpSuit: ts, trumpRank: tr,
                                      myTeam: myTeam, ctx: ctx) {
            return [sideAce]
        }

        // ── 3. 非主花色连对 ──────────────────────────────────
        if let tractor = findTractor(in: hand, trumpSuit: ts, trumpRank: tr) {
            return tractor
        }

        // ── 4. 队友绝花色且该花色有分未出 → 引出队友垫分 ────
        // 找队友位置，检查队友已绝的花色里哪些还有分牌未出
        // 领出该花色让队友把手中分牌垫给我们
        if let partnerPos = PlayerPosition.allCases.first(where: { $0.team == myTeam && $0 != position }) {
            // 收集候选：队友已绝 & 该花色有分未出 & AI手中有该花色牌
            var candidates: [(strongest: Card, suitCards: [Card])] = []
            for suit in Suit.allCases {
                let key = suit.rawValue
                guard ctx.isVoid(partnerPos, key: key) else { continue }
                guard ctx.unplayedSuitPoints(suit: suit, tr: tr) > 0 else { continue }
                let sc = sideCards.filter { $0.suit == suit }
                guard let strongest = sc.max(by: {
                    CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
                }) else { continue }
                candidates.append((strongest: strongest, suitCards: sc))
            }
            // 从候选中选最强的花色
            if let best = candidates.max(by: {
                CardComparator.beats($1.strongest, $0.strongest, trumpSuit: ts, trumpRank: tr)
            }) {
                // 有对子则出对子
                if let p = pairs(in: best.suitCards, trumpSuit: ts, trumpRank: tr)
                    .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                    return p
                }
                return [best.strongest]
            }
        }

        // ── 5. 非主花色对子（避免敌方已绝花色）──────────────────
        if let pair = findBestPairAvoidingVoid(in: hand, ts: ts, tr: tr,
                                               myTeam: myTeam, ctx: ctx) {
            return pair
        }
        if let pair = findPair(in: hand, trumpSuit: ts, trumpRank: tr) {
            return pair
        }

        // ── 6. 小主牌（无分孤张优先，再有分，再最弱主对）────
        if let card = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                         trumpSuit: ts, trumpRank: tr).first { return [card] }
        if let card = leadableSingletons(from: hand, isTrump: true, pointOnly: nil,
                                         trumpSuit: ts, trumpRank: tr).first { return [card] }
        if let p = findWeakestTrumpPair(in: hand, nonPointFirst: true,
                                         trumpSuit: ts, trumpRank: tr) { return p }

        // ── 7. 主牌不多时，改从副牌中出较大的 ──────────────
        // 当手中主牌 ≤ 3 张时，主动领副牌大牌以尽量赢墩
        let trumpCount = hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
        if trumpCount <= 3, !sideCards.isEmpty {
            // 按牌力从大到小排，选最强非主牌（忽略是否已是最大）
            let strongest = sideCards.sorted {
                CardComparator.beats($0, $1, trumpSuit: ts, trumpRank: tr)
            }
            // 有对子则出对子（强对）
            if let p = pairs(in: sideCards, trumpSuit: ts, trumpRank: tr)
                .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                return p
            }
            if let card = strongest.first { return [card] }
        }

        // ── 8. 最弱牌（最后兜底）────────────────────────────
        return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }


    static func buildLeadAssets(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> [LeadAsset] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let myTeam = position.team
        let safeGroups = findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam,
            ctx: ctx, position: position, state: state)
        // Asset Lifecycle: when a side suit would be ruffed now but re-appreciates after
        // pulling trump, do not treat it as an immediate Tier 1 cashing asset (delay, pull first).
        let cashingGroups = safeGroups.filter {
            isTimeSensitiveSideControlGroup($0, hand: hand, ts: ts, tr: tr, ctx: ctx)
                && !moveSuitAwaitingTrumpPull($0, position: position, hand: hand, state: state, ctx: ctx)
        }
        let protectedGroups = cashingGroups + safeGroups

        var assets: [LeadAsset] = []

        // Tier 1: realize side-suit winners before they decay into ruff risk.
        for cards in cashingGroups {
            let move = AIMove(cards: cards, kind: .slam)
            assets.append(LeadAsset(
                move: move,
                tier: .cashingWinner,
                score: leadAssetScore(move, tier: .cashingWinner, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }
        for move in findAbsoluteSideWinnerLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups)
                && !moveSuitAwaitingTrumpPull(move.cards, position: position, hand: hand, state: state, ctx: ctx) {
            assets.append(LeadAsset(
                move: move,
                tier: .cashingWinner,
                score: leadAssetScore(move, tier: .cashingWinner, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // Tier 2: safe whole groups. They are compared as groups, not as A plus pair fragments.
        for cards in safeGroups where !cashingGroups.contains(where: { sameCardSet($0, cards) }) {
            let move = AIMove(cards: cards, kind: .slam)
            assets.append(LeadAsset(
                move: move,
                tier: .safeControlGroup,
                score: leadAssetScore(move, tier: .safeControlGroup, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // Tier 3: stable structures that preserve control.
        let structureMoves =
            findTractorLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            + findStrongPairLeadCandidates(in: hand, position: position, state: state, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            + findNoTrumpControlLeadCandidates(in: hand, position: position, state: state, trumpSuit: ts, trumpRank: tr)
        for move in structureMoves where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups) {
            assets.append(LeadAsset(
                move: move,
                tier: .strongStructure,
                score: leadAssetScore(move, tier: .strongStructure, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // 副牌孤对尽早整出清门；J及以上对子在没有更好资产时先试，
        // 避免普通吊主让对子一直留到被迫拆跟。仍保留明确的先拔主保护计划。
        for move in findTimelySidePairLeadCandidates(
            in: hand, position: position, state: state, ctx: ctx
        ) where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups) {
            assets.append(LeadAsset(
                move: move, tier: .sidePairOpportunity,
                score: leadAssetScore(move, tier: .sidePairOpportunity,
                    position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // Build future control only after no cashing/group/structure/pair asset needs action.
        var initiativeMoves =
            findPartnerDumpLeadCandidates(in: hand, position: position, ts: ts, tr: tr, ctx: ctx)
            + findWeakPairDisposalLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
                .filter { !isTrumpLead($0, ts: ts, tr: tr) }
            + findTrumpLeadCandidates(in: hand, position: position, state: state, ts: ts, tr: tr, ctx: ctx)
            + findTrumpTransferLeadCandidates(in: hand, ts: ts, tr: tr)
        if leadControlPlan(position: position, hand: hand, state: state, ctx: ctx) == .reassessSideAssets {
            // 经历过队友/对手领牌后再拿回牌权，要重新考虑清门和杂牌处理，
            // 这些走法不再被默认吊主挡在下一层。
            initiativeMoves += findLongSuitDevelopmentLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            initiativeMoves += findWeakLeadCandidates(in: hand, ts: ts, tr: tr)
                .filter { !isTrumpLead($0, ts: ts, tr: tr) }
        }
        for move in initiativeMoves where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups) {
            assets.append(LeadAsset(
                move: move,
                tier: .initiativeBuilder,
                score: leadAssetScore(move, tier: .initiativeBuilder, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // Disposal, including ordinary weak pairs only when nothing strategic exists.
        let disposalMoves =
            findWeakLeadCandidates(in: hand, ts: ts, tr: tr)
            + findLongSuitDevelopmentLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            + findWeakPairDisposalLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
        for move in disposalMoves where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups) {
            assets.append(LeadAsset(
                move: move,
                tier: .weakDisposal,
                score: leadAssetScore(move, tier: .weakDisposal, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        return assets
    }


    static func deduplicatedLeadAssets(_ assets: [LeadAsset]) -> [LeadAsset] {
        var byKey: [String: LeadAsset] = [:]
        for asset in assets where !asset.move.cards.isEmpty {
            let key = moveKey(asset.move.cards)
            if let existing = byKey[key] {
                if asset.tier.rawValue < existing.tier.rawValue
                    || (asset.tier == existing.tier && asset.score > existing.score) {
                    byKey[key] = asset
                }
            } else {
                byKey[key] = asset
            }
        }
        return Array(byKey.values)
    }


    static func filterAllowedLeadAssets(
        _ assets: [LeadAsset],
        position: PlayerPosition,
        hand: [Card],
        state: GameState
    ) -> [LeadAsset] {
        let valid = assets.filter {
            !$0.move.cards.isEmpty
                && $0.move.cards.allSatisfy { card in hand.contains(where: { $0.id == card.id }) }
        }
        let allowed = valid.filter {
            allowTrumpLead(state: state, position: position, hand: hand, move: $0.move)
        }
        if !allowed.isEmpty { return allowed }

        let nonTrump = valid.filter {
            !isTrumpLead($0.move, ts: state.trumpSuit, tr: state.trumpRank)
        }
        return nonTrump.isEmpty ? valid : nonTrump
    }


    static func selectLeadAssetPool(_ assets: [LeadAsset], preferTrumpTransfer: Bool = true) -> [LeadAsset] {
        // 层级是先验，不是互斥开关。兑现、结构、试对、牌权计划和清门
        // 各保留一个最佳代表，余下名额再按分补齐，让低成本替代也能接受模拟。
        let ranked = assets.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if preferTrumpTransfer && ($0.move.kind == .trumpTransfer) != ($1.move.kind == .trumpTransfer) {
                return $0.move.kind == .trumpTransfer
            }
            return moveKey($0.move.cards) < moveKey($1.move.cards)
        }
        func family(_ asset: LeadAsset) -> Int {
            asset.tier == .safeControlGroup ? LeadAssetTier.cashingWinner.rawValue : asset.tier.rawValue
        }
        var selected: [LeadAsset] = []
        var families = Set<Int>()
        var keys = Set<String>()
        for asset in ranked where families.insert(family(asset)).inserted {
            guard selected.count < monteCarloTopMoveCount else { break }
            selected.append(asset)
            keys.insert(moveKey(asset.move.cards))
        }
        for asset in ranked where selected.count < monteCarloTopMoveCount {
            if keys.insert(moveKey(asset.move.cards)).inserted { selected.append(asset) }
        }
        return selected
    }


    static func leadAssetScore(
        _ move: AIMove,
        tier: LeadAssetTier,
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let cards = move.cards
        let points = Double(cards.reduce(0) { $0 + $1.pointValue })
        let security = leadTeamControlProbability(cards, position: position, hand: hand, state: state, ctx: ctx)
        let pointPressure = pointPressureBonus(totalPoints: Int(points))
        let endgameAdjustment = endgameControlPreservationScoreAdjustment(
            move,
            position: position,
            hand: hand,
            state: state
        )

        let base: Double
        switch tier {
        case .cashingWinner:
            base = 400
                + points * 8 * pointPressure
                + security * 90
                + Double(cards.count) * 18
                + sideSuitUrgency(cards, position: position, hand: hand, ts: ts, tr: tr, ctx: ctx)
        case .safeControlGroup:
            base = 320
                + security * 85
                + Double(cards.count) * 24
                + points * 5
                + mixedSlamControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * 55
        case .strongStructure:
            base = 240
                + security * 70
                + points * 4
                + wholeStructureControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * 80
                + (isTractorLead(cards, ts: ts, tr: tr) ? 35 : 0)
        case .sidePairOpportunity:
            base = 200
                + Double(cards.first?.rank.rawValue ?? 0) * 4
                + (clearsSideSuitForLead(cards, hand: hand, ts: ts, tr: tr) ? 30 : 0)
        case .initiativeBuilder:
            let remaining = handAfterPlaying(cards, from: hand)
            let plan = leadControlPlan(position: position, hand: hand, state: state, ctx: ctx)
            var s = 120
                + leadInitiativeValue(hand: remaining, position: position, state: state, ctx: ctx, security: max(security, 0.55)) * 80
                + partnerDumpLeadValue(cards, position: position, tr: tr, ctx: ctx) * 35
                + (plan == .reassessSideAssets ? 0 : idleTrumpTransferValue(move, hand: hand, ts: ts, tr: tr))
                + fallbackLeadShapeAdjustment(move, ts: ts, tr: tr)
                - (isPairMove(cards, ts: ts, tr: tr) ? 0 : points * 2)
            // Asset Lifecycle: pull trump to unlock side-suit winners awaiting it (pull first, realize later).
            if isTrumpLead(move, ts: ts, tr: tr) {
                s += delayedSideRealizationValue(position: position, hand: hand, state: state, ctx: ctx) * 1.2
            }
            base = s
        case .weakDisposal:
            let breakCost = structureFragmentationCost(cards, hand: hand, ts: ts, tr: tr)
            let isSidePair = cards.count == 2
                && cards.allSatisfy { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
                && pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) != nil
            base = 40
                // 普通副牌对子只按牌力排序，不因 5/10/K 的牌面分值单独升降级；
                // 实际送分风险仍由蒙特卡洛的墩分结果负责。
                - (isSidePair ? 0 : points * 6)
                - breakCost * 45
                - Double(cards.count - 1) * 8
                + (clearsSideSuitForLead(cards, hand: hand, ts: ts, tr: tr) ? 15 : 0)
                + fallbackLeadShapeAdjustment(move, ts: ts, tr: tr)
        }
        // 同一资产也会因绝门、主牌耗尽而升贬值，层级先验不能掩盖实际风险。
        return base * (0.35 + security * 0.65) + endgameAdjustment
    }

    static func leadTeamControlProbability(
        _ cards: [Card], position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> Double {
        guard let first = cards.first else { return 0 }
        let evaluator = TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        var trick = Trick(leadPosition: position)
        trick.plays = [(position, cards)]
        var keep = 1.0
        for opponent in PlayerPosition.allCases where opponent.team != position.team {
            let risk = cards.count == 1
                ? playerBeatProbability(first, by: opponent, leadSuit: evaluator.cardSuit(first),
                    hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx,
                    state: state, position: position)
                : structuredOvertakeProbability(trick: trick, opponent: opponent, hand: hand,
                    position: position, state: state, evaluator: evaluator, ctx: ctx)
            keep *= 1 - risk
        }
        return keep
    }


    // MARK: - Endgame Control Asset Preservation

    static func identifyEndgameControlAssets(
        hand: [Card],
        gameState: GameState
    ) -> [EndgameControlAsset] {
        let ts = gameState.trumpSuit
        let tr = gameState.trumpRank
        let ctx = AIContext.build(state: gameState, ts: ts, tr: tr)
        let likelyNoTrump = opponentsLikelyNoTrumpOrControl(gameState: gameState)
        let estimatedBottom = estimatedBottomCaptureValue(
            position: gameState.currentTurn,
            hand: hand,
            state: gameState,
            ctx: ctx
        )
        var assets: [EndgameControlAsset] = []

        func addAsset(cards: [Card], isTrumpBased: Bool, isStructureBased: Bool, winProbability: Double) {
            guard !cards.isEmpty else { return }
            let pattern = playPattern(for: cards, ts: ts, tr: tr)
            let trickCount = max(1, cards.count / max(1, pattern.count))
            let breakCost = structureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr)
                + strongStructureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr)
            assets.append(EndgameControlAsset(
                combination: CardCombination(cards: cards, pattern: pattern),
                winProbability: winProbability,
                trickCountCovered: trickCount,
                bottomPointCapturePotential: estimatedBottom,
                structureBreakCost: breakCost,
                isTrumpBased: isTrumpBased,
                isStructureBased: isStructureBased
            ))
        }

        let trump = trumpCards(in: hand, ts: ts, tr: tr)
        for tractor in tractors(in: trump, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
            let probability = likelyNoTrump ? 0.96 : leadWinProbability(tractor, hand: hand, ts: ts, tr: tr, ctx: ctx)
            addAsset(cards: tractor, isTrumpBased: true, isStructureBased: true, winProbability: probability)
        }

        for pair in pairs(in: trump, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            guard isBigTrump(rep, ts: ts, tr: tr) || likelyNoTrump || hand.count <= 3 else { continue }
            let probability = likelyNoTrump ? 0.94 : leadWinProbability(pair, hand: hand, ts: ts, tr: tr, ctx: ctx)
            addAsset(cards: pair, isTrumpBased: true, isStructureBased: true, winProbability: probability)
        }

        let pairedTrumpIDs = pairedCardIDs(in: trump, trumpSuit: ts, trumpRank: tr)
        for card in trump where !pairedTrumpIDs.contains(card.id) {
            guard isBigTrump(card, ts: ts, tr: tr) || likelyNoTrump else { continue }
            let probability = likelyNoTrump ? 0.88 : leadWinProbability([card], hand: hand, ts: ts, tr: tr, ctx: ctx)
            addAsset(cards: [card], isTrumpBased: true, isStructureBased: false, winProbability: probability)
        }

        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            guard !suitCards.isEmpty else { continue }

            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                guard let info = tractorInfo(of: tractor, trumpSuit: ts, trumpRank: tr),
                      isEffectivelyBiggestPair(info.highCard, hand: hand, ctx: ctx, ts: ts, tr: tr),
                      likelyNoTrump else { continue }
                addAsset(cards: tractor, isTrumpBased: false, isStructureBased: true, winProbability: 0.86)
            }

            for pair in pairs(in: suitCards, trumpSuit: ts, trumpRank: tr) {
                guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                      isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr),
                      likelyNoTrump else { continue }
                addAsset(cards: pair, isTrumpBased: false, isStructureBased: true, winProbability: 0.82)
            }
        }

        var byKey: [String: EndgameControlAsset] = [:]
        for asset in assets where asset.winProbability >= 0.65 {
            let key = moveKey(asset.combination.cards)
            if let existing = byKey[key] {
                if endgameControlValue(asset, position: nil, state: gameState)
                    > endgameControlValue(existing, position: nil, state: gameState) {
                    byKey[key] = asset
                }
            } else {
                byKey[key] = asset
            }
        }
        return Array(byKey.values)
    }


    static func shouldPreserveEndgameControlAsset(
        aiPlayer: Player,
        hand: [Card],
        gameState: GameState
    ) -> Bool {
        guard hand.count <= 5 else { return false }
        let ts = gameState.trumpSuit
        let tr = gameState.trumpRank
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        guard !sideCards.isEmpty else { return false }

        let assets = identifyEndgameControlAssets(hand: hand, gameState: gameState)
        guard !assets.isEmpty else { return false }
        let likelyNoTrump = opponentsLikelyNoTrumpOrControl(gameState: gameState)
        guard likelyNoTrump || hand.count <= 3 else { return false }
        guard assets.contains(where: { $0.winProbability >= (likelyNoTrump ? 0.72 : 0.82) }) else { return false }

        if hand.count <= 3 { return true }
        if canPotentiallyCaptureBottom(position: aiPlayer.position, hand: hand, state: gameState, assets: assets) {
            return true
        }
        return sideCards.contains { $0.pointValue == 0 }
    }


    static func opponentsLikelyNoTrumpOrControl(gameState: GameState) -> Bool {
        let ts = gameState.trumpSuit
        let tr = gameState.trumpRank
        let ctx = AIContext.build(state: gameState, ts: ts, tr: tr)
        let activePosition = gameState.currentTurn
        let totalTrump = referenceDeck.filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }.count
        let playedTrump = ctx.playedCards.filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }.count
        let trumpVoidEnemyCount = ctx.voidEnemies(
            myTeam: activePosition.team,
            key: "TRUMP"
        ).count
        let playedRatio = totalTrump == 0 ? 1.0 : Double(playedTrump) / Double(totalTrump)
        let bigTrumpTotal = referenceDeck.filter {
            $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == tr
        }.count
        let bigTrumpPlayed = ctx.playedCards.filter {
            $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == tr
        }.count

        return trumpVoidEnemyCount == 2
            || playedRatio >= 0.72
            || (playedRatio >= 0.6 && bigTrumpPlayed >= max(1, bigTrumpTotal - 2))
    }


    /// 已确认底牌有分、且两个对手都已经暴露无主时，残局不再继续吊主。
    /// 优先处理副牌，保留至少一手主牌控制来争取最后一墩。
    static func knownPointKittyEndgameLead(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card]? {
        guard hand.count <= 8,
              ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP"),
              case .knownPositive = kittyPointKnowledge(
                position: position,
                hand: hand,
                state: state,
                ctx: ctx
              ) else {
            return nil
        }

        let ts = state.trumpSuit
        let tr = state.trumpRank
        let hasTrumpControl = hand.contains {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        let hasSideCard = hand.contains {
            !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        guard hasTrumpControl, hasSideCard else { return nil }

        let assets = identifyEndgameControlAssets(hand: hand, gameState: state)
        let candidates = endgameSideDisposalLeadAssets(
            position: position,
            hand: hand,
            state: state,
            ctx: ctx,
            protectedAssets: assets
        )
        return bestEndgameSideDisposalLead(
            candidates,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
    }


    static func endgameControlPreservationLead(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card]? {
        guard shouldPreserveEndgameControlAsset(
            aiPlayer: state.player(position),
            hand: hand,
            gameState: state
        ) else { return nil }

        let assets = identifyEndgameControlAssets(hand: hand, gameState: state)
        let candidates = endgameSideDisposalLeadAssets(
            position: position,
            hand: hand,
            state: state,
            ctx: ctx,
            protectedAssets: assets
        )
        return bestEndgameSideDisposalLead(
            candidates,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
    }


    static func bestEndgameSideDisposalLead(
        _ candidates: [LeadAsset],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card]? {
        guard !candidates.isEmpty else { return nil }
        let topAssets = Array(candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return leadAssetTieBreakScore($0.move, hand: hand, state: state, ctx: ctx)
                > leadAssetTieBreakScore($1.move, hand: hand, state: state, ctx: ctx)
        }.prefix(monteCarloTopMoveCount))
        let heuristicScores = Dictionary(
            uniqueKeysWithValues: topAssets.map { (moveKey($0.move.cards), $0.score) }
        )
        return monteCarloBestMove(
            from: topAssets.map(\.move),
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            heuristicScore: { heuristicScores[moveKey($0.cards)] ?? 0 }
        )?.cards ?? topAssets.first?.move.cards
    }


    static func endgameSideDisposalLeadAssets(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext,
        protectedAssets: [EndgameControlAsset]
    ) -> [LeadAsset] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let protectedIDs = Set(protectedAssets.flatMap { $0.combination.cards.map(\.id) })
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        guard !sideCards.isEmpty else { return [] }

        let pairedSideIDs = pairedCardIDs(in: sideCards, trumpSuit: ts, trumpRank: tr)
        let singletonCandidates = sideCards
            .filter { !protectedIDs.contains($0.id) && !pairedSideIDs.contains($0.id) }
            .sorted { endgameSideDisposalSort($0, $1, hand: hand, state: state, ctx: ctx) }

        var moves = singletonCandidates.map { AIMove(cards: [$0], kind: .weak) }
        let bundles = findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: position.team,
            ctx: ctx, position: position, state: state).filter { cards in
                Set(cards.map(\.id)).isDisjoint(with: protectedIDs)
                    && leadTeamControlProbability(cards, position: position, hand: hand, state: state, ctx: ctx) >= 0.95
            }
        // 保留末轮主控不等于把安全副牌甩牌拆单；整组同样能先清副牌。
        moves.removeAll { isStrictSubsetOfAnyGroup($0.cards, groups: bundles) }
        moves += bundles.map { AIMove(cards: $0, kind: .slam) }
        let pointBundles = bundles.filter { $0.contains { $0.pointValue > 0 } }
        if !pointBundles.isEmpty {
            // 既不动最后主控、又能安全兑现实分的整组，先于无分杂牌清理。
            moves = pointBundles.map { AIMove(cards: $0, kind: .slam) }
        }

        if moves.isEmpty {
            let weakPairs = pairs(in: sideCards, trumpSuit: ts, trumpRank: tr)
                .filter { pair in
                    let ids = Set(pair.map(\.id))
                    return ids.isDisjoint(with: protectedIDs)
                        && tractorInfo(of: pair, trumpSuit: ts, trumpRank: tr) == nil
                }
                .sorted {
                    guard let a = pairRepresentative(of: $0, trumpSuit: ts, trumpRank: tr),
                          let b = pairRepresentative(of: $1, trumpSuit: ts, trumpRank: tr) else { return false }
                    return endgameSideDisposalSort(a, b, hand: hand, state: state, ctx: ctx)
                }
            moves += weakPairs.map { AIMove(cards: $0, kind: .weak) }
        }

        if moves.isEmpty {
            moves = sideCards
                .sorted { endgameSideDisposalSort($0, $1, hand: hand, state: state, ctx: ctx) }
                .map { AIMove(cards: [$0], kind: .weak) }
        }

        return deduplicatedMoves(moves).map { move in
            let adjustment = endgameControlPreservationScoreAdjustment(
                move,
                position: position,
                hand: hand,
                state: state
            )
            let score = 260
                + adjustment
                - Double(move.cards.reduce(0) { $0 + $1.pointValue }) * 4
                - structureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr) * 120
                + (clearsSideSuitForLead(move.cards, hand: hand, ts: ts, tr: tr) ? 35 : 0)
            return LeadAsset(move: move, tier: .weakDisposal, score: score)
        }
    }


    static func endgameSideDisposalSort(
        _ lhs: Card,
        _ rhs: Card,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let lPoint = lhs.pointValue
        let rPoint = rhs.pointValue
        if lPoint != rPoint { return lPoint < rPoint }
        let lBreak = structureBreakPenalty(cards: [lhs], hand: hand, ts: ts, tr: tr)
            + strongStructureBreakPenalty(cards: [lhs], hand: hand, ts: ts, tr: tr)
        let rBreak = structureBreakPenalty(cards: [rhs], hand: hand, ts: ts, tr: tr)
            + strongStructureBreakPenalty(cards: [rhs], hand: hand, ts: ts, tr: tr)
        if lBreak != rBreak { return lBreak < rBreak }
        let lBig = ctx.isEffectivelyBiggest(lhs, ts: ts, tr: tr, hand: hand)
        let rBig = ctx.isEffectivelyBiggest(rhs, ts: ts, tr: tr, hand: hand)
        if lBig != rBig { return !lBig }
        return weakerCard(lhs, than: rhs, trumpSuit: ts, trumpRank: tr)
    }


    static func endgameControlPreservationScoreAdjustment(
        _ move: AIMove,
        position: PlayerPosition,
        hand: [Card],
        state: GameState
    ) -> Double {
        guard hand.count <= 5 else { return 0 }
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let assets = identifyEndgameControlAssets(hand: hand, gameState: state)
        guard !assets.isEmpty else { return 0 }

        let moveIDs = Set(move.cards.map(\.id))
        let assetValue = assets.reduce(0.0) {
            $0 + endgameControlValue($1, position: position, state: state)
        }
        let preserveMultiplier = position.team != state.dealerTeamIdx
            && canPotentiallyCaptureBottom(position: position, hand: hand, state: state, assets: assets)
            ? 2.0
            : 1.0

        let consumedValue = assets.reduce(0.0) { partial, asset in
            let ids = Set(asset.combination.cards.map(\.id))
            guard !ids.isDisjoint(with: moveIDs) else { return partial }
            let partialUse = !ids.isSubset(of: moveIDs)
            let structuralMultiplier = asset.isStructureBased && partialUse ? 1.7 : 1.0
            return partial + endgameControlValue(asset, position: position, state: state) * structuralMultiplier
        }
        if consumedValue > 0 {
            return -consumedValue * preserveMultiplier
        }

        if move.cards.allSatisfy({ !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }) {
            return min(160, assetValue * 0.35 * preserveMultiplier)
        }
        return 0
    }


    static func endgameControlValue(
        _ asset: EndgameControlAsset,
        position: PlayerPosition?,
        state: GameState
    ) -> Double {
        let futurePoints = 10.0 + Double(asset.combination.cards.reduce(0) { $0 + $1.pointValue })
        let bottomValue = Double(asset.bottomPointCapturePotential)
        let attackerMultiplier = position.map { $0.team != state.dealerTeamIdx } == true ? 2.0 : 1.0
        return asset.winProbability
            * Double(asset.trickCountCovered)
            * (futurePoints + bottomValue * attackerMultiplier)
            - asset.structureBreakCost * 45
    }


    static func canPotentiallyCaptureBottom(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        assets: [EndgameControlAsset]
    ) -> Bool {
        guard position.team != state.dealerTeamIdx,
              !assets.isEmpty,
              hand.count <= 5,
              assets.contains(where: { $0.winProbability >= 0.72 }) else {
            return false
        }
        let ctx = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)
        return kittyPointKnowledge(
            position: position,
            hand: hand,
            state: state,
            ctx: ctx
        ) != .knownZero
    }


    static func estimatedBottomCaptureValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Int {
        switch kittyPointKnowledge(
            position: position,
            hand: hand,
            state: state,
            ctx: ctx
        ) {
        case .knownPositive(let points):
            return points * 2
        case .knownZero:
            return 0
        case .unknown:
            return 30
        }
    }


    /// AI 对底牌分数的合法知识边界：
    /// - 庄家知道自己埋下的底牌，可确认有分或 0 分；
    /// - 非庄家只有在牌张记忆能确定时才返回已知结果，不能直接读取真实底牌；
    /// - 其余情况保持 unknown。
    static func kittyPointKnowledge(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> KittyPointKnowledge {
        if position == state.dealerPosition {
            let points = state.kitty.reduce(0) { $0 + $1.pointValue }
            return points > 0 ? .knownPositive(points) : .knownZero
        }

        var seenIDs = Set<UUID>()
        let knownCards = (ctx.knownCards + hand).filter {
            seenIDs.insert($0.id).inserted
        }
        let pointDeck = referenceDeck.filter { $0.pointValue > 0 }

        let totalPointCounts = Dictionary(grouping: pointDeck, by: cardFaceKey)
            .mapValues(\.count)
        let knownPointCounts = Dictionary(
            grouping: knownCards.filter { $0.pointValue > 0 },
            by: cardFaceKey
        ).mapValues(\.count)

        let allPointCardsAccountedFor = totalPointCounts.allSatisfy { face, total in
            (knownPointCounts[face] ?? 0) >= total
        }
        if allPointCardsAccountedFor {
            return .knownZero
        }

        let otherPlayers = PlayerPosition.allCases.filter { $0 != position }
        var guaranteedPoints = 0
        for (face, deckCards) in Dictionary(grouping: pointDeck, by: cardFaceKey) {
            guard let representative = deckCards.first else { continue }
            let logicalSuit = AIContext.suitKey(
                representative,
                ts: state.trumpSuit,
                tr: state.trumpRank
            )
            guard otherPlayers.allSatisfy({
                ctx.isVoid($0, key: logicalSuit)
            }) else {
                continue
            }
            let remainingCount = max(
                0,
                deckCards.count - (knownPointCounts[face] ?? 0)
            )
            guaranteedPoints += remainingCount * representative.pointValue
        }

        return guaranteedPoints > 0
            ? .knownPositive(guaranteedPoints)
            : .unknown
    }


    static func cardFaceKey(_ card: Card) -> String {
        "\(card.suit?.rawValue ?? "JOKER"):\(card.rank.rawValue)"
    }


    static func playPattern(for cards: [Card], ts: Suit?, tr: Rank) -> PlayPattern {
        if let info = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) {
            var grouped: [String: [Card]] = [:]
            for card in cards {
                grouped[pairKey(card, trumpSuit: ts, trumpRank: tr), default: []].append(card)
            }
            let orderedPairs = grouped.values
                .filter { $0.count >= 2 }
                .map { Array($0.prefix(2)) }
                .sorted {
                    CardComparator.pairOrderValue($0[0], trumpSuit: ts, trumpRank: tr)
                        < CardComparator.pairOrderValue($1[0], trumpSuit: ts, trumpRank: tr)
                }
            if orderedPairs.count == info.pairCount {
                return .tractor(orderedPairs.map { ($0[0], $0[1]) })
            }
        }
        if cards.count == 2,
           pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) != nil {
            return .pair(cards[0], cards[1])
        }
        if cards.count == 1, let card = cards.first {
            return .single(card)
        }
        return .mixed(cards)
    }


    static func leadAssetTieBreakScore(
        _ move: AIMove,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let cards = move.cards
        let points = Double(cards.reduce(0) { $0 + $1.pointValue })
        let security = leadWinProbability(cards, hand: hand, ts: ts, tr: tr, ctx: ctx)
        return points * 3
            + security * 20
            + Double(cards.count) * 2
            + (clearsSideSuitForLead(cards, hand: hand, ts: ts, tr: tr) ? 4 : 0)
    }


    /// Whether the side suit of this move is "awaiting trump pull" (ruffed if led now, re-appreciates after pulling).
    static func moveSuitAwaitingTrumpPull(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard let first = cards.first,
              !CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr),
              let suit = first.suit else { return false }
        guard suitAwaitingTrumpPull(suit, position: position, hand: hand, state: state, ctx: ctx) else { return false }
        if cards.count == 1 { return true }
        // 副牌对子/拖拉机需要相应主结构才能将吃；不能因对手还有一张主
        // 就无限期推迟已经安全的整对。这里与模拟、跟牌安全证明使用同一牌池。
        let evaluator = TrickEvaluator(trumpSuit: ts, trumpRank: tr)
        let slam = evaluator.slamInfo(of: cards)
        let needsPairs = isPairMove(cards, ts: ts, tr: tr)
            || tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) != nil
            || !(slam?.pairs.isEmpty ?? true) || !(slam?.tractors.isEmpty ?? true)
        let ruffers = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).filter {
            !ctx.isVoid($0, key: "TRUMP") && state.handCount(for: $0) >= cards.count
                && (!needsPairs || !failedToFollowTrumpPair(position: $0, state: state, ts: ts, tr: tr))
        }
        guard !ruffers.isEmpty else { return false }
        var known = ctx.playedCards + hand
        if position == state.dealerPosition { known += state.kitty }
        let trumps = removeKnownFaces(from: referenceDeck, knownCards: known).filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        if let tractor = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) {
            return !tractors(in: trumps, pairCount: tractor.pairCount, trumpSuit: ts, trumpRank: tr).isEmpty
        }
        if isPairMove(cards, ts: ts, tr: tr) { return !pairs(in: trumps, trumpSuit: ts, trumpRank: tr).isEmpty }
        guard let slam else { return false }
        return buildMatchingSlamTrump(slam: slam, trumpCards: trumps, winningCards: cards,
            ts: ts, tr: tr, stopAtFirstWinner: true) != nil
    }


    static func isStrictSubsetOfAnyGroup(_ cards: [Card], groups: [[Card]]) -> Bool {
        let ids = Set(cards.map(\.id))
        guard !ids.isEmpty else { return false }
        return groups.contains { group in
            let groupIDs = Set(group.map(\.id))
            return ids.isSubset(of: groupIDs) && ids != groupIDs
        }
    }


    static func isTimeSensitiveSideControlGroup(
        _ cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard cards.count >= 2,
              let first = cards.first,
              !CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr),
              let suit = first.suit,
              cards.allSatisfy({
                  $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
              }) else {
            return false
        }

        if cards.contains(where: {
            $0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
        }) {
            return true
        }
        return pairs(in: cards, trumpSuit: ts, trumpRank: tr).contains { pair in
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { return false }
            return isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr)
        }
    }


    static func sideSuitUrgency(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let first = cards.first,
              !CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr),
              let suit = first.suit else {
            return 0
        }

        let voidEnemies = Double(ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).count)
        var urgency = 35.0 - voidEnemies * 22.0
        if cards.contains(where: { $0.rank == .ace }) { urgency += 25 }
        if cards.contains(where: {
            ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
        }) { urgency += 20 }
        urgency += Double(ctx.unplayedSuitPoints(suit: suit, tr: tr)) * 0.8
        return urgency
    }


    static func partnerDumpLeadValue(
        _ cards: [Card],
        position: PlayerPosition,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let first = cards.first,
              let suit = first.suit,
              let partner = PlayerPosition.allCases.first(where: {
                  $0.team == position.team && $0 != position
              }),
              ctx.isVoid(partner, key: suit.rawValue) else {
            return 0
        }
        return Double(ctx.unplayedSuitPoints(suit: suit, tr: tr)) / 3.0
    }


    static func idleTrumpTransferValue(_ move: AIMove, hand: [Card], ts: Suit?, tr: Rank) -> Double {
        guard move.kind == .trumpTransfer,
              move.cards.count == 1,
              let card = move.cards.first,
              CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              !isBigTrump(card, ts: ts, tr: tr),
              card.pointValue == 0,
              structureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr) == 0 else {
            return 0
        }

        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        let reserveBonus = min(Double(trumpCount - trumpTransferMinTrumpCount) * 4.0, 16.0)
        return 55.0 + max(0, reserveBonus)
    }

    /// 吊主的目的分为“交给对家领牌”与“拔主解锁副牌赢家”。
    /// 计划进度完全由本局公开出牌历史推导，每次拿回牌权重新评估；
    /// 不读取其他玩家手牌，也不需要在联机快照中保存额外的AI私有状态。
    static func leadControlPlan(
        position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> LeadControlPlan {
        if ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP") { return .reassessSideAssets }
        // 有明确的副牌将吃威胁及足够控主资源时，继续拔主仍有具体收益。
        if delayedSideRealizationValue(position: position, hand: hand, state: state, ctx: ctx) >= 30
            || sidePairProtectionValue(position: position, hand: hand, state: state, ctx: ctx) >= 45 {
            return .pullForSideWinners
        }
        if let partner = PlayerPosition.allCases.first(where: { $0 != position && $0.team == position.team }),
           ctx.isVoid(partner, key: "TRUMP") { return .reassessSideAssets }

        func transferPlan() -> LeadControlPlan {
            let partner = PlayerPosition(rawValue: (position.rawValue + 2) % 4)!
            guard let small = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
                .first(where: { !isBigTrump($0, ts: state.trumpSuit, tr: state.trumpRank) }),
                playerBeatProbability(small, by: partner, leadSuit: nil, hand: hand,
                    ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx,
                    state: state, position: position) > 0 else { return .reassessSideAssets }
            return .seekPartnerLead
        }

        var ownTransferAttempts = 0
        // 只重建最近一段计划。自己领过副牌意味着已经开始并执行了新的
        // 兑现/发展计划，不能让更早的一次他人领牌永久关闭后续交牌权机会。
        for trick in state.completedTricks.reversed() {
            guard let lead = trick.plays.first, let first = lead.cards.first else { continue }
            // 对家已经得到过领牌机会，或对手领过牌而自己现已拿回主动权，
            // 均不再重复用默认吊主替代新的副牌计划。
            if lead.position != position { return .reassessSideAssets }
            if lead.cards.count == 1,
               CardComparator.isTrump(first, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank),
               !isBigTrump(first, ts: state.trumpSuit, tr: state.trumpRank), first.pointValue == 0 {
                ownTransferAttempts += 1
                if ownTransferAttempts >= 2 { return .reassessSideAssets }
            } else {
                return CardComparator.isTrump(first, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
                    ? .reassessSideAssets : transferPlan()
            }
        }
        return transferPlan()
    }


    /// 无兑现资产时的兜底牌型微调：普通副牌对子仍有逼出对方对子、争取牌权的价值，
    /// 并只按对子本身的牌力连续排序，不把 5/10/K 作为特殊档位；
    /// 随机副牌小单则略降权，避免它在空档期压过吊主或一个完整对子。
    /// 拖拉机和强对子已在更高资产层处理，不会进入这里竞争。
    static func fallbackLeadShapeAdjustment(_ move: AIMove, ts: Suit?, tr: Rank) -> Double {
        guard !move.cards.isEmpty,
              move.cards.allSatisfy({ !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }) else {
            return 0
        }
        if move.cards.count == 2,
           let rep = pairRepresentative(of: move.cards, trumpSuit: ts, trumpRank: tr) {
            return 12 + Double(rep.rank.rawValue)
        }
        if move.kind == .weak, move.cards.count == 1 {
            return -10
        }
        return 0
    }

    /// 纯兜底接近同分时，稍偏向有公开依据的低成本交牌权；不盖过兑现/对子/清分计划。
    static func fallbackTrumpTransferPreference(
        _ move: AIMove, position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> Double {
        guard state.currentTrick.plays.isEmpty,
              !ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP"),
              let transfer = findTrumpTransferLeadCandidates(in: hand, ts: state.trumpSuit, tr: state.trumpRank).first else { return 0 }
        let partner = PlayerPosition(rawValue: (position.rawValue + 2) % 4)!
        guard !ctx.isVoid(partner, key: "TRUMP"),
              playerBeatProbability(transfer.cards[0], by: partner, leadSuit: nil, hand: hand,
                ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx, state: state, position: position) > 0 else { return 0 }
        if sameCardSet(move.cards, transfer.cards) { return 3 }
        if move.kind == .weak, move.cards.count == 1, let first = move.cards.first,
           first.pointValue == 0, !CardComparator.isTrump(first, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank),
           !clearsSideSuitForLead(move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank),
           !ctx.isEffectivelyBiggest(first, ts: state.trumpSuit, tr: state.trumpRank, hand: hand) { return -3 }
        return 0
    }

    static func filterUnplannedSideFallback(
        _ assets: [LeadAsset], position: PlayerPosition, hand: [Card], state: GameState, ctx: AIContext
    ) -> [LeadAsset] {
        func unplannedSideSingle(_ asset: LeadAsset) -> Bool {
            let move = asset.move
            guard move.kind == .weak, move.cards.count == 1, let card = move.cards.first,
                  card.pointValue == 0, !isTrumpLead(move, ts: state.trumpSuit, tr: state.trumpRank) else { return false }
            return !clearsSideSuitForLead(move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank)
                && !ctx.isEffectivelyBiggest(card, ts: state.trumpSuit, tr: state.trumpRank, hand: hand)
        }
        let transfers = assets.filter {
            fallbackTrumpTransferPreference($0.move, position: position, hand: hand, state: state, ctx: ctx) > 0
        }
        guard !transfers.isEmpty else { return assets }
        let plan = leadControlPlan(position: position, hand: hand, state: state, ctx: ctx)
        if plan == .seekPartnerLead || plan == .pullForSideWinners {
            let partner = PlayerPosition(rawValue: (position.rawValue + 2) % 4)!
            let planned = assets.filter { asset in
                guard unplannedSideSingle(asset), let card = asset.move.cards.first,
                      card.rank.rawValue <= Rank.nine.rawValue, let suit = card.suit else { return true }
                // 有副牌对子不等于“另出一张小副牌”也有计划。逐走法剔除这类
                // 无目标小单，保留对子等其他方案与小主比较。已知对家绝门且
                // 本门还有分是公开配合目标；高副单试探和真正清门也不在此裁剪。
                return ctx.isVoid(partner, key: suit.rawValue)
                    && ctx.unplayedSuitPoints(suit: suit, tr: state.trumpRank) > 0
            }
            if planned.count < assets.count { return planned }
        }
        // 只处理真正的兜底空档；对子、甩牌、兑现、清门、公开对家垫分目标
        // 都继续共同评估。没有这些目标时，不靠抽样里虚构的对家大牌领小副。
        guard assets.allSatisfy({ $0.tier == .initiativeBuilder || $0.tier == .weakDisposal }),
              assets.allSatisfy({ isTrumpLead($0.move, ts: state.trumpSuit, tr: state.trumpRank) || unplannedSideSingle($0) })
        else { return assets }
        return transfers
    }


    static func clearsSideSuitForLead(_ cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard let first = cards.first,
              !CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr),
              let suit = first.suit else {
            return false
        }
        let selected = Set(cards.map(\.id))
        return !hand.contains {
            $0.suit == suit
                && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                && !selected.contains($0.id)
        }
    }


    static func findPartnerDumpLeadCandidates(
        in hand: [Card],
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> [AIMove] {
        guard let partner = PlayerPosition.allCases.first(where: { $0.team == position.team && $0 != position })
        else { return [] }

        var moves: [AIMove] = []
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        for suit in Suit.allCases where ctx.isVoid(partner, key: suit.rawValue) {
            guard ctx.unplayedSuitPoints(suit: suit, tr: tr) > 0 else { continue }
            let suitCards = sideCards.filter { $0.suit == suit }
            guard !suitCards.isEmpty else { continue }

            if let pair = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
                .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                moves.append(AIMove(cards: pair, kind: .partnerDump))
            }
            if let strongest = suitCards.max(by: {
                CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
            }) {
                moves.append(AIMove(cards: [strongest], kind: .partnerDump))
            }
        }
        return moves
    }


    static func findLongSuitDevelopmentLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        var moves: [AIMove] = []

        for suit in Suit.allCases {
            guard !ctx.allEnemiesVoid(myTeam: myTeam, key: suit.rawValue) else { continue }
            let suitCards = sideCards.filter { $0.suit == suit }
            guard suitCards.count >= 4 else { continue }

            let pairedIDs = pairedCardIDs(in: suitCards, trumpSuit: ts, trumpRank: tr)
            let developmentSingles = suitCards
                .filter { !pairedIDs.contains($0.id) && $0.pointValue == 0 }
                .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            if let low = developmentSingles.first {
                moves.append(AIMove(cards: [low], kind: .weak))
                continue
            }

            if let low = suitCards
                .filter({ !pairedIDs.contains($0.id) })
                .sorted(by: { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) })
                .first {
                moves.append(AIMove(cards: [low], kind: .weak))
            }
        }

        return moves
    }


    static func findAbsoluteSideWinnerLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        let pairedIDs = pairedCardIDs(in: sideCards, trumpSuit: ts, trumpRank: tr)
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr, hand: hand) {
            guard let suit = card.suit else { continue }
            if ctx.allEnemiesVoid(myTeam: myTeam, key: suit.rawValue) { continue }
            bySuit[suit, default: []].append(card)
        }

        var moves: [AIMove] = []

        // 1) Side-suit A singletons: time-sensitive winners that decay as opponents become void.
        for ace in sideCards
            where ace.rank == .ace
                && !pairedIDs.contains(ace.id)
                && !ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(ace, ts: ts, tr: tr)) {
            moves.append(AIMove(cards: [ace], kind: .bigSingle))
        }

        // 2) Known highest side-suit pairs. Pair "highest" uses pair-specific knowledge:
        // opponents cannot form any higher pair, even if a higher single may remain.
        for pair in pairs(in: sideCards, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  !ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)),
                  isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr) else { continue }
            moves.append(AIMove(cards: pair, kind: .bigPair))
        }

        // 3) Known highest side-suit singletons, excluding paired cards so normal pair assets stay intact.
        for cards in bySuit.values {
            let singletons = cards.filter { !pairedIDs.contains($0.id) }
            if let single = singletons.max(by: {
                CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
            }) {
                moves.append(AIMove(cards: [single], kind: .bigSingle))
            }
        }

        return moves
    }


    static func findTractorLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        var moves: [AIMove] = []
        for logicalSuit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter {
                CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == logicalSuit
            }
            guard !suitCards.isEmpty else { continue }
            if let suit = logicalSuit,
               ctx.allEnemiesVoid(myTeam: myTeam, key: suit.rawValue) {
                continue
            }

            let pairCount = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
            guard pairCount >= 2 else { continue }
            for count in 2...pairCount {
                moves += tractors(in: suitCards, pairCount: count, trumpSuit: ts, trumpRank: tr)
                    .map { AIMove(cards: $0, kind: .tractor) }
            }
        }
        return moves
    }


    static func findWeakPairDisposalLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        pairs(in: hand, trumpSuit: ts, trumpRank: tr).compactMap { pair in
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  !isLeadStrongPair(rep, ts: ts, tr: tr),
                  tractorInfo(of: pair, trumpSuit: ts, trumpRank: tr) == nil else {
                return nil
            }
            if !CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
               ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)) {
                return nil
            }
            return AIMove(cards: pair, kind: .bigPair)
        }
    }

    /// “孤对”指本逻辑副花色只剩这两张，不是从拖拉机中抽出一个对子。
    /// 孤对（任意点数）和J以上副牌对在普通吊主之前使用；
    /// 牌权周转后重新组织副牌时，其他小对子也可优先整出。
    static func findTimelySidePairLeadCandidates(
        in hand: [Card], position: PlayerPosition, state: GameState, ctx: AIContext
    ) -> [AIMove] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let reassessing = leadControlPlan(position: position, hand: hand, state: state, ctx: ctx) == .reassessSideAssets
        let side = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        return pairs(in: side, trumpSuit: ts, trumpRank: tr).compactMap { pair in
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  let suit = rep.suit else { return nil }
            let isolated = side.filter { $0.suit == suit }.count == 2
            guard isolated || rep.rank.rawValue >= Rank.jack.rawValue || reassessing,
                  structureFragmentationCost(pair, hand: hand, ts: ts, tr: tr) == 0,
                  !moveSuitAwaitingTrumpPull(pair, position: position, hand: hand, state: state, ctx: ctx) else {
                return nil
            }
            if ctx.allEnemiesVoid(myTeam: position.team, key: suit.rawValue),
               !ctx.allEnemiesVoid(myTeam: position.team, key: "TRUMP") { return nil }
            return AIMove(cards: pair, kind: .bigPair)
        }
    }


    static func findNoTrumpControlLeadCandidates(
        in hand: [Card], position: PlayerPosition, state: GameState,
        trumpSuit: Suit?, trumpRank: Rank
    ) -> [AIMove] {
        guard trumpSuit == nil,
              hand.contains(where: { $0.rank == .smallJoker || $0.rank == .bigJoker })
                || pairs(in: hand, trumpSuit: nil, trumpRank: trumpRank).contains(where: {
                    pairRepresentative(of: $0, trumpSuit: nil, trumpRank: trumpRank) != nil
                }) else { return [] }

        var moves: [AIMove] = []
        moves += tractors(in: hand, pairCount: 2, trumpSuit: nil, trumpRank: trumpRank)
            .map { AIMove(cards: $0, kind: .tractor) }

        let controlPairs = pairs(in: hand, trumpSuit: nil, trumpRank: trumpRank)
            .filter {
                guard let rep = pairRepresentative(of: $0, trumpSuit: nil, trumpRank: trumpRank) else { return false }
                let isControl = rep.rank == trumpRank || rep.rank == .smallJoker || rep.rank == .bigJoker || rep.rank == .ace
                guard isControl else { return false }
                // 大主对子（无主局的王对/级牌对）同样适用开局保护，避免从此路径漏出
                if isBigTrump(rep, ts: trumpSuit, tr: trumpRank),
                   !bigTrumpPairLeadAllowed($0, hand: hand, position: position, state: state, ts: trumpSuit, tr: trumpRank) {
                    return false
                }
                return true
            }
        moves += controlPairs.map { AIMove(cards: $0, kind: .bigPair) }
        return moves
    }


    static func findTrumpLeadCandidates(
        in hand: [Card],
        position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> [AIMove] {
        let trumpCards = hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        guard !trumpCards.isEmpty else { return [] }

        var moves: [AIMove] = []
        if let weakTrump = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                              trumpSuit: ts, trumpRank: tr).first {
            moves.append(AIMove(cards: [weakTrump], kind: .trump))
        }
        if state.dealerTeamIdx == position.team || trumpCards.count >= 6 {
            if let stronger = trumpCards.sorted(by: {
                CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr)
                    > CardComparator.trumpWeight($1, trumpSuit: ts, trumpRank: tr)
            }).first(where: {
                !pairedCardIDs(in: hand, trumpSuit: ts, trumpRank: tr).contains($0.id)
                    && isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx, hand: hand)
            }) {
                moves.append(AIMove(cards: [stronger], kind: .trump))
            }
        }
        if let pair = findWeakestTrumpPair(in: hand, nonPointFirst: true, trumpSuit: ts, trumpRank: tr) {
            moves.append(AIMove(cards: pair, kind: .trump))
        }
        return moves
    }


    /// 小主过渡（Controlled Trump Transfer）：
    /// 无更好先手时，领出一张低成本、不拆主牌结构的小主，尝试把出牌权过渡给队友或我方强主，
    /// 而非随手领一张无控制力的小副牌，把出牌权随机送给对手。
    /// 仅在主牌充足（≥ `trumpTransferMinTrumpCount`）时生成候选。
    static func findTrumpTransferLeadCandidates(in hand: [Card], ts: Suit?, tr: Rank) -> [AIMove] {
        guard trumpCards(in: hand, ts: ts, tr: tr).count >= trumpTransferMinTrumpCount else { return [] }
        // 最弱的无分、不拆对子的小主单张；排除大主（王 / 级牌 / 主A 等关键主牌）
        guard let small = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                             trumpSuit: ts, trumpRank: tr)
            .first(where: { !isBigTrump($0, ts: ts, tr: tr) }) else { return [] }
        // 二次确认不破坏主对子 / 主拖拉机结构
        guard structureBreakPenalty(cards: [small], hand: hand, ts: ts, tr: tr) == 0 else { return [] }
        return [AIMove(cards: [small], kind: .trumpTransfer)]
    }


    static func findWeakLeadCandidates(in hand: [Card], ts: Suit?, tr: Rank) -> [AIMove] {
        var moves: [AIMove] = []
        if let sideWeak = leadableSingletons(from: hand, isTrump: false, pointOnly: false,
                                             trumpSuit: ts, trumpRank: tr).first {
            moves.append(AIMove(cards: [sideWeak], kind: .weak))
        }
        moves.append(AIMove(cards: weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr), kind: .weak))
        return moves
    }


    static func allowTrumpLead(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard isTrumpLead(move, ts: ts, tr: tr) else { return true }
        // 所有生成路径统一保护大主对子，包括拖拉机和无主控制组。
        if hand.count > 6 {
            let selected = Set(move.cards.map(\.id))
            if pairs(in: hand, trumpSuit: ts, trumpRank: tr).contains(where: {
                isBigTrump($0[0], ts: ts, tr: tr) && $0.contains { selected.contains($0.id) }
            }) { return false }
            if containsBigTrump(move.cards, ts: ts, tr: tr) {
                let context = AIContext.build(state: state, ts: ts, tr: tr)
                let cheapTrump = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                    trumpSuit: ts, trumpRank: tr).contains { !isBigTrump($0, ts: ts, tr: tr) }
                guard !cheapTrump,
                      leadControlPlan(position: position, hand: hand, state: state, ctx: context) == .pullForSideWinners
                else { return false }
            }
        }
        if ts == nil,
           (isStrongNoTrumpPair(move.cards, trumpRank: tr)
                || tractorInfo(of: move.cards, trumpSuit: ts, trumpRank: tr) != nil) {
            return true
        }

        // 小主过渡：主牌充足时允许领出低成本小主以保住出牌权
        if move.kind == .trumpTransfer,
           trumpCards(in: hand, ts: ts, tr: tr).count >= trumpTransferMinTrumpCount {
            return true
        }

        let remaining = remainingTricks(for: hand)
        if remaining <= 5 { return true }

        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        if trumpCount >= 8 { return true }
        if strongTrumpCount(in: hand, ts: ts, tr: tr) >= 4 { return true }
        if sideCardsRemaining(in: hand, ts: ts, tr: tr) <= trumpCount { return true }
        if exposedPointCardsToProtect(in: hand, ts: ts, tr: tr) >= 25 { return true }
        let leadCtx = AIContext.build(state: state, ts: ts, tr: tr)
        if sidePairProtectionValue(position: position, hand: hand, state: state, ctx: leadCtx) >= 45 {
            return true
        }
        // Asset Lifecycle: allow leading trump to pull when holding side-suit winners awaiting it.
        if delayedSideRealizationValue(position: position, hand: hand, state: state, ctx: leadCtx) >= 30 {
            return true
        }
        if state.dealerTeamIdx == position.team && trumpCount >= 6 { return true }

        return false
    }


    static func leadWinProbability(
        _ cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let first = cards.first else { return 0 }
        if CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr) {
            let high = cards.map { CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) }.max() ?? 0
            return min(0.95, 0.35 + Double(high) / 120.0)
        }

        let allBig = cards.allSatisfy {
            ctx.isEffectivelyBiggest($0, ts: ts, tr: tr, hand: hand)
        }
        if allBig { return 0.78 }
        if cards.contains(where: { $0.rank == .ace }) { return 0.62 }
        let high = cards.map(\.rank.rawValue).max() ?? 0
        return min(0.55, Double(high) / 24.0)
    }


    static func isStrongPairAsset(_ representative: Card, ts: Suit?, tr: Rank) -> Bool {
        if representative.rank == .bigJoker || representative.rank == .smallJoker { return true }
        if representative.rank == tr { return true }
        if representative.rank == .ace { return true }
        if CardComparator.isTrump(representative, trumpSuit: ts, trumpRank: tr),
           isBigTrump(representative, ts: ts, tr: tr) { return true }
        return false
    }


    // MARK: - Lead Structure Helpers

    static func isTractorLead(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) != nil
    }


    // MARK: - Lead Strong Pair Assets

    /// 先手「强对子」分级。非强对子返回 (0, 0)。
    /// 强对子只由控制力定义：A对 / 级牌对 / 王对 / 高主对子。
    /// 副牌 K/10/5 不再因带分自动晋级；若已知最大，会由兑现赢家路径提升。
    static func leadStrongPairWeights(_ rep: Card, ts: Suit?, tr: Rank)
        -> (breakPenalty: Double, leadBonus: Double) {
        // 顶级：王对 / 级牌对 / A对
        if rep.rank == .bigJoker || rep.rank == .smallJoker || rep.rank == tr || rep.rank == .ace {
            return (140, 60)
        }
        // 主牌强对子（大主 或 牌力 ≥ K）
        if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
           isBigTrump(rep, ts: ts, tr: tr)
            || CardComparator.trumpWeight(rep, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue {
            return (120, 50)
        }
        return (0, 0)
    }


    static func isLeadStrongPair(_ rep: Card, ts: Suit?, tr: Rank) -> Bool {
        leadStrongPairWeights(rep, ts: ts, tr: tr).breakPenalty > 0
    }


    /// 「大主对子」（王对 / 级牌对 / 主A对，即 `isBigTrump` 的对子）是否放行为先手候选。
    /// 这类牌是全局最强的控制 / 将吃资源。主牌够长只说明可以拔主，不说明应该用最高控制对拔；
    /// 开局和中盘应优先用低成本小主过渡 / 普通主牌拔主，避免把对王、对级牌直接消耗掉。
    /// 因此只有残局才主动放行；若全手没有其他可用走法，最终兜底仍可出合法牌。
    static func bigTrumpPairLeadAllowed(
        _ pair: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank
    ) -> Bool {
        // 残局
        if hand.count <= 6 { return true }
        return false
    }


    /// 规则 1：把手中所有强对子都作为先手候选加入（避免被漏掉而只剩单张候选）。
    static func findStrongPairLeadCandidates(
        in hand: [Card], position: PlayerPosition, state: GameState,
        ts: Suit?, tr: Rank, myTeam: Int, ctx: AIContext
    ) -> [AIMove] {
        var moves: [AIMove] = []
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  isLeadStrongPair(rep, ts: ts, tr: tr) else { continue }
            // 敌方已全绝的副花色，领出会被将吃 → 跳过
            if !CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
               ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)) { continue }
            // 大主对子（王对/级牌对/主A对）开局保护：无拔主/带分/残局等理由时不作为先手候选
            if isBigTrump(rep, ts: ts, tr: tr),
               !bigTrumpPairLeadAllowed(pair, hand: hand, position: position, state: state, ts: ts, tr: tr) {
                continue
            }
            moves.append(AIMove(cards: pair, kind: .bigPair))
        }
        return moves
    }


    /// 找甩牌候选：同一非主花色中"无法被压制"的牌组合在一起领出（甩牌）
    ///
    /// 合法甩牌要求（按分量分别判断）：
    /// - 单张分量：所有更高 rank 在 played+hand 中合计 ≥ 2（两张都已知晓，对手无法有更大单张）
    /// - 对子分量：所有更高 rank 在 played+hand 中合计 ≥ 1（对手最多只有 1 张，凑不成更大对子）
    ///
    /// 例：手中 A♠K♠K♠ → KK 是最大对子（A 在手里，外面最多 1 张 A 凑不成 AA 对），A 是最大单张 → 合法甩牌
    ///     手中 A♠Q♠Q♠ 且手中还有 K♠ → QQ 是最大对子（K/A 各有 ≥1 张在手，外面凑不成 KK/AA），A 最大单张 → 合法甩牌
    ///
    /// - 有人绝门时纯散牌甩牌需等待主牌消耗到足够少，不能一律禁甩。
    /// 优先选张数最多的花色，张数相同时优先含对子的花色
    static func findSlamLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext,
        position: PlayerPosition? = nil,
        state: GameState? = nil
    ) -> [[Card]] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards {
            guard let suit = card.suit else { continue }
            bySuit[suit, default: []].append(card)
        }

        var candidates: [[Card]] = []
        for (suit, suitCards) in bySuit {
            let allOthersVoid = position.map { observer in
                PlayerPosition.allCases.filter { $0 != observer }
                    .allSatisfy { ctx.isVoid($0, key: suit.rawValue) }
            } ?? false
            let unbeatableSingles = suitCards.filter {
                allOthersVoid || isEffectivelyBiggestSingle($0, hand: hand, ctx: ctx, ts: ts, tr: tr)
            }

            var rankGroups: [Rank: [Card]] = [:]
            for card in suitCards { rankGroups[card.rank, default: []].append(card) }

            var unbeatablePairCards: [Card] = []
            for cards in rankGroups.values where cards.count >= 2 {
                if allOthersVoid || isEffectivelyBiggestPair(cards[0], hand: hand, ctx: ctx, ts: ts, tr: tr) {
                    unbeatablePairCards += Array(cards.prefix(2))
                }
            }

            var candidateIds = Set(unbeatableSingles.map { $0.id })
            for card in unbeatablePairCards { candidateIds.insert(card.id) }
            let candidateCards = suitCards.filter { candidateIds.contains($0.id) }
            guard candidateCards.count >= 2 else { continue }
            if candidateCards.count == 2,
               pairKey(candidateCards[0], trumpSuit: ts, trumpRank: tr)
                    == pairKey(candidateCards[1], trumpSuit: ts, trumpRank: tr) { continue }

            let hasVoidEnemy = ctx.voidEnemies(myTeam: myTeam, key: suit.rawValue).count > 0
            let hasPairs = !unbeatablePairCards.isEmpty
            if hasVoidEnemy && !hasPairs {
                guard let position,
                      latePureSlamAllowed(candidateCards, hand: hand, position: position,
                        ts: ts, tr: tr, ctx: ctx, state: state) else { continue }
            }

            candidates.append(candidateCards)

            // 大甩牌风险较高时，也提供较小的安全子集给评分器选择。
            if candidateCards.count > 3, !unbeatablePairCards.isEmpty {
                let pairOnly = suitCards.filter { card in unbeatablePairCards.contains(where: { $0.id == card.id }) }
                if pairOnly.count >= 2 { candidates.append(pairOnly) }
            }
        }
        return candidates
    }

    /// 外面主还多时保留早期保护；主少时比较“凑齐N张全主”而非单张将吃。
    static func latePureSlamAllowed(
        _ cards: [Card], hand: [Card], position: PlayerPosition, ts: Suit?, tr: Rank,
        ctx: AIContext, state: GameState?
    ) -> Bool {
        let ruffers = PlayerPosition.allCases.filter {
            $0.team != position.team && !ctx.isVoid($0, key: "TRUMP")
        }
        if ruffers.isEmpty { return true }
        var known = ctx.playedCards + hand
        if let state, position == state.dealerPosition { known += state.kitty }
        let remainingTrump = removeKnownFaces(from: referenceDeck, knownCards: known).filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }.count
        if remainingTrump < cards.count { return true }
        guard remainingTrump <= max(4, cards.count * 2 - 1) else { return false }
        var trick = Trick(leadPosition: position)
        trick.plays = [(position, cards)]
        let evaluator = TrickEvaluator(trumpSuit: ts, trumpRank: tr)
        let keep = ruffers.reduce(1.0) { probability, opponent in
            probability * (1 - structuredOvertakeProbability(trick: trick, opponent: opponent,
                hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx))
        }
        return keep >= 0.75
    }


    static func findSlamLead(
        in hand: [Card],
        ts: Suit?, tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card]? {
        findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            .max { lhs, rhs in
                let lSuit = lhs.first?.suit?.rawValue ?? ""
                let rSuit = rhs.first?.suit?.rawValue ?? ""
                let lRisk = Double(ctx.voidEnemies(myTeam: myTeam, key: lSuit).count)
                let rRisk = Double(ctx.voidEnemies(myTeam: myTeam, key: rSuit).count)
                let lScore = Double(lhs.reduce(0) { $0 + $1.pointValue }) + Double(lhs.count * 2) - lRisk * 20
                let rScore = Double(rhs.reduce(0) { $0 + $1.pointValue }) + Double(rhs.count * 2) - rRisk * 20
                return lScore < rScore
            }
    }


    /// 单张"最大"检查：所有比它大的同花色 rank，played + inHand ≥ 2（双副牌两张都已知晓，对手无法有更大单张）
    static func isEffectivelyBiggestSingle(
        _ card: Card, hand: [Card], ctx: AIContext, ts: Suit?, tr: Rank
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        for rank in higherRanks {
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            if played + inHand < 2 { return false }
        }
        return true
    }


    /// 对子"最大"检查：所有比它大的同花色 rank，played + inHand ≥ 1（对手最多只有 1 张，凑不出更大对子）
    static func isEffectivelyBiggestPair(
        _ card: Card, hand: [Card], ctx: AIContext, ts: Suit?, tr: Rank
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        for rank in higherRanks {
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            // 对手凑成对子需要 2 张；played+inHand ≥ 1 则对手至多 1 张 → 凑不成对子
            if played + inHand < 1 { return false }
        }
        return true
    }


    /// 旁门 Ace（且敌方未全绝此花色，出才有意义；且不是对子中的一张，对子留给步骤1/4）
    static func bestSideAce(
        in hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> Card? {
        // 找出所有配对的 pairKey，Ace 若有对子则不单独领出（步骤1已处理配对 Ace）
        var pairGroupMap: [String: [Card]] = [:]
        for card in hand {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank),
                         default: []].append(card)
        }
        let pairedIDs = Set(pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })

        return hand.first {
            $0.rank == .ace
                && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                && !pairedIDs.contains($0.id)   // 不拆对子 Ace
                && !ctx.allEnemiesVoid(myTeam: myTeam,
                                       key: AIContext.suitKey($0, ts: trumpSuit, tr: trumpRank))
        }
    }


    /// 在非绝牌花色中找对子（避免领出敌方已绝花色的单牌）
    static func findBestPairAvoidingVoid(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card]? {
        var seen: [String: [Card]] = [:]
        for card in hand {
            let key = pairKey(card, trumpSuit: ts, trumpRank: tr)
            seen[key, default: []].append(card)
        }
        let candidates = seen.filter { entry in
            guard entry.value.count >= 2 else { return false }
            let card = entry.value[0]
            if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) { return false }
            let sk = AIContext.suitKey(card, ts: ts, tr: tr)
            return !ctx.allEnemiesVoid(myTeam: myTeam, key: sk)
        }
        if let best = candidates.max(by: { a, b in a.value[0].rank < b.value[0].rank }) {
            return Array(best.value.prefix(2))
        }
        return nil
    }
}
