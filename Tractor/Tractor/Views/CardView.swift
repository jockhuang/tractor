import SwiftUI

struct CardView: View {
    let card: Card
    var isSelected: Bool = false
    var isFaceDown: Bool = false
    var isSmall: Bool = false

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
        ZStack {
            RoundedRectangle(cornerRadius: isSmall ? 6 : 10)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.2), radius: isSmall ? 2 : 4, x: 0, y: isSmall ? 1 : 2)

            if isSelected {
                RoundedRectangle(cornerRadius: isSmall ? 6 : 10)
                    .strokeBorder(Color.blue, lineWidth: 2.5)
            }

            if card.isJoker {
                jokerContent
            } else {
                regularCardContent
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSelected)
    }

    private var cardBack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isSmall ? 6 : 10)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.12, green: 0.28, blue: 0.68), Color(red: 0.05, green: 0.15, blue: 0.45)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .shadow(color: .black.opacity(0.25), radius: isSmall ? 2 : 4, x: 0, y: isSmall ? 1 : 2)

            // 背面花纹
            RoundedRectangle(cornerRadius: isSmall ? 4 : 7)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                .padding(isSmall ? 3 : 5)

            Image(systemName: "star.fill")
                .font(.system(size: isSmall ? 12 : 20))
                .foregroundColor(.white.opacity(0.25))
        }
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
                    .font(.system(size: isSmall ? 13 : 20, weight: .heavy, design: .rounded))
                    .offset(x: isSmall ? -6 : -9, y: isSmall ? -8 : -13)
                    .opacity(0.45)

                Text("王")
                    .font(.system(size: isSmall ? 30 : 46, weight: .heavy, design: .rounded))
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
        .shadow(color: jokerColor.opacity(isBig ? 0.5 : 0.4), radius: isSmall ? 2 : 3)
    }

    private func jokerCornerLabel(isBig: Bool) -> some View {
        VStack(spacing: 0) {
            Text(isBig ? "大" : "小")
            Text("王")
        }
        .font(.system(size: isSmall ? 9 : 12, weight: .heavy, design: .rounded))
        .lineLimit(1)
    }

    private var cardWidth: CGFloat  { isSmall ? 40 : 64 }
    private var cardHeight: CGFloat { isSmall ? 58 : 90 }
}

// MARK: - Mini card for AI players
struct MiniCardBack: View {
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
                    .offset(x: CGFloat(i) * 4 - CGFloat(min(count,5)) * 2)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            }
        }
        .frame(height: cardHeight)  // 固定高度，count=0 时也保留空间
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
