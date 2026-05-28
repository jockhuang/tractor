import SwiftUI

struct PlayerHandView: View {
    @ObservedObject var player: Player
    @Binding var selectedCards: Set<UUID>
    var isActive: Bool = false
    var canSelect: Bool = true
    var maxVisible: Int = 25
    var lastDrawnCardId: UUID? = nil  // 发牌动画：最新一张牌浮起

    private let cardWidth: CGFloat = 64
    private let cardHeight: CGFloat = 90
    private let selectedCardLift: CGFloat = 12
    private let drawnCardLift: CGFloat = 10
    private let verticalPadding: CGFloat = 16
    private let overlapFactor: CGFloat = 0.55  // 叠牌重叠比例

    private var topPadding: CGFloat {
        verticalPadding + max(selectedCardLift, drawnCardLift)
    }

    private var handHeight: CGFloat {
        cardHeight + topPadding + verticalPadding
    }

    var body: some View {
        let cards = player.hand
//        let count  = min(cards.count, maxVisible)
//        let total  = cardWidth + CGFloat(count - 1) * cardWidth * overlapFactor
//        let maxW   = UIScreen.main.bounds.width - 32

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: -(cardWidth * (1 - overlapFactor))) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { _, card in
                    CardView(
                        card: card,
                        isSelected: selectedCards.contains(card.id)
                    )
                    .offset(y: cardOffset(for: card))
                    .onTapGesture {
                        if canSelect && isActive {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                if selectedCards.contains(card.id) {
                                    selectedCards.remove(card.id)
                                } else {
                                    selectedCards.insert(card.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            .padding(.bottom, verticalPadding)
        }
        .scrollClipDisabled()
        .frame(height: handHeight)
    }

    private func cardOffset(for card: Card) -> CGFloat {
        if selectedCards.contains(card.id) {
            return -selectedCardLift
        }
        if card.id == lastDrawnCardId {
            return -drawnCardLift
        }
        return 0
    }
}

// MARK: - AI手牌展示（背面）
struct AIHandView: View {
    let position: PlayerPosition
    let cardCount: Int
    let isActive: Bool

    var body: some View {
        VStack(spacing: 4) {
            if isActive {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(4)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            MiniCardBack(count: cardCount)
            Text("\(position.displayName)  \(cardCount)张")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}
