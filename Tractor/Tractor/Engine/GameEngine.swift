import Foundation
import Combine
import SwiftUI

@MainActor
class GameEngine: ObservableObject {

    @Published var state: GameState = GameState() {
        didSet { subscribeToState() }
    }

    private var aiDelay: TimeInterval = 1.2
    private var trickEndDelay: TimeInterval = 1.5
    private var stateCancellable: AnyCancellable?
    private var phaseCancellable: AnyCancellable?
    private var dealingTask: Task<Void, Never>?
    private var aiTurnTask: Task<Void, Never>?
    private var trickResolutionTask: Task<Void, Never>?
    private var aiTurnGeneration = 0
    private var trickResolutionGeneration = 0
    let multiplayer = LANMultiplayerManager()
    @Published var localPosition: PlayerPosition = .south
    private var humanControlledPositions: Set<PlayerPosition> = [.south]

    var localPlayer: Player { state.player(localPosition) }

    init() {
        subscribeToState()
        multiplayer.attach(engine: self)
    }

    private func subscribeToState() {
        stateCancellable = state.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

    }

    // MARK: - 开始游戏 / 新局

    func startNewGame() {
        dealingTask?.cancel()
        cancelScheduledTurnWork()
        multiplayer.leave()
        localPosition = .south
        humanControlledPositions = [.south]
        state = GameState()
        state.dealerTeamIdx = 0
        state.teamLevels    = [0: .two, 1: .two]
        startNewRound()
    }

    func returnToMenuFromMultiplayer() {
        dealingTask?.cancel()
        cancelScheduledTurnWork()
        localPosition = .south
        humanControlledPositions = [.south]
        state.selectedCards = []
        state.lastRoundResult = nil
        state.phase = .menu
    }

    func startMultiplayerGame(
        localPosition: PlayerPosition,
        humanPositions: Set<PlayerPosition>,
        playerNames: [PlayerPosition: String] = [:]
    ) {
        dealingTask?.cancel()
        cancelScheduledTurnWork()
        self.localPosition = localPosition
        self.humanControlledPositions = humanPositions
        state = GameState()
        state.playerNames = playerNames
        state.dealerTeamIdx = 0
        state.teamLevels = [0: .two, 1: .two]
        startNewRound()
    }

    func displayName(for position: PlayerPosition) -> String {
        state.displayName(for: position)
    }

    func startNewRound() {
        dealingTask?.cancel()
        cancelScheduledTurnWork()
        state.resetRound()
        state.phase     = .dealing
        state.trumpRank = state.currentDealerTeamLevel

        // 确定本局庄家
        // - 第 1 局：先设默认庄家，发牌期间亮主可覆盖
        // - 第 2 局起：庄家已在上局结算时确定，亮主不可更改
        let dealerPos: PlayerPosition
        if let pending = state.pendingDealerPosition {
            dealerPos = pending
            state.pendingDealerPosition = nil
        } else {
            dealerPos = state.dealerTeamIdx == 0 ? .south : .west
        }
        setDealer(dealerPos)

        state.message = "正在发牌，可亮主..."

        // 启动发牌动画任务
        dealingTask = Task { await self.dealCardsAnimated() }
        syncMultiplayerState()
    }

    // MARK: - 逐张发牌（动画）

    private func dealCardsAnimated() async {
        let deck = Deck.doubleDeck().shuffled()
        let order: [PlayerPosition] = [.south, .west, .north, .east]

        for i in 0..<100 {
            if Task.isCancelled { return }

            let pos  = order[i % 4]
            let card = deck[i]

            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                state.player(pos).hand.append(card)
                // 实时排序：同花色聚拢，级牌/Joker 靠左
                state.player(pos).sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
            }
            // 记录本家最新拿到的牌 ID，用于高亮浮起效果
            if pos == localPosition {
                state.lastDrawnCardId = card.id
            }
            state.dealtCount = i + 1

            // 每 4 张播放一次抓牌音效（避免快速模式下声音堆叠）
            if i % 4 == 0 {
                SoundManager.shared.playCardDraw()
            }

            // AI 在收到牌后考虑亮主
            if !humanControlledPositions.contains(pos) {
                aiConsiderDeclaration(position: pos)
            }
            syncMultiplayerState()

            // 等待间隔（快速模式约 50ms，正常模式约 250ms）
            let ns: UInt64 = state.isDealingFast ? 40_000_000 : 250_000_000
            do {
                try await Task.sleep(nanoseconds: ns)
            } catch { return }
        }

        if Task.isCancelled { return }

        // 底牌
        state.kitty    = Array(deck[100...])
        state.dealtCount = 100
        syncMultiplayerState()

        // 最终排序（主牌已确认，消除亮主后的位置偏差）
        for pos in order {
            state.player(pos).sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }
        // 清除发牌高亮
        state.lastDrawnCardId = nil

        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        // 发牌结束，给人类 10 秒考虑时间（可在此期间亮主/反主）
        // 若人类已无法亮主或反主（手中无合法牌），直接跳过倒计时
        for remaining in stride(from: 10, through: 1, by: -1) {
            if Task.isCancelled { return }
            // 每秒重新检测：若人类无法再亮/反主，提前结束倒计时
            if !humanControlledPositions.isEmpty && !humanCanDeclareOrOverride() { break }
            state.postDealCountdown = remaining
            syncMultiplayerState()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state.postDealCountdown = 0
        if Task.isCancelled { return }

        afterDealingComplete()
        syncMultiplayerState()
    }

    /// 快速发牌（跳过剩余延迟）
    func toggleFastDealing() {
        guard !multiplayer.hasRemotePlayers else { return }
        state.isDealingFast.toggle()
        syncMultiplayerState()
    }

    // MARK: - 发牌结束后处理

    private func afterDealingComplete() {
        // 若无人亮主，且庄家是真人 → 等待真人亮主
        if state.trumpDeclaration == nil {
            if humanControlledPositions.contains(state.dealerPosition) {
                state.message = "无人亮主，请选牌亮主"
                // 仍在 .dealing 阶段，等待人类操作
                syncMultiplayerState()
                return
            } else {
                // AI 庄家强制亮主
                forceAIDeclare(dealer: state.dealerPosition)
            }
        }

        // 已有亮主 → 进入换底
        proceedToKittyExchange()
    }

    /// AI 庄家在无人亮主时必须亮主
    private func forceAIDeclare(dealer: PlayerPosition) {
        let hand = state.player(dealer).hand
        let suitCandidates = Suit.allCases.map { suit in
            aiDeclarationCandidate(for: suit, hand: hand, position: dealer, forced: true)
        }
        let bestSuit = suitCandidates.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.strength < rhs.strength
        }
        let noTrump = noTrumpDeclarationCandidate(hand: hand, position: dealer, forced: true)

        if let noTrump,
           let bestSuit,
           noTrump.score > bestSuit.score {
            applyDeclaration(position: dealer, suit: nil, strength: 3)
        } else if let bestSuit {
            applyDeclaration(position: dealer, suit: bestSuit.suit, strength: bestSuit.strength)
        } else {
            applyDeclaration(position: dealer, suit: Suit.allCases.randomElement()!, strength: 1)
        }
    }

    // MARK: - 亮主 / 反主（人类）

    /// 人类玩家用选中的牌亮主或反主
    func humanDeclareTrump() {
        humanDeclareTrump(position: localPosition, selectedIDs: state.selectedCards)
    }

    func humanDeclareTrump(position: PlayerPosition, selectedIDs: Set<UUID>) {
        guard !state.isResolvingTrick else { return }

        if multiplayer.isClient {
            multiplayer.sendAction(MultiplayerAction(
                position: position,
                kind: .declareTrump(selectedCardIDs: Array(selectedIDs))
            ))
            state.selectedCards = []
            return
        }

        guard state.phase == .dealing else { return }

        let player = state.player(position)
        let selected = player.hand.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else {
            state.message = "请先选择级牌（\(state.trumpRank.display)）来亮主"
            syncMultiplayerState()
            return
        }

        let tr = state.trumpRank
        let cur = state.declarationStrength

        // ── 王牌路径：小王对或大王对，均为无主 (strength=3) ──
        // 可在任意 cur < 3 时直接亮无主（不要求先有级牌对子）
        let isJokerPair = selected.count == 2 &&
            (selected.allSatisfy { $0.rank == .smallJoker } ||
             selected.allSatisfy { $0.rank == .bigJoker })
        if isJokerPair {
            guard cur < 3 else {
                state.message = "已是无主，不可再反"
                syncMultiplayerState()
                return
            }
            applyDeclaration(position: position, suit: nil, strength: 3, revealedCards: Array(selected.prefix(2)))
            state.selectedCards = []
            if state.dealtCount == 100 { proceedToKittyExchange() }
            syncMultiplayerState()
            return
        }

        // ── 普通路径：级牌亮主 ──────────────────────────
        guard selected.allSatisfy({ $0.rank == tr && !$0.isJoker }) else {
            state.message = "亮主只能使用 \(tr.display)（或对子王牌反无主）"
            syncMultiplayerState()
            return
        }

        // 必须同一花色
        let suits = Set(selected.compactMap { $0.suit })
        guard suits.count == 1, let suit = suits.first else {
            state.message = "亮主的牌必须是同一花色"
            syncMultiplayerState()
            return
        }

        let strength = min(selected.count, 2)

        // 强度必须严格大于当前声明（级牌最高 strength=2）
        guard strength > cur else {
            let hint: String
            switch cur {
            case 1: hint = "需要对子才能反主"
            case 2: hint = "级牌已满，可用小王或大王对反无主"
            default: hint = "已是最强亮主"
            }
            state.message = hint
            syncMultiplayerState()
            return
        }

        applyDeclaration(position: position, suit: suit, strength: strength, revealedCards: Array(selected.prefix(strength)))
        state.selectedCards = []

        // 发牌全部结束后才跳转
        if state.dealtCount == 100 {
            proceedToKittyExchange()
        }
        syncMultiplayerState()
    }

    // MARK: - 人类亮主能力检测

    /// 返回人类玩家当前是否有能力亮主或反主
    /// 用于发牌结束后判断是否需要给人类留倒计时思考时间
    private func humanCanDeclareOrOverride() -> Bool {
        let hand = localPlayer.hand
        let tr   = state.trumpRank
        let cur  = state.declarationStrength

        // strength==3 是最高等级，无法再反
        if cur >= 3 { return false }

        // 王对（大王对或小王对）在任意 cur < 3 时均可亮无主
        let bigJokers   = hand.filter { $0.rank == .bigJoker }.count
        let smallJokers = hand.filter { $0.rank == .smallJoker }.count
        if bigJokers >= 2 || smallJokers >= 2 { return true }

        // 当前 strength==2：只有王牌对能盖过（已在上面检查，此处已无能力）
        if cur == 2 { return false }

        // cur < 2：检查手中级牌
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank == tr {
            if let s = card.suit { counts[s, default: 0] += 1 }
        }

        // 当前 strength==1：需要对子才能盖过
        if cur == 1 { return counts.values.contains { $0 >= 2 } }

        // 当前 strength==0：单张或对子均可
        return !counts.isEmpty
    }

    // MARK: - AI 亮主逻辑

    private func aiConsiderDeclaration(position: PlayerPosition) {
        let hand    = state.player(position).hand
        let cur     = state.declarationStrength

        guard cur < 3 else { return }

        if let noTrump = noTrumpDeclarationCandidate(hand: hand, position: position, forced: false),
           shouldApplyAIDeclaration(noTrump, position: position) {
            applyDeclaration(position: position, suit: nil, strength: 3)
            return
        }

        let candidates = Suit.allCases
            .map { aiDeclarationCandidate(for: $0, hand: hand, position: position, forced: false) }
            .filter { $0.strength > cur }
            .filter { shouldApplyAIDeclaration($0, position: position) }

        if let best = candidates.max(by: { $0.score < $1.score }) {
            applyDeclaration(position: position, suit: best.suit, strength: best.strength)
        }
    }

    private struct AIDeclarationCandidate {
        let suit: Suit?
        let strength: Int
        let score: Int
    }

    private func aiDeclarationCandidate(
        for suit: Suit,
        hand: [Card],
        position: PlayerPosition,
        forced: Bool
    ) -> AIDeclarationCandidate {
        let levelCount = levelCardCount(in: hand, suit: suit)
        let strength = levelCount >= 2 ? 2 : 1
        let score = scoreTrumpSuit(suit, hand: hand, position: position)

        if forced {
            return AIDeclarationCandidate(suit: suit, strength: strength, score: score)
        }

        if strength == 2 {
            let minimumScore = state.declarationStrength == 0 ? 58 : 70
            guard dealProgress >= 0.30, score >= minimumScore else {
                return AIDeclarationCandidate(suit: suit, strength: 0, score: score)
            }
            return AIDeclarationCandidate(suit: suit, strength: 2, score: score)
        }

        guard canSingleDeclare(suit, hand: hand, position: position),
              score >= 45 else {
            return AIDeclarationCandidate(suit: suit, strength: 0, score: score)
        }
        return AIDeclarationCandidate(suit: suit, strength: 1, score: score)
    }

    private func noTrumpDeclarationCandidate(
        hand: [Card],
        position: PlayerPosition,
        forced: Bool
    ) -> AIDeclarationCandidate? {
        guard hasJokerPair(in: hand) else { return nil }

        let noTrumpScore = scoreNoTrump(hand: hand, position: position)
        let bestSuitScore = Suit.allCases
            .map { scoreTrumpSuit($0, hand: hand, position: position) }
            .max() ?? 0

        if forced {
            guard noTrumpScore > bestSuitScore + 20,
                  noTrumpShapeIsPlayable(hand: hand) else { return nil }
            return AIDeclarationCandidate(suit: nil, strength: 3, score: noTrumpScore)
        }

        guard dealProgress >= 0.35,
              noTrumpScore >= 105,
              noTrumpScore > bestSuitScore + 20,
              noTrumpShapeIsPlayable(hand: hand) else { return nil }
        return AIDeclarationCandidate(suit: nil, strength: 3, score: noTrumpScore)
    }

    private func shouldApplyAIDeclaration(
        _ candidate: AIDeclarationCandidate,
        position: PlayerPosition
    ) -> Bool {
        let cur = state.declarationStrength
        guard candidate.strength > cur else { return false }
        guard let current = state.trumpDeclaration else { return true }

        let currentScore: Int
        if let currentSuit = current.suit {
            currentScore = scoreTrumpSuit(currentSuit, hand: state.player(position).hand, position: position)
        } else {
            currentScore = scoreNoTrump(hand: state.player(position).hand, position: position)
        }

        if candidate.suit == current.suit {
            return candidate.score >= currentScore
        }

        let margin = position.team == state.dealerPosition.team ? 10 : 25
        return candidate.score > currentScore + margin
    }

    private var dealProgress: Double {
        min(1.0, max(0.0, Double(state.dealtCount) / 100.0))
    }

    private func canSingleDeclare(_ suit: Suit, hand: [Card], position: PlayerPosition) -> Bool {
        guard dealProgress >= 0.35,
              levelCardCount(in: hand, suit: suit) >= 1 else { return false }

        return suitLength(in: hand, suit: suit) >= 5
            || highCardCount(in: hand, suit: suit) >= 2
            || position.team == state.dealerPosition.team
            || dealProgress >= 0.75
    }

    private func scoreTrumpSuit(_ suit: Suit, hand: [Card], position: PlayerPosition) -> Int {
        let levelCards = levelCardCount(in: hand, suit: suit)
        let levelPairs = levelCards / 2
        let length = suitLength(in: hand, suit: suit)
        let highCards = highCardCount(in: hand, suit: suit)
        let pairTotal = pairCount(in: hand, trumpSuit: suit)
        let tractorTotal = tractorCount(in: hand, trumpSuit: suit)

        var score = 0
        score += levelCards * 20
        score += levelPairs * 35
        score += hand.filter { $0.rank == .ace }.count * 8
        score += pairTotal * 10
        score += tractorTotal * 15
        score += Int(dealProgress * 10.0)
        score += length * 4
        score += highCards * 6
        if position.team == state.dealerPosition.team { score += 10 }
        score -= sideDispersionPenalty(forTrumpSuit: suit, hand: hand)
        score -= overDeclareRiskPenalty(for: suit, position: position)
        if levelCards == 2 && length <= 2 { score -= 10 }
        return score
    }

    private func scoreNoTrump(hand: [Card], position: PlayerPosition) -> Int {
        let levelCards = hand.filter { $0.rank == state.trumpRank && !$0.isJoker }.count
        let levelPairs = levelCards / 2
        let jokerCount = hand.filter { $0.isJoker }.count
        let pairTotal = pairCount(in: hand, trumpSuit: nil)
        let tractorTotal = tractorCount(in: hand, trumpSuit: nil)

        var score = 0
        score += levelCards * 20
        score += levelPairs * 35
        score += hand.filter { $0.rank == .ace }.count * 10
        score += pairTotal * 10
        score += tractorTotal * 15
        score += Int(dealProgress * 10.0)
        score += jokerCount * 18
        if hasJokerPair(in: hand) { score += 35 }
        if position.team == state.dealerPosition.team { score += 6 }
        score -= noTrumpWeakSuitPenalty(hand: hand)
        score -= overDeclareRiskPenalty(for: nil, position: position)
        return score
    }

    private func levelCardCount(in hand: [Card], suit: Suit) -> Int {
        hand.filter { $0.rank == state.trumpRank && $0.suit == suit }.count
    }

    private func suitLength(in hand: [Card], suit: Suit) -> Int {
        hand.filter { $0.suit == suit }.count
    }

    private func highCardCount(in hand: [Card], suit: Suit) -> Int {
        hand.filter {
            $0.suit == suit && ($0.rank == .ace || $0.rank == .king || $0.rank == .ten)
        }.count
    }

    private func hasJokerPair(in hand: [Card]) -> Bool {
        hand.filter { $0.rank == .bigJoker }.count >= 2
            || hand.filter { $0.rank == .smallJoker }.count >= 2
    }

    private func noTrumpShapeIsPlayable(hand: [Card]) -> Bool {
        let aceCount = hand.filter { $0.rank == .ace }.count
        let pairs = pairCount(in: hand, trumpSuit: nil)
        let weakestSuit = Suit.allCases
            .map { suitLength(in: hand, suit: $0) }
            .min() ?? 0

        return aceCount >= 2
            && pairs >= 2
            && weakestSuit >= 2
    }

    private func pairCount(in hand: [Card], trumpSuit: Suit?) -> Int {
        var groups: [String: Int] = [:]
        for card in hand {
            let key = CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: state.trumpRank)
            groups[key, default: 0] += 1
        }
        return groups.values.reduce(0) { $0 + $1 / 2 }
    }

    private func tractorCount(in hand: [Card], trumpSuit: Suit?) -> Int {
        var groups: [String: [Card]] = [:]
        for card in hand {
            let key = CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: state.trumpRank)
            groups[key, default: []].append(card)
        }

        let pairRepresentatives = groups.values.compactMap { cards -> Card? in
            cards.count >= 2 ? cards[0] : nil
        }
        let bySuit = Dictionary(grouping: pairRepresentatives) {
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: state.trumpRank)
        }

        var total = 0
        for pairs in bySuit.values {
            let sorted = pairs.sorted {
                CardComparator.pairOrderValue($0, trumpSuit: trumpSuit, trumpRank: state.trumpRank)
                    < CardComparator.pairOrderValue($1, trumpSuit: trumpSuit, trumpRank: state.trumpRank)
            }

            var runLength = 1
            for idx in sorted.indices.dropFirst() {
                let previous = sorted[sorted.index(before: idx)]
                let current = sorted[idx]
                if CardComparator.areAdjacentPairRanks(previous, current, trumpSuit: trumpSuit, trumpRank: state.trumpRank) {
                    runLength += 1
                } else {
                    if runLength >= 2 { total += 1 }
                    runLength = 1
                }
            }
            if runLength >= 2 { total += 1 }
        }
        return total
    }

    private func sideDispersionPenalty(forTrumpSuit trumpSuit: Suit, hand: [Card]) -> Int {
        let sideLengths = Suit.allCases
            .filter { $0 != trumpSuit }
            .map { suit in
                hand.filter { $0.suit == suit && $0.rank != state.trumpRank }.count
            }
        let activeSideSuits = sideLengths.filter { $0 > 0 }.count
        let sideCards = sideLengths.reduce(0, +)
        let maxSide = sideLengths.max() ?? 0
        let minActiveSide = sideLengths.filter { $0 > 0 }.min() ?? 0
        let flatSidePenalty = activeSideSuits == 3 && maxSide - minActiveSide <= 2 ? 8 : 0
        return max(0, activeSideSuits - 2) * 4
            + max(0, sideCards - maxSide - 4) * 2
            + flatSidePenalty
    }

    private func noTrumpWeakSuitPenalty(hand: [Card]) -> Int {
        let lengths = Suit.allCases.map { suitLength(in: hand, suit: $0) }
        let weakest = lengths.min() ?? 0
        let veryShortSuits = lengths.filter { $0 < 2 }.count
        return max(0, 2 - weakest) * 30 + veryShortSuits * 12
    }

    private func overDeclareRiskPenalty(for suit: Suit?, position: PlayerPosition) -> Int {
        guard let current = state.trumpDeclaration else { return 0 }
        if current.suit == suit { return 0 }

        var penalty = current.strength * 4
        if current.declarer.team == position.team { penalty += 18 }
        if position.team != state.dealerPosition.team { penalty += 6 }
        return penalty
    }

    /// 应用亮主声明
    /// 亮主更新主花色，并将庄家设为亮主玩家（标准拖拉机规则：谁亮主谁坐庄）
    private func applyDeclaration(
        position: PlayerPosition,
        suit: Suit?,
        strength: Int,
        revealedCards explicitRevealedCards: [Card]? = nil
    ) {
        let revealedCards = explicitRevealedCards ?? declarationCards(
            position: position,
            suit: suit,
            strength: strength
        )
        state.trumpSuit = suit          // nil = 无主
        state.trumpDeclaration = TrumpDeclaration(
            declarer: position,
            suit: suit,
            strength: strength
        )
        state.declarationEvents.append(DeclarationEvent(
            declarer: position,
            suit: suit,
            strength: strength,
            revealedCards: revealedCards,
            sequence: state.declarationEvents.count + 1
        ))
        // roundNumber == 0（第 1 局发牌中）：亮主者成为庄家
        // roundNumber  > 0（第 2 局起）：庄家已定，亮主只更新主花色
        if state.roundNumber == 0 {
            setDealer(position)
        }
        let badge: String
        switch strength {
        case 1: badge = "（单张）"
        case 2: badge = "（对子）"
        case 3: badge = "（王牌对·无主）"
        default: badge = ""
        }
        let suitStr = suit.map { $0.rawValue } ?? "无主"
        state.message = "\(displayName(for: position)) 亮主：\(suitStr)\(strength < 3 ? state.trumpRank.display : "") \(badge)"
        syncMultiplayerState()
    }

    private func declarationCards(position: PlayerPosition, suit: Suit?, strength: Int) -> [Card] {
        let hand = state.player(position).hand
        if strength == 3 {
            for rank in [Rank.bigJoker, .smallJoker] {
                let cards = hand.filter { $0.rank == rank }
                if cards.count >= 2 { return Array(cards.prefix(2)) }
            }
            return []
        }

        guard let suit else { return [] }
        return Array(
            hand
                .filter { $0.rank == state.trumpRank && $0.suit == suit && !$0.isJoker }
                .prefix(strength)
        )
    }

    private func setDealer(_ position: PlayerPosition) {
        state.dealerPosition = position
        state.dealerTeamIdx = position.team
        for player in state.players {
            player.isDealer = player.position == position
        }
    }

    // MARK: - 换底牌

    private func proceedToKittyExchange() {
        // 重新排序（主牌已确定）
        for pos in PlayerPosition.allCases {
            state.player(pos).sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }

        state.phase        = .kittyExchange
        state.currentTurn  = state.dealerPosition   // 让庄家手牌可交互

        if humanControlledPositions.contains(state.dealerPosition) {
            // 真人庄家换底
            let dealer = state.player(state.dealerPosition)
            dealer.hand.append(contentsOf: state.kitty)
            dealer.sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
            state.kitty    = []
            state.message  = "\(displayName(for: state.dealerPosition)) 请选择 8 张牌压入底牌"
            syncMultiplayerState()
        } else {
            // AI 庄家自动换底
            aiKittyExchange(dealer: state.dealerPosition)
        }
    }

    func confirmKittyExchange(selectedIDs: Set<UUID>) {
        confirmKittyExchange(position: localPosition, selectedIDs: selectedIDs)
    }

    func confirmKittyExchange(position: PlayerPosition, selectedIDs: Set<UUID>) {
        guard !state.isResolvingTrick else { return }

        if multiplayer.isClient {
            multiplayer.sendAction(MultiplayerAction(
                position: position,
                kind: .confirmKitty(selectedCardIDs: Array(selectedIDs))
            ))
            state.selectedCards = []
            return
        }

        guard selectedIDs.count == 8 else {
            state.message = "请选择恰好 8 张牌放入底牌"
            syncMultiplayerState()
            return
        }
        let player = state.player(position)
        let selected = player.hand.filter { selectedIDs.contains($0.id) }
        state.kitty = selected
        player.hand.removeAll { selectedIDs.contains($0.id) }
        player.sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        state.selectedCards = []
        state.message = "换底完成，开始出牌"
        startPlaying()
        syncMultiplayerState()
    }

    private func aiKittyExchange(dealer: PlayerPosition) {
        let player = state.player(dealer)
        player.hand.append(contentsOf: state.kitty)
        player.sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)

        let ts = state.trumpSuit
        let tr = state.trumpRank
        let hand = player.hand

        // 找出所有对子组（同一 pairKey 有 ≥2 张）
        var pairGroupMap: [String: [Card]] = [:]
        for card in hand {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr), default: []].append(card)
        }
        let pairedIDs = Set(pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })

        func isTrump(_ c: Card) -> Bool { CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr) }
        func isAce(_ c: Card)   -> Bool { c.rank == .ace && !isTrump(c) }
        func isPaired(_ c: Card) -> Bool { pairedIDs.contains(c.id) }

        // 垫底牌优先级（数字越小越优先放入底牌）：
        // 0: 非主·非A·散牌·无分   1: 非主·非A·散牌·有分
        // 2: 非主·非A·配对·无分   3: 非主·非A·配对·有分
        // 4: 非主·A（尽量保留）   5: 主牌·散牌   6: 主牌·配对（最不想动）
        func tier(_ c: Card) -> Int {
            if isTrump(c)  { return isPaired(c) ? 6 : 5 }
            if isAce(c)    { return 4 }
            if isPaired(c) { return c.pointValue > 0 ? 3 : 2 }
            return c.pointValue > 0 ? 1 : 0
        }

        let sorted = hand.sorted { a, b in
            let ta = tier(a), tb = tier(b)
            if ta != tb { return ta < tb }
            // 同 tier 内：无分优先，再按 rank 升序（小牌先进底）
            if a.pointValue != b.pointValue { return a.pointValue < b.pointValue }
            return a.rank.rawValue < b.rank.rawValue
        }

        let kittyCards = Array(sorted.prefix(8))
        let kittyIDs   = Set(kittyCards.map { $0.id })
        state.kitty    = kittyCards
        player.hand.removeAll { kittyIDs.contains($0.id) }

        state.message = "换底完成，开始出牌"
        startPlaying()
        syncMultiplayerState()
    }

    private func startPlaying() {
        state.phase         = .playing
        state.isResolvingTrick = false
        state.currentLeader = state.dealerPosition
        state.currentTurn   = state.dealerPosition
        state.currentTrick  = Trick(leadPosition: state.dealerPosition)

        syncMultiplayerState()

        if !humanControlledPositions.contains(state.dealerPosition) {
            scheduleAITurn(position: state.dealerPosition, delay: 0.6)
        }
    }

    // MARK: - 出牌

    func humanPlay(selectedIDs: Set<UUID>) {
        humanPlay(position: localPosition, selectedIDs: selectedIDs)
    }

    func humanPlay(position: PlayerPosition, selectedIDs: Set<UUID>) {
        guard !state.isResolvingTrick else {
            state.selectedCards = []
            return
        }

        if multiplayer.isClient {
            multiplayer.sendAction(MultiplayerAction(
                position: position,
                kind: .play(selectedCardIDs: Array(selectedIDs))
            ))
            state.selectedCards = []
            return
        }

        guard state.phase == .playing,
              !state.isResolvingTrick,
              state.currentTurn == position else { return }

        let player = state.player(position)
        let selected = player.hand.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let leadCount = state.currentTrick.leadCards?.count ?? selected.count
        guard selected.count == leadCount else {
            state.message = "请出 \(leadCount) 张牌"
            syncMultiplayerState()
            return
        }

        if !state.currentTrick.plays.isEmpty {
            // 甩牌失败强制出牌校验：若人类选牌未包含强制牌，自动替换为强制牌+最弱补牌
            if let forced = state.forcedFollowCards[position], !forced.isEmpty {
                let forcedIDs   = Set(forced.map { $0.id })
                let selectedIDs = Set(selected.map { $0.id })
                if !forcedIDs.isSubset(of: selectedIDs) {
                    // 回退人类选的牌，改成强制牌 + 最弱补牌
                    let autoCards = buildForcedPlay(
                        forced: forced,
                        hand: player.hand,
                        count: leadCount
                    )
                    state.message = "甩牌失败，强制出：\(forced.map { $0.shortDisplay }.joined(separator: " "))"
                    syncMultiplayerState()
                    performPlay(position: position, cards: autoCards)
                    return
                }
            }

            let evaluator = makeEvaluator()
            guard evaluator.isValidPlay(
                selected: selected,
                hand: player.hand,
                leadCards: state.currentTrick.leadCards!) else {
                state.message = "出牌不合法，请检查花色"
                syncMultiplayerState()
                return
            }
        }

        performPlay(position: position, cards: selected)
    }

    private func performPlay(position: PlayerPosition, cards: [Card]) {
        guard state.phase == .playing,
              !state.isResolvingTrick,
              state.currentTurn == position,
              !cards.isEmpty,
              state.currentTrick.plays.count < 4,
              !state.currentTrick.plays.contains(where: { $0.position == position }) else { return }

        let leadCount = state.currentTrick.leadCards?.count ?? cards.count
        guard cards.count == leadCount else { return }

        let player = state.player(position)
        guard cards.allSatisfy({ card in
            player.hand.contains(where: { $0.id == card.id })
        }) else { return }

        if let leadCards = state.currentTrick.leadCards {
            let evaluator = makeEvaluator()
            guard evaluator.isValidPlay(selected: cards, hand: player.hand, leadCards: leadCards) else {
                state.message = "\(displayName(for: position)) 出牌不合法，已取消"
                syncMultiplayerState()
                return
            }
        }

        SoundManager.shared.playCardSlap()
        player.play(cards: cards)
        state.currentTrick.plays.append((position: position, cards: cards))
        state.selectedCards = []
        state.message = "\(displayName(for: position)) 出了 \(cards.map { $0.shortDisplay }.joined(separator: " "))"

        // 首张：检测甩牌，更新强制出牌和罚分
        // 若是人类甩牌失败，需回退出牌并让人类重新选择
        if state.currentTrick.plays.count == 1 {
            if humanControlledPositions.contains(position) {
                if revertSlamIfFailed(position: position, cards: cards) {
                    return   // 已回退，等待人类重新出牌
                }
            } else {
                analyzeSlamLead(position: position, cards: cards)
            }
            // 领出语音播报
            let announcement = makeEvaluator().leadAnnouncement(cards: cards)
            SoundManager.shared.speakLead(announcement)
        }

        // 跟牌：先手是副牌，且出主牌后自己成为赢家（真正将吃）才播报"毙"
        if state.currentTrick.plays.count > 1 {
            let evaluator = makeEvaluator()
            let leadCards = state.currentTrick.plays[0].cards
            if evaluator.dominantSuit(of: leadCards) != nil,          // 先手是副牌
               evaluator.dominantSuit(of: cards) == nil,              // 当前出的是主牌
               evaluator.winner(of: state.currentTrick) == position { // 出牌后自己是赢家
                SoundManager.shared.speakLead("毙")
            }
        }

        if state.currentTrick.isComplete {
            beginTrickResolution()
        } else {
            let next = nextPosition(after: position)
            state.currentTurn = next
            syncMultiplayerState()
            if !humanControlledPositions.contains(next) {
                scheduleAITurn(position: next, delay: aiDelay)
            }
        }
    }

    // MARK: - 结算一墩

    private func beginTrickResolution() {
        guard state.currentTrick.isComplete,
              Set(state.currentTrick.plays.map(\.position)).count == 4,
              !state.isResolvingTrick else { return }

        cancelAITurnTask()
        state.isResolvingTrick = true
        state.phase = .trickEnd
        state.selectedCards = []
        syncMultiplayerState()

        scheduleTrickResolution(delay: trickEndDelay)
    }

    private func resolveTrick() {
        guard state.isResolvingTrick,
              state.currentTrick.isComplete,
              Set(state.currentTrick.plays.map(\.position)).count == 4 else { return }

        let evaluator = makeEvaluator()
        let winner    = evaluator.winner(of: state.currentTrick)
        let points    = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }

        if winner.team == state.attackTeamIdx { state.attackScore += points }

        state.completedTricks.append(state.currentTrick)
        state.currentLeader = winner
        state.currentTurn   = winner
        state.message = "\(displayName(for: winner)) 赢得本墩，+\(points) 分 | 攻方累计：\(state.attackScore) 分"
        syncMultiplayerState()

        if state.players.allSatisfy({ $0.hand.isEmpty }) {
            state.isResolvingTrick = false
            resolveRound()
            syncMultiplayerState()
            return
        }

        state.currentTrick        = Trick(leadPosition: winner)
        state.forcedFollowCards   = [:]   // 新的一墩，清除强制出牌
        state.phase               = .playing
        state.isResolvingTrick    = false
        syncMultiplayerState()

        if !humanControlledPositions.contains(winner) {
            scheduleAITurn(position: winner, delay: aiDelay)
        }
    }

    // MARK: - 结算一局

    private func resolveRound() {
        state.roundNumber += 1   // 局结束后自增，之后亮主不再换庄
        state.phase = .roundEnd

        let evaluator    = makeEvaluator()
        let kittyCards   = state.kitty
        let kittyPoints  = kittyCards.reduce(0) { $0 + $1.pointValue }
        let lastTrick    = state.completedTricks.last!
        let lastWinner   = evaluator.winner(of: lastTrick)
        var finalScore   = state.attackScore

        // 计算底牌翻倍系数（由最后一墩先手牌型决定）
        let multiplier   = kittyMultiplier(lastTrickLeadCards: lastTrick.plays.first?.cards ?? [],
                                           evaluator: evaluator)

        var rawKittyPts  = 0
        if lastWinner.team == state.attackTeamIdx {
            rawKittyPts   = kittyPoints
            let bonus     = kittyPoints * multiplier
            finalScore   += bonus
            state.message = "攻方吃底牌 ×\(multiplier)，+\(bonus) 分"
        } else {
            state.message = "庄家方保底"
        }

        let threshold   = 80
        let attackWon   = finalScore >= threshold
        state.attackScore = finalScore

        // 在 dealerTeamIdx 被修改之前确定本局胜负，用于音效
        let localIsAttack = localPosition.team == state.attackTeamIdx
        let localWon      = localIsAttack ? attackWon : !attackWon

        var dealerAdvance = 0
        var attackAdvance = 0

        if attackWon {
            // 每超过80分的40分升一级：120升1级，160升2级，200升3级，以此类推
            attackAdvance = (finalScore - 80) / 40
        } else {
            dealerAdvance = finalScore == 0 ? 3 : finalScore < 40 ? 2 : 1
        }

        state.lastRoundResult = RoundResult(
            attackScore: finalScore,
            attackTeamWon: attackWon,
            levelAdvance: dealerAdvance,
            attackAdvance: attackAdvance,
            kittyCards: kittyCards,
            kittyMultiplier: multiplier,
            rawKittyPoints: rawKittyPts
        )

        if attackWon {
            advanceLevel(team: state.attackTeamIdx, steps: attackAdvance)
            // 攻方胜：新庄家 = 当前庄家顺时针下一位
            state.pendingDealerPosition = nextPosition(after: state.dealerPosition)
            state.dealerTeamIdx = state.attackTeamIdx
        } else {
            advanceLevel(team: state.dealerTeamIdx, steps: dealerAdvance)
            // 守方胜：无论第几局，庄家都在队内轮换（搭档接任）
            let partnerRaw = (state.dealerPosition.rawValue + 2) % 4
            state.pendingDealerPosition = PlayerPosition(rawValue: partnerRaw)
        }

        if teamLevelRank(state.dealerTeamIdx) == .ace ||
           teamLevelRank(state.attackTeamIdx) == .ace {
            state.phase = .gameOver
        }

        // 每局结束播放胜负音效（localWon 在 dealerTeamIdx 改变前已算好）
        if localWon {
            SoundManager.shared.playVictory()
        } else {
            SoundManager.shared.playGameOver()
        }

        syncMultiplayerState()
    }

    /// 根据最后一墩先手牌型计算底牌翻倍系数：
    /// 单张→×2，对子→×4，连对（N对=2N张）→×(2N×2)，甩牌→取各组件最大值
    private func kittyMultiplier(lastTrickLeadCards: [Card], evaluator: TrickEvaluator) -> Int {
        let count = lastTrickLeadCards.count
        guard count > 0 else { return 2 }

        if count == 1 { return 2 }

        // 甩牌（混合牌型）：取最大分支
        if let slam = evaluator.slamInfo(of: lastTrickLeadCards) {
            var m = 2
            for tractor in slam.tractors { m = max(m, tractor.count * 2) }
            if !slam.pairs.isEmpty { m = max(m, 4) }
            return m
        }

        // 纯对子
        if count == 2 { return 4 }

        // 纯连对（slamInfo==nil 且 count>=4 偶数）
        return count * 2
    }

    private func advanceLevel(team: Int, steps: Int) {
        let ranks: [Rank] = [.two,.three,.four,.five,.six,.seven,.eight,.nine,.ten,.jack,.queen,.king,.ace]
        let cur  = teamLevelRank(team)
        let val  = min(cur.rawValue + steps, Rank.ace.rawValue)
        state.teamLevels[team] = ranks.first { $0.rawValue >= val } ?? .ace
    }

    private func teamLevelRank(_ team: Int) -> Rank { state.teamLevels[team] ?? .two }

    // MARK: - AI 出牌

    private func aiTakeTurn(position: PlayerPosition) {
        guard state.phase == .playing,
              !state.isResolvingTrick,
              state.currentTurn == position,
              !state.currentTrick.plays.contains(where: { $0.position == position }) else { return }

        let forcedCards = state.forcedFollowCards[position] ?? []
        let cards = AIPlayer.chooseCards(
            position: position,
            state: state,
            evaluator: makeEvaluator(),
            forcedCards: forcedCards
        )
        performPlay(position: position, cards: cards)
    }

    private func scheduleAITurn(position: PlayerPosition, delay: TimeInterval) {
        guard state.phase == .playing,
              !state.isResolvingTrick,
              state.currentTurn == position,
              !humanControlledPositions.contains(position) else { return }

        cancelAITurnTask()
        aiTurnGeneration += 1
        let generation = aiTurnGeneration
        let roundNumber = state.roundNumber
        let leadPosition = state.currentTrick.leadPosition
        let playCount = state.currentTrick.plays.count
        let completedCount = state.completedTricks.count
        let handCount = state.player(position).hand.count
        let nanoseconds = UInt64(delay * 1_000_000_000)

        aiTurnTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.runScheduledAITurn(
                position: position,
                generation: generation,
                roundNumber: roundNumber,
                leadPosition: leadPosition,
                playCount: playCount,
                completedCount: completedCount,
                handCount: handCount
            )
        }
    }

    private func runScheduledAITurn(
        position: PlayerPosition,
        generation: Int,
        roundNumber: Int,
        leadPosition: PlayerPosition,
        playCount: Int,
        completedCount: Int,
        handCount: Int
    ) {
        guard generation == aiTurnGeneration,
              state.phase == .playing,
              !state.isResolvingTrick,
              state.roundNumber == roundNumber,
              state.currentTurn == position,
              state.currentTrick.leadPosition == leadPosition,
              state.currentTrick.plays.count == playCount,
              state.completedTricks.count == completedCount,
              state.player(position).hand.count == handCount,
              !state.currentTrick.plays.contains(where: { $0.position == position }) else { return }

        aiTakeTurn(position: position)
    }

    private func scheduleTrickResolution(delay: TimeInterval) {
        cancelTrickResolutionTask()
        trickResolutionGeneration += 1
        let generation = trickResolutionGeneration
        let leadPosition = state.currentTrick.leadPosition
        let completedCount = state.completedTricks.count
        let nanoseconds = UInt64(delay * 1_000_000_000)

        trickResolutionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.runScheduledTrickResolution(
                generation: generation,
                leadPosition: leadPosition,
                completedCount: completedCount
            )
        }
    }

    private func runScheduledTrickResolution(
        generation: Int,
        leadPosition: PlayerPosition,
        completedCount: Int
    ) {
        guard generation == trickResolutionGeneration,
              state.phase == .trickEnd,
              state.isResolvingTrick,
              state.currentTrick.isComplete,
              state.currentTrick.leadPosition == leadPosition,
              state.completedTricks.count == completedCount else { return }

        resolveTrick()
    }

    private func cancelScheduledTurnWork() {
        cancelAITurnTask()
        cancelTrickResolutionTask()
    }

    private func cancelAITurnTask() {
        aiTurnTask?.cancel()
        aiTurnTask = nil
        aiTurnGeneration += 1
    }

    private func cancelTrickResolutionTask() {
        trickResolutionTask?.cancel()
        trickResolutionTask = nil
        trickResolutionGeneration += 1
    }

    // MARK: - 甩牌分析

    /// 若人类先手甩牌失败，回退出牌，重置到出牌前状态，返回 true 表示已回退
    private func revertSlamIfFailed(position: PlayerPosition, cards: [Card]) -> Bool {
        let evaluator = makeEvaluator()
        guard let slam = evaluator.slamInfo(of: cards) else {
            // 不是甩牌，正常走后续流程
            analyzeSlamLead(position: position, cards: cards)
            return false
        }

        // 先对所有对手的手牌做检测
        let opponents = PlayerPosition.allCases.filter { $0 != position }
        var opponentHands: [PlayerPosition: [Card]] = [:]
        for pos in opponents {
            opponentHands[pos] = state.player(pos).hand
        }
        let penalty = evaluator.slamPenaltyPoints(slam: slam, opponentHands: opponentHands)

        if penalty == 0 {
            // 甩牌成功，继续正常流程（设置强制跟牌）
            analyzeSlamLead(position: position, cards: cards)
            return false
        }

        // 甩牌失败：回退人类的出牌
        state.currentTrick.plays.removeLast()
        state.player(position).hand.append(contentsOf: cards)
        state.player(position).sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)

        // 扣分
        if position.team == state.attackTeamIdx {
            state.attackScore = max(0, state.attackScore - penalty)
        } else {
            state.attackScore += penalty
        }

        // 显示哪些对手有更大的牌
        var forcedParts: [String] = []
        for pos in opponents {
            let forcing = evaluator.slamForcing(slam: slam, opponentHand: opponentHands[pos]!)
            if !forcing.isEmpty {
                let display = forcing.resolvedForcedCards.map { $0.shortDisplay }.joined(separator: " ")
                forcedParts.append("\(displayName(for: pos))有[\(display)]")
            }
        }
        state.message = "甩牌失败 -\(penalty)分（\(forcedParts.joined(separator: "，"))），请重新出牌"
        syncMultiplayerState()
        return true
    }

    /// 构建强制出牌：forced 牌 + 从手牌中取最弱补牌，总张数 = count
    private func buildForcedPlay(forced: [Card], hand: [Card], count: Int) -> [Card] {
        var result = Array(forced.prefix(count))
        if result.count < count {
            let usedIDs = Set(result.map { $0.id })
            let rest = hand.filter { !usedIDs.contains($0.id) }
            let ts = state.trumpSuit
            let tr = state.trumpRank
            let fill = rest.sorted { a, b in
                // 垫牌顺序：非主优先，分值低优先，rank 小优先
                let aTrump = CardComparator.isTrump(a, trumpSuit: ts, trumpRank: tr)
                let bTrump = CardComparator.isTrump(b, trumpSuit: ts, trumpRank: tr)
                if aTrump != bTrump { return !aTrump }
                if a.pointValue != b.pointValue { return a.pointValue < b.pointValue }
                return a.rank.rawValue < b.rank.rawValue
            }
            result += Array(fill.prefix(count - result.count))
        }
        return Array(result.prefix(count))
    }

    /// 检测领出的牌是否为甩牌，若是则计算罚分并设置各家的强制出牌
    private func analyzeSlamLead(position: PlayerPosition, cards: [Card]) {
        let evaluator = makeEvaluator()
        guard let slam = evaluator.slamInfo(of: cards) else { return }

        let opponents = PlayerPosition.allCases.filter { $0 != position }
        var opponentHands: [PlayerPosition: [Card]] = [:]
        var forced: [PlayerPosition: [Card]] = [:]

        for pos in opponents {
            let hand = state.player(pos).hand
            opponentHands[pos] = hand
            let forcing = evaluator.slamForcing(slam: slam, opponentHand: hand)
            if !forcing.isEmpty {
                forced[pos] = forcing.resolvedForcedCards
            }
        }

        // 罚分
        let penalty = evaluator.slamPenaltyPoints(slam: slam, opponentHands: opponentHands)
        if penalty > 0 {
            if position.team == state.attackTeamIdx {
                // 攻方甩错牌：攻方得分减少
                state.attackScore = max(0, state.attackScore - penalty)
            } else {
                // 庄方甩错牌：攻方得分增加
                state.attackScore += penalty
            }
            state.message += "  ⚡甩牌失败 -\(penalty)分"
        }

        // 记录强制出牌
        if !forced.isEmpty {
            state.forcedFollowCards = forced
            let names = forced.keys.map { displayName(for: $0) }.joined(separator: "、")
            state.message += "  [\(names) 被强制出牌]"
        }
    }

    // MARK: - 开始下一局

    func startNextRound() {
        guard !multiplayer.isClient else { return }
        state.lastRoundResult = nil
        startNewRound()
    }

    // MARK: - 联机同步

    func handleRemoteAction(_ action: MultiplayerAction) {
        guard !state.isResolvingTrick else { return }

        switch action.kind {
        case .declareTrump(let selectedCardIDs):
            humanDeclareTrump(position: action.position, selectedIDs: Set(selectedCardIDs))
        case .confirmKitty(let selectedCardIDs):
            confirmKittyExchange(position: action.position, selectedIDs: Set(selectedCardIDs))
        case .play(let selectedCardIDs):
            humanPlay(position: action.position, selectedIDs: Set(selectedCardIDs))
        }
    }

    func snapshot(for position: PlayerPosition) -> GameSnapshot {
        let trick = NetworkTrickSnapshot(
            leadPosition: state.currentTrick.leadPosition,
            plays: state.currentTrick.plays.map {
                NetworkPlaySnapshot(position: $0.position, cards: $0.cards)
            }
        )
        let completedTricks = state.completedTricks.map { completedTrick in
            NetworkTrickSnapshot(
                leadPosition: completedTrick.leadPosition,
                plays: completedTrick.plays.map {
                    NetworkPlaySnapshot(position: $0.position, cards: $0.cards)
                }
            )
        }

        let players = state.players.map { player in
            NetworkPlayerSnapshot(
                position: player.position,
                hand: player.position == position ? player.hand : [],
                handCount: player.hand.count,
                isDealer: player.isDealer
            )
        }

        return GameSnapshot(
            localPosition: position,
            playerNames: state.playerNames,
            phase: state.phase,
            trumpSuit: state.trumpSuit,
            trumpRank: state.trumpRank,
            trumpDeclaration: state.trumpDeclaration,
            declarationEvents: state.declarationEvents,
            dealtCount: state.dealtCount,
            isDealingFast: state.isDealingFast,
            isResolvingTrick: state.isResolvingTrick,
            dealerPosition: state.dealerPosition,
            currentTrick: trick,
            completedTricks: completedTricks,
            currentLeader: state.currentLeader,
            currentTurn: state.currentTurn,
            attackScore: state.attackScore,
            teamLevels: state.teamLevels,
            dealerTeamIdx: state.dealerTeamIdx,
            message: state.message,
            lastRoundResult: state.lastRoundResult,
            players: players
        )
    }

    func apply(snapshot: GameSnapshot) {
        dealingTask?.cancel()
        cancelScheduledTurnWork()
        localPosition = snapshot.localPosition
        humanControlledPositions = [snapshot.localPosition]

        state.phase = snapshot.phase
        state.playerNames = snapshot.playerNames
        state.trumpSuit = snapshot.trumpSuit
        state.trumpRank = snapshot.trumpRank
        state.trumpDeclaration = snapshot.trumpDeclaration
        state.declarationEvents = snapshot.declarationEvents
        state.dealtCount = snapshot.dealtCount
        state.isDealingFast = snapshot.isDealingFast
        state.isResolvingTrick = snapshot.isResolvingTrick
        state.dealerPosition = snapshot.dealerPosition
        state.currentLeader = snapshot.currentLeader
        state.currentTurn = snapshot.currentTurn
        state.attackScore = snapshot.attackScore
        state.teamLevels = snapshot.teamLevels
        state.dealerTeamIdx = snapshot.dealerTeamIdx
        state.message = snapshot.message
        state.lastRoundResult = snapshot.lastRoundResult

        for playerSnapshot in snapshot.players {
            let player = state.player(playerSnapshot.position)
            player.isDealer = playerSnapshot.isDealer
            if playerSnapshot.position == snapshot.localPosition {
                player.hand = playerSnapshot.hand
            } else {
                player.hand = placeholderCards(count: playerSnapshot.handCount)
            }
        }

        var trick = Trick(leadPosition: snapshot.currentTrick.leadPosition)
        trick.plays = snapshot.currentTrick.plays.map { ($0.position, $0.cards) }
        state.currentTrick = trick
        state.completedTricks = snapshot.completedTricks.map { trickSnapshot in
            var completedTrick = Trick(leadPosition: trickSnapshot.leadPosition)
            completedTrick.plays = trickSnapshot.plays.map { ($0.position, $0.cards) }
            return completedTrick
        }
    }

    private func placeholderCards(count: Int) -> [Card] {
        guard count > 0 else { return [] }
        return (0..<count).map { _ in Card(suit: nil, rank: .smallJoker) }
    }

    private func syncMultiplayerState() {
        guard multiplayer.isHost else { return }
        multiplayer.broadcastSnapshots()
    }

    // MARK: - 工具

    private func makeEvaluator() -> TrickEvaluator {
        TrickEvaluator(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
    }

    private func nextPosition(after pos: PlayerPosition) -> PlayerPosition {
        let order: [PlayerPosition] = [.south, .west, .north, .east]
        return order[(order.firstIndex(of: pos)! + 1) % 4]
    }

}
