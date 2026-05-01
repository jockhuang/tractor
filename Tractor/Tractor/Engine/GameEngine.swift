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
    private var dealingTask: Task<Void, Never>?
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
        multiplayer.leave()
        localPosition = .south
        humanControlledPositions = [.south]
        state = GameState()
        state.dealerTeamIdx = 0
        state.teamLevels    = [0: .two, 1: .two]
        startNewRound()
    }

    func startMultiplayerGame(localPosition: PlayerPosition, humanPositions: Set<PlayerPosition>) {
        dealingTask?.cancel()
        self.localPosition = localPosition
        self.humanControlledPositions = humanPositions
        state = GameState()
        state.dealerTeamIdx = 0
        state.teamLevels = [0: .two, 1: .two]
        startNewRound()
    }

    func startNewRound() {
        dealingTask?.cancel()
        state.resetRound()
        state.phase     = .dealing
        state.trumpRank = state.currentDealerTeamLevel

        // 确定庄家
        let dealerPos: PlayerPosition = state.dealerTeamIdx == 0 ? .south : .west
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
            }
            state.dealtCount = i + 1

            // AI 在收到牌后考虑亮主
            if !humanControlledPositions.contains(pos) {
                aiConsiderDeclaration(position: pos)
            }
            syncMultiplayerState()

            // 等待间隔（快速模式约 50ms，正常模式约 1s）
            let ns: UInt64 = state.isDealingFast ? 40_000_000 : 900_000_000
            do {
                try await Task.sleep(nanoseconds: ns)
            } catch { return }
        }

        if Task.isCancelled { return }

        // 底牌
        state.kitty    = Array(deck[100...])
        state.dealtCount = 100
        syncMultiplayerState()

        // 排序手牌
        for pos in order {
            state.player(pos).sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        afterDealingComplete()
        syncMultiplayerState()
    }

    /// 快速发牌（跳过剩余延迟）
    func toggleFastDealing() {
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
        let tr   = state.trumpRank

        // 找张数最多的级牌花色
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank == tr {
            if let s = card.suit { counts[s, default: 0] += 1 }
        }
        if let best = counts.max(by: { $0.value < $1.value }) {
            let str = best.value >= 2 ? 2 : 1
            applyDeclaration(position: dealer, suit: best.key, strength: str)
        } else {
            // 没有级牌，随机选一门
            let fallback = Suit.allCases.randomElement()!
            applyDeclaration(position: dealer, suit: fallback, strength: 1)
        }
    }

    // MARK: - 亮主 / 反主（人类）

    /// 人类玩家用选中的牌亮主或反主
    func humanDeclareTrump() {
        humanDeclareTrump(position: localPosition, selectedIDs: state.selectedCards)
    }

    func humanDeclareTrump(position: PlayerPosition, selectedIDs: Set<UUID>) {
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

        // 必须全是级牌（非大小王）
        let tr = state.trumpRank
        guard selected.allSatisfy({ $0.rank == tr && !$0.isJoker }) else {
            state.message = "亮主只能使用 \(tr.display) 且不能用王"
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

        // 强度必须严格大于当前声明
        guard strength > state.declarationStrength else {
            let hint = state.declarationStrength == 1 ? "需要对子才能反主" : "已是最强亮主"
            state.message = hint
            syncMultiplayerState()
            return
        }

        applyDeclaration(position: position, suit: suit, strength: strength)
        state.selectedCards = []

        // 发牌全部结束后才跳转
        if state.dealtCount == 100 {
            proceedToKittyExchange()
        }
        syncMultiplayerState()
    }

    // MARK: - AI 亮主逻辑

    private func aiConsiderDeclaration(position: PlayerPosition) {
        let hand = state.player(position).hand
        let tr   = state.trumpRank
        let cur  = state.declarationStrength

        // 统计每花色级牌数量
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank == tr {
            if let s = card.suit { counts[s, default: 0] += 1 }
        }

        // 优先宣告对子（可覆盖任何单张声明）
        if let best = counts.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value }) {
            if cur < 2 {
                applyDeclaration(position: position, suit: best.key, strength: 2)
            }
            return
        }

        // 单张：只在无人亮主时随机亮（40% 概率）
        if cur == 0, let suit = counts.keys.first {
            if Int.random(in: 0..<100) < 40 {
                applyDeclaration(position: position, suit: suit, strength: 1)
            }
        }
    }

    /// 应用亮主声明
    /// 注意：亮主只更新主花色，不改变庄家位置（庄家由每局开始时确定）
    private func applyDeclaration(position: PlayerPosition, suit: Suit, strength: Int) {
        state.trumpSuit = suit
        state.trumpDeclaration = TrumpDeclaration(
            declarer: position,
            suit: suit,
            strength: strength
        )
        let badge = strength == 2 ? "（对子）" : "（单张）"
        state.message = "\(position.displayName) 亮主：\(suit.rawValue)\(state.trumpRank.display) \(badge)"
        syncMultiplayerState()
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

        state.phase = .kittyExchange

        if humanControlledPositions.contains(state.dealerPosition) {
            // 真人庄家换底
            let dealer = state.player(state.dealerPosition)
            dealer.hand.append(contentsOf: state.kitty)
            dealer.sortHand(trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
            state.kitty    = []
            state.message  = "\(state.dealerPosition.displayName) 请选择 8 张牌压入底牌"
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

        let nonTrump = player.hand.filter {
            !CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }.sorted { a, b in
            CardComparator.handSortOrder(b, a, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }

        let kittyCards = Array(nonTrump.prefix(8))
        let kittyIDs   = Set(kittyCards.map { $0.id })
        state.kitty    = kittyCards
        player.hand.removeAll { kittyIDs.contains($0.id) }

        state.message = "换底完成，开始出牌"
        startPlaying()
        syncMultiplayerState()
    }

    private func startPlaying() {
        state.phase         = .playing
        state.currentLeader = state.dealerPosition
        state.currentTurn   = state.dealerPosition
        state.currentTrick  = Trick(leadPosition: state.dealerPosition)

        syncMultiplayerState()

        if !humanControlledPositions.contains(state.dealerPosition) {
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                aiTakeTurn(position: state.dealerPosition)
            }
        }
    }

    // MARK: - 出牌

    func humanPlay(selectedIDs: Set<UUID>) {
        humanPlay(position: localPosition, selectedIDs: selectedIDs)
    }

    func humanPlay(position: PlayerPosition, selectedIDs: Set<UUID>) {
        if multiplayer.isClient {
            multiplayer.sendAction(MultiplayerAction(
                position: position,
                kind: .play(selectedCardIDs: Array(selectedIDs))
            ))
            state.selectedCards = []
            return
        }

        guard state.phase == .playing,
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
            // 甩牌失败强制出牌校验
            if let forced = state.forcedFollowCards[position], !forced.isEmpty {
                let forcedIDs  = Set(forced.map { $0.id })
                let selectedIDs = Set(selected.map { $0.id })
                guard forcedIDs.isSubset(of: selectedIDs) else {
                    state.message = "甩牌失败，你必须出：\(forced.map { $0.shortDisplay }.joined(separator: " "))"
                    syncMultiplayerState()
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
        state.player(position).play(cards: cards)
        state.currentTrick.plays.append((position: position, cards: cards))
        state.selectedCards = []
        state.message = "\(position.displayName) 出了 \(cards.map { $0.shortDisplay }.joined(separator: " "))"

        // 首张：检测甩牌，更新强制出牌和罚分
        if state.currentTrick.plays.count == 1 {
            analyzeSlamLead(position: position, cards: cards)
        }

        syncMultiplayerState()

        if state.currentTrick.isComplete {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(trickEndDelay * 1_000_000_000))
                resolveTrick()
            }
        } else {
            let next = nextPosition(after: position)
            state.currentTurn = next
            syncMultiplayerState()
            if !humanControlledPositions.contains(next) {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(aiDelay * 1_000_000_000))
                    aiTakeTurn(position: next)
                }
            }
        }
    }

    // MARK: - 结算一墩

    private func resolveTrick() {
        let evaluator = makeEvaluator()
        let winner    = evaluator.winner(of: state.currentTrick)
        let points    = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }

        if winner.team == state.attackTeamIdx { state.attackScore += points }

        state.completedTricks.append(state.currentTrick)
        state.currentLeader = winner
        state.currentTurn   = winner
        state.message = "\(winner.displayName) 赢得本墩，+\(points) 分 | 攻方累计：\(state.attackScore) 分"
        syncMultiplayerState()

        if state.players.allSatisfy({ $0.hand.isEmpty }) {
            resolveRound()
            syncMultiplayerState()
            return
        }

        state.currentTrick        = Trick(leadPosition: winner)
        state.forcedFollowCards   = [:]   // 新的一墩，清除强制出牌
        syncMultiplayerState()

        if !humanControlledPositions.contains(winner) {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(aiDelay * 1_000_000_000))
                aiTakeTurn(position: winner)
            }
        }
    }

    // MARK: - 结算一局

    private func resolveRound() {
        state.phase = .roundEnd

        let kittyPoints  = state.kitty.reduce(0) { $0 + $1.pointValue }
        let lastWinner   = makeEvaluator().winner(of: state.completedTricks.last!)
        var finalScore   = state.attackScore

        if lastWinner.team == state.attackTeamIdx {
            finalScore += kittyPoints * 2
            state.message = "攻方吃底牌 x2，+\(kittyPoints * 2) 分"
        } else {
            state.message = "庄家方保底"
        }

        let threshold   = 80
        let attackWon   = finalScore >= threshold
        state.attackScore = finalScore

        var dealerAdvance = 0
        var attackAdvance = 0

        if attackWon {
            attackAdvance = finalScore >= 120 ? 3 : finalScore >= 100 ? 2 : 1
        } else {
            dealerAdvance = finalScore == 0 ? 3 : finalScore < 40 ? 2 : 1
        }

        state.lastRoundResult = RoundResult(
            attackScore: finalScore,
            attackTeamWon: attackWon,
            levelAdvance: dealerAdvance,
            attackAdvance: attackAdvance
        )

        if attackWon {
            advanceLevel(team: state.attackTeamIdx, steps: attackAdvance)
            state.dealerTeamIdx = state.attackTeamIdx
        } else {
            advanceLevel(team: state.dealerTeamIdx, steps: dealerAdvance)
        }

        if teamLevelRank(state.dealerTeamIdx) == .ace ||
           teamLevelRank(state.attackTeamIdx) == .ace {
            state.phase = .gameOver
        }
        syncMultiplayerState()
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
              state.currentTurn == position else { return }

        let forcedCards = state.forcedFollowCards[position] ?? []
        let cards = AIPlayer.chooseCards(
            position: position,
            state: state,
            evaluator: makeEvaluator(),
            forcedCards: forcedCards
        )
        performPlay(position: position, cards: cards)
    }

    // MARK: - 甩牌分析

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
            let names = forced.keys.map { $0.displayName }.joined(separator: "、")
            state.message += "  [\(names) 被强制出牌]"
        }
    }

    // MARK: - 开始下一局

    func startNextRound() {
        state.lastRoundResult = nil
        startNewRound()
    }

    // MARK: - 联机同步

    func handleRemoteAction(_ action: MultiplayerAction) {
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
            phase: state.phase,
            trumpSuit: state.trumpSuit,
            trumpRank: state.trumpRank,
            trumpDeclaration: state.trumpDeclaration,
            dealtCount: state.dealtCount,
            isDealingFast: state.isDealingFast,
            dealerPosition: state.dealerPosition,
            currentTrick: trick,
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
        localPosition = snapshot.localPosition
        humanControlledPositions = [snapshot.localPosition]

        state.phase = snapshot.phase
        state.trumpSuit = snapshot.trumpSuit
        state.trumpRank = snapshot.trumpRank
        state.trumpDeclaration = snapshot.trumpDeclaration
        state.dealtCount = snapshot.dealtCount
        state.isDealingFast = snapshot.isDealingFast
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
