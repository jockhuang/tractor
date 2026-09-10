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
        let deck = doubleDeck().shuffled()
        var hands: [[Card]] = [[], [], [], []]
        // 顺序发牌
        for i in 0..<100 {
            hands[i % 4].append(deck[i])
        }
        let kitty = Array(deck[100...])
        return (hands, kitty)
    }

    /// 为单机轻松模式准备牌序。真人（南家）必定拿到至少 5 张常主，
    /// 并拿到同一花色的两组相邻对子（一个拖拉机）。
    static func easyModeDeck(trumpRank: Rank) -> [Card] {
        arrangeForEasyMode(doubleDeck().shuffled(), trumpRank: trumpRank)
    }

    static func arrangeForEasyMode(_ deck: [Card], trumpRank: Rank) -> [Card] {
        let permanentTrumps = deck
            .filter { $0.isJoker || $0.rank == trumpRank }
            .prefix(5)

        let ordinaryRanks = Rank.allCases
            .filter { !$0.isJoker && $0 != trumpRank }
            .sorted()
        let adjacentRanks = zip(ordinaryRanks, ordinaryRanks.dropFirst())
            .map { ($0, $1) }
            .shuffled()

        var tractorCards: [Card] = []
        for suit in Suit.allCases.shuffled() {
            for (lower, upper) in adjacentRanks {
                let lowerPair = deck.filter { $0.suit == suit && $0.rank == lower }.prefix(2)
                let upperPair = deck.filter { $0.suit == suit && $0.rank == upper }.prefix(2)
                guard lowerPair.count == 2, upperPair.count == 2 else { continue }
                tractorCards = Array(lowerPair + upperPair)
                break
            }
            if !tractorCards.isEmpty { break }
        }

        let guaranteedCards = Array(permanentTrumps) + tractorCards
        let guaranteedIDs = Set(guaranteedCards.map(\.id))
        var remainingCards = deck.filter { !guaranteedIDs.contains($0.id) }.makeIterator()
        var guaranteedIterator = guaranteedCards.makeIterator()
        var arranged: [Card] = []
        arranged.reserveCapacity(deck.count)

        for index in deck.indices {
            // 发牌顺序为南、西、北、东；前 100 张中每四张的第一张发给南家。
            if index < 100, index % 4 == 0, let card = guaranteedIterator.next() {
                arranged.append(card)
            } else if let card = remainingCards.next() {
                arranged.append(card)
            }
        }
        return arranged
    }
}
