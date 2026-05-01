import Foundation

struct AIPlayer {

    private struct TractorInfo {
        let pairCount: Int
        let highCard: Card
    }

    /// AI 决策：选择要出的牌
    /// - Parameter forcedCards: 甩牌失败后被强制必须出的牌（跟牌时使用）
    static func chooseCards(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = []
    ) -> [Card] {

        let hand = state.player(position).hand
        guard !hand.isEmpty else { return [] }

        // 先手出牌
        if state.currentTrick.plays.isEmpty {
            return leadCards(position: position, hand: hand, state: state, evaluator: evaluator)
        }

        // 跟牌
        let leadCards = state.currentTrick.leadCards!
        return followCards(
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            forcedCards: forcedCards
        )
    }

    // MARK: - 先手策略

    private static func leadCards(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        if let sideAce = strongestSideAce(in: hand, trumpSuit: ts, trumpRank: tr) {
            return [sideAce]
        }

        if let tractor = findTractor(in: hand, trumpSuit: ts, trumpRank: tr) {
            return tractor
        }
        if let pair = findPair(in: hand, trumpSuit: ts, trumpRank: tr) {
            return pair
        }

        if let smallTrump = weakestCards(
            from: hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) },
            count: 1,
            trumpSuit: ts,
            trumpRank: tr
        ).first {
            return [smallTrump]
        }

        return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }

    // MARK: - 跟牌策略

    private static func followCards(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = []
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count

        // 甩牌失败强制出牌：先包含强制牌，剩余用最弱牌补足
        if !forcedCards.isEmpty {
            var chosen = Array(forcedCards.prefix(count))
            if chosen.count < count {
                let usedIDs = Set(chosen.map { $0.id })
                let rest = hand.filter { !usedIDs.contains($0.id) }
                chosen += weakestCards(from: rest, count: count - chosen.count, trumpSuit: ts, trumpRank: tr)
            }
            return Array(chosen.prefix(count))
        }
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let winningCards = state.currentTrick.plays.first { $0.position == currentWinner }?.cards ?? leadCards
        let partnerWinning = currentWinner.team == position.team

        // 找出手中同花色的牌
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }

        if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
            return followTractor(
                leadTractor: leadTractor,
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr
            )
        }

        if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
            return followPair(
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr
            )
        }

        var chosen: [Card] = []

        if suitCards.count >= count {
            // 有足够同花色牌：尝试压牌
            let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
            let canBeat = partnerWinning ? [] : suitCards.filter {
                CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr)
            }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            if !canBeat.isEmpty {
                chosen = Array(canBeat.prefix(count))
            } else {
                chosen = partnerWinning
                    ? partnerSupportCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
                    : weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }
        } else {
            // 同花色不够，先把所有同花色都打出
            chosen = suitCards
            let remaining = count - chosen.count
            if remaining > 0 {
                let extra = hand.filter { evaluator.cardSuit($0) != leadSuit }
                chosen += partnerWinning
                    ? partnerSupportCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr)
                    : weakestCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr)
            }
        }

        // 确保数量正确
        if chosen.count < count {
            let ids = Set(chosen.map { $0.id })
            let rest = hand.filter { !ids.contains($0.id) }
            chosen += Array(rest.prefix(count - chosen.count))
        }
        return Array(chosen.prefix(count))
    }

    // MARK: - Helpers

    private static func followTractor(
        leadTractor: TractorInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank
    ) -> [Card] {
        let count = leadTractor.pairCount * 2

        if suitCards.count >= count {
            if partnerWinning {
                return partnerSupportCards(from: suitCards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }

            let availableTractors = tractors(in: suitCards, pairCount: leadTractor.pairCount, trumpSuit: trumpSuit, trumpRank: trumpRank)

            if !partnerWinning,
               let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beatingTractors = availableTractors
                    .filter { tractor in
                        guard let info = tractorInfo(of: tractor, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
                            return false
                        }
                        return CardComparator.beats(info.highCard, winningTractor.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

                if let tractor = beatingTractors.first {
                    return tractor
                }
            }

            if let weakestTractor = availableTractors.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first {
                return weakestTractor
            }

            return weakestCards(from: suitCards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        if suitCards.isEmpty,
           !partnerWinning,
           let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
            let beatingTractors = tractors(in: hand, pairCount: leadTractor.pairCount, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { tractor in
                    guard let info = tractorInfo(of: tractor, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
                        return false
                    }
                    return CardComparator.beats(info.highCard, winningTractor.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

            if let tractor = beatingTractors.first {
                return tractor
            }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest = hand.filter { !usedIDs.contains($0.id) }
        let extra = partnerWinning
            ? partnerSupportCards(from: rest, count: count - suitCards.count, trumpSuit: trumpSuit, trumpRank: trumpRank)
            : weakestCards(from: rest, count: count - suitCards.count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        return suitCards + extra
    }

    private static func followPair(
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank
    ) -> [Card] {
        if suitCards.count >= 2 {
            if partnerWinning {
                return partnerSupportCards(from: suitCards, count: 2, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }

            let availablePairs = pairs(in: suitCards, trumpSuit: trumpSuit, trumpRank: trumpRank)

            if !partnerWinning,
               let winningPair = pairRepresentative(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beatingPairs = availablePairs
                    .filter { pair in
                        guard let rep = pairRepresentative(of: pair, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
                            return false
                        }
                        return CardComparator.beats(rep, winningPair, trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

                if let pair = beatingPairs.first {
                    return pair
                }
            }

            if let weakestPair = availablePairs.sorted(by: {
                weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first {
                return weakestPair
            }

            return weakestCards(from: suitCards, count: 2, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        if suitCards.isEmpty,
           !partnerWinning,
           let winningPair = pairRepresentative(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
            let beatingPairs = pairs(in: hand, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { pair in
                    guard let rep = pairRepresentative(of: pair, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
                        return false
                    }
                    return CardComparator.beats(rep, winningPair, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

            if let pair = beatingPairs.first {
                return pair
            }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest = hand.filter { !usedIDs.contains($0.id) }
        let extra = partnerWinning
            ? partnerSupportCards(from: rest, count: 2 - suitCards.count, trumpSuit: trumpSuit, trumpRank: trumpRank)
            : weakestCards(from: rest, count: 2 - suitCards.count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        return suitCards + extra
    }

    private static func maxCard(in cards: [Card], ts: Suit?, tr: Rank) -> Card {
        // beats(b, a) 作为升序谓词，max 取最强牌
        cards.max { a, b in CardComparator.beats(b, a, trumpSuit: ts, trumpRank: tr) }!
    }

    private static func strongestSideAce(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Card? {
        hand.first {
            $0.rank == .ace && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
    }

    private static func tractors(in cards: [Card], pairCount: Int, trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        guard pairCount >= 2 else { return [] }

        let pairGroups = pairs(in: cards, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bySuit = Dictionary(grouping: pairGroups) { pair in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        var result: [[Card]] = []
        for groups in bySuit.values {
            let orderedGroups = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }

            guard orderedGroups.count >= pairCount else { continue }

            for start in 0...(orderedGroups.count - pairCount) {
                let window = Array(orderedGroups[start..<(start + pairCount)])
                let representatives = window.map { $0[0] }
                let isConsecutive = zip(representatives, representatives.dropFirst()).allSatisfy {
                    CardComparator.areAdjacentPairRanks($0, $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                if isConsecutive {
                    result.append(window.flatMap { $0 })
                }
            }
        }
        return result
    }

    private static func pairs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        return grouped.values.compactMap { group in
            group.count >= 2 ? Array(group.prefix(2)) : nil
        }
    }

    private static func tractorInfo(of cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> TractorInfo? {
        guard cards.count >= 4, cards.count.isMultiple(of: 2) else { return nil }

        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }

        let pairCount = cards.count / 2
        guard grouped.count == pairCount,
              grouped.values.allSatisfy({ $0.count == 2 }) else {
            return nil
        }

        let representatives = grouped.values.compactMap(\.first)
        guard let suit = representatives.first.map({
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }),
              representatives.allSatisfy({
                  CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank) == suit
              }) else {
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

    private static func pairRepresentative(of cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Card? {
        guard cards.count == 2,
              pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank) == pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank) else {
            return nil
        }
        return cards[0]
    }

    private static func weakerPair(_ a: [Card], than b: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aRep = pairRepresentative(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bRep = pairRepresentative(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
            return false
        }
        return weakerCard(aRep, than: bRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakerTractor(_ a: [Card], than b: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aInfo = tractorInfo(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bInfo = tractorInfo(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank) else {
            return false
        }
        return weakerCard(aInfo.highCard, than: bInfo.highCard, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakestCards(from cards: [Card], count: Int, trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        Array(cards.sorted {
            discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    private static func partnerSupportCards(from cards: [Card], count: Int, trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.sorted {
            partnerSupportOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    private static func weakerCard(_ a: Card, than b: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        CardComparator.beats(b, a, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func discardOrder(_ a: Card, before b: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        let aTrump = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bTrump = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aTrump != bTrump { return !aTrump }
        if aTrump {
            return CardComparator.trumpWeight(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
                < CardComparator.trumpWeight(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if a.pointValue != b.pointValue { return a.pointValue < b.pointValue }
        return a.rank.rawValue < b.rank.rawValue
    }

    private static func partnerSupportOrder(_ a: Card, before b: Card, trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        if a.pointValue != b.pointValue { return a.pointValue > b.pointValue }

        let aTrump = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bTrump = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aTrump != bTrump { return !aTrump }

        return discardOrder(a, before: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func findPair(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        var seen: [String: [Card]] = [:]
        for card in hand {
            let key = pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
            seen[key, default: []].append(card)
        }
        // 找到非主的对子（优先出大对）
        let pairs = seen.filter { $0.value.count >= 2 && !CardComparator.isTrump($0.value[0], trumpSuit: trumpSuit, trumpRank: trumpRank) }
        if let best = pairs.max(by: { a, b in a.value[0].rank < b.value[0].rank }) {
            return Array(best.value.prefix(2))
        }
        return nil
    }

    private static func findTractor(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        // 简化：找非主花色中的连对
        for suit in Suit.allCases {
            let suitCards = hand.filter { $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            let candidates = tractors(in: suitCards, pairCount: 2, trumpSuit: trumpSuit, trumpRank: trumpRank)
            if let strongest = candidates.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).last {
                return strongest
            }
        }
        return nil
    }

    private static func pairKey(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> String {
        CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }
}
