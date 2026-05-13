import Foundation

/// 判断一墩的赢家，以及跟牌合法性
struct TrickEvaluator {

    let trumpSuit: Suit?
    let trumpRank: Rank

    private struct TractorInfo {
        let pairCount: Int
        let highCard: Card
    }

    // MARK: - 跟牌合法性

    /// 玩家选择的 selectedCards 是否合法（给定先手的 leadCards）
    ///
    /// 严格优先级：
    ///   先手连对 → 同花色中：连对 > 对子 > 散牌，超出部分随意
    ///   先手对子 → 同花色中：有对子必须出对子，不足才出散牌
    ///   先手单牌 → 有同花色必须出同花色
    func isValidPlay(selected: [Card], hand: [Card], leadCards: [Card]) -> Bool {
        let leadCount = leadCards.count
        guard selected.count == leadCount else { return false }

        // 1. 先手的逻辑花色
        let leadSuit = dominantSuit(of: leadCards)

        // 2. 手中同花色的牌 / 已选中的同花色牌
        let suitCardsInHand = hand.filter { cardSuit($0) == leadSuit }
        let selectedSuit    = selected.filter { cardSuit($0) == leadSuit }

        // 3. 必须出尽可能多的同花色牌
        let requiredSuitCount = min(suitCardsInHand.count, leadCount)
        guard selectedSuit.count == requiredSuitCount else { return false }

        // 4. 同花色不足或恰好满足：无需检查内部结构
        if suitCardsInHand.count <= leadCount { return true }

        // 5. 同花色足够：检查结构优先级
        if let leadTractor = tractorInfo(of: leadCards) {
            // 先手连对：同花色里连对 > 对子 > 散牌
            return validateTractorFollow(
                selectedSuit: selectedSuit,
                suitCards: suitCardsInHand,
                N: leadTractor.pairCount
            )
        }

        if pairRepresentative(of: leadCards) != nil {
            // 先手对子：有同花色对子就必须出对子
            if !pairs(in: suitCardsInHand).isEmpty {
                return !pairs(in: selectedSuit).isEmpty
            }
        }

        // 先手甩牌：同花色足够时也必须满足结构优先级（连对 > 对子 > 散牌）
        if let slam = slamInfo(of: leadCards) {
            return validateSlamFollow(selectedSuit: selectedSuit,
                                      suitCards: suitCardsInHand, slam: slam)
        }

        return true
    }

    /// 验证跟甩牌时同花色牌的结构合法性
    /// 规则：甩牌含对子/连对时，同花色必须先贡献对子（含连对），才能出散牌
    private func validateSlamFollow(selectedSuit: [Card], suitCards: [Card], slam: SlamInfo) -> Bool {
        // 甩牌的总对子槽数（连对各对 + 孤立对子数）
        let slamPairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 } + slam.pairs.count
        guard slamPairSlots > 0 else { return true }   // 纯散牌甩牌，无对子要求

        let handTotalPairs = pairs(in: suitCards).count
        let requiredPairs  = min(handTotalPairs, slamPairSlots)
        guard requiredPairs > 0 else { return true }   // 手中同花色无对子，无需检查

        // 已选牌中的对子数 >= 需贡献的最少对子数
        guard pairs(in: selectedSuit).count >= requiredPairs else { return false }

        // 连对槽优先：甩牌含连对时，手中有连对必须先出连对
        let slamTractorPairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 }
        if slamTractorPairSlots > 0 {
            let handTractorPairs     = tractorPairCount(in: suitCards)
            let requiredTractorPairs = min(handTractorPairs, slamTractorPairSlots)
            if requiredTractorPairs > 0 {
                guard tractorPairCount(in: selectedSuit) >= requiredTractorPairs else { return false }
            }
        }

        return true
    }

    /// 验证跟连对（N 对）时同花色牌的结构合法性
    /// 规则：先最大化连对对数，再最大化孤立对子数，剩余才用散牌
    private func validateTractorFollow(selectedSuit: [Card], suitCards: [Card], N: Int) -> Bool {
        // 手中同花色中属于连对序列的对子总数
        let handTractorPairs   = tractorPairCount(in: suitCards)
        let requiredTractorPairs = min(handTractorPairs, N)

        // 已选牌中连对对数必须 >= 要求
        let selectedTractorPairs = tractorPairCount(in: selectedSuit)
        guard selectedTractorPairs >= requiredTractorPairs else { return false }

        // 剩余槽位需要用孤立对子填充
        let remainingN = N - requiredTractorPairs
        if remainingN > 0 {
            let handIsolatedPairs     = isolatedPairCount(in: suitCards)
            let requiredExtraPairs    = min(handIsolatedPairs, remainingN)
            let selectedIsolatedPairs = isolatedPairCount(in: selectedSuit)
            guard selectedIsolatedPairs >= requiredExtraPairs else { return false }
        }

        return true
    }

    // MARK: - 赢家判断

    /// 返回赢得本墩的玩家位置
    func winner(of trick: Trick) -> PlayerPosition {
        guard !trick.plays.isEmpty else { return trick.leadPosition }

        let leadCards = trick.plays[0].cards
        let leadSuit  = dominantSuit(of: leadCards)
        var winnerIdx = 0
        var winningCards = leadCards

        for i in 1..<trick.plays.count {
            let cards = trick.plays[i].cards
            let suit  = dominantSuit(of: cards)

            if suit == leadSuit || suit == nil {
                // 同花色跟牌，或用主牌压副牌
                if beatsPlay(cards, winningCards: winningCards, leadCards: leadCards) {
                    winnerIdx = i
                    winningCards = cards
                }
            }
            // 非主花色无法压先手或当前赢家
        }
        return trick.plays[winnerIdx].position
    }

    // MARK: - 分数计算

    func points(in cards: [Card]) -> Int {
        cards.reduce(0) { $0 + $1.pointValue }
    }

    // MARK: - Helpers

    /// 一组牌的「代表牌」（用于比较，取最大）
    private func representativeCard(of cards: [Card]) -> Card {
        cards.max { a, b in
            CardComparator.beats(b, a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }!
    }

    /// 判断 cards 是否压过 winningCards（给定先手 leadCards）
    ///
    /// 压牌规则（按优先级）：
    ///   1. 先检查组合类型资格：垫牌（不满足组合要求）无法压任何牌
    ///   2. 将牌 > 副牌（相同组合类型下）
    ///   3. 同为将牌或同为副牌：比点数大小，同大小先出者胜
    private func beatsPlay(_ cards: [Card], winningCards: [Card], leadCards: [Card]) -> Bool {
        let candidateSuit = dominantSuit(of: cards)
        let winningSuit   = dominantSuit(of: winningCards)

        // ── 先手出连对 ──────────────────────────────────────────────
        if let leadTractor = tractorInfo(of: leadCards) {
            // 候选必须是相同对数的连对，否则视为垫牌
            guard let ct = tractorInfo(of: cards),
                  ct.pairCount == leadTractor.pairCount else { return false }
            // 当前赢家若不是合格连对，候选自动获胜（安全保障，正常不会触发）
            guard let wt = tractorInfo(of: winningCards),
                  wt.pairCount == leadTractor.pairCount else { return true }
            // 将牌连对 > 副牌连对
            if winningSuit != nil && candidateSuit == nil { return true }
            if winningSuit == nil && candidateSuit != nil { return false }
            // 同类型：比最高牌
            return CardComparator.beats(ct.highCard, wt.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        // ── 先手出对子 ──────────────────────────────────────────────
        if pairRepresentative(of: leadCards) != nil {
            // 候选必须是对子，否则视为垫牌（包括将牌单张）
            guard let cp = pairRepresentative(of: cards) else { return false }
            // 当前赢家若不是对子，候选自动获胜
            guard let wp = pairRepresentative(of: winningCards) else { return true }
            // 将牌对子 > 副牌对子
            if winningSuit != nil && candidateSuit == nil { return true }
            if winningSuit == nil && candidateSuit != nil { return false }
            // 同类型：比代表牌
            return CardComparator.beats(cp, wp, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        // ── 先手出单牌（含甩牌）──────────────────────────────────────

        // 甩牌先手：将牌压甩牌的资格规则
        //   - 甩牌含对子/连对：主牌结构必须与甩牌完全一致才能将吃
        //   - 甩牌纯散牌：任意主牌均可将吃
        if let slam = slamInfo(of: leadCards) {
            // 将吃的第一必要条件：出的牌必须全部是主牌（只看第一张不够，逐张验证）
            guard cards.allSatisfy({ cardSuit($0) == nil }) else { return false }
            // 甩牌含对子或连对时，主牌结构必须完全匹配才有资格将吃
            let slamHasPairsOrTractors = !slam.pairs.isEmpty || !slam.tractors.isEmpty
            if slamHasPairsOrTractors {
                guard trumpMatchesSlamStructure(cards, slam: slam) else { return false }
            }
            // 候选合格；若当前赢家是副牌（甩牌者），直接胜出
            if winningSuit != nil { return true }
            // 当前赢家也是将牌：同样验证其资格，再按结构层级比大小
            if slamHasPairsOrTractors {
                guard trumpMatchesSlamStructure(winningCards, slam: slam) else { return true }
            }
            return slamTrumpBeats(cards, over: winningCards, leadSlam: slam)
        }

        // 非甩牌单牌：将牌 > 副牌
        if winningSuit != nil && candidateSuit == nil { return true }
        if winningSuit == nil && candidateSuit != nil { return false }
        // 不同副牌花色无法互压
        if candidateSuit != winningSuit { return false }

        // 同花色（副牌）：比代表牌，同大小先出者胜
        let rep        = representativeCard(of: cards)
        let winningRep = representativeCard(of: winningCards)
        return CardComparator.beats(rep, winningRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    /// 甩牌先手时，两个主牌出牌（suit 均为 nil）之间的结构比较
    ///
    /// 比较层级由**领出甩牌的结构**决定，而非固定为"连对 > 对子 > 单张"：
    /// - 领出含连对 → 先比最高连对，再比对子，再比单张
    /// - 领出含对子（无连对）→ 先比最高对子，再比单张
    /// - 领出纯散牌 → 仅比最高单张
    ///
    /// 例：北甩 Q♥10♥（纯散牌），东出 3♣3♣，南出大王+主K
    /// → 领出无对子，只比最高单张：大王(100) > 3♣(70) → 南赢
    private func slamTrumpBeats(_ candidate: [Card], over winner: [Card], leadSlam: SlamInfo) -> Bool {
        let cInfo = decomposeSlam(candidate, suit: nil)
        let wInfo = decomposeSlam(winner,    suit: nil)

        // ① 比最高连对（仅当领出含连对时才进行此层比较）
        if !leadSlam.tractors.isEmpty {
            let cTopTractor = cInfo.tractors
                .compactMap { tractorInfo(of: $0) }
                .max { a, b in
                    a.pairCount != b.pairCount
                        ? a.pairCount < b.pairCount
                        : CardComparator.beats(b.highCard, a.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            let wTopTractor = wInfo.tractors
                .compactMap { tractorInfo(of: $0) }
                .max { a, b in
                    a.pairCount != b.pairCount
                        ? a.pairCount < b.pairCount
                        : CardComparator.beats(b.highCard, a.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }

            if let cT = cTopTractor, let wT = wTopTractor {
                if cT.pairCount != wT.pairCount { return cT.pairCount > wT.pairCount }
                return CardComparator.beats(cT.highCard, wT.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
            } else if cTopTractor != nil { return true  }
              else if wTopTractor != nil { return false }
        }

        // ② 比最高对子（仅当领出含对子时才进行此层比较）
        if !leadSlam.pairs.isEmpty {
            let cTopPair = cInfo.pairs
                .compactMap { pairRepresentative(of: $0) }
                .max { CardComparator.beats($1, $0, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            let wTopPair = wInfo.pairs
                .compactMap { pairRepresentative(of: $0) }
                .max { CardComparator.beats($1, $0, trumpSuit: trumpSuit, trumpRank: trumpRank) }

            if let cP = cTopPair, let wP = wTopPair {
                return CardComparator.beats(cP, wP, trumpSuit: trumpSuit, trumpRank: trumpRank)
            } else if cTopPair != nil { return true  }
              else if wTopPair != nil { return false }
        }

        // ③ 比最高单张（领出含任何结构时均可作为最终决胜依据）
        let rep        = representativeCard(of: candidate)
        let winningRep = representativeCard(of: winner)
        return CardComparator.beats(rep, winningRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    /// 判断将牌出牌是否有资格将吃甩牌
    ///
    /// 规则（两个条件均须满足）：
    ///   1. 甩牌中的每个连对，将牌必须有对数 ≥ 该连对的连对（不允许用孤立对子代替连对）
    ///   2. 将牌的总「对子信用」≥ 甩牌的总「对子信用」
    ///      对子信用 = 各连对的对数之和 + 孤立对子数
    ///      （连对可以覆盖对子槽，故对数更多的连对可将吃只含孤立对子的甩牌）
    private func trumpMatchesSlamStructure(_ trumpCards: [Card], slam: SlamInfo) -> Bool {
        let trumpInfo = decomposeSlam(trumpCards, suit: nil)

        // 条件1：甩牌每个连对必须由将牌中对数 ≥ 它的连对覆盖（贪心：最大甩牌连对优先匹配）
        let slamTractorSizes = slam.tractors
            .compactMap { tractorInfo(of: $0)?.pairCount }
            .sorted(by: >)
        var availableTrumpTractors = trumpInfo.tractors
            .compactMap { tractorInfo(of: $0)?.pairCount }
            .sorted(by: >)

        for slamSize in slamTractorSizes {
            // 找最小的满足 trumpSize >= slamSize 的将牌连对（避免过度消耗大连对）
            guard let idx = availableTrumpTractors.indices.last(where: {
                availableTrumpTractors[$0] >= slamSize
            }) else {
                return false   // 无法为此甩牌连对找到匹配的将牌连对
            }
            availableTrumpTractors.remove(at: idx)
        }

        // 条件2：将牌总对子信用 ≥ 甩牌总对子信用
        let trumpPairCredits = trumpInfo.tractors.reduce(0) { $0 + $1.count / 2 } + trumpInfo.pairs.count
        let slamPairCredits  = slam.tractors.reduce(0)  { $0 + $1.count / 2 } + slam.pairs.count

        return trumpPairCredits >= slamPairCredits
    }

    private func tractorInfo(of cards: [Card]) -> TractorInfo? {
        guard cards.count >= 4, cards.count.isMultiple(of: 2) else { return nil }

        var groups: [String: [Card]] = [:]
        for card in cards {
            groups[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }

        let pairCount = cards.count / 2
        guard groups.count == pairCount,
              groups.values.allSatisfy({ $0.count == 2 }) else {
            return nil
        }

        let representatives = groups.values.compactMap(\.first)
        guard let suit = representatives.first.map(cardSuit),
              representatives.allSatisfy({ cardSuit($0) == suit }) else {
            return nil
        }

        let ordered = representatives.sorted {
            CardComparator.pairOrderValue($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                < CardComparator.pairOrderValue($1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            guard CardComparator.areAdjacentPairRanks(lower, upper, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
                return nil
            }
        }

        guard let highCard = ordered.last else { return nil }
        return TractorInfo(pairCount: pairCount, highCard: highCard)
    }

    private func pairRepresentative(of cards: [Card]) -> Card? {
        guard cards.count == 2,
              CardComparator.pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
              == CardComparator.pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank) else {
            return nil
        }
        return cards[0]
    }

    // MARK: - 对子 / 连对统计辅助

    /// 找出 cards 中的所有对子（每个 pairKey 取前两张）
    private func pairs(in cards: [Card]) -> [[Card]] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        return grouped.values.compactMap { group in
            group.count >= 2 ? Array(group.prefix(2)) : nil
        }
    }

    /// 属于连续对子序列（长度 ≥ 2）的对子总对数
    private func tractorPairCount(in cards: [Card]) -> Int {
        let allPairs = pairs(in: cards)
        guard allPairs.count >= 2 else { return 0 }

        var count = 0
        let bySuit = Dictionary(grouping: allPairs) { pair -> Suit? in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        for groups in bySuit.values {
            let sorted = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            var i = 0
            while i < sorted.count {
                var j = i + 1
                while j < sorted.count && CardComparator.areAdjacentPairRanks(
                    sorted[j-1][0], sorted[j][0], trumpSuit: trumpSuit, trumpRank: trumpRank
                ) { j += 1 }
                if j - i >= 2 { count += j - i }
                i = j
            }
        }
        return count
    }

    /// 孤立对子（不属于任何连续序列）的对数
    private func isolatedPairCount(in cards: [Card]) -> Int {
        let allPairs = pairs(in: cards)
        guard !allPairs.isEmpty else { return 0 }

        var count = 0
        let bySuit = Dictionary(grouping: allPairs) { pair -> Suit? in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        for groups in bySuit.values {
            let sorted = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            var i = 0
            while i < sorted.count {
                var j = i + 1
                while j < sorted.count && CardComparator.areAdjacentPairRanks(
                    sorted[j-1][0], sorted[j][0], trumpSuit: trumpSuit, trumpRank: trumpRank
                ) { j += 1 }
                if j - i == 1 { count += 1 }
                i = j
            }
        }
        return count
    }

    /// 一组牌的逻辑花色（nil = trump）
    func dominantSuit(of cards: [Card]) -> Suit? {
        // 取第一张牌的逻辑花色（先手决定出牌花色）
        cardSuit(cards[0])
    }

    func cardSuit(_ card: Card) -> Suit? {
        CardComparator.isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank) ? nil : card.suit
    }

    // MARK: - 甩牌（Slam Lead）

    /// 甩牌拆解结果：将混合出牌拆成连对 / 对子 / 单张三类组件
    struct SlamInfo {
        let suit: Suit?          // 逻辑花色（nil = 主牌）
        let tractors: [[Card]]   // 连对组件（每组已排序）
        let pairs:    [[Card]]   // 对子组件
        let singles:  [Card]     // 单张组件

        var allCards: [Card] { tractors.flatMap { $0 } + pairs.flatMap { $0 } + singles }
        var count: Int { allCards.count }
    }

    /// 某玩家对甩牌的「被逼出」信息
    struct SlamForcing {
        let beatingTractors: [[Card]]  // 能压各连对组件的最小连对（每组）
        let beatingPairs:    [[Card]]  // 能压各对子组件的最小对子
        let beatingSingles:  [Card]    // 能压各单张组件的最小单张

        var hasTractor: Bool { !beatingTractors.isEmpty }
        var hasPair:    Bool { !beatingPairs.isEmpty }
        var hasSingle:  Bool { !beatingSingles.isEmpty }
        var isEmpty:    Bool { !hasTractor && !hasPair && !hasSingle }
        var categoryCount: Int { (hasTractor ? 1 : 0) + (hasPair ? 1 : 0) + (hasSingle ? 1 : 0) }

        /// 最终强制出的牌：单类直接出，多类自动取张数最多的一类
        /// TODO：多类时正式规则应由下家指定，当前自动处理
        var resolvedForcedCards: [Card] {
            guard !isEmpty else { return [] }
            let options: [[Card]] = [
                beatingTractors.flatMap { $0 },
                beatingPairs.flatMap { $0 },
                beatingSingles
            ].filter { !$0.isEmpty }
            return options.count == 1 ? options[0] : (options.max(by: { $0.count < $1.count }) ?? [])
        }
    }

    /// 判断领出的牌是否为甩牌；若是则拆解并返回 SlamInfo
    func slamInfo(of cards: [Card]) -> SlamInfo? {
        guard cards.count >= 2 else { return nil }
        let suit = cardSuit(cards[0])
        guard cards.allSatisfy({ cardSuit($0) == suit }) else { return nil }
        // 纯连对 / 纯对子 不算甩牌
        if tractorInfo(of: cards) != nil { return nil }
        if cards.count == 2, pairRepresentative(of: cards) != nil { return nil }
        return decomposeSlam(cards, suit: suit)
    }

    private func decomposeSlam(_ cards: [Card], suit: Suit?) -> SlamInfo {
        var pairGroups: [String: [Card]] = [:]
        for card in cards {
            pairGroups[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let validPairs = pairGroups.values.compactMap { g -> [Card]? in
            g.count >= 2 ? Array(g.prefix(2)) : nil
        }

        let bySuit = Dictionary(grouping: validPairs) { pair -> Suit? in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        var tractors: [[Card]] = []
        var isolatedPairs: [[Card]] = []
        var usedIDs = Set<UUID>()

        for groups in bySuit.values {
            let sorted = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            var i = 0
            while i < sorted.count {
                var j = i + 1
                while j < sorted.count && CardComparator.areAdjacentPairRanks(
                    sorted[j-1][0], sorted[j][0], trumpSuit: trumpSuit, trumpRank: trumpRank
                ) { j += 1 }

                let seq = Array(sorted[i..<j])
                if j - i >= 2 {
                    let tc = seq.flatMap { $0 }
                    tractors.append(tc)
                    tc.forEach { usedIDs.insert($0.id) }
                } else {
                    isolatedPairs.append(seq[0])
                    seq[0].forEach { usedIDs.insert($0.id) }
                }
                i = j
            }
        }

        let singles = cards.filter { !usedIDs.contains($0.id) }
        return SlamInfo(suit: suit, tractors: tractors, pairs: isolatedPairs, singles: singles)
    }

    /// 计算某个对手对这手甩牌的被逼出情况（每个组件找能压赢的最小牌）
    func slamForcing(slam: SlamInfo, opponentHand: [Card]) -> SlamForcing {
        let suitCards = opponentHand.filter { cardSuit($0) == slam.suit }

        // 连对组件
        var beatingTractors: [[Card]] = []
        for tractor in slam.tractors {
            guard let ti = tractorInfo(of: tractor) else { continue }
            let candidates = slamFindTractors(in: suitCards, pairCount: ti.pairCount)
                .filter { ot in
                    guard let oti = tractorInfo(of: ot) else { return false }
                    return CardComparator.beats(oti.highCard, ti.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { a, b in          // 取最小的（赢就行）
                    guard let ai = tractorInfo(of: a), let bi = tractorInfo(of: b) else { return false }
                    return CardComparator.beats(bi.highCard, ai.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            if let smallest = candidates.last { beatingTractors.append(smallest) }
        }

        // 对子组件
        var beatingPairs: [[Card]] = []
        for pair in slam.pairs {
            guard let pRep = pairRepresentative(of: pair) else { continue }
            let candidates = pairs(in: suitCards)
                .filter { op in
                    guard let opRep = pairRepresentative(of: op) else { return false }
                    return CardComparator.beats(opRep, pRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { a, b in
                    guard let aRep = pairRepresentative(of: a), let bRep = pairRepresentative(of: b) else { return false }
                    return CardComparator.beats(bRep, aRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            if let smallest = candidates.last { beatingPairs.append(smallest) }
        }

        // 单张组件
        var beatingSingles: [Card] = []
        for single in slam.singles {
            let candidates = suitCards
                .filter { CardComparator.beats($0, single, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                .sorted { a, b in CardComparator.beats(b, a, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            if let smallest = candidates.last { beatingSingles.append(smallest) }
        }

        return SlamForcing(beatingTractors: beatingTractors, beatingPairs: beatingPairs, beatingSingles: beatingSingles)
    }

    /// 计算甩牌的罚分：任意一家有大牌则对应组件计罚（每张 ×10 分）
    func slamPenaltyPoints(slam: SlamInfo, opponentHands: [PlayerPosition: [Card]]) -> Int {
        var penaltyCards = 0

        for tractor in slam.tractors {
            guard let ti = tractorInfo(of: tractor) else { continue }
            let anyBeats = opponentHands.values.contains { hand in
                slamFindTractors(in: hand.filter { cardSuit($0) == slam.suit }, pairCount: ti.pairCount).contains { ot in
                    guard let oti = tractorInfo(of: ot) else { return false }
                    return CardComparator.beats(oti.highCard, ti.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            }
            if anyBeats { penaltyCards += tractor.count }
        }

        for pair in slam.pairs {
            guard let pRep = pairRepresentative(of: pair) else { continue }
            let anyBeats = opponentHands.values.contains { hand in
                pairs(in: hand.filter { cardSuit($0) == slam.suit }).contains { op in
                    guard let opRep = pairRepresentative(of: op) else { return false }
                    return CardComparator.beats(opRep, pRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            }
            if anyBeats { penaltyCards += 2 }
        }

        for single in slam.singles {
            let anyBeats = opponentHands.values.contains { hand in
                hand.filter { cardSuit($0) == slam.suit }
                    .contains { CardComparator.beats($0, single, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            }
            if anyBeats { penaltyCards += 1 }
        }

        return penaltyCards * 10
    }

    /// 在给定的牌组中寻找指定对数的连对
    private func slamFindTractors(in cards: [Card], pairCount: Int) -> [[Card]] {
        guard pairCount >= 2 else { return [] }
        var pairGroups: [String: [Card]] = [:]
        for card in cards {
            pairGroups[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let validPairs = pairGroups.values.compactMap { g -> [Card]? in
            g.count >= 2 ? Array(g.prefix(2)) : nil
        }
        let bySuit = Dictionary(grouping: validPairs) { pair -> Suit? in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        var result: [[Card]] = []
        for groups in bySuit.values {
            let sorted = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            guard sorted.count >= pairCount else { continue }
            for start in 0...(sorted.count - pairCount) {
                let window = Array(sorted[start..<(start + pairCount)])
                let reps = window.map { $0[0] }
                if zip(reps, reps.dropFirst()).allSatisfy({
                    CardComparator.areAdjacentPairRanks($0, $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }) {
                    result.append(window.flatMap { $0 })
                }
            }
        }
        return result
    }

    // MARK: - 领出语音播报文字

    /// 根据领出牌型返回应播报的文字
    /// - 连对 → "拖拉机"
    /// - 对子 → "对X"（X 为点数中文名，如"对A"、"对十"）
    /// - 单张主牌 → "吊主"
    /// - 单张非主 → "花色+点数"（如"黑桃A"、"红桃五"）
    /// - 甩牌/其他 → ""（不播报）
    func leadAnnouncement(cards: [Card]) -> String {
        guard !cards.isEmpty else { return "" }

        // 连对
        if tractorInfo(of: cards) != nil {
            return "拖拉机"
        }

        // 对子
        if cards.count == 2 {
            let key0 = CardComparator.pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            let key1 = CardComparator.pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank)
            if key0 == key1 {
                return "对\(rankName(cards[0].rank))"
            }
        }

        // 单张
        if cards.count == 1 {
            let card = cards[0]
            if CardComparator.isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank) {
                return "吊主"
            }
            let suit = card.suit.map { suitName($0) } ?? ""
            return "\(suit)\(rankName(card.rank))"
        }

        // 甩牌播报"甩牌"
        if slamInfo(of: cards) != nil { return "甩牌" }

        // 其他牌型不播报
        return ""
    }

    private func rankName(_ rank: Rank) -> String {
        switch rank {
        case .two:       return "二"
        case .three:     return "三"
        case .four:      return "四"
        case .five:      return "五"
        case .six:       return "六"
        case .seven:     return "七"
        case .eight:     return "八"
        case .nine:      return "九"
        case .ten:       return "十"
        case .jack:      return "J"
        case .queen:     return "Q"
        case .king:      return "K"
        case .ace:       return "A"
        case .smallJoker: return "小王"
        case .bigJoker:  return "大王"
        }
    }

    private func suitName(_ suit: Suit) -> String {
        switch suit {
        case .spades:   return "黑桃"
        case .hearts:   return "红桃"
        case .diamonds: return "方块"
        case .clubs:    return "梅花"
        }
    }
}
