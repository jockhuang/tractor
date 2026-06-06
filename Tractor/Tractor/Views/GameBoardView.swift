import SwiftUI

struct GameBoardView: View {
    @ObservedObject var engine: GameEngine
    @State private var showHistory = false
    @State private var soundEnabled = SoundManager.shared.soundEnabled

    private var state: GameState { engine.state }
    private var localPosition: PlayerPosition { engine.localPosition }
    private var leftPosition: PlayerPosition { relativePosition(offset: 1) }
    private var topPosition: PlayerPosition { relativePosition(offset: 2) }
    private var rightPosition: PlayerPosition { relativePosition(offset: 3) }

    private var selectedCardsBinding: Binding<Set<UUID>> {
        Binding(
            get: { self.engine.state.selectedCards },
            set: { self.engine.state.selectedCards = $0 }
        )
    }

    private var scoreBgColor: Color {
        state.attackScore >= 80 ? Color.green.opacity(0.55) : Color.black.opacity(0.55)
    }
    private var historyBgColor: Color {
        showHistory ? Color.blue.opacity(0.7) : Color.black.opacity(0.55)
    }
    private var requiredPlayCardCount: Int? {
        state.currentTrick.leadCards?.count
    }
    private var canSubmitPlay: Bool {
        guard state.phase == .playing,
              state.currentTurn == localPosition else { return false }

        if let required = requiredPlayCardCount {
            return state.selectedCards.count == required
        }
        return !state.selectedCards.isEmpty
    }
    private var playButtonTitle: String {
        if let required = requiredPlayCardCount {
            return "出牌 (\(state.selectedCards.count)/\(required)张)"
        }
        return "出牌 (\(state.selectedCards.count)张)"
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = GameBoardMetrics(size: proxy.size)

        ZStack {
            // ── 横屏主布局 ──────────────────────────────
            VStack(spacing: 0) {

                // 中间区域：西 | 北+桌面 | 东
                HStack(spacing: 0) {

                    // 左侧玩家
                    sideAIArea(position: leftPosition, metrics: metrics)
                        .frame(width: metrics.sideRailWidth)

                    // 中央：对家 + 桌面
                    VStack(spacing: 0) {
                        topAIArea(position: topPosition, metrics: metrics)
                            .padding(.top, metrics.topPlayerPadding)

                        // 桌面中央
                        centerArea(metrics: metrics)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 右侧玩家
                    sideAIArea(position: rightPosition, metrics: metrics)
                        .frame(width: metrics.sideRailWidth)
                }
                .frame(maxHeight: .infinity)

                // 南家手牌区（包含发牌/换底信息栏）
                southArea(metrics: metrics)
            }
            .frame(maxWidth: metrics.boardMaxWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity)

            // 局结算覆层
            if let result = state.lastRoundResult, state.phase == .roundEnd {
                RoundResultView(
                    result: result,
                    teamLevels: state.teamLevels,
                    canStartNext: !engine.multiplayer.isClient,
                    onNext: {
                        engine.startNextRound()
                    },
                    onQuit: {
                        engine.multiplayer.leave()
                        withAnimation { engine.state.phase = .menu }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // 游戏结束覆层
            if state.phase == .gameOver {
                GameOverView(
                    teamLevels: state.teamLevels,
                    localTeam: engine.localPlayer.team,
                    onRestart: { engine.startNewGame() },
                    onQuit: {
                        engine.multiplayer.leave()
                        withAnimation { engine.state.phase = .menu }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // ── 常驻顶部浮层：主牌（左上）+ 分数（右上）+ 历史（右上角）
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    // 左上：当前主牌
                    HStack(spacing: 4) {
                        Text("主")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                        if let suit = state.trumpSuit {
                            Text(suit.rawValue)
                                .font(.system(size: 15))
                                .foregroundColor(suit.color == "red" ? .red : .white)
                        } else {
                            Text("—")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Text(state.trumpRank.display)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())

                    Spacer()

                    // 右上：攻方得分
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                        Text("攻 \(state.attackScore)分")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(scoreBgColor)
                    .clipShape(Capsule())

                    // 历史记录按钮
                    if !state.completedTricks.isEmpty || !state.declarationEvents.isEmpty {
                        Button(action: { showHistory.toggle() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                Text("记录")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(historyBgColor)
                            .clipShape(Capsule())
                        }
                    }

                    // 音效开关
                    Button(action: {
                        soundEnabled.toggle()
                        SoundManager.shared.soundEnabled = soundEnabled
                        if !soundEnabled { SoundManager.shared.stopAll() }
                    }) {
                        Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, metrics.overlayHorizontalPadding)
                .padding(.top, metrics.overlayTopPadding)

                Spacer()
            }
            .allowsHitTesting(true)

            // ── 历史出牌记录面板 ─────────────────────────
            if showHistory {
                TrickHistoryPanel(
                    tricks: state.completedTricks,
                    declarationEvents: state.declarationEvents,
                    trumpSuit: state.trumpSuit,
                    trumpRank: state.trumpRank,
                    playerNames: state.playerNames,
                    onClose: { showHistory = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            // ── 悬浮消息 toast（不占用布局空间）────────────
            if !state.message.isEmpty {
                VStack {
                    Spacer()
                    Text(state.message)
                        .font(.system(size: metrics.messageFontSize))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.07, green: 0.35, blue: 0.12),
                    Color(red: 0.05, green: 0.25, blue: 0.09)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.3), value: state.phase)
        .animation(.easeInOut(duration: 0.2), value: showHistory)
        .animation(.easeInOut(duration: 0.25), value: state.message)
        }
    }

    // MARK: - 对家（横屏顶部，水平展示）
    private func topAIArea(position: PlayerPosition, metrics: GameBoardMetrics) -> some View {
        HStack(spacing: 8) {
            if state.currentTurn == position {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
            MiniCardBack(count: state.player(position).hand.count, cardHeight: metrics.topMiniCardHeight)
            HStack(spacing: 3) {
                if state.dealerPosition == position {
                    Text("👑").font(.system(size: 11))
                }
                Text("\(displayName(for: position))  \(state.player(position).hand.count)张")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            state.currentTurn == position
                ? Color.yellow.opacity(0.15)
                : Color.black.opacity(0.15)
        )
        .clipShape(Capsule())
    }

    // MARK: - 侧方 AI（西/东，竖排显示）
    private func sideAIArea(position: PlayerPosition, metrics: GameBoardMetrics) -> some View {
        let isActive = state.currentTurn == position
        let count = state.player(position).hand.count

        return VStack(spacing: 6) {
            Spacer()
            if isActive {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .padding(4)
                    .background(Color.yellow.opacity(0.2))
                    .clipShape(Circle())
            }
            // 竖向叠牌效果
            ZStack {
                ForEach(0..<min(count, 6), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.12, green: 0.28, blue: 0.68),
                                Color(red: 0.05, green: 0.15, blue: 0.45)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 30, height: 44)
                        .scaleEffect(metrics.sideCardScale)
                        .offset(y: (CGFloat(i) * 3 - CGFloat(min(count, 6)) * 1.5) * metrics.sideCardScale)
                        .shadow(color: .black.opacity(0.2), radius: 1)
                }
            }
            .frame(height: 60 * metrics.sideCardScale)
            HStack(spacing: 2) {
                if state.dealerPosition == position {
                    Text("👑").font(.system(size: 10))
                }
                Text(displayName(for: position))
                    .font(.caption2.bold())
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text("\(count)张")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isActive
                ? Color.yellow.opacity(0.08)
                : Color.black.opacity(0.08)
        )
    }

    // MARK: - 中央桌面
    private func centerArea(metrics: GameBoardMetrics) -> some View {
        ZStack(alignment: .bottom) {
            TrickAreaView(
                trick: state.currentTrick,
                trumpSuit: state.trumpSuit,
                trumpRank: state.trumpRank,
                localPosition: localPosition,
                layoutScale: metrics.trickAreaScale
            )
            if state.currentTurn == localPosition && state.phase == .playing {
                Text("轮到你出牌")
                    .font(.caption.bold())
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 南家手牌区
    private func southArea(metrics: GameBoardMetrics) -> some View {
        VStack(spacing: 0) {

            // ── 常驻：南家标识（含庄家皇冠）────────────
            HStack(spacing: 6) {
                if state.dealerPosition == localPosition {
                    Text("👑").font(.system(size: 11))
                }
                Text(localPlayerLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // ── 阶段操作栏（ZStack 固定高度，避免切换时布局抖动）─
            ZStack(alignment: .top) {
                // 发牌阶段：亮主面板（最高，决定 ZStack 高度）
                DealingOverlayView(engine: engine)
                    .opacity(state.phase == .dealing ? 1 : 0)
                    .allowsHitTesting(state.phase == .dealing)

                // 换底阶段：紧凑换底栏
                KittyInfoBar(
                    selectedCount: state.selectedCards.count,
                    onConfirm: {
                        engine.confirmKittyExchange(selectedIDs: state.selectedCards)
                    }
                )
                .opacity(state.phase == .kittyExchange && state.dealerPosition == localPosition ? 1 : 0)
                .allowsHitTesting(state.phase == .kittyExchange && state.dealerPosition == localPosition)

                // 出牌阶段：出牌操作栏
                HStack(spacing: 10) {
                    teamBadge(team: engine.localPlayer.team)
                    HStack(spacing: 3) {
                        if state.dealerPosition == localPosition {
                            Text("👑").font(.system(size: 12))
                        }
                        Text(localPlayerLabel)
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer()
                    Button(action: {
                        engine.humanPlay(selectedIDs: state.selectedCards)
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text(playButtonTitle)
                                .font(.caption.bold())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(canSubmitPlay ? Color.blue : Color.gray.opacity(0.5))
                        .clipShape(Capsule())
                        .shadow(color: .blue.opacity(0.3), radius: 3)
                    }
                    .disabled(!canSubmitPlay)
                    .opacity(state.currentTurn == localPosition ? 1 : 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.22))
                .opacity(state.phase == .playing ? 1 : 0)
                .allowsHitTesting(state.phase == .playing)
            }

            // ── 手牌（始终可见）────────────────────────
            PlayerHandView(
                player: engine.localPlayer,
                selectedCards: selectedCardsBinding,
                isActive: state.currentTurn == localPosition &&
                    (state.phase == .playing || state.phase == .kittyExchange),
                canSelect: state.phase == .playing || state.phase == .kittyExchange
                    || state.phase == .dealing,
                lastDrawnCardId: state.lastDrawnCardId,
                cardScale: metrics.handCardScale
            )
            .background(Color.black.opacity(0.12))
        }
    }

    private func teamBadge(team: Int) -> some View {
        let color: Color = team == 0 ? .blue : .orange
        let label = team == state.dealerTeamIdx ? "庄" : "攻"
        return Text(label)
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }

    private var localPlayerLabel: String {
        let name = displayName(for: localPosition)
        if engine.multiplayer.mode != .none || !state.playerNames.isEmpty {
            return "\(name)（\(localPosition.seatName)）"
        }
        return name
    }

    private func displayName(for position: PlayerPosition) -> String {
        state.displayName(for: position)
    }

    private func relativePosition(offset: Int) -> PlayerPosition {
        let order: [PlayerPosition] = [.south, .west, .north, .east]
        let localIndex = order.firstIndex(of: localPosition) ?? 0
        return order[(localIndex + offset) % order.count]
    }
}

private struct GameBoardMetrics {
    let size: CGSize

    private var isTabletCanvas: Bool {
        size.width >= 900 && size.height >= 600
    }

    var boardMaxWidth: CGFloat {
        isTabletCanvas ? min(size.width, 1180) : .infinity
    }

    var sideRailWidth: CGFloat {
        isTabletCanvas ? min(108, max(86, size.width * 0.085)) : 72
    }

    var topPlayerPadding: CGFloat {
        isTabletCanvas ? 10 : 4
    }

    var overlayHorizontalPadding: CGFloat {
        isTabletCanvas ? 18 : 10
    }

    var overlayTopPadding: CGFloat {
        isTabletCanvas ? 12 : 6
    }

    var messageFontSize: CGFloat {
        isTabletCanvas ? 14 : 12
    }

    var handCardScale: CGFloat {
        guard isTabletCanvas else { return 1 }
        return min(1.22, max(1.12, size.height / 680))
    }

    var trickAreaScale: CGFloat {
        guard isTabletCanvas else { return 1 }
        return min(1.42, max(1.24, size.height / 580))
    }

    var sideCardScale: CGFloat {
        guard isTabletCanvas else { return 1 }
        return min(1.18, max(1.05, size.height / 720))
    }

    var topMiniCardHeight: CGFloat {
        isTabletCanvas ? 34 : 28
    }
}

// MARK: - Game Over
struct GameOverView: View {
    let teamLevels: [Int: Rank]
    let localTeam: Int
    let onRestart: () -> Void
    let onQuit: () -> Void

    private var winnerTeam: Int {
        let southNorth = teamLevels[0]?.rawValue ?? 0
        let eastWest   = teamLevels[1]?.rawValue ?? 0
        return southNorth >= eastWest ? 0 : 1
    }

    private var winner: String {
        winnerTeam == 0 ? "南北队" : "东西队"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            HStack(spacing: 40) {
                VStack(spacing: 16) {
                    Text(winnerTeam == localTeam ? "🎊" : "😔")
                        .font(.system(size: 48))
                    Text("\(winner) 获胜！")
                        .font(.title2.bold())
                        .foregroundColor(.yellow)
                }

                HStack(spacing: 24) {
                    levelDisplay(name: "南北", team: 0)
                    levelDisplay(name: "东西", team: 1)
                }

                VStack(spacing: 12) {
                    Button(action: onQuit) {
                        Text("主菜单")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Button(action: onRestart) {
                        Text("再来一局 ↺")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(28)
            .background(Color(red: 0.1, green: 0.12, blue: 0.28))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private func levelDisplay(name: String, team: Int) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.caption).foregroundColor(.white.opacity(0.6))
            Text(teamLevels[team]?.display ?? "2")
                .font(.title.bold()).foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
        }
    }
}
