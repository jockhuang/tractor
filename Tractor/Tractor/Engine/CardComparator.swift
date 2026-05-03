import Foundation

/// 拖拉机牌力比较工具
struct CardComparator {

    // MARK: - Trump 判断

    /// 是否是主牌
    static func isTrump(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        if card.isJoker { return true }
        if card.rank == trumpRank { return true }       // 级牌无论花色都是主
        if let ts = trumpSuit, card.suit == ts { return true }
        return false
    }

    /// 主牌内部权重（越大越大）
    /// 大王=100, 小王=90, 主花色级牌=80, 非主花色级牌=70, 主花色其他=card.rank.rawValue
    static func trumpWeight(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> Int {
        if card.rank == .bigJoker   { return 100 }
        if card.rank == .smallJoker { return 90  }
        if card.rank == trumpRank {
            return card.suit == trumpSuit ? 80 : 70
        }
        // 普通主花色牌
        return card.rank.rawValue
    }

    /// 非主牌权重（只按点数）
    static func nonTrumpWeight(_ card: Card) -> Int { card.rank.rawValue }

    static func pairKey(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> String {
        if card.rank == .bigJoker   { return "bigJoker" }
        if card.rank == .smallJoker { return "smallJoker" }
        if card.rank == trumpRank {
            // 级牌对子以花色区分：同花色才能配对（♥5+♥5 合法，♥5+♣5 不合法）
            return "trumpRank_\(card.suit?.rawValue ?? "x")"
        }
        return "\(card.suit?.rawValue ?? "x")_\(card.rank.rawValue)"
    }

    static func pairOrderValue(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> Int {
        let regularRanks = Rank.allCases
            .filter { !$0.isJoker && $0 != trumpRank }
            .sorted()

        guard isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
            return regularRanks.firstIndex(of: card.rank) ?? 0
        }

        let offSuitTrumpRankValue = regularRanks.count
        let mainSuitTrumpRankValue = trumpSuit == nil
            ? offSuitTrumpRankValue
            : offSuitTrumpRankValue + 1

        if card.rank == trumpRank {
            return card.suit == trumpSuit ? mainSuitTrumpRankValue : offSuitTrumpRankValue
        }
        if card.rank == .smallJoker { return mainSuitTrumpRankValue + 1 }
        if card.rank == .bigJoker { return mainSuitTrumpRankValue + 2 }

        return regularRanks.firstIndex(of: card.rank) ?? 0
    }

    static func areAdjacentPairRanks(_ lower: Card, _ upper: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        logicalSuit(lower, trumpSuit: trumpSuit, trumpRank: trumpRank)
            == logicalSuit(upper, trumpSuit: trumpSuit, trumpRank: trumpRank)
            && pairOrderValue(upper, trumpSuit: trumpSuit, trumpRank: trumpRank)
            == pairOrderValue(lower, trumpSuit: trumpSuit, trumpRank: trumpRank) + 1
    }

    // MARK: - 手牌排序（主牌最左，其余按花色分组）

    static func handSortOrder(_ a: Card, _ b: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        let aT = isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)

        if aT && !bT { return true }
        if !aT && bT { return false }

        if aT && bT {
            let aW = trumpWeight(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
            let bW = trumpWeight(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
            if aW != bW { return aW > bW }
            // 同权重（如多张非主花色级牌）：按实际花色分组，使对子在界面上相邻
            let aSuit = a.suit?.rawValue ?? ""
            let bSuit = b.suit?.rawValue ?? ""
            return aSuit < bSuit
        }

        // 都不是主牌：先按花色分，再按大小
        let suitOrder: [Suit] = [.spades, .hearts, .clubs, .diamonds]
        let aSuit = a.suit ?? .spades
        let bSuit = b.suit ?? .spades
        if aSuit != bSuit {
            return (suitOrder.firstIndex(of: aSuit) ?? 0) < (suitOrder.firstIndex(of: bSuit) ?? 0)
        }
        return a.rank.rawValue > b.rank.rawValue
    }

    // MARK: - 出牌花色（用于跟牌判断）

    /// 出牌的「逻辑花色」：主牌统一算主，其他按实际花色
    static func logicalSuit(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> Suit? {
        if isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank) { return nil /* nil = trump */ }
        return card.suit
    }

    // MARK: - 比较谁赢（同花色下）

    /// 在同花色跟牌时，哪张牌更大（返回 true 表示 a > b）
    static func beats(_ a: Card, _ b: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        let aT = isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aT && bT {
            return trumpWeight(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
                 > trumpWeight(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if aT && !bT { return true }
        if !aT && bT { return false }
        // 同花色非主
        if a.suit == b.suit { return a.rank > b.rank }
        return false // 不同非主花色，先手赢
    }
}
