import SwiftUI

/// 桌面中间区域：展示当前墩四家出的牌
struct TrickAreaView: View {
    let trick: Trick
    let trumpSuit: Suit?
    let trumpRank: Rank
    var localPosition: PlayerPosition = .south

    var body: some View {
        ZStack {
            // 底部绿桌
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.13, green: 0.45, blue: 0.18).opacity(0.6))
                .frame(width: 260, height: 200)

            // 四个方向的出牌区
            ForEach(trick.plays, id: \.position.rawValue) { play in
                playArea(position: play.position, cards: play.cards)
            }
        }
    }

    @ViewBuilder
    private func playArea(position: PlayerPosition, cards: [Card]) -> some View {
        let offset = offsetFor(position: position)
        HStack(spacing: -18) {
            ForEach(cards) { card in
                CardView(card: card, isSmall: true)
            }
        }
        .offset(x: offset.x, y: offset.y)
    }

    private func offsetFor(position: PlayerPosition) -> CGPoint {
        switch relativeIndex(of: position) {
        case 0: return CGPoint(x: 0,    y:  58)
        case 1: return CGPoint(x: -110, y:   0)
        case 2: return CGPoint(x: 0,    y: -58)
        default: return CGPoint(x:  110, y:   0)
        }
    }

    private func relativeIndex(of position: PlayerPosition) -> Int {
        let order: [PlayerPosition] = [.south, .west, .north, .east]
        let localIndex = order.firstIndex(of: localPosition) ?? 0
        let positionIndex = order.firstIndex(of: position) ?? 0
        return (positionIndex - localIndex + order.count) % order.count
    }
}

// MARK: - 主牌信息条
struct TrumpInfoBar: View {
    let trumpSuit: Suit?
    let trumpRank: Rank
    let attackScore: Int
    let phase: GamePhase

    var body: some View {
        HStack(spacing: 16) {
            // 主牌
            HStack(spacing: 4) {
                Text("主：")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                if let suit = trumpSuit {
                    Text(suit.rawValue)
                        .font(.system(size: 18))
                        .foregroundColor(suit.color == "red" ? .red : .white)
                }
                Text(trumpRank.display)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())

            Spacer()

            // 攻方得分
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
                Text("攻方 \(attackScore) 分")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(attackScore >= 80
                ? Color.green.opacity(0.35)
                : Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
    }
}
