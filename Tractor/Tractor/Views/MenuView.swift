import SwiftUI
import StoreKit

struct MenuView: View {
    @ObservedObject var engine: GameEngine
    @EnvironmentObject private var adsManager: AdsManager

    @State private var showRules = false
    @State private var showLobby = false
    @State private var showRemoveAds = false
    @State private var soundEnabled = SoundManager.shared.soundEnabled
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? L10n.text("menu.version_unknown")
    }

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
                .allowsHitTesting(false)

            // 横屏：左右分栏布局
            HStack(spacing: 0) {
                // 左侧：标题区
                VStack(spacing: 10) {
                    Spacer()
                    Text(L10n.text("升 级"))
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    Text(L10n.text("拖拉机 · 单机版"))
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
                            Text(L10n.text("开始游戏")).font(.title3.bold())
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
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(isOn: $engine.easyModeEnabled) {
                            Label(L10n.text("欢乐模式"), systemImage: "sparkles")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .tint(.yellow)

                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button(action: { showLobby.toggle() }) {
                        HStack {
                            Image(systemName: "network")
                            Text(L10n.text("局域网联机")).font(.headline)
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
                            Text(L10n.text("游戏规则")).font(.headline)
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

                    Button(action: { showRemoveAds = true }) {
                        HStack {
                            Image(systemName: adsManager.hasActiveRemoveAdsSubscription
                                ? "checkmark.shield.fill"
                                : "nosign")
                            Text(adsManager.hasActiveRemoveAdsSubscription
                                ? L10n.text("ads.subscription_active")
                                : removeAdsMenuTitle)
                                .font(.headline)
                        }
                        .foregroundColor(adsManager.hasActiveRemoveAdsSubscription ? .green : .yellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background((adsManager.hasActiveRemoveAdsSubscription ? Color.green : .yellow).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    (adsManager.hasActiveRemoveAdsSubscription ? Color.green : .yellow).opacity(0.3),
                                    lineWidth: 1
                                )
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
                    Text(L10n.format("menu.version_format", appVersion))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))

                    Spacer()

                    if adsManager.isPrivacyOptionsRequired {
                        Button {
                            Task { await adsManager.presentPrivacyOptions() }
                        } label: {
                            Label(L10n.text("ads.privacy_choices"), systemImage: "hand.raised.fill")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }

                    Link(
                        L10n.text("ads.privacy_policy"),
                        destination: URL(string: "https://jock.kiwi/tractor-privacy-policy.html")!
                    )
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                    // 音效开关
                    Button(action: {
                        soundEnabled.toggle()
                        SoundManager.shared.soundEnabled = soundEnabled
                        if !soundEnabled { SoundManager.shared.stopAll() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 12))
                            Text(L10n.text(soundEnabled ? "音效开" : "音效关"))
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
        .sheet(isPresented: $showRemoveAds) {
            RemoveAdsSubscriptionView()
        }
    }

    private var removeAdsMenuTitle: String {
        guard let product = adsManager.removeAdsSubscriptionProduct,
              let period = product.localizedSubscriptionPeriod else {
            return L10n.text("ads.remove_ads")
        }
        return L10n.format("ads.remove_ads_price", product.displayPrice, period)
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

            CardView(card: Card(suit: .clubs, rank: .king))
                .rotationEffect(.degrees(-8))
                .offset(x: 240, y: 190)
                .opacity(0.25)

            CardView(card: Card(suit: .diamonds, rank: .ace))
                .rotationEffect(.degrees(20))
                .offset(x: -130, y: 150)
                .opacity(0.4)
        }
    }
}

private struct RemoveAdsSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var adsManager: AdsManager
    @State private var showManageSubscriptions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: adsManager.hasAdFreeAccess ? "checkmark.shield.fill" : "nosign")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundColor(adsManager.hasAdFreeAccess ? .green : .yellow)

                Text(L10n.text(adsManager.hasAdFreeAccess ? "ads.removed" : "ads.remove_ads"))
                    .font(.title2.bold())

                Text(L10n.text("ads.remove_ads_description"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                if adsManager.hasActiveRemoveAdsSubscription {
                    Label(L10n.text("ads.purchase_active"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.headline)

                    Button(L10n.text("ads.manage_subscription")) {
                        showManageSubscriptions = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    purchaseControls
                }

                Text(L10n.text("ads.subscription_terms"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                HStack(spacing: 16) {
                    Link(
                        L10n.text("ads.privacy_policy"),
                        destination: URL(
                            string: "https://jock.kiwi/tractor-privacy-policy.html"
                        )!
                    )

                    Link(
                        L10n.text("ads.terms_of_use"),
                        destination: URL(
                            string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
                        )!
                    )
                }
                .font(.caption)

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundColor(statusIsError ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(28)
            .navigationTitle(L10n.text("ads.remove_ads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
            .task {
                await adsManager.loadRemoveAdsProductIfNeeded()
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        }
    }

    @ViewBuilder
    private var purchaseControls: some View {
        if let product = adsManager.removeAdsSubscriptionProduct,
           let period = product.localizedSubscriptionPeriod {
            Button {
                Task { await adsManager.subscribeToRemoveAds() }
            } label: {
                Text(L10n.format("ads.buy_for_price", product.displayPrice, period))
                    .font(.headline)
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .disabled(adsManager.isRemoveAdsStoreBusy)
        } else if adsManager.removeAdsStoreStatus == .loadingProduct {
            ProgressView(L10n.text("ads.loading_product"))
        } else {
            Button(L10n.text("ads.retry")) {
                Task { await adsManager.loadRemoveAdsProductIfNeeded(forceReload: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(adsManager.isRemoveAdsStoreBusy)
        }

        Button(L10n.text("ads.restore_purchases")) {
            Task { await adsManager.restoreRemoveAdsSubscription() }
        }
        .buttonStyle(.bordered)
        .disabled(adsManager.isRemoveAdsStoreBusy)
    }

    private var statusIsError: Bool {
        adsManager.removeAdsStoreStatus == .failed ||
            adsManager.removeAdsStoreStatus == .unavailable
    }

    private var statusText: String? {
        switch adsManager.removeAdsStoreStatus {
        case .idle, .ready:
            return nil
        case .loadingProduct:
            return L10n.text("ads.loading_product")
        case .purchasing:
            return L10n.text("ads.purchasing")
        case .pending:
            return L10n.text("ads.purchase_pending")
        case .purchased:
            return L10n.text("ads.purchase_success")
        case .restoring:
            return L10n.text("ads.restoring")
        case .restored:
            return L10n.text("ads.restore_success")
        case .nothingToRestore:
            return L10n.text("ads.nothing_to_restore")
        case .unavailable:
            return L10n.text("ads.product_unavailable")
        case .failed:
            return adsManager.removeAdsStoreError ?? L10n.text("ads.purchase_failed")
        }
    }
}

private extension Product {
    var localizedSubscriptionPeriod: String? {
        guard let period = subscription?.subscriptionPeriod else { return nil }

        var components = DateComponents()
        switch period.unit {
        case .day:
            components.day = period.value
        case .week:
            components.weekOfMonth = period.value
        case .month:
            components.month = period.value
        case .year:
            components.year = period.value
        @unknown default:
            return nil
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: components)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("联机名字"))
                        .font(.headline)
                    TextField(L10n.text("输入你的名字"), text: $multiplayer.localPlayerName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(multiplayer.mode != .none)
                        .onSubmit {
                            multiplayer.commitLocalPlayerName()
                        }
                    if multiplayer.mode != .none {
                        Text(L10n.text("断开当前房间后可修改名字。"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(action: { multiplayer.hostGame() }) {
                        Label(L10n.text("发起房间"), systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { multiplayer.browseGames() }) {
                        Label(L10n.text("搜索加入"), systemImage: "magnifyingglass")
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
                    SectionHeader(L10n.text("可加入房间"))
                    ForEach(Array(multiplayer.discoveredHosts.enumerated()), id: \.offset) { _, host in
                        Button(action: { multiplayer.join(host) }) {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                Text(host.displayName)
                                Spacer()
                                Text(L10n.text("加入"))
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SectionHeader(L10n.text("当前房间"))
                if multiplayer.lobby.players.isEmpty {
                    Text(L10n.text("还没有房间。发起房间或搜索附近房主。"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(multiplayer.lobby.players) { player in
                        HStack {
                            Image(systemName: player.isHost ? "crown.fill" : "person.fill")
                                .foregroundColor(player.isHost ? .yellow : .blue)
                            Text(player.name)
                            Spacer()
                            Text(player.position?.seatName ?? L10n.text("待分配"))
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
                        Label(L10n.text("随机分组并开始"), systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if multiplayer.isClient {
                    Text(L10n.text("等待房主开始。未满 4 人时，空位会由 AI 接管。"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(20)
            .navigationTitle(L10n.text("局域网联机"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("断开")) { multiplayer.leave() }
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
                    ruleSection(title: L10n.text("基本规则"), content: L10n.text("rules.basic.body"))
                    ruleSection(title: L10n.text("主牌体系"), content: L10n.text("rules.trump.body"))
                    ruleSection(title: L10n.text("出牌"), content: L10n.text("rules.play.body"))
                    ruleSection(title: L10n.text("计分"), content: L10n.text("rules.scoring.body"))
                    ruleSection(title: L10n.text("升级"), content: L10n.text("rules.level.body"))
                }
                .padding(20)
            }
            .navigationTitle(L10n.text("游戏规则"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("完成")) { dismiss() }
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
