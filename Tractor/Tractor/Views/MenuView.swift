import SwiftUI

struct MenuView: View {
    @ObservedObject var engine: GameEngine

    @State private var showRules = false
    @State private var showLobby = false
    @State private var soundEnabled = SoundManager.shared.soundEnabled

    var body: some View {
        ZStack {
            // 渐变背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.08, green: 0.14, blue: 0.32),
                    Color(red: 0.04, green: 0.28, blue: 0.18)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // 装饰牌
            decorativeCards

            // 横屏：左右分栏布局
            HStack(spacing: 0) {
                // 左侧：标题区
                VStack(spacing: 10) {
                    Spacer()
                    Text("升 级")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    Text("拖拉机 · 单机版")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))
                        .tracking(4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // 右侧：按钮区
                VStack(spacing: 14) {
                    Spacer()
                    Button(action: { engine.startNewGame() }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("开始游戏").font(.title3.bold())
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue, Color(red: 0.1, green: 0.4, blue: 0.9)]),
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .blue.opacity(0.4), radius: 8, y: 4)
                    }
                    Button(action: { showLobby.toggle() }) {
                        HStack {
                            Image(systemName: "network")
                            Text("局域网联机").font(.headline)
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        )
                    }
                    Button(action: { showRules.toggle() }) {
                        HStack {
                            Image(systemName: "book.fill")
                            Text("游戏规则").font(.headline)
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)

            }
            .padding(.vertical, 12)

            // 底部：版本号 + 音效开关
            VStack {
                Spacer()
                HStack {
                    Text("版本 1.0  ·  南北 vs 东西")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))

                    Spacer()

                    // 音效开关
                    Button(action: {
                        soundEnabled.toggle()
                        SoundManager.shared.soundEnabled = soundEnabled
                        if !soundEnabled { SoundManager.shared.stopAll() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 12))
                            Text(soundEnabled ? "音效开" : "音效关")
                                .font(.caption)
                        }
                        .foregroundColor(soundEnabled ? .white.opacity(0.7) : .white.opacity(0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showRules) {
            RulesView()
        }
        .sheet(isPresented: $showLobby) {
            LANLobbyView(engine: engine)
        }
    }

    private var decorativeCards: some View {
        ZStack {
            CardView(card: Card(suit: .spades, rank: .ace))
                .rotationEffect(.degrees(-15))
                .offset(x: -140, y: -160)
                .opacity(0.5)

            CardView(card: Card(suit: .hearts, rank: .king))
                .rotationEffect(.degrees(12))
                .offset(x: 130, y: -180)
                .opacity(0.5)

            CardView(card: Card(suit: nil, rank: .bigJoker))
                .rotationEffect(.degrees(-8))
                .offset(x: 150, y: 120)
                .opacity(0.4)

            CardView(card: Card(suit: .diamonds, rank: .ace))
                .rotationEffect(.degrees(20))
                .offset(x: -130, y: 150)
                .opacity(0.4)
        }
    }
}

struct LANLobbyView: View {
    @ObservedObject var engine: GameEngine
    @ObservedObject private var multiplayer: LANMultiplayerManager
    @Environment(\.dismiss) private var dismiss

    init(engine: GameEngine) {
        self.engine = engine
        self._multiplayer = ObservedObject(wrappedValue: engine.multiplayer)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Button(action: { multiplayer.hostGame() }) {
                        Label("发起房间", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { multiplayer.browseGames() }) {
                        Label("搜索加入", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !multiplayer.statusText.isEmpty {
                    Text(multiplayer.statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if multiplayer.isClient && !multiplayer.discoveredHosts.isEmpty {
                    SectionHeader("可加入房间")
                    ForEach(Array(multiplayer.discoveredHosts.enumerated()), id: \.offset) { _, host in
                        Button(action: { multiplayer.join(host) }) {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                Text(host.displayName)
                                Spacer()
                                Text("加入")
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SectionHeader("当前房间")
                if multiplayer.lobby.players.isEmpty {
                    Text("还没有房间。发起房间或搜索附近房主。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(multiplayer.lobby.players) { player in
                        HStack {
                            Image(systemName: player.isHost ? "crown.fill" : "person.fill")
                                .foregroundColor(player.isHost ? .yellow : .blue)
                            Text(player.name)
                            Spacer()
                            Text(player.position?.displayName ?? "待分配")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Spacer()

                if multiplayer.isHost {
                    Button(action: {
                        multiplayer.startHostedGame()
                        dismiss()
                    }) {
                        Label("随机分组并开始", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if multiplayer.isClient {
                    Text("等待房主开始。未满 4 人时，空位会由 AI 接管。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(20)
            .navigationTitle("局域网联机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("断开") { multiplayer.leave() }
                }
            }
            .onChange(of: multiplayer.mode) { _, mode in
                if mode == .none {
                    dismiss()
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

// MARK: - Rules View
struct RulesView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ruleSection(title: "基本规则", content: """
• 4人游戏：南北 vs 东西，两两一队
• 使用两副完整扑克牌（108张），含大小王
• 庄家方持有当前"级"（从2开始，逐步升到A）
""")
                    ruleSection(title: "主牌体系", content: """
• 庄家方亮出"主花色"
• 主牌由高到低：大王 > 小王 > 主花色级牌 > 其他花色级牌 > 主花色其他牌
• 级牌无论什么花色都是主牌
""")
                    ruleSection(title: "出牌", content: """
• 先手可以出单张、对子、连对（拖拉机）
• 跟牌必须跟同花色，不够时可以补其他牌
• 非主牌不能压主，主牌可以压任意非主
""")
                    ruleSection(title: "计分", content: """
• 5 = 5分，10 = 10分，K = 10分
• 攻方（非庄家方）累计 ≥ 80分则赢得本局
• 最后一墩赢家拿底牌分 ×2
""")
                    ruleSection(title: "升级", content: """
• 庄家方赢：根据攻方得分，庄家方升 1~3 级
• 攻方赢：攻方成为下一局庄家
• 超过120分升1级，超过160分升2级
• 率先升到 A 且赢得一局者获胜
""")
                }
                .padding(20)
            }
            .navigationTitle("游戏规则")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func ruleSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.bold())
                .foregroundColor(.primary)

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
