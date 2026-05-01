import Foundation
import Combine

// MARK: - Game Phase
enum GamePhase: Equatable, Codable {
    case menu
    case dealing             // 逐张发牌（含亮主窗口）
    case kittyExchange       // 庄家换底牌
    case playing             // 正常出牌
    case trickEnd            // 一墩结束（短暂展示）
    case roundEnd            // 一局结束
    case gameOver            // 游戏结束
}

// MARK: - Trump Declaration
struct TrumpDeclaration: Equatable, Codable {
    var declarer: PlayerPosition
    var suit: Suit
    var strength: Int        // 1 = 单张, 2 = 对子
}

// MARK: - Trick（一墩）
struct Trick {
    var plays: [(position: PlayerPosition, cards: [Card])] = []
    var leadPosition: PlayerPosition

    init(leadPosition: PlayerPosition) {
        self.leadPosition = leadPosition
    }

    var isComplete: Bool { plays.count == 4 }
    var leadCards: [Card]? { plays.first?.cards }
}

// MARK: - Round Result
struct RoundResult: Codable {
    let attackScore: Int
    let attackTeamWon: Bool
    let levelAdvance: Int
    let attackAdvance: Int
}

// MARK: - GameState
class GameState: ObservableObject {

    // 四个玩家
    @Published var players: [Player] = PlayerPosition.allCases.map { Player(position: $0) } {
        didSet { subscribeToPlayers() }
    }
    private var playerCancellables: [AnyCancellable] = []

    init() { subscribeToPlayers() }

    private func subscribeToPlayers() {
        playerCancellables = players.map { player in
            player.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    // 游戏阶段
    @Published var phase: GamePhase = .menu

    // 主牌
    @Published var trumpSuit: Suit? = nil
    @Published var trumpRank: Rank = .two

    // 亮主状态
    @Published var trumpDeclaration: TrumpDeclaration? = nil   // 当前亮主信息

    // 发牌进度
    @Published var dealtCount: Int = 0         // 已发出的牌数 (0-100)
    @Published var isDealingFast: Bool = false  // 快速发牌开关

    // 庄家位置（每局开始时确定）
    @Published var dealerPosition: PlayerPosition = .south

    // 当前局状态
    @Published var kitty: [Card] = []
    @Published var currentTrick: Trick = Trick(leadPosition: .south)
    @Published var currentLeader: PlayerPosition = .south
    @Published var currentTurn: PlayerPosition = .south

    // 得分
    @Published var attackScore: Int = 0

    // 升级进度
    @Published var teamLevels: [Int: Rank] = [0: .two, 1: .two]
    @Published var dealerTeamIdx: Int = 0

    // 历史墩
    @Published var completedTricks: [Trick] = []

    // 消息提示
    @Published var message: String = ""
    @Published var lastRoundResult: RoundResult? = nil

    // 选中的手牌（人类玩家）
    @Published var selectedCards: Set<UUID> = []

    // 甩牌强制出牌：key = 被逼出的玩家，value = 必须包含在跟牌中的牌
    @Published var forcedFollowCards: [PlayerPosition: [Card]] = [:]

    // ── 计算属性 ──────────────────────────────
    var humanPlayer: Player { players[PlayerPosition.south.rawValue] }
    func player(_ pos: PlayerPosition) -> Player { players[pos.rawValue] }
    func teamLevel(_ team: Int) -> Rank { teamLevels[team] ?? .two }
    var currentDealerTeamLevel: Rank { teamLevel(dealerTeamIdx) }
    var attackTeamIdx: Int { 1 - dealerTeamIdx }

    /// 亮主强度（0=无，1=单张，2=对子）
    var declarationStrength: Int { trumpDeclaration?.strength ?? 0 }

    /// 重置一局
    func resetRound() {
        kitty             = []
        currentTrick      = Trick(leadPosition: .south)
        completedTricks   = []
        attackScore       = 0
        selectedCards     = []
        message           = ""
        trumpSuit         = nil
        trumpDeclaration  = nil
        dealtCount        = 0
        isDealingFast     = false
        forcedFollowCards = [:]
        for p in players { p.hand = []; p.isDealer = false }
    }
}
