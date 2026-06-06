import SwiftUI

/// 本局历史出牌记录面板
struct TrickHistoryPanel: View {
    let tricks: [Trick]
    let declarationEvents: [DeclarationEvent]
    let trumpSuit: Suit?
    let trumpRank: Rank
    let playerNames: [PlayerPosition: String]
    let onClose: () -> Void

    private var evaluator: TrickEvaluator {
        TrickEvaluator(trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 背景遮罩
                Color.black.opacity(0.60)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                // 面板
                VStack(spacing: 0) {
                    // 标题栏
                    HStack {
                        Text("本局记录")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(declarationEvents.count) 次亮主 · \(tricks.count) 墩")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.5))
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.08))

                    Divider().background(Color.white.opacity(0.15))

                    // 记录列表
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !declarationEvents.isEmpty {
                                sectionHeader("亮主 / 反主记录")
                                ForEach(declarationEvents) { event in
                                    DeclarationHistoryRow(event: event, playerNames: playerNames)
                                    Divider().background(Color.white.opacity(0.08))
                                        .padding(.horizontal, 12)
                                }
                            }

                            if !tricks.isEmpty {
                                sectionHeader("出牌记录")
                                ForEach(Array(tricks.enumerated()), id: \.offset) { idx, trick in
                                    TrickHistoryRow(
                                        index: idx + 1,
                                        trick: trick,
                                        winner: evaluator.winner(of: trick),
                                        playerNames: playerNames
                                    )
                                    if idx < tricks.count - 1 {
                                        Divider().background(Color.white.opacity(0.08))
                                            .padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .frame(width: proxy.size.width * 0.80, height: proxy.size.height * 0.80)
                .background(Color(red: 0.08, green: 0.14, blue: 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 20)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }
}

private struct DeclarationHistoryRow: View {
    let event: DeclarationEvent
    let playerNames: [PlayerPosition: String]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("#\(event.sequence)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(displayName(for: event.declarer))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(event.sequence == 1 ? "亮主" : "反主")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.yellow)
                    Text(declarationText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }

                HStack(spacing: 6) {
                    Text("已知牌")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                    if event.revealedCards.isEmpty {
                        Text("未记录具体牌")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.35))
                    } else {
                        ForEach(event.revealedCards, id: \.id) { card in
                            cardChip(card: card)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var declarationText: String {
        let suitText = event.suit?.rawValue ?? "无主"
        let strengthText: String
        switch event.strength {
        case 1: strengthText = "单张"
        case 2: strengthText = "对子"
        case 3: strengthText = "王牌对"
        default: strengthText = ""
        }
        return strengthText.isEmpty ? suitText : "\(suitText) · \(strengthText)"
    }

    private func displayName(for position: PlayerPosition) -> String {
        let name = playerNames[position]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return playerNames.isEmpty ? position.displayName : position.seatName
    }

    private func cardChip(card: Card) -> some View {
        let isRed = card.suit?.color == "red"
        return Text(card.shortDisplay)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(card.isJoker ? .yellow : (isRed ? .red : .white))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - 单墩行
private struct TrickHistoryRow: View {
    let index: Int
    let trick: Trick
    let winner: PlayerPosition
    let playerNames: [PlayerPosition: String]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // 墩号
            Text("#\(index)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 38, alignment: .leading)

            // 先手标记
            Text(displayName(for: trick.leadPosition))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, alignment: .center)

            // 四家出牌
            ForEach(orderedPlays, id: \.position.rawValue) { play in
                playerColumn(play: play)
            }

            Spacer()

            // 赢家
            HStack(spacing: 3) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
                Text(displayName(for: winner))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 按出牌顺序排列（先手打头）
    private var orderedPlays: [(position: PlayerPosition, cards: [Card])] {
        let order: [PlayerPosition] = [.south, .west, .north, .east]
        let leadIdx = order.firstIndex(of: trick.leadPosition) ?? 0
        let sorted = (0..<4).compactMap { offset -> (position: PlayerPosition, cards: [Card])? in
            let pos = order[(leadIdx + offset) % 4]
            return trick.plays.first(where: { $0.position == pos })
        }
        return sorted
    }

    @ViewBuilder
    private func playerColumn(play: (position: PlayerPosition, cards: [Card])) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(displayName(for: play.position))
                .font(.system(size: 12))
                .foregroundColor(play.position == trick.leadPosition
                    ? .white.opacity(0.8) : .white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // 牌列表（横排，最多显示 4 张，再多就省略）
            let display = play.cards.prefix(4)
            HStack(spacing: 2) {
                ForEach(Array(display), id: \.id) { card in
                    cardChip(card: card)
                }
                if play.cards.count > 4 {
                    Text("+\(play.cards.count - 4)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // 本墩得分
            let pts = play.cards.reduce(0) { $0 + $1.pointValue }
            if pts > 0 {
                Text("+\(pts)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func displayName(for position: PlayerPosition) -> String {
        let name = playerNames[position]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return playerNames.isEmpty ? position.displayName : position.seatName
    }

    private func cardChip(card: Card) -> some View {
        let isRed = card.suit?.color == "red"
        return Text(card.shortDisplay)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(card.isJoker ? .yellow : (isRed ? .red : .white))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
