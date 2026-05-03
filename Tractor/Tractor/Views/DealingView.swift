import SwiftUI

/// 发牌阶段顶部面板：进度条 + 常驻亮主/反主按钮
struct DealingOverlayView: View {
    @ObservedObject var engine: GameEngine

    private var state: GameState { engine.state }
    private var tr: Rank { state.trumpRank }

    /// 人类手中每花色的级牌数量（非王）
    private var suitCounts: [Suit: Int] {
        var d: [Suit: Int] = [:]
        for card in engine.localPlayer.hand where card.rank == tr && !card.isJoker {
            if let s = card.suit { d[s, default: 0] += 1 }
        }
        return d
    }

    private var smallJokerCount: Int {
        engine.localPlayer.hand.filter { $0.rank == .smallJoker }.count
    }
    private var bigJokerCount: Int {
        engine.localPlayer.hand.filter { $0.rank == .bigJoker }.count
    }

    var body: some View {
        HStack(spacing: 14) {

            // ── 进度 ───────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                Text("发牌 \(state.dealtCount)/100")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                progressBar
            }

            // ── 当前亮主 ───────────────────────────────
            declarationBadge

            Spacer()

            // ── 亮主按钮（4花色 + 无主）──────────────
            HStack(spacing: 8) {
                ForEach(Suit.allCases, id: \.self) { suit in
                    suitButton(suit: suit)
                }
                noTrumpButton
            }

            // ── 倒计时（发牌结束后思考时间）─────────────
            Text("\(state.postDealCountdown)")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(state.postDealCountdown <= 3 ? .red : .yellow)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1))
                .opacity(state.postDealCountdown > 0 ? 1 : 0)

            // ── 快速发牌 ───────────────────────────────
            Button(action: { engine.toggleFastDealing() }) {
                Image(systemName: state.isDealingFast
                      ? "forward.fill" : "forward")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(7)
                    .background(state.isDealingFast
                        ? Color.orange.opacity(0.7)
                        : Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.40))
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.green.opacity(0.75))
                    .frame(width: geo.size.width * CGFloat(state.dealtCount) / 100)
                    .animation(.linear(duration: 0.15), value: state.dealtCount)
            }
        }
        .frame(width: 64, height: 5)
    }

    // MARK: - 当前亮主徽章

    private var declarationBadge: some View {
        Group {
            if let decl = state.trumpDeclaration {
                HStack(spacing: 4) {
                    if let suit = decl.suit {
                        Text(suit.rawValue)
                            .font(.system(size: 15))
                            .foregroundColor(suit.color == "red" ? .red : .white)
                    } else {
                        // 无主：显示王牌图标
                        Text(decl.strength == 4 ? "🃏" : "🂿")
                            .font(.system(size: 14))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(decl.declarer.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                        Text(badgeLabel(decl.strength))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("暂无亮主")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func badgeLabel(_ strength: Int) -> String {
        switch strength {
        case 1: return "单张"
        case 2: return "对子"
        case 3: return "王牌·无主"
        default: return ""
        }
    }

    // MARK: - 花色亮主按钮

    private func suitButton(suit: Suit) -> some View {
        let count    = suitCounts[suit] ?? 0
        let strength = min(count, 2)
        let canUse   = count > 0 && strength > state.declarationStrength
        let isRed    = suit.color == "red"

        return Button(action: {
            guard canUse else { return }
            // 自动选同花色前 strength 张级牌并亮主
            let picks = engine.localPlayer.hand
                .filter { $0.rank == tr && !$0.isJoker && $0.suit == suit }
                .prefix(strength)
            engine.state.selectedCards = Set(picks.map { $0.id })
            engine.humanDeclareTrump()
        }) {
            VStack(spacing: 2) {
                Text(suit.rawValue)
                    .font(.system(size: 18))
                    .foregroundColor(canUse
                        ? (isRed ? .red : .white)
                        : .white.opacity(0.25))
                // 小圆点指示器（有几张级牌）
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .frame(width: 4, height: 4)
                            .foregroundColor(
                                i < count
                                    ? (canUse ? .yellow : .white.opacity(0.3))
                                    : .white.opacity(0.08)
                            )
                    }
                }
            }
            .frame(width: 36, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(canUse
                        ? (strength >= 2 ? Color.blue.opacity(0.5) : Color.green.opacity(0.35))
                        : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        canUse ? Color.white.opacity(0.4) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .disabled(!canUse)
    }

    // MARK: - 无主按钮（小王对或大王对，覆盖 strength==2）

    private var noTrumpButton: some View {
        let cur      = state.declarationStrength
        let jokers   = smallJokerCount + bigJokerCount   // 用于指示点数量
        let hasPair  = smallJokerCount >= 2 || bigJokerCount >= 2
        let canUse   = hasPair && cur == 2
        return Button(action: {
            guard canUse else { return }
            // 优先选大王，其次小王
            let rank: Rank = bigJokerCount >= 2 ? .bigJoker : .smallJoker
            let picks = engine.localPlayer.hand.filter { $0.rank == rank }.prefix(2)
            engine.state.selectedCards = Set(picks.map { $0.id })
            engine.humanDeclareTrump()
        }) {
            VStack(spacing: 2) {
                Text("无主")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(canUse ? .white : .white.opacity(0.22))
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .frame(width: 4, height: 4)
                            .foregroundColor(
                                i < min(jokers, 2)
                                    ? (canUse ? .yellow : .white.opacity(0.3))
                                    : .white.opacity(0.08)
                            )
                    }
                }
            }
            .frame(width: 36, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(canUse ? Color.purple.opacity(0.45) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        canUse ? Color.white.opacity(0.4) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .disabled(!canUse)
    }
}
