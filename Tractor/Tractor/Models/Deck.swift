import Foundation

struct Deck {
    /// 生成两副标准牌（108张）
    static func doubleDeck() -> [Card] {
        var cards: [Card] = []
        for _ in 0..<2 {
            for suit in Suit.allCases {
                for rank in Rank.allCases where !rank.isJoker {
                    cards.append(Card(suit: suit, rank: rank))
                }
            }
            cards.append(Card(suit: nil, rank: .smallJoker))
            cards.append(Card(suit: nil, rank: .bigJoker))
        }
        return cards
    }

    /// 洗牌并发牌：4人各25张，剩余8张为底牌
    static func shuffleAndDeal() -> (hands: [[Card]], kitty: [Card]) {
        var deck = doubleDeck().shuffled()
        var hands: [[Card]] = [[], [], [], []]
        // 顺序发牌
        for i in 0..<100 {
            hands[i % 4].append(deck[i])
        }
        let kitty = Array(deck[100...])
        return (hands, kitty)
    }
}
