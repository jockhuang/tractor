import Foundation

enum PlayerPosition: Int, CaseIterable, Codable {
    case south = 0   // 玩家（底部）
    case west  = 1   // AI 左侧
    case north = 2   // AI 对家
    case east  = 3   // AI 右侧

    /// 队伍：0和2 为庄家方 / 1和3 为攻方
    var team: Int { rawValue % 2 }

    var displayName: String {
        switch self {
        case .south: return "我"
        case .west:  return "西"
        case .north: return "北"
        case .east:  return "东"
        }
    }

    var isHuman: Bool { self == .south }

    /// 视图布局位置描述
    var layoutAnchor: String {
        switch self {
        case .south: return "bottom"
        case .west:  return "left"
        case .north: return "top"
        case .east:  return "right"
        }
    }
}

class Player: ObservableObject, Identifiable {
    let id = UUID()
    let position: PlayerPosition

    @Published var hand: [Card] = []
    @Published var isDealer: Bool = false     // 庄家（可换底）
    @Published var level: Rank = .two         // 本方当前级别

    var name: String { position.displayName }
    var team: Int { position.team }
    var isHuman: Bool { position.isHuman }

    init(position: PlayerPosition) {
        self.position = position
    }

    /// 出牌：从手牌移除
    func play(cards: [Card]) {
        let ids = Set(cards.map { $0.id })
        hand.removeAll { ids.contains($0.id) }
    }

    /// 排序手牌（主牌在前，按花色分组）
    func sortHand(trumpSuit: Suit?, trumpRank: Rank) {
        hand = hand.sorted { CardComparator.handSortOrder($0, $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
    }
}
