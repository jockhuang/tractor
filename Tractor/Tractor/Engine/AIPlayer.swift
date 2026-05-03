import Foundation

// MARK: - AI Game Memory（从已出的牌推导）

private struct AIContext {

    let playedCards: [Card]
    /// 每个玩家确认绝掉的逻辑花色 key（同 suitKey 格式）
    let voidSuits: [PlayerPosition: Set<String>]
    /// 当前 AI 是否为本墩最后一个出牌的玩家（3 家已出牌时为 true）
    let isLastPlayer: Bool

    // MARK: Build

    static func build(state: GameState, ts: Suit?, tr: Rank) -> AIContext {
        var played: [Card] = []
        var voids: [PlayerPosition: Set<String>] = [:]

        for trick in state.completedTricks {
            guard let lead = trick.plays.first,
                  let lc   = lead.cards.first else { continue }
            let lk = suitKey(lc, ts: ts, tr: tr)
            for play in trick.plays {
                played.append(contentsOf: play.cards)
                if play.position != lead.position,
                   let fc = play.cards.first,
                   suitKey(fc, ts: ts, tr: tr) != lk {
                    voids[play.position, default: []].insert(lk)
                }
            }
        }
        // 本墩已出的牌也算"已知"
        for play in state.currentTrick.plays {
            played.append(contentsOf: play.cards)
        }
        let isLast = state.currentTrick.plays.count == 3
        return AIContext(playedCards: played, voidSuits: voids, isLastPlayer: isLast)
    }

    // MARK: Helpers

    /// 逻辑花色 key：主牌 → "TRUMP"，副牌 → suit.rawValue
    static func suitKey(_ card: Card, ts: Suit?, tr: Rank) -> String {
        CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? "TRUMP"
            : (card.suit?.rawValue ?? "TRUMP")
    }

    func isVoid(_ pos: PlayerPosition, key: String) -> Bool {
        voidSuits[pos]?.contains(key) ?? false
    }

    /// 该敌方玩家是否确认已绝此花色
    func enemyVoid(_ pos: PlayerPosition, key: String, myTeam: Int) -> Bool {
        pos.team != myTeam && isVoid(pos, key: key)
    }

    /// 所有敌方玩家都绝了此花色
    func allEnemiesVoid(myTeam: Int, key: String) -> Bool {
        PlayerPosition.allCases
            .filter { $0.team != myTeam }
            .allSatisfy { isVoid($0, key: key) }
    }

    /// 指定逻辑花色 key 的敌方绝对玩家列表
    func voidEnemies(myTeam: Int, key: String) -> [PlayerPosition] {
        PlayerPosition.allCases.filter { enemyVoid($0, key: key, myTeam: myTeam) }
    }

    /// 该非主牌是否当前"已是最大"（双副牌中，所有更大的同花色牌均已出完 2 张）
    func isEffectivelyBiggest(_ card: Card, ts: Suit?, tr: Rank) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }

        // 统计已打出的同花色、更大牌的数量
        var higherPlayed: [Int: Int] = [:]
        for c in playedCards
            where c.suit == suit
               && !CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr)
               && c.rank.rawValue > card.rank.rawValue {
            higherPlayed[c.rank.rawValue, default: 0] += 1
        }
        // 每个更大的 rank 需要 2 张都打完（双副牌）
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { (higherPlayed[$0.rawValue] ?? 0) >= 2 }
    }

    /// 双副牌共有 4 张王牌（大王×2 + 小王×2），若已出少于 2 张则认为还有大量大主牌在场
    func manyBigTrumpsRemain() -> Bool {
        let played = playedCards.filter {
            $0.rank == .bigJoker || $0.rank == .smallJoker
        }.count
        return played < 2   // 4 张王中，不足一半出完 → 大主牌仍多
    }

    /// 某非主花色剩余未出的分牌张数（双副牌：5,10,K 各 2 张）
    func unplayedSuitPoints(suit: Suit, tr: Rank) -> Int {
        let pointRanks: [Rank] = [.five, .ten, .king]
        var total = 0
        for rank in pointRanks where rank != tr {
            let played = playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            total += max(0, 2 - played)
        }
        return total
    }
}

// MARK: - AIPlayer

struct AIPlayer {

    private struct TractorInfo {
        let pairCount: Int
        let highCard: Card
    }

    /// AI 决策：选择要出的牌
    static func chooseCards(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = []
    ) -> [Card] {
        let hand = state.player(position).hand
        guard !hand.isEmpty else { return [] }

        let ts = state.trumpSuit
        let tr = state.trumpRank
        let ctx = AIContext.build(state: state, ts: ts, tr: tr)

        if state.currentTrick.plays.isEmpty {
            return leadCards(position: position, hand: hand,
                             state: state, evaluator: evaluator, ctx: ctx)
        }

        let lc = state.currentTrick.leadCards!
        return followCards(leadCards: lc, hand: hand, position: position,
                           state: state, evaluator: evaluator,
                           forcedCards: forcedCards, ctx: ctx)
    }

    // MARK: - 先手策略

    private static func leadCards(
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

        // ── 4. 非主花色对子（避免敌方已绝花色）──────────────────
        if let pair = findBestPairAvoidingVoid(in: hand, ts: ts, tr: tr,
                                               myTeam: myTeam, ctx: ctx) {
            return pair
        }
        if let pair = findPair(in: hand, trumpSuit: ts, trumpRank: tr) {
            return pair
        }

        // ── 5. 最小主牌 ──────────────────────────────────────
        if let smallTrump = weakestCards(
            from: hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) },
            count: 1, trumpSuit: ts, trumpRank: tr
        ).first {
            return [smallTrump]
        }

        // ── 6. 最弱牌 ────────────────────────────────────────
        return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }

    // MARK: - 跟牌策略

    private static func followCards(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = [],
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count

        // 甩牌失败强制出牌
        if !forcedCards.isEmpty {
            var chosen = Array(forcedCards.prefix(count))
            if chosen.count < count {
                let usedIDs = Set(chosen.map { $0.id })
                let rest = hand.filter { !usedIDs.contains($0.id) }
                chosen += smartDiscard(
                    from: rest, count: count - chosen.count,
                    enemyWinning: true, ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx
                )
            }
            return Array(chosen.prefix(count))
        }

        let leadSuit     = evaluator.dominantSuit(of: leadCards)
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let winningCards  = state.currentTrick.plays.first {
            $0.position == currentWinner
        }?.cards ?? leadCards
        let partnerWinning = currentWinner.team == position.team
        let enemyWinning   = !partnerWinning

        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }

        // ── 连对 ────────────────────────────────────────────
        if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
            return followTractor(
                leadTractor: leadTractor,
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr,
                position: position,
                leadSuit: leadSuit,
                ctx: ctx
            )
        }

        // ── 对子 ─────────────────────────────────────────────
        if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
            return followPair(
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr,
                position: position,
                leadSuit: leadSuit,
                ctx: ctx
            )
        }

        // ── 单牌 ─────────────────────────────────────────────
        var chosen: [Card] = []

        if suitCards.count >= count {
            let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
            let canBeat = partnerWinning ? [] : suitCards.filter {
                CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr)
            }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

            if !canBeat.isEmpty {
                chosen = Array(canBeat.prefix(count))
            } else {
                chosen = partnerWinning
                    ? safePartnerCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr, ctx: ctx)
                    : weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }
        } else {
            // 同花色不够：先出所有同花色
            chosen = suitCards
            let remaining = count - chosen.count
            if remaining > 0 {
                let extra = hand.filter { evaluator.cardSuit($0) != leadSuit }

                // 绝牌后额外出牌策略（考虑是否出主/垫分）
                let fills = voidFillCards(
                    extra: extra, remaining: remaining,
                    leadSuit: leadSuit,
                    partnerWinning: partnerWinning,
                    enemyWinning: enemyWinning,
                    position: position,
                    ts: ts, tr: tr,
                    ctx: ctx
                )
                chosen += fills
            }
        }

        if chosen.count < count {
            let ids = Set(chosen.map { $0.id })
            let rest = hand.filter { !ids.contains($0.id) }
            chosen += Array(rest.prefix(count - chosen.count))
        }
        return Array(chosen.prefix(count))
    }

    // MARK: - 绝牌后额外牌策略

    /// 当自己绝了先手花色，需要出 remaining 张额外牌时的决策
    private static func voidFillCards(
        extra: [Card],
        remaining: Int,
        leadSuit: Suit?,
        partnerWinning: Bool,
        enemyWinning: Bool,
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> [Card] {
        guard remaining > 0 else { return [] }

        if partnerWinning {
            return safePartnerCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr, ctx: ctx)
        }

        // 敌方当前赢，且先手花色还有未出的分牌
        if enemyWinning, let leadActualSuit = leadSuit {
            let unplayedPts = ctx.unplayedSuitPoints(suit: leadActualSuit, tr: tr)
            if unplayedPts > 0 {
                // 两家敌方都还有此花色 → 出主截胡（带最强分牌垫底）
                let lk = leadActualSuit.rawValue
                let bothEnemiesHave = !ctx.allEnemiesVoid(myTeam: position.team, key: lk)
                    && ctx.voidEnemies(myTeam: position.team, key: lk).count < 2

                let trumpCards = extra.filter {
                    CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

                if bothEnemiesHave, let smallTrump = trumpCards.first {
                    // 出小主截胡
                    var result = [smallTrump]
                    if result.count < remaining {
                        let usedIDs = Set(result.map { $0.id })
                        let rest = extra.filter { !usedIDs.contains($0.id) }
                        result += smartDiscard(
                            from: rest, count: remaining - result.count,
                            enemyWinning: true, ts: ts, tr: tr,
                            myTeam: position.team, ctx: ctx
                        )
                    }
                    return Array(result.prefix(remaining))
                }
            }
        }

        // 否则走智能垫牌
        return smartDiscard(
            from: extra, count: remaining,
            enemyWinning: enemyWinning,
            ts: ts, tr: tr,
            myTeam: position.team, ctx: ctx
        )
    }

    // MARK: - 智能垫牌（利用对手绝牌信息）

    /// 选出 count 张要垫的牌：
    /// - 优先垫敌方绝的花色的牌（浪费对手的大牌机会）
    /// - 敌方赢时避免垫分牌
    private static func smartDiscard(
        from cards: [Card],
        count: Int,
        enemyWinning: Bool,
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card] {
        guard count > 0, !cards.isEmpty else { return [] }

        // 分牌和非分牌
        let pointCards    = cards.filter { $0.pointValue > 0 }
        let nonPointCards = cards.filter { $0.pointValue == 0 }

        // 敌方已绝花色的牌（垫这些对手也拿不走）
        func isEnemyVoidSuit(_ card: Card) -> Bool {
            let k = AIContext.suitKey(card, ts: ts, tr: tr)
            return ctx.allEnemiesVoid(myTeam: myTeam, key: k)
        }

        var pool: [Card]

        if enemyWinning {
            // 敌方赢时：先垫敌方绝的非分牌，再垫敌方绝的分牌，最后垫非分弱牌
            let safeNonPoint = nonPointCards.filter { isEnemyVoidSuit($0) }
            let safePoint    = pointCards.filter    { isEnemyVoidSuit($0) }
            let fallbackNon  = nonPointCards.filter { !isEnemyVoidSuit($0) }
            let fallbackPt   = pointCards.filter    { !isEnemyVoidSuit($0) }
            pool = safeNonPoint + safePoint + fallbackNon + fallbackPt
        } else {
            // 队友赢时：不怕垫分，敌方绝的分牌（可让队友赢分）优先
            let safePoint    = pointCards.filter    { isEnemyVoidSuit($0) }
            let safeNonPoint = nonPointCards.filter { isEnemyVoidSuit($0) }
            let fallbackPt   = pointCards.filter    { !isEnemyVoidSuit($0) }
            let fallbackNon  = nonPointCards.filter { !isEnemyVoidSuit($0) }
            pool = safePoint + safeNonPoint + fallbackPt + fallbackNon
        }

        // 同优先级内按 discardOrder 排序
        let sorted = pool.sorted {
            discardOrder($0, before: $1, trumpSuit: ts, trumpRank: tr)
        }
        return Array(sorted.prefix(count))
    }

    // MARK: - followTractor / followPair（带 context 版本）

    private static func followTractor(
        leadTractor: TractorInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        ctx: AIContext
    ) -> [Card] {
        let count = leadTractor.pairCount * 2

        if suitCards.count >= count {
            let availableTractors = tractors(in: suitCards, pairCount: leadTractor.pairCount,
                                             trumpSuit: trumpSuit, trumpRank: trumpRank)
            if partnerWinning {
                // 规则：有连对必须出连对；无连对再按支持策略
                if let weakestTractor = availableTractors.sorted(by: {
                    weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }).first {
                    return weakestTractor   // 出最弱连对，保留大牌
                }
                return safePartnerCards(from: suitCards, count: count,
                                        trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            }
            if let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beatingTractors = availableTractors
                    .filter { t in
                        guard let info = tractorInfo(of: t, trumpSuit: trumpSuit, trumpRank: trumpRank)
                        else { return false }
                        return CardComparator.beats(info.highCard, winningTractor.highCard,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let t = beatingTractors.first { return t }
            }
            if let weakest = availableTractors.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first { return weakest }
            return weakestCards(from: suitCards, count: count,
                                trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        if suitCards.isEmpty,
           !partnerWinning,
           let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
            let beatingTractors = tractors(in: hand, pairCount: leadTractor.pairCount,
                                           trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { t in
                    guard let info = tractorInfo(of: t, trumpSuit: trumpSuit, trumpRank: trumpRank)
                    else { return false }
                    return CardComparator.beats(info.highCard, winningTractor.highCard,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            if let t = beatingTractors.first { return t }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest    = hand.filter { !usedIDs.contains($0.id) }
        let extra   = partnerWinning
            ? safePartnerCards(from: rest, count: count - suitCards.count,
                               trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            : voidFillCards(extra: rest, remaining: count - suitCards.count,
                            leadSuit: leadSuit,
                            partnerWinning: false, enemyWinning: true,
                            position: .south,   // 仅用于 team，传实际 position 更好但重构成本高
                            ts: trumpSuit, tr: trumpRank, ctx: ctx)
        return suitCards + extra
    }

    private static func followPair(
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        ctx: AIContext
    ) -> [Card] {
        if suitCards.count >= 2 {
            let availablePairs = pairs(in: suitCards, trumpSuit: trumpSuit, trumpRank: trumpRank)

            if partnerWinning {
                // 规则：有对子必须出对子；无对子才可随意选两张
                if let weakestPair = availablePairs.sorted(by: {
                    weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }).first {
                    return weakestPair   // 出最弱对子，保留大牌
                }
                return safePartnerCards(from: suitCards, count: 2,
                                        trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            }
            if let winningPair = pairRepresentative(of: winningCards,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beating = availablePairs
                    .filter { p in
                        guard let rep = pairRepresentative(of: p, trumpSuit: trumpSuit,
                                                           trumpRank: trumpRank) else { return false }
                        return CardComparator.beats(rep, winningPair,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let p = beating.first { return p }
            }
            if let weakest = availablePairs.sorted(by: {
                weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first { return weakest }
            return weakestCards(from: suitCards, count: 2,
                                trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        if suitCards.isEmpty,
           !partnerWinning,
           let winningPair = pairRepresentative(of: winningCards,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank) {
            let beating = pairs(in: hand, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { p in
                    guard let rep = pairRepresentative(of: p, trumpSuit: trumpSuit,
                                                       trumpRank: trumpRank) else { return false }
                    return CardComparator.beats(rep, winningPair,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            if let p = beating.first { return p }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest    = hand.filter { !usedIDs.contains($0.id) }
        let extra   = partnerWinning
            ? safePartnerCards(from: rest, count: 2 - suitCards.count,
                               trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            : voidFillCards(extra: rest, remaining: 2 - suitCards.count,
                            leadSuit: leadSuit,
                            partnerWinning: false, enemyWinning: true,
                            position: position,
                            ts: trumpSuit, tr: trumpRank, ctx: ctx)
        return suitCards + extra
    }

    // MARK: - 领出辅助

    /// 队友赢时决定是否扔分牌：只有「本墩最后出牌」或「大主牌已基本耗尽」时才贡献分牌
    /// 否则用安全垫牌（避免后手对手用大王截胡）
    private static func safePartnerCards(
        from cards: [Card], count: Int,
        trumpSuit: Suit?, trumpRank: Rank,
        ctx: AIContext
    ) -> [Card] {
        let safe = !ctx.isLastPlayer && ctx.manyBigTrumpsRemain()
        if safe {
            // 不贡献分牌：出最弱的非主牌，再补主牌
            return weakestCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        return partnerSupportCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    /// 旁门 Ace（且敌方未全绝此花色，出才有意义）
    private static func bestSideAce(
        in hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> Card? {
        hand.first {
            $0.rank == .ace
                && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                && !ctx.allEnemiesVoid(myTeam: myTeam,
                                       key: AIContext.suitKey($0, ts: trumpSuit, tr: trumpRank))
        }
    }

    /// 在非绝牌花色中找对子（避免领出敌方已绝花色的单牌）
    private static func findBestPairAvoidingVoid(
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

    // MARK: - Utility Helpers（与原版一致）

    private static func maxCard(in cards: [Card], ts: Suit?, tr: Rank) -> Card {
        cards.max { a, b in CardComparator.beats(b, a, trumpSuit: ts, trumpRank: tr) }!
    }

    private static func tractors(in cards: [Card], pairCount: Int,
                                  trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        guard pairCount >= 2 else { return [] }
        let pairGroups = pairs(in: cards, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bySuit = Dictionary(grouping: pairGroups) { pair in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        var result: [[Card]] = []
        for groups in bySuit.values {
            let ordered = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            guard ordered.count >= pairCount else { continue }
            for start in 0...(ordered.count - pairCount) {
                let window = Array(ordered[start..<(start + pairCount)])
                let reps = window.map { $0[0] }
                let isConsec = zip(reps, reps.dropFirst()).allSatisfy {
                    CardComparator.areAdjacentPairRanks($0, $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                if isConsec { result.append(window.flatMap { $0 }) }
            }
        }
        return result
    }

    private static func pairs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        return grouped.values.compactMap { $0.count >= 2 ? Array($0.prefix(2)) : nil }
    }

    private static func tractorInfo(of cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> TractorInfo? {
        guard cards.count >= 4, cards.count.isMultiple(of: 2) else { return nil }
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let pairCount = cards.count / 2
        guard grouped.count == pairCount,
              grouped.values.allSatisfy({ $0.count == 2 }) else { return nil }
        let reps = grouped.values.compactMap(\.first)
        guard let suit = reps.first.map({
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }), reps.allSatisfy({
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank) == suit
        }) else { return nil }
        let ordered = reps.sorted {
            CardComparator.pairOrderValue($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                < CardComparator.pairOrderValue($1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        for (lo, hi) in zip(ordered, ordered.dropFirst()) {
            guard CardComparator.areAdjacentPairRanks(lo, hi,
                                                       trumpSuit: trumpSuit, trumpRank: trumpRank)
            else { return nil }
        }
        guard let highCard = ordered.last else { return nil }
        return TractorInfo(pairCount: pairCount, highCard: highCard)
    }

    private static func pairRepresentative(of cards: [Card], trumpSuit: Suit?,
                                            trumpRank: Rank) -> Card? {
        guard cards.count == 2,
              pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                == pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return nil }
        return cards[0]
    }

    private static func weakerPair(_ a: [Card], than b: [Card],
                                    trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aRep = pairRepresentative(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bRep = pairRepresentative(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aRep, than: bRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakerTractor(_ a: [Card], than b: [Card],
                                       trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aInfo = tractorInfo(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bInfo = tractorInfo(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aInfo.highCard, than: bInfo.highCard,
                          trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakestCards(from cards: [Card], count: Int,
                                      trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        Array(cards.sorted {
            discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    private static func partnerSupportCards(from cards: [Card], count: Int,
                                             trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.sorted {
            partnerSupportOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    private static func weakerCard(_ a: Card, than b: Card,
                                    trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        CardComparator.beats(b, a, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    static func discardOrder(_ a: Card, before b: Card,
                              trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        let aT = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aT != bT { return !aT }
        if aT {
            return CardComparator.trumpWeight(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
                 < CardComparator.trumpWeight(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if a.pointValue != b.pointValue { return a.pointValue < b.pointValue }
        return a.rank.rawValue < b.rank.rawValue
    }

    private static func partnerSupportOrder(_ a: Card, before b: Card,
                                             trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        if a.pointValue != b.pointValue { return a.pointValue > b.pointValue }
        let aT = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aT != bT { return !aT }
        return discardOrder(a, before: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func findPair(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        var seen: [String: [Card]] = [:]
        for card in hand {
            seen[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let p = seen.filter {
            $0.value.count >= 2
                && !CardComparator.isTrump($0.value[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if let best = p.max(by: { a, b in a.value[0].rank < b.value[0].rank }) {
            return Array(best.value.prefix(2))
        }
        return nil
    }

    private static func findTractor(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit
                    && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            let candidates = tractors(in: suitCards, pairCount: 2,
                                      trumpSuit: trumpSuit, trumpRank: trumpRank)
            if let strongest = candidates.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).last { return strongest }
        }
        return nil
    }

    private static func pairKey(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> String {
        CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }
}
