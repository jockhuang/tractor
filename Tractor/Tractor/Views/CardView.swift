import SwiftUI
import UIKit

struct CardView: View {
    @Environment(\.colorScheme) private var colorScheme

    let card: Card
    var isSelected: Bool = false
    var isFaceDown: Bool = false
    var isSmall: Bool = false
    var sizeScale: CGFloat = 1

    private var isRed: Bool {
        card.suit == .hearts || card.suit == .diamonds
    }

    var body: some View {
        if isFaceDown {
            cardBack
        } else {
            cardFront
        }
    }

    private var cardFront: some View {
        let corner: CGFloat = isSmall ? 6 : 10
        return ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color(.systemBackground))
                .shadow(color: cardShadowColor, radius: isSmall ? 2 : 4, x: 0, y: cardShadowYOffset)
                .shadow(color: cardGlowColor, radius: isSmall ? 1 : 3, x: 0, y: 0)

            // J/Q/K 与大小王：若已放入对应图片资源则用图片牌面，否则回退到矢量画法。
            if useFaceImage, let name = faceImageName {
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: baseCardWidth, height: baseCardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
            } else if card.isJoker {
                jokerContent
            } else {
                regularCardContent
            }

            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(cardEdgeColor, lineWidth: isSmall ? 0.75 : 1)

            if isSelected {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Color.blue, lineWidth: 2.5)
            }
        }
        .frame(width: baseCardWidth, height: baseCardHeight)
        .scaleEffect(sizeScale)
        .frame(width: cardWidth, height: cardHeight)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSelected)
    }

    /// 替换 J/Q/K 与大小王牌面（数字牌仍用矢量画法）。
    /// 资源命名：card_J_hearts / card_Q_spades / card_K_clubs …，大小王为 card_joker_big / card_joker_small。
    private var faceImageName: String? {
        switch card.rank {
        case .bigJoker:   return "card_joker_big"
        case .smallJoker: return "card_joker_small"
        case .jack, .queen, .king:
            guard let suit = card.suit else { return nil }
            let rankKey = card.rank == .jack ? "J" : (card.rank == .queen ? "Q" : "K")
            let suitKey: String
            switch suit {
            case .spades:   suitKey = "spades"
            case .hearts:   suitKey = "hearts"
            case .diamonds: suitKey = "diamonds"
            case .clubs:    suitKey = "clubs"
            }
            return "card_\(rankKey)_\(suitKey)"
        default:
            return nil
        }
    }

    /// 对应图片资源存在时启用图片牌面（大牌 / 小牌均适用）；否则回退矢量画法。
    private var useFaceImage: Bool {
        guard let name = faceImageName else { return false }
        return UIImage(named: name) != nil
    }

    private var cardBack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isSmall ? 6 : 10)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.12, green: 0.28, blue: 0.68), Color(red: 0.05, green: 0.15, blue: 0.45)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .shadow(color: cardShadowColor, radius: isSmall ? 2 : 4, x: 0, y: cardShadowYOffset)
                .shadow(color: cardGlowColor, radius: isSmall ? 1 : 3, x: 0, y: 0)
                .overlay {
                    RoundedRectangle(cornerRadius: isSmall ? 6 : 10)
                        .strokeBorder(cardEdgeColor, lineWidth: isSmall ? 0.75 : 1)
                }

            // 背面花纹
            RoundedRectangle(cornerRadius: isSmall ? 4 : 7)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                .padding(isSmall ? 3 : 5)

            Image(systemName: "star.fill")
                .font(.system(size: isSmall ? 12 : 20))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(width: baseCardWidth, height: baseCardHeight)
        .scaleEffect(sizeScale)
        .frame(width: cardWidth, height: cardHeight)
    }

    private var regularCardContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.rank.display)
                        .font(.system(size: isSmall ? 11 : 15, weight: .bold, design: .rounded))
                    Text(card.suit?.rawValue ?? "")
                        .font(.system(size: isSmall ? 9 : 12))
                }
                .foregroundColor(isRed ? .red : Color(.label))
                Spacer()
            }
            .padding(.horizontal, isSmall ? 4 : 6)
            .padding(.top, isSmall ? 3 : 5)

            Spacer()

            Text(card.suit?.rawValue ?? "")
                .font(.system(size: isSmall ? 22 : 34))
                .foregroundColor(isRed ? Color.red.opacity(0.85) : Color(.label).opacity(0.85))

            Spacer()

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(card.suit?.rawValue ?? "")
                        .font(.system(size: isSmall ? 9 : 12))
                    Text(card.rank.display)
                        .font(.system(size: isSmall ? 11 : 15, weight: .bold, design: .rounded))
                }
                .foregroundColor(isRed ? .red : Color(.label))
                .rotationEffect(.degrees(180))
            }
            .padding(.horizontal, isSmall ? 4 : 6)
            .padding(.bottom, isSmall ? 3 : 5)
        }
    }

    private var jokerContent: some View {
        let isBig = card.rank == .bigJoker
        let jokerColor = isBig
            ? Color(red: 0.85, green: 0.55, blue: 0.0)
            : Color(red: 0.1, green: 0.55, blue: 0.1)

        return VStack(spacing: 0) {
            HStack {
                jokerCornerLabel(isBig: isBig)
                Spacer()
            }
            .padding(.horizontal, isSmall ? 4 : 6)
            .padding(.top, isSmall ? 3 : 5)

            Spacer()

            ZStack {
                Text(isBig ? "大" : "小")
                    .font(.system(size: isSmall ? 11 : 17, weight: .heavy, design: .rounded))
                    .offset(x: isSmall ? -5 : -8, y: isSmall ? -7 : -11)
                    .opacity(0.45)

                Text("王")
                    .font(.system(size: isSmall ? 26 : 40, weight: .heavy, design: .rounded))
            }
            .frame(maxWidth: .infinity)

            Spacer()

            HStack {
                Spacer()
                jokerCornerLabel(isBig: isBig)
                    .rotationEffect(.degrees(180))
            }
            .padding(.horizontal, isSmall ? 4 : 6)
            .padding(.bottom, isSmall ? 3 : 5)
        }
        .foregroundColor(jokerColor)
        .shadow(color: jokerColor.opacity(isBig ? 0.35 : 0.3), radius: isSmall ? 1 : 2)
    }

    private func jokerCornerLabel(isBig: Bool) -> some View {
        VStack(spacing: 0) {
            Text(isBig ? "大" : "小")
            Text("王")
        }
        .font(.system(size: isSmall ? 9 : 12, weight: .heavy, design: .rounded))
        .lineLimit(1)
    }

    private var baseCardWidth: CGFloat  { isSmall ? 40 : 64 }
    private var baseCardHeight: CGFloat { isSmall ? 58 : 90 }
    private var cardWidth: CGFloat  { baseCardWidth * sizeScale }
    private var cardHeight: CGFloat { baseCardHeight * sizeScale }
    private var isDarkMode: Bool { colorScheme == .dark }
    private var cardShadowYOffset: CGFloat { isSmall ? 1 : 2 }
    private var cardShadowColor: Color {
        isDarkMode ? .white.opacity(0.16) : .black.opacity(0.2)
    }
    private var cardGlowColor: Color {
        isDarkMode ? .white.opacity(0.12) : .clear
    }
    private var cardEdgeColor: Color {
        isDarkMode ? .white.opacity(0.26) : .black.opacity(0.08)
    }
}

// MARK: - Mini card for AI players
struct MiniCardBack: View {
    @Environment(\.colorScheme) private var colorScheme

    var count: Int
    var cardHeight: CGFloat = 52

    var body: some View {
        ZStack {
            ForEach(0..<min(count, 5), id: \.self) { i in
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [Color(red: 0.12, green: 0.28, blue: 0.68), Color(red: 0.05, green: 0.15, blue: 0.45)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: cardHeight * 0.69, height: cardHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(miniCardEdgeColor, lineWidth: 0.75)
                    }
                    .offset(x: CGFloat(i) * 4 - CGFloat(min(count,5)) * 2)
                    .shadow(color: miniCardShadowColor, radius: 2, x: 0, y: 1)
                    .shadow(color: miniCardGlowColor, radius: 2, x: 0, y: 0)
            }
        }
        .frame(height: cardHeight)  // 固定高度，count=0 时也保留空间
    }

    private var isDarkMode: Bool { colorScheme == .dark }
    private var miniCardShadowColor: Color {
        isDarkMode ? .white.opacity(0.16) : .black.opacity(0.2)
    }
    private var miniCardGlowColor: Color {
        isDarkMode ? .white.opacity(0.12) : .clear
    }
    private var miniCardEdgeColor: Color {
        isDarkMode ? .white.opacity(0.24) : .black.opacity(0.08)
    }
}

#Preview {
    HStack(spacing: 8) {
        CardView(card: Card(suit: .spades, rank: .ace))
        CardView(card: Card(suit: .hearts, rank: .king), isSelected: true)
        CardView(card: Card(suit: nil, rank: .bigJoker))
        CardView(card: Card(suit: .diamonds, rank: .five), isFaceDown: true)
        CardView(card: Card(suit: .clubs, rank: .ten), isSmall: true)
    }
    .padding()
    .background(Color.green.opacity(0.3))
}
