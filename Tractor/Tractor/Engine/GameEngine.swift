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

    func returnToMenuFromMultiplayer() {
        dealingTask?.cancel()
        localPosition = .south
        humanControlledPositions = [.south]
        state.selectedCards = []
        state.lastRoundResult = nil
        state.phase = .menu
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
            applyDeclaration(position: position, suit: nil, strength: 3)
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

        applyDeclaration(position: position, suit: suit, strength: strength)
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
        let tr      = state.trumpRank
        let cur     = state.declarationStrength
        let dealt   = state.dealtCount   // 0-100

        // ── 统计每花色级牌数量（非王）──────────────────
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank == tr {
            if let s = card.suit { counts[s, default: 0] += 1 }
        }

        // ── 王牌对反无主（小王或大王，覆盖 strength==2）──
        if cur == 2 {
            let bigCount   = hand.filter { $0.rank == .bigJoker }.count
            let smallCount = hand.filter { $0.rank == .smallJoker }.count
            if bigCount >= 2 || smallCount >= 2 {
                // 对王反无主限制：需要手中 ≥3 张 A 且 ≥3 对子（含连对），手牌强度足够才值得打无主
                let aceCount = hand.filter { $0.rank == .ace }.count
                var pairGroupMap: [String: Int] = [:]
                for card in hand {
                    let key = CardComparator.pairKey(card, trumpSuit: state.trumpSuit, trumpRank: tr)
                    pairGroupMap[key, default: 0] += 1
                }
                let pairCount = pairGroupMap.values.filter { $0 >= 2 }.count
                guard aceCount >= 3 && pairCount >= 3 else { return }
                applyDeclaration(position: position, suit: nil, strength: 3)
                return
            }
        }

        // ── 按发牌进度确定亮主门槛 ──────────────────────
        // dealt < 33  : 不亮（太早）
        // 33 ≤ dealt < 50  : 某花色 ≥ 5 张才亮
        // 50 ≤ dealt < 75  : 某花色 ≥ 8 张，或手中有某花色 < 3 张
        // dealt ≥ 75       : 某花色 ≥ 平均值（总张数 / 有牌花色数）
        guard dealt >= 33 else { return }

        func meetsThreshold(_ count: Int) -> Bool {
            if dealt < 50 {
                return count >= 5
            } else if dealt < 75 {
                if count >= 8 { return true }
                // 手中某花色少于3张时降低门槛（弱花色，尽早亮主保护）
                let minSuitCount = counts.values.min() ?? 0
                return minSuitCount < 3
            } else {
                // 后半程：达到平均水平即可亮
                let uniqueSuits = max(counts.count, 1)
                let avg = hand.filter { $0.rank == tr && !$0.isJoker }.count / uniqueSuits
                return count >= max(avg, 1)
            }
        }

        // ── 优先宣告对子 ──────────────────────────────
        if let best = counts.filter({ $0.value >= 2 && meetsThreshold($0.value) })
                            .max(by: { $0.value < $1.value }) {
            if cur < 2 {
                // 反不同花色限制（已有亮主时）：新花色级牌数须严格大于当前声明数；
                // 数量相同时须有更多对子；都相同则不反
                if cur > 0, state.trumpDeclaration?.suit != best.key {
                    let newCount  = best.value
                    let newPairs  = newCount / 2
                    let curPairs  = cur == 2 ? 1 : 0   // cur==1→单张0对; cur==2→1对
                    guard newCount > cur || (newCount == cur && newPairs > curPairs) else {
                        return
                    }
                }
                applyDeclaration(position: position, suit: best.key, strength: 2)
            }
            return
        }

        // ── 单张亮主（原规则：仅须满足发牌进度门槛，无额外手牌限制）────
        if cur == 0,
           let best = counts.filter({ meetsThreshold($0.value) })
                            .max(by: { $0.value < $1.value }) {
            applyDeclaration(position: position, suit: best.key, strength: 1)
        }
    }

    /// 应用亮主声明
    /// 亮主更新主花色，并将庄家设为亮主玩家（标准拖拉机规则：谁亮主谁坐庄）
    private func applyDeclaration(position: PlayerPosition, suit: Suit?, strength: Int) {
        state.trumpSuit = suit          // nil = 无主
        state.trumpDeclaration = TrumpDeclaration(
            declarer: position,
            suit: suit,
            strength: strength
        )
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
        state.message = "\(position.displayName) 亮主：\(suitStr)\(strength < 3 ? state.trumpRank.display : "") \(badge)"
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

        state.phase        = .kittyExchange
        state.currentTurn  = state.dealerPosition   // 让庄家手牌可交互

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
        SoundManager.shared.playCardSlap()
        state.player(position).play(cards: cards)
        state.currentTrick.plays.append((position: position, cards: cards))
        state.selectedCards = []
        state.message = "\(position.displayName) 出了 \(cards.map { $0.shortDisplay }.joined(separator: " "))"

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
                forcedParts.append("\(pos.displayName)有[\(display)]")
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
            let names = forced.keys.map { $0.displayName }.joined(separator: "、")
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
