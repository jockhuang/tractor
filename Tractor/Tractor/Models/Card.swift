import Foundation

// MARK: - Suit
enum Suit: String, CaseIterable, Codable, Identifiable {
    case spades   = "♠"
    case hearts   = "♥"
    case diamonds = "♦"
    case clubs    = "♣"

    var id: String { rawValue }
    var color: String { (self == .hearts || self == .diamonds) ? "red" : "black" }
    var name: String { rawValue }
}

// MARK: - Rank
enum Rank: Int, CaseIterable, Codable, Comparable {
    case two   = 2, three, four, five, six, seven, eight, nine, ten
    case jack  = 11, queen, king, ace = 14
    case smallJoker = 20, bigJoker = 21

    static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    var display: String {
        switch self {
        case .jack:       return "J"
        case .queen:      return "Q"
        case .king:       return "K"
        case .ace:        return "A"
        case .smallJoker: return "小王"
        case .bigJoker:   return "大王"
        default:          return "\(rawValue)"
        }
    }

    var isJoker: Bool { self == .smallJoker || self == .bigJoker }

    /// 5、10、K 是得分牌
    var pointValue: Int {
        switch self {
        case .five:  return 5
        case .ten, .king: return 10
        default:     return 0
        }
    }
}

// MARK: - Card
struct Card: Identifiable, Equatable, Codable {
    let id: UUID
    let suit: Suit?   // nil for jokers
    let rank: Rank

    init(suit: Suit? = nil, rank: Rank) {
        self.id   = UUID()
        self.suit = suit
        self.rank = rank
    }

    var isJoker: Bool { rank.isJoker }
    var pointValue: Int { rank.pointValue }

    /// 简短展示，如 ♠A, ♥5, 大王
    var shortDisplay: String {
        if isJoker { return rank.display }
        return "\(suit!.rawValue)\(rank.display)"
    }
}

// MARK: - CardGroup (出牌组合类型)
enum PlayPattern {
    case single(Card)
    case pair(Card, Card)              // 同牌两张
    case tractor([(Card, Card)])       // 连对（至少两对）
    case mixed([Card])                 // 混合出牌（甩牌/抠底等）

    var cards: [Card] {
        switch self {
        case .single(let c):      return [c]
        case .pair(let a, let b): return [a, b]
        case .tractor(let pairs): return pairs.flatMap { [$0.0, $0.1] }
        case .mixed(let cs):      return cs
        }
    }

    var count: Int { cards.count }
}
