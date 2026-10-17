import SwiftUI

struct RoundResultView: View {
    @EnvironmentObject private var adsManager: AdsManager
    @StateObject private var nativeAdModel = NativeAdModel()

    let result: RoundResult
    let teamLevels: [Int: Rank]
    let canStartNext: Bool
    let onNext: () -> Void
    let onQuit: () -> Void

    private let kittyCardHeight: CGFloat = 58
    private let kittyTopPadding: CGFloat = 16
    private let kittyBottomPadding: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let metrics = RoundResultMetrics(size: proxy.size)

            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                ViewThatFits(in: .vertical) {
                    resultContent(metrics: metrics)
                        .padding(metrics.contentPadding)
                        .frame(width: metrics.panelWidth)
                        .background(panelBackground)

                    ScrollView {
                        resultContent(metrics: metrics)
                            .padding(metrics.contentPadding)
                    }
                    .frame(width: metrics.panelWidth)
                    .frame(maxHeight: metrics.panelMaxHeight)
                    .background(panelBackground)
                }
                .padding(.horizontal, metrics.outerHorizontalPadding)
            }
        }
    }

    // MARK: - 底牌展示区

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color(red: 0.1, green: 0.15, blue: 0.3))
    }

    private func resultContent(metrics: RoundResultMetrics) -> some View {
        VStack(spacing: metrics.contentSpacing) {
            Text(L10n.text(result.attackTeamWon ? "round.attackers_win" : "round.dealers_hold"))
                .font(metrics.titleFont)
                .foregroundColor(result.attackTeamWon ? .yellow : .cyan)

            if let nativeAd = nativeAdModel.nativeAd, adsManager.canRequestAds {
                NativeAdPlacement(nativeAd: nativeAd)
            }

            kittySection

            HStack(spacing: metrics.teamLevelSpacing) {
                teamLevel(name: L10n.text("team.north_south"), team: 0)
                teamLevel(name: L10n.text("team.east_west"), team: 1)
            }

            HStack(spacing: 20) {
                Button(action: onQuit) {
                    Text(L10n.text("退出"))
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                }

                Button(action: onNext) {
                    Text(L10n.text("下一局 →"))
                        .font(.headline.bold())
                        .foregroundColor(canStartNext ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(canStartNext ? Color.blue : Color.gray.opacity(0.45))
                        .clipShape(Capsule())
                }
                .disabled(!canStartNext)
            }
        }
        .task(id: adsManager.canRequestAds) {
            nativeAdModel.updateAdEligibility(adsManager.canRequestAds)
        }
    }

    @ViewBuilder
    private var kittySection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(L10n.text("底牌"))
                    .font(.subheadline.bold())
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                if result.rawKittyPoints > 0 && result.attackTeamWon {
                    Text(L10n.format(
                        "round.kitty_bonus_format",
                        result.kittyMultiplier,
                        result.rawKittyPoints * result.kittyMultiplier
                    ))
                        .font(.caption.bold())
                        .foregroundColor(.yellow)
                } else if result.attackTeamWon {
                    Text(L10n.text("底牌无分"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text(L10n.text("庄家保底"))
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
                    .padding(.top, kittyTopPadding)
                    .padding(.bottom, kittyBottomPadding)
                }
                .scrollClipDisabled()
                .frame(height: kittyCardHeight + kittyTopPadding + kittyBottomPadding + 6)
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
            Text(L10n.format("round.levels_format", steps))
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

private struct RoundResultMetrics {
    let size: CGSize

    private var isTabletCanvas: Bool {
        size.width >= 900 && size.height >= 600
    }

    var panelWidth: CGFloat {
        min(size.width - outerHorizontalPadding * 2, isTabletCanvas ? 640 : 560)
    }

    var panelMaxHeight: CGFloat {
        size.height - 40
    }

    var outerHorizontalPadding: CGFloat {
        isTabletCanvas ? 40 : 24
    }

    var contentPadding: CGFloat {
        isTabletCanvas ? 32 : 28
    }

    var contentSpacing: CGFloat {
        isTabletCanvas ? 26 : 24
    }

    var teamLevelSpacing: CGFloat {
        isTabletCanvas ? 40 : 32
    }

    var titleFont: Font {
        isTabletCanvas ? .largeTitle.bold() : .title.bold()
    }
}
