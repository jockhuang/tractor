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
            deduplicatedLeadAssets(
                buildLeadAssets(position: position, hand: hand, state: state, ctx: ctx)
            ),
            position: position,
            hand: hand,
            state: state
        )

        guard !assets.isEmpty else {
            return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
        }

        let assetPool = selectLeadAssetPool(assets)
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
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) {
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
        let safeGroups = findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
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

        // Tier 4: build future control only after no cashing/group/structure asset needs action.
        let initiativeMoves =
            findPartnerDumpLeadCandidates(in: hand, position: position, ts: ts, tr: tr, ctx: ctx)
            + findLongSuitDevelopmentLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            + findTrumpLeadCandidates(in: hand, position: position, state: state, ts: ts, tr: tr, ctx: ctx)
            + findTrumpTransferLeadCandidates(in: hand, ts: ts, tr: tr)
        for move in initiativeMoves where !isStrictSubsetOfAnyGroup(move.cards, groups: protectedGroups) {
            assets.append(LeadAsset(
                move: move,
                tier: .initiativeBuilder,
                score: leadAssetScore(move, tier: .initiativeBuilder, position: position, hand: hand, state: state, ctx: ctx)
            ))
        }

        // Tier 5: disposal, including ordinary weak pairs only when nothing strategic exists.
        let disposalMoves =
            findWeakLeadCandidates(in: hand, ts: ts, tr: tr)
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


    static func selectLeadAssetPool(_ assets: [LeadAsset]) -> [LeadAsset] {
        guard let bestTier = assets.map(\.tier.rawValue).min() else { return [] }
        let pool = assets.filter { $0.tier.rawValue == bestTier }
        guard pool.first?.tier == .initiativeBuilder else { return pool }

        // Tier 4 内部：没有明确队友垫分计划时，低成本小主过渡比长门弱副牌更稳定。
        if pool.contains(where: { $0.move.kind == .partnerDump }) {
            return pool
        }
        let trumpTransfers = pool.filter { $0.move.kind == .trumpTransfer }
        return trumpTransfers.isEmpty ? pool : trumpTransfers
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
        let security = leadWinProbability(cards, hand: hand, ts: ts, tr: tr, ctx: ctx)
        let pointPressure = pointPressureBonus(totalPoints: Int(points))

        switch tier {
        case .cashingWinner:
            return 400
                + points * 8 * pointPressure
                + security * 90
                + Double(cards.count) * 18
                + sideSuitUrgency(cards, position: position, ts: ts, tr: tr, ctx: ctx)
        case .safeControlGroup:
            return 320
                + security * 85
                + Double(cards.count) * 24
                + points * 5
                + mixedSlamControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * 55
        case .strongStructure:
            return 240
                + security * 70
                + points * 4
                + wholeStructureControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * 80
                + (isTractorLead(cards, ts: ts, tr: tr) ? 35 : 0)
        case .initiativeBuilder:
            let remaining = handAfterPlaying(cards, from: hand)
            var s = 120
                + leadInitiativeValue(hand: remaining, position: position, state: state, ctx: ctx, security: max(security, 0.55)) * 80
                + partnerDumpLeadValue(cards, position: position, tr: tr, ctx: ctx) * 35
                + idleTrumpTransferValue(move, hand: hand, ts: ts, tr: tr)
                - points * 2
            // Asset Lifecycle: pull trump to unlock side-suit winners awaiting it (pull first, realize later).
            if isTrumpLead(move, ts: ts, tr: tr) {
                s += delayedSideRealizationValue(position: position, hand: hand, state: state, ctx: ctx) * 1.2
            }
            return s
        case .weakDisposal:
            let breakCost = structureFragmentationCost(cards, hand: hand, ts: ts, tr: tr)
            return 40
                - points * 6
                - breakCost * 45
                - Double(cards.count - 1) * 8
                + (clearsSideSuitForLead(cards, hand: hand, ts: ts, tr: tr) ? 15 : 0)
        }
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
        return suitAwaitingTrumpPull(suit, position: position, hand: hand, state: state, ctx: ctx)
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

        if cards.contains(where: { $0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) {
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
        if cards.contains(where: { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) { urgency += 20 }
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
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) {
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
            }).first(where: { isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx, hand: hand) }) {
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

        let allBig = cards.allSatisfy { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }
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
    /// 强对子定义：A对 / 级牌对 / 王对 / K对 / 10对 / 含分牌对子(5) / 主牌强对子。
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
        // K对 / 10对（注意：必须在「含分对子」之前判断，K/10 本身也是分牌）
        if rep.rank == .king || rep.rank == .ten { return (100, 40) }
        // 其他含分对子（5对）→ 中等
        if rep.pointValue > 0 { return (70, 30) }
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
    /// - 对手已确认绝该花色：仅当组合含对子时才甩
    /// 优先选张数最多的花色，张数相同时优先含对子的花色
    static func findSlamLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [[Card]] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards {
            guard let suit = card.suit else { continue }
            bySuit[suit, default: []].append(card)
        }

        var candidates: [[Card]] = []
        for (suit, suitCards) in bySuit {
            let unbeatableSingles = suitCards.filter {
                isEffectivelyBiggestSingle($0, hand: hand, ctx: ctx, ts: ts, tr: tr)
            }

            var rankGroups: [Rank: [Card]] = [:]
            for card in suitCards { rankGroups[card.rank, default: []].append(card) }

            var unbeatablePairCards: [Card] = []
            for cards in rankGroups.values where cards.count >= 2 {
                if isEffectivelyBiggestPair(cards[0], hand: hand, ctx: ctx, ts: ts, tr: tr) {
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
            if hasVoidEnemy && !hasPairs { continue }

            candidates.append(candidateCards)

            // 大甩牌风险较高时，也提供较小的安全子集给评分器选择。
            if candidateCards.count > 3, !unbeatablePairCards.isEmpty {
                let pairOnly = suitCards.filter { card in unbeatablePairCards.contains(where: { $0.id == card.id }) }
                if pairOnly.count >= 2 { candidates.append(pairOnly) }
            }
        }
        return candidates
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
