import SwiftUI

struct RoundResultView: View {
    let result: RoundResult
    let teamLevels: [Int: Rank]
    let onNext: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // 标题
                    Text(result.attackTeamWon ? "🎉 攻方胜利" : "🏆 庄家方守住")
                        .font(.title.bold())
                        .foregroundColor(result.attackTeamWon ? .yellow : .cyan)

                    // 底牌展示
                    kittySection

                    // 得分详情
                    VStack(spacing: 10) {
                        scoreRow(label: "攻方得分", value: "\(result.attackScore) 分",
                                 note: result.attackScore >= 80 ? "≥80 分，赢" : "<80 分，输")

                        Divider().background(Color.white.opacity(0.3))

                        if result.attackTeamWon {
                            upgradeRow(label: "攻方升级", steps: result.attackAdvance)
                        } else {
                            upgradeRow(label: "庄家方升级", steps: result.levelAdvance)
                        }
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // 当前级别
                    HStack(spacing: 32) {
                        teamLevel(name: "南北", team: 0)
                        teamLevel(name: "东西", team: 1)
                    }

                    // 按钮
                    HStack(spacing: 20) {
                        Button(action: onQuit) {
                            Text("退出")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Button(action: onNext) {
                            Text("下一局 →")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(28)
            }
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(red: 0.1, green: 0.15, blue: 0.3))
            )
            .padding(.horizontal, 24)
        }
    }

    // MARK: - 底牌展示区

    @ViewBuilder
    private var kittySection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("底牌")
                    .font(.subheadline.bold())
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                if result.rawKittyPoints > 0 && result.attackTeamWon {
                    Text("×\(result.kittyMultiplier) → +\(result.rawKittyPoints * result.kittyMultiplier) 分")
                        .font(.caption.bold())
                        .foregroundColor(.yellow)
                } else if result.attackTeamWon {
                    Text("底牌无分")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("庄家保底")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            if result.kittyCards.isEmpty {
                Text("—")
                    .foregroundColor(.white.opacity(0.4))
                    .font(.caption)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(result.kittyCards) { card in
                            CardView(card: card, isSmall: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func scoreRow(label: String, value: String, note: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.headline.bold())
                .foregroundColor(.white)
            Text(note)
                .font(.caption)
                .foregroundColor(result.attackTeamWon ? .green : .orange)
        }
    }

    private func upgradeRow(label: String, steps: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text("+\(steps) 级")
                .font(.headline.bold())
                .foregroundColor(.yellow)
        }
    }

    private func teamLevel(name: String, team: Int) -> some View {
        let level = teamLevels[team] ?? .two
        return VStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            Text(level.display)
                .font(.title2.bold())
                .foregroundColor(.white)
                .frame(width: 50, height: 50)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
        }
    }
}
