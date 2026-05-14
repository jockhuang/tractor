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

    /// 大主牌（大小王 + 级牌）是否仍有残留
    /// 双副牌共 4 张王 + 8 张级牌（4花色×2副）= 12 张大主牌
    /// 若已出数量不足一半（<6），则认为场上仍有大主牌威胁
    func manyBigTrumpsRemain(trumpRank: Rank) -> Bool {
        // 双副牌大主牌总张数：大王×2 + 小王×2 + 4花色×2副×1张 = 12
        let totalBigTrumps = 12
        let played = playedCards.filter {
            $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == trumpRank
        }.count
        return played < totalBigTrumps / 2   // 不足一半出完 → 大主牌仍多
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

        let suitCards  = hand.filter { evaluator.cardSuit($0) == leadSuit }
        let trickPoints = state.currentTrick.plays
            .flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }

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
                trickPoints: trickPoints,
                ctx: ctx
            )
        }

        // ── 甩牌 ─────────────────────────────────────────────
        if let slam = evaluator.slamInfo(of: leadCards) {
            return followSlam(
                slam: slam, winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards, hand: hand,
                position: position, count: count,
                ts: ts, tr: tr, ctx: ctx
            )
        }

        // ── 单牌 ─────────────────────────────────────────────
        var chosen: [Card] = []

        // 吊主保守条件：先手花色为主牌 && 非末位出牌 && 敌方领先 && 仍有大主牌残留
        // 满足时跟牌优先出无分主牌，避免把 5/10/K 送给后手大牌截胡
        let leadIsTrump = leadSuit == nil
        let shouldAvoidPointsWhenFollowing =
            leadIsTrump && !ctx.isLastPlayer && enemyWinning && ctx.manyBigTrumpsRemain(trumpRank: tr)

        if suitCards.count >= count {
            let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
            let canBeat = partnerWinning ? [] : suitCards.filter {
                CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr)
            }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

            if !canBeat.isEmpty {
                // 本墩 ≥10分 且 攻方累计 >60分：局势关键，从大往小出，争胜
                let aggressive = trickPoints >= 10 && state.attackScore > 60
                if aggressive {
                    // 末位出牌时无后手威胁，出最小能压赢的即可；非末位才需要出最大牌确保拿墩
                    chosen = ctx.isLastPlayer
                        ? Array(canBeat.prefix(count))
                        : Array(canBeat.reversed().prefix(count))
                } else if leadIsTrump && !ctx.isLastPlayer {
                    // 跟主 + 非末位 + 后手仍有对手时：优先选 A 及以上大牌压住
                    // 防止后手对手用 K 轻松击败我方出的 J/Q 等中等主牌而获分
                    let subsequent = unplayedSubsequentPositions(after: position, in: state)
                    if subsequent.contains(where: { $0.team != position.team }) {
                        let safeCanBeat = canBeat.filter { isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx) }
                        chosen = Array((safeCanBeat.isEmpty ? canBeat : safeCanBeat).prefix(count))
                    } else {
                        chosen = Array(canBeat.prefix(count))
                    }
                } else {
                    chosen = Array(canBeat.prefix(count))
                }
            } else if partnerWinning {
                if leadIsTrump {
                    // 跟主且我方领先：只有后手全部绝主才安全加分
                    // 否则出无分主牌，防止后手大主截胡
                    let subsequent = unplayedSubsequentPositions(after: position, in: state)
                    let allVoidInTrump = subsequent.allSatisfy { ctx.isVoid($0, key: "TRUMP") }
                    chosen = allVoidInTrump
                        ? partnerSupportCards(from: suitCards, count: count,
                                              trumpSuit: ts, trumpRank: tr)
                        : weakestNonPointFirst(from: suitCards, count: count,
                                               trumpSuit: ts, trumpRank: tr)
                } else {
                    chosen = safePartnerCards(from: suitCards, count: count,
                                              trumpSuit: ts, trumpRank: tr, ctx: ctx)
                }
            } else if shouldAvoidPointsWhenFollowing {
                // 吊主保守：优先出无分主牌
                chosen = weakestNonPointFirst(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            } else {
                chosen = weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }
        } else {
            // 同花色不够：先出所有同花色
            chosen = suitCards
            let remaining = count - chosen.count
            if remaining > 0 {
                let extra = hand.filter { evaluator.cardSuit($0) != leadSuit }

                // 提前计算后手对手花色信息（截胡和常规策略均需要）
                let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
                let subsequent = unplayedSubsequentPositions(after: position, in: state)
                // 后手对手绝了先手花色 且 还有主牌（可能出主将吃）才需要特殊处理
                // 若后手对手绝花色但也没有主，小主截胡即可，走原有逻辑
                let enemySubsequentVoidInLead = subsequent.contains {
                    $0.team != position.team
                    && ctx.isVoid($0, key: leadKey)
                    && !ctx.isVoid($0, key: "TRUMP")
                }

                // ── 对方大 + 本墩有分 → 主动压牌（优先截胡）──────
                if enemyWinning && trickPoints > 0 {
                    let winRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    // 找能压赢的牌（主牌优先能压非主赢家），按弱到强排序
                    let canBeatExtra = extra.filter {
                        CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr)
                    }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                    if !canBeatExtra.isEmpty {
                        let intercept: [Card]
                        let aggressive = trickPoints >= 10 && state.attackScore > 60
                        if aggressive {
                            // 本墩 ≥10分 且 攻方累计 >60分：局势关键，争胜
                            // 末位出牌时无后手威胁，出最小能压赢的；非末位才出最大牌
                            intercept = ctx.isLastPlayer
                                ? Array(canBeatExtra.prefix(remaining))
                                : Array(canBeatExtra.reversed().prefix(remaining))
                        } else if enemySubsequentVoidInLead && !ctx.isLastPlayer {
                            // 后手对手也绝该花色且还有主牌：出安全主牌（A及以上），
                            // 防止后手对手用稍大主牌截走本墩
                            let safeCanBeat = canBeatExtra.filter {
                                isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx)
                            }
                            intercept = Array((safeCanBeat.isEmpty ? canBeatExtra : safeCanBeat)
                                .prefix(remaining))
                        } else {
                            intercept = Array(canBeatExtra.prefix(remaining))
                        }
                        chosen += intercept
                        // 若还需凑牌（多张跟牌场景），垫分给自己
                        if chosen.count < count {
                            let ids = Set(chosen.map { $0.id })
                            let rest = hand.filter { !ids.contains($0.id) }
                            chosen += smartDiscard(
                                from: rest, count: count - chosen.count,
                                enemyWinning: false,   // 我方已压住，按队友赢策略垫分
                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                            )
                        }
                        return Array(chosen.prefix(count))
                    }
                    // canBeatExtra 为空：手中无牌能压赢当前领先者
                    // 激进模式下不浪费大牌（如小王赔给大王毫无意义），直接出最弱的
                    if trickPoints >= 10 && state.attackScore > 60 {
                        chosen += smartDiscard(
                            from: extra, count: remaining,
                            enemyWinning: true,
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                        )
                        return Array(chosen.prefix(count))
                    }
                }
                // 队友赢 但该花色还有更大的未出牌 → 后续对手可能出大牌压走本墩
                // 此时不应垫分给队友，而要用主将吃保护本墩
                var partnerAtRisk = false
                if partnerWinning, let suit = leadSuit {
                    let winRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    if !CardComparator.isTrump(winRep, trumpSuit: ts, trumpRank: tr) {
                        let trickCards = state.currentTrick.plays.flatMap { $0.cards }
                        let winRankVal = winRep.rank.rawValue
                        for rank in Rank.allCases
                            where rank.rawValue > winRankVal
                               && rank != tr
                               && rank != .smallJoker && rank != .bigJoker {
                            let played  = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
                            let inHand  = hand.filter { $0.suit == suit && $0.rank == rank }.count
                            let inTrick = trickCards.filter { $0.suit == suit && $0.rank == rank }.count
                            if 2 - played - inHand - inTrick > 0 {
                                partnerAtRisk = true
                                break
                            }
                        }
                    }
                }

                let fills = voidFillCards(
                    extra: extra, remaining: remaining,
                    leadSuit: leadSuit,
                    partnerWinning: partnerWinning,
                    enemyWinning: enemyWinning,
                    position: position,
                    ts: ts, tr: tr,
                    ctx: ctx,
                    enemySubsequentVoidInLead: enemySubsequentVoidInLead,
                    partnerAtRisk: partnerAtRisk
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
    /// - enemySubsequentVoidInLead: 后手中是否有对手也绝了先手花色（需谨慎垫牌）
    private static func voidFillCards(
        extra: [Card],
        remaining: Int,
        leadSuit: Suit?,
        partnerWinning: Bool,
        enemyWinning: Bool,
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext,
        enemySubsequentVoidInLead: Bool = false,
        partnerAtRisk: Bool = false
    ) -> [Card] {
        guard remaining > 0 else { return [] }

        if partnerWinning {
            // 队友当前赢，但该花色还有更大的未出牌 → 需用主将吃，不能垫分
            if partnerAtRisk {
                let trumpCards = extra.filter {
                    CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

                if !trumpCards.isEmpty {
                    // 后手对手也绝花色 → 安全出主（A 及以上），防止被截胡
                    let chosen: Card
                    if enemySubsequentVoidInLead {
                        let safeTrumps = trumpCards.filter { isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx) }
                        chosen = (safeTrumps.isEmpty ? trumpCards : safeTrumps).first!
                    } else {
                        // 优先将孤张主牌分（10/K/5，不拆对子）垫给队友；无则出最弱主牌
                        var pairMap: [String: [Card]] = [:]
                        for card in trumpCards {
                            pairMap[CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr),
                                    default: []].append(card)
                        }
                        let pairedIDs = Set(pairMap.values.filter { $0.count >= 2 }
                            .flatMap { $0 }.map { $0.id })
                        let pointRanks: Set<Rank> = [.ten, .king, .five]
                        // 孤张主分牌，按分值高→低（10/K 同分则取 K，再取 5）
                        let singletonPointTrump = trumpCards
                            .filter { !pairedIDs.contains($0.id)
                                   && $0.rank != tr
                                   && pointRanks.contains($0.rank) }
                            .sorted { $0.pointValue > $1.pointValue }
                            .first
                        chosen = singletonPointTrump ?? trumpCards.first!
                    }
                    var result = [chosen]
                    if result.count < remaining {
                        let usedIDs = Set(result.map { $0.id })
                        let rest = extra.filter { !usedIDs.contains($0.id) }
                        result += smartDiscard(
                            from: rest, count: remaining - result.count,
                            enemyWinning: false,
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                        )
                    }
                    return Array(result.prefix(remaining))
                }
                // 无主牌可将吃：安全垫牌（不送分）
                return smartDiscard(
                    from: extra, count: remaining,
                    enemyWinning: true,
                    ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                )
            }

            if enemySubsequentVoidInLead {
                // 我方领先，但后手对手也绝了该花色 → 他可能出主将吃本墩
                // 谨慎策略：不加分，出主只用 A 及以上（K 以下容易被对手稍大主牌截走）
                let safePool = extra.filter { card in
                    if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                        return isSafeTrumpFiller(card, ts: ts, tr: tr, ctx: ctx)
                    }
                    return true
                }
                return smartDiscard(
                    from: safePool.isEmpty ? extra : safePool,
                    count: remaining,
                    enemyWinning: true,   // 视同对方可能截胡，避免垫分牌
                    ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx
                )
            }
            return safePartnerCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr, ctx: ctx)
        }

        // 敌方当前赢，且先手花色还有未出的分牌
        if enemyWinning, let leadActualSuit = leadSuit {
            let unplayedPts = ctx.unplayedSuitPoints(suit: leadActualSuit, tr: tr)
            if unplayedPts > 0 {
                let lk = leadActualSuit.rawValue
                let bothEnemiesHave = !ctx.allEnemiesVoid(myTeam: position.team, key: lk)
                    && ctx.voidEnemies(myTeam: position.team, key: lk).count < 2

                // 按牌力从弱到强排好（first = 最弱，last = 最强）
                let trumpCards = extra.filter {
                    CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

                if enemySubsequentVoidInLead {
                    // 后手对手也绝花色 → 竞争截胡：优先出王/级牌（最强）
                    // 没有王/级牌则退为安全垫牌，不出小主送分
                    let bigTrumps = trumpCards.filter {
                        $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == tr
                    }
                    if let strongest = bigTrumps.last {
                        var result = [strongest]
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
                    // 无王/级牌：安全垫牌（出主只用 A，不出分牌）
                    let safePool = extra.filter { card in
                        if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                            return isSafeTrumpFiller(card, ts: ts, tr: tr, ctx: ctx)
                        }
                        return true
                    }
                    return smartDiscard(
                        from: safePool.isEmpty ? extra : safePool,
                        count: remaining,
                        enemyWinning: true, ts: ts, tr: tr,
                        myTeam: position.team, ctx: ctx
                    )
                }

                if bothEnemiesHave, let smallTrump = trumpCards.first {
                    // 后手对手有该花色：出小主截胡
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

        // 常规智能垫牌
        return smartDiscard(
            from: extra, count: remaining,
            enemyWinning: enemyWinning,
            ts: ts, tr: tr,
            myTeam: position.team, ctx: ctx
        )
    }

    // MARK: - 智能垫牌（利用对手绝牌信息，保留对子，避免垫主牌）

    /// 选出 count 张要垫的牌：
    /// - 优先垫散牌（避免拆对子）
    /// - 非主牌优先于主牌（尽量不垫主）
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

        // 识别手中的对子组（同一 pairKey 有 ≥2 张）
        var pairGroupMap: [String: [Card]] = [:]
        for card in cards {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr), default: []].append(card)
        }
        let pairedIDs: Set<UUID> = Set(
            pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id }
        )

        func isTrump(_ c: Card) -> Bool { CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr) }
        func isPaired(_ c: Card) -> Bool { pairedIDs.contains(c.id) }
        func isEnemyVoid(_ c: Card) -> Bool {
            ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(c, ts: ts, tr: tr))
        }

        // 优先级层次（数字越小越优先垫出）：
        // 0: 非主散牌·敌绝花色   1: 非主散牌·非敌绝
        // 2: 非主配对·敌绝花色   3: 非主配对·非敌绝
        // 4: 主牌散牌             5: 主牌配对（最后才动）
        func tier(_ c: Card) -> Int {
            let t = isTrump(c)
            let p = isPaired(c)
            let v = isEnemyVoid(c)
            switch (t, p, v) {
            case (false, false, true):  return 0
            case (false, false, false): return 1
            case (false, true,  true):  return 2
            case (false, true,  false): return 3
            case (true,  false, _):     return 4
            default:                    return 5   // 主牌配对
            }
        }

        // 散牌按 tier 和分值/rank 排序
        // 队友赢时（!enemyWinning）：同 tier 内高分牌优先（垫分给队友）
        // 敌方赢时（enemyWinning）：同 tier 内低分牌优先（避免送分）
        let singletons = cards
            .filter { !isPaired($0) }
            .sorted { a, b in
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                if a.pointValue != b.pointValue {
                    return enemyWinning ? a.pointValue < b.pointValue : a.pointValue > b.pointValue
                }
                return discardOrder(a, before: b, trumpSuit: ts, trumpRank: tr)
            }

        // 配对组按 tier（取首张代表）排序，同 tier 内分值处理同上
        let pairedGroups = pairGroupMap.values
            .filter { $0.count >= 2 }
            .sorted { a, b in
                let ta = tier(a[0]), tb = tier(b[0])
                if ta != tb { return ta < tb }
                if a[0].pointValue != b[0].pointValue {
                    return enemyWinning ? a[0].pointValue < b[0].pointValue : a[0].pointValue > b[0].pointValue
                }
                return discardOrder(a[0], before: b[0], trumpSuit: ts, trumpRank: tr)
            }

        var result: [Card] = []
        var remaining = count

        // 阶段1：先垫散牌
        for card in singletons {
            if remaining <= 0 { break }
            result.append(card)
            remaining -= 1
        }

        // 阶段2：不得不动对子时，尽量整对垫出；只差1张时取对子中最弱的一张
        for group in pairedGroups {
            if remaining <= 0 { break }
            if remaining >= 2 {
                result.append(contentsOf: Array(group.prefix(2)))
                remaining -= 2
            } else {
                let worst = group.sorted {
                    discardOrder($0, before: $1, trumpSuit: ts, trumpRank: tr)
                }.first!
                result.append(worst)
                remaining -= 1
            }
        }

        return Array(result.prefix(count))
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
                // 规则：有连对必须出连对；无连对按结构规则选牌（对子 → 散牌）
                if let weakestTractor = availableTractors.sorted(by: {
                    weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }).first {
                    return weakestTractor   // 出最弱连对，保留大牌
                }
                // 无匹配连对：按结构约束选牌，但对子和散牌槽优先出分牌
                return structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: leadTractor.pairCount,
                                                 trumpSuit: trumpSuit, trumpRank: trumpRank,
                                                 partnerWinning: true)
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
            // 无合适连对：按规则选牌（最大化对子，再填散牌）
            return structuredSuitFollowCards(suitCards: suitCards,
                                             neededPairs: leadTractor.pairCount,
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
        // 跟连对绝牌时，碎牌主牌无法压连对，不调 voidFillCards（会浪费主牌）
        // 直接智能垫牌
        let extra   = partnerWinning
            ? safePartnerCards(from: rest, count: count - suitCards.count,
                               trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            : smartDiscard(from: rest, count: count - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx)
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
        trickPoints: Int,
        ctx: AIContext
    ) -> [Card] {
        let enemyWinning = !partnerWinning

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

        // ── 绝牌（无同花色）路径 ─────────────────────────────────────

        // 尝试用全手牌中的对子压赢者
        if suitCards.isEmpty, enemyWinning {
            let winRep = maxCard(in: winningCards, ts: trumpSuit, tr: trumpRank)
            let canBeatPairs = pairs(in: hand, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { p in
                    guard let rep = pairRepresentative(of: p, trumpSuit: trumpSuit,
                                                       trumpRank: trumpRank) else { return false }
                    return CardComparator.beats(rep, winRep,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

            // 对方大 + 本墩有分：只要有能赢的对子就出
            if let p = canBeatPairs.first, trickPoints > 0 {
                return p
            }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest    = hand.filter { !usedIDs.contains($0.id) }
        // 跟对子绝牌时，单张主牌无法压对子，不调 voidFillCards（会浪费主牌）
        // 直接智能垫牌：对方赢时避免垫分，队友赢时加分
        let extra   = partnerWinning
            ? safePartnerCards(from: rest, count: 2 - suitCards.count,
                               trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
            : smartDiscard(from: rest, count: 2 - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx)
        return suitCards + extra
    }

    // MARK: - 甩牌跟牌

    /// 跟甩牌：有同花色正常出弱牌；无同花色时只在能组成匹配将牌结构时才出主，否则垫非主牌
    private static func followSlam(
        slam: TrickEvaluator.SlamInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        count: Int,
        ts: Suit?, tr: Rank,
        ctx: AIContext
    ) -> [Card] {
        // 有足够同花色：按结构优先（连对 > 对子 > 散牌），与跟连对规则一致
        if suitCards.count >= count {
            let slamPairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 } + slam.pairs.count
            let handPairs     = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
            let requiredPairs = min(handPairs, slamPairSlots)

            // 无对子要求（纯散牌甩牌）：直接出最弱的
            if requiredPairs == 0 {
                return partnerWinning
                    ? safePartnerCards(from: suitCards, count: count,
                                       trumpSuit: ts, trumpRank: tr, ctx: ctx)
                    : weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }

            // 先按结构取配对牌（连对 > 孤立对子），剩余散牌用弱牌/支持牌填充
            // 队友赢时：对子和散牌槽也优先出分牌
            let pairPart  = structuredSuitFollowCards(
                suitCards: suitCards, neededPairs: requiredPairs,
                trumpSuit: ts, trumpRank: tr,
                partnerWinning: partnerWinning
            )
            let usedIDs   = Set(pairPart.map { $0.id })
            let leftover  = suitCards.filter { !usedIDs.contains($0.id) }
            let fillCount = count - pairPart.count
            guard fillCount > 0 else { return Array(pairPart.prefix(count)) }
            let fill = partnerWinning
                ? safePartnerCards(from: leftover, count: fillCount,
                                   trumpSuit: ts, trumpRank: tr, ctx: ctx)
                : weakestCards(from: leftover, count: fillCount, trumpSuit: ts, trumpRank: tr)
            return pairPart + fill
        }

        // 先出所有同花色
        var chosen = suitCards
        let remaining = count - chosen.count
        guard remaining > 0 else { return chosen }

        let usedIDs   = Set(chosen.map { $0.id })
        let extra     = hand.filter { !usedIDs.contains($0.id) }
        let trumpPool = extra.filter {  CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        let nonTrump  = extra.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        // 完全绝牌且敌方赢 → 尝试组成匹配甩牌结构的将牌将吃
        if suitCards.isEmpty && !partnerWinning {
            if let trumpCombo = buildMatchingSlamTrump(
                slam: slam, trumpCards: trumpPool,
                winningCards: winningCards, ts: ts, tr: tr
            ) {
                return trumpCombo
            }
        }

        // 无法将吃或队友赢：优先垫非主牌，不浪费主牌
        // 队友甩牌 ≥4 张且含对子（结构有意义的大甩牌）且当前领先 → 视同拖拉机策略，主动垫分支持
        let slamIsStrong = partnerWinning
            && slam.count >= 4
            && (!slam.pairs.isEmpty || !slam.tractors.isEmpty)
        var fills = slamIsStrong
            ? safePartnerCards(from: nonTrump, count: remaining,
                               trumpSuit: ts, trumpRank: tr, ctx: ctx)
            : smartDiscard(from: nonTrump, count: remaining,
                           enemyWinning: !partnerWinning,
                           ts: ts, tr: tr, myTeam: position.team, ctx: ctx)
        // 非主牌不够时才补最弱主牌
        if fills.count < remaining {
            let usedIDs2    = Set(fills.map { $0.id })
            let trumpLeft   = trumpPool.filter { !usedIDs2.contains($0.id) }
            fills += weakestCards(from: trumpLeft, count: remaining - fills.count,
                                  trumpSuit: ts, trumpRank: tr)
        }
        chosen += Array(fills.prefix(remaining))
        return Array(chosen.prefix(count))
    }

    /// 在主牌中构造与甩牌结构完全匹配的最弱组合，并检查能否压过当前赢家
    /// 找不到合格组合时返回 nil
    private static func buildMatchingSlamTrump(
        slam: TrickEvaluator.SlamInfo,
        trumpCards: [Card],
        winningCards: [Card],
        ts: Suit?, tr: Rank
    ) -> [Card]? {
        let tractorSizes = slam.tractors
            .compactMap { tractorInfo(of: $0, trumpSuit: ts, trumpRank: tr)?.pairCount }
            .sorted(by: >)

        // 贪心构造：依次取最弱的连对 → 对子 → 单张
        var pool   = trumpCards
        var result = [Card]()

        for neededSize in tractorSizes {
            let candidates = tractors(in: pool, pairCount: neededSize,
                                      trumpSuit: ts, trumpRank: tr)
                .sorted { weakerTractor($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard let weakest = candidates.first else { return nil }
            result += weakest
            let ids = Set(weakest.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
        }

        for _ in 0..<slam.pairs.count {
            let candidates = pairs(in: pool, trumpSuit: ts, trumpRank: tr)
                .sorted { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard let weakest = candidates.first else { return nil }
            result += weakest
            let ids = Set(weakest.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
        }

        for _ in 0..<slam.singles.count {
            let sorted = pool.sorted { discardOrder($0, before: $1, trumpSuit: ts, trumpRank: tr) }
            guard let weakest = sorted.first else { return nil }
            result.append(weakest)
            pool = pool.filter { $0.id != weakest.id }
        }

        guard result.count == slam.count else { return nil }

        // 判断能否压过当前赢家
        let winnerIsTrump = winningCards.first.map {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        } ?? false

        if !winnerIsTrump { return result }  // 主牌必然大于非主赢家

        // 赢家也是主牌：用最高牌近似比较（足够 AI 决策）
        let comboHigh  = result.max      { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }!
        let winnerHigh = winningCards.max { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }!
        guard CardComparator.beats(comboHigh, winnerHigh, trumpSuit: ts, trumpRank: tr) else {
            return nil  // 压不过 → 不浪费主牌
        }
        return result
    }

    // MARK: - 领出辅助

    /// 队友赢时决定是否扔分牌：只有「本墩最后出牌」或「大主牌已基本耗尽」时才贡献分牌
    /// 否则用安全垫牌（避免后手对手用大王截胡）
    private static func safePartnerCards(
        from cards: [Card], count: Int,
        trumpSuit: Suit?, trumpRank: Rank,
        ctx: AIContext
    ) -> [Card] {
        let safe = !ctx.isLastPlayer && ctx.manyBigTrumpsRemain(trumpRank: trumpRank)
        if safe {
            // 不贡献分牌：出最弱的非主牌，再补主牌
            return weakestCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        return partnerSupportCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
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
    private static func findSlamLead(
        in hand: [Card],
        ts: Suit?, tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card]? {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        // 按花色分组
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards {
            guard let suit = card.suit else { continue }
            bySuit[suit, default: []].append(card)
        }

        var best: (cards: [Card], hasPairs: Bool)? = nil

        for (suit, suitCards) in bySuit {
            // 1. 最大单张：所有更高 rank 的两张都已知晓（played+inHand ≥ 2）
            let unbeatableSingles = suitCards.filter { card in
                isEffectivelyBiggestSingle(card, hand: hand, ctx: ctx, ts: ts, tr: tr)
            }

            // 2. 最大对子：同 rank 手中 ≥2 张，且所有更高 rank 至少有 1 张已知晓（played+inHand ≥ 1）
            //    → 对手最多只有 1 张更大的牌，凑不成更大对子
            var rankGroups: [Rank: [Card]] = [:]
            for card in suitCards { rankGroups[card.rank, default: []].append(card) }
            var unbeatablePairCards: [Card] = []
            for (_, cards) in rankGroups where cards.count >= 2 {
                if isEffectivelyBiggestPair(cards[0], hand: hand, ctx: ctx, ts: ts, tr: tr) {
                    unbeatablePairCards += Array(cards.prefix(2))
                }
            }

            // 3. 合并两类候选（去重，一张牌可能同时属于两类）
            var candidateIds = Set(unbeatableSingles.map { $0.id })
            for card in unbeatablePairCards { candidateIds.insert(card.id) }
            let candidateCards = suitCards.filter { candidateIds.contains($0.id) }

            guard candidateCards.count >= 2 else { continue }

            // 纯对子（恰好 2 张且同 pairKey）已由步骤 1/4 处理，跳过
            if candidateCards.count == 2,
               pairKey(candidateCards[0], trumpSuit: ts, trumpRank: tr)
                   == pairKey(candidateCards[1], trumpSuit: ts, trumpRank: tr) { continue }

            let suitKey = suit.rawValue
            let hasVoidEnemy = ctx.voidEnemies(myTeam: myTeam, key: suitKey).count > 0
            let hasPairs = !unbeatablePairCards.isEmpty

            // 已知对手绝花色：只有含对子的组合才值得甩
            if hasVoidEnemy && !hasPairs { continue }

            // 取张数最多的花色；张数相同时优先含对子的
            if let current = best {
                if candidateCards.count > current.cards.count ||
                   (candidateCards.count == current.cards.count && hasPairs && !current.hasPairs) {
                    best = (cards: candidateCards, hasPairs: hasPairs)
                }
            } else {
                best = (cards: candidateCards, hasPairs: hasPairs)
            }
        }

        return best?.cards
    }

    /// 单张"最大"检查：所有比它大的同花色 rank，played + inHand ≥ 2（双副牌两张都已知晓，对手无法有更大单张）
    private static func isEffectivelyBiggestSingle(
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
    private static func isEffectivelyBiggestPair(
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
    private static func bestSideAce(
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

    // MARK: - 后手位置辅助

    /// 判断某张主牌是否适合在「我方绝牌且后手对手也绝花色」时用作安全垫牌
    /// 安全：大小王、级牌（逻辑强度高，压不走）/ 主花色 A
    /// 不安全：主花色 K 及以下（容易被后手稍大的主牌截走）
    /// 判断一张主牌是否"安全"（出了不容易被后手对手用更大主牌顺手截分）
    /// 始终安全：大王 / 小王 / 级牌 / 主花色 A 及以上
    /// 动态安全：比该牌大的主花色分牌（K/10/5，排除级牌）已全部出完（双副牌各 2 张）
    private static func isSafeTrumpFiller(_ card: Card, ts: Suit?, tr: Rank, ctx: AIContext) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        if card.rank == .bigJoker || card.rank == .smallJoker { return true }
        if card.rank == tr { return true }
        if card.rank.rawValue >= Rank.ace.rawValue { return true }   // 主花色 A（不含 K）

        // 低于 A 的主花色牌：若比它大的每种分牌（K/10/5）在主花色中已出完 2 张，则视为安全
        // 例：两张 K♠ 已出 → J♠ 安全；两张 K♠ + 两张 10♠ 已出 → 6♠ 安全
        guard let suit = card.suit, suit == ts else { return false }
        let scoringRanks: [Rank] = [.king, .ten, .five]
        for rank in scoringRanks where rank != tr && rank.rawValue > card.rank.rawValue {
            let played = ctx.playedCards.filter { $0.rank == rank && $0.suit == suit }.count
            if played < 2 { return false }
        }
        return true
    }

    /// 返回本墩中当前 position 之后、还未出牌的玩家列表（顺时针顺序）
    /// 用于判断"后手是否绝主"以决定是否可以安全加分
    private static func unplayedSubsequentPositions(
        after position: PlayerPosition,
        in state: GameState
    ) -> [PlayerPosition] {
        let played = Set(state.currentTrick.plays.map { $0.position })
        var result: [PlayerPosition] = []
        var pos = PlayerPosition(rawValue: (position.rawValue + 1) % 4)!
        for _ in 0..<3 {
            if !played.contains(pos) {
                result.append(pos)
            }
            pos = PlayerPosition(rawValue: (pos.rawValue + 1) % 4)!
        }
        return result
    }

    // MARK: - Utility Helpers（与原版一致）

    /// 从同花色牌中按结构优先选出 neededPairs*2 张牌：
    /// 连对优先 → 孤立对子 → 散牌，避免出弱牌时拆散对子
    ///
    /// - partnerWinning: 队友赢时为 true，此时孤立对子和散牌优先选分多的（加分给队友）
    private static func structuredSuitFollowCards(
        suitCards: [Card],
        neededPairs: Int,
        trumpSuit: Suit?,
        trumpRank: Rank,
        partnerWinning: Bool = false
    ) -> [Card] {
        let count = neededPairs * 2
        var pool = suitCards
        var result = [Card]()
        var pairsLeft = neededPairs

        // 1. 贡献尽可能多的连对（取最弱的优先，从最大可用 size 往下贪心）
        //    队友赢时也保留最强连对，以备后续进攻
        var improved = true
        while pairsLeft >= 2 && improved {
            improved = false
            for size in stride(from: pairsLeft, through: 2, by: -1) {
                let candidates = tractors(in: pool, pairCount: size,
                                          trumpSuit: trumpSuit, trumpRank: trumpRank)
                    .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let t = candidates.first {
                    result += t
                    let ids = Set(t.map { $0.id })
                    pool = pool.filter { !ids.contains($0.id) }
                    pairsLeft -= size
                    improved = true
                    break
                }
            }
        }

        // 2. 贡献孤立对子
        //    队友赢：优先出分多的对子（同分再出弱对保大牌）
        //    否则：出最弱对子
        while pairsLeft > 0 {
            let available = pairs(in: pool, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .sorted { a, b in
                    if partnerWinning {
                        if a[0].pointValue != b[0].pointValue { return a[0].pointValue > b[0].pointValue }
                    }
                    return weakerPair(a, than: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            guard let p = available.first else { break }
            result += p
            let ids = Set(p.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
            pairsLeft -= 1
        }

        // 3. 用散牌填充剩余张数
        //    队友赢：用 partnerSupportCards（分多优先）；否则用最弱散牌
        let needed = count - result.count
        if needed > 0 {
            if partnerWinning {
                result += partnerSupportCards(from: pool, count: needed,
                                              trumpSuit: trumpSuit, trumpRank: trumpRank)
            } else {
                result += weakestCards(from: pool, count: needed,
                                       trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
        }

        return Array(result.prefix(count))
    }

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

    /// 优先选无分牌（pointValue==0），再选分牌，同组内按 discardOrder 排序
    /// 用于吊主时非末位出牌，避免把分牌送给后手截胡
    private static func weakestNonPointFirst(from cards: [Card], count: Int,
                                              trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        let nonPoint = cards.filter { $0.pointValue == 0 }
        let point    = cards.filter { $0.pointValue > 0 }
        let sorted   = nonPoint.sorted { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                     + point.sorted    { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
        return Array(sorted.prefix(count))
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

    /// 领出用散牌候选：返回手中真正"孤张"（无对子搭档）的指定类型牌，按 weakest 排序
    /// - isTrump: true=只看主牌, false=只看非主牌
    /// - pointOnly: true=只含分牌, false=只含无分牌, nil=不限
    private static func leadableSingletons(from hand: [Card], isTrump: Bool, pointOnly: Bool?,
                                            trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        // 计算配对 ID（同一 pairKey 有 ≥2 张）
        var pairGroupMap: [String: [Card]] = [:]
        for card in hand {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank),
                         default: []].append(card)
        }
        let pairedIDs = Set(pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })

        return hand.filter { card in
            let t = CardComparator.isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
            guard t == isTrump else { return false }
            guard !pairedIDs.contains(card.id) else { return false }   // 排除有对子搭档的牌
            if let wantPoint = pointOnly { return wantPoint ? card.pointValue > 0 : card.pointValue == 0 }
            return true
        }.sorted { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
    }

    /// 在主牌中找最弱对子；nonPointFirst=true 时优先选无分对子
    private static func findWeakestTrumpPair(in hand: [Card], nonPointFirst: Bool,
                                              trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        let trumpPairs = pairs(in: hand.filter {
            CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }, trumpSuit: trumpSuit, trumpRank: trumpRank)
        guard !trumpPairs.isEmpty else { return nil }

        let sorted = trumpPairs.sorted { a, b in
            if nonPointFirst && a[0].pointValue != b[0].pointValue {
                return a[0].pointValue < b[0].pointValue   // 无分对子优先
            }
            return weakerPair(a, than: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        return sorted.first
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
