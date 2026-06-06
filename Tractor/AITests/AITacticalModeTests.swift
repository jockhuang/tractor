import XCTest
@testable import Tractor_Game

/// 战术模式 / 阻分（Point Denial）的 XCTest 用例。
/// 复用与 AITests/main.swift（独立 swiftc 跑测）相同的场景，验证 Monte Carlo 在
/// 阻分场景下按 TacticalMode 切换目标函数，不再被保主偏置带偏。
final class AITacticalModeTests: XCTestCase {

    private let ts: Suit? = .spades
    private let tr: Rank = .two
    private var eval: TrickEvaluator { TrickEvaluator(trumpSuit: ts, trumpRank: tr) }
    private var win10: Card { Card(suit: .spades, rank: .ten) }   // 对手领先牌：♠10（10 分）

    private func c(_ s: Suit?, _ r: Rank) -> Card { Card(suit: s, rank: r) }

    private func makeState(dealerTeam: Int = 0) -> GameState {
        let s = GameState()
        s.phase = .playing
        s.trumpSuit = ts
        s.trumpRank = tr
        s.dealerTeamIdx = dealerTeam
        return s
    }

    private func setTrick(_ s: GameState,
                          lead: PlayerPosition,
                          plays: [(PlayerPosition, [Card])],
                          turn: PlayerPosition) {
        var trick = Trick(leadPosition: lead)
        for p in plays { trick.plays.append((position: p.0, cards: p.1)) }
        s.currentTrick = trick
        s.currentLeader = lead
        s.currentTurn = turn
    }

    private func setHand(_ s: GameState, _ pos: PlayerPosition, _ cards: [Card]) {
        s.players[pos.rawValue].hand = cards
    }

    private func beats(_ a: Card, _ b: Card) -> Bool {
        CardComparator.beats(a, b, trumpSuit: ts, trumpRank: tr)
    }

    // Test 1：当前墩有分，对手领先，AI(北=P3) 有主A可压 → 应压过而非垫小牌（也不能用 K）。
    func testPointDenialBeatsWithNonPointHighTrump() {
        let s = makeState()
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
                 turn: .north)
        setHand(s, .north,
                [c(.spades, .ace), c(.spades, .queen), c(.spades, .king),
                 c(.spades, .four), c(.spades, .three), c(.hearts, .six), c(.hearts, .seven)])
        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1, "应出单张")
        XCTAssertTrue(beats(chosen[0], win10), "应压过对手♠10，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertEqual(chosen[0].pointValue, 0, "争抢牌应为非分牌(不用K)，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // Test 2：当前墩无分，且我不是本队最后行动者（队友南在我之后）→ 非阻分，应保留大主出小牌。
    //（西先手 → 出牌顺序 西→北→东→南，北为第二手，队友南在最后，故为 normal。）
    func testNoPointsNonLastActorConservesBigTrump() {
        let s = makeState()
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.spades, .seven)])],
                 turn: .north)
        setHand(s, .north, [c(.spades, .ace), c(.spades, .three), c(.hearts, .six)])
        let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(mode, .normal, "无分且非最后行动者应为 normal，实际=\(mode)")
        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.first?.rank, .three, "无分应保留♠A出♠3，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // Test 2b：无分但我是本队最后行动者且后手有对手 → 仍进入 Point Denial（阻止对手用分牌赢墩）。
    func testNoPointsLastDefenderTriggersPointDenial() {
        let s = makeState()
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.spades, .seven)]), (.west, [c(.spades, .nine)])],
                 turn: .north)
        setHand(s, .north, [c(.spades, .ace), c(.spades, .three), c(.hearts, .six)])
        let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(mode, .pointDenial, "无分+最后行动者+后手有对手应进入 POINT_DENIAL，实际=\(mode)")
    }

    // Test 3：当前墩有分，AI 有多张可压牌 → 应选择能赢的牌，而非垫最小牌被轻松丢分。
    func testMultipleWinnersPicksWinningCard() {
        let s = makeState()
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
                 turn: .north)
        setHand(s, .north,
                [c(.spades, .jack), c(.spades, .queen), c(.spades, .ace), c(.spades, .three)])
        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertTrue(beats(chosen[0], win10), "应选择赢牌而非垫小牌，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertEqual(chosen[0].pointValue, 0, "赢牌应为非分牌")
    }

    // Test 4：AI 是本队最后一手且有分 → 触发 POINT_DENIAL。
    func testLastDefenderTriggersPointDenial() {
        let s = makeState()
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
                 turn: .north)
        setHand(s, .north, [c(.spades, .ace), c(.spades, .four), c(.hearts, .six)])
        let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(mode, .pointDenial, "最后防守人+有分应进入 POINT_DENIAL，实际=\(mode)")
    }

    // Test 5：A 是最大牌(代价高)，但不压就丢分 → 仍应压过（资产/早出大主只能轻微 tie-break）。
    func testHighCostStillContestsToDefendPoints() {
        let s = makeState()
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.spades, .king)]), (.west, [c(.spades, .ace)])],  // 对手♠A领先, 墩内10分(K)
                 turn: .north)
        // 北只有"小王"能压对手的♠A
        setHand(s, .north,
                [c(nil, .smallJoker), c(.spades, .four), c(.spades, .three), c(.hearts, .six)])
        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertTrue(beats(chosen[0], c(.spades, .ace)),
                      "高代价大牌也应为守分压过，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 需求 6：调试 / 测试钩子已拆入 AIPlayer+Debug.swift，且在各场景下可用、行为正确。
    func testReq6_DebugTacticalModeHook() {
        // 最后行动者 + 有分 → POINT_DENIAL
        let denial = makeState()
        setTrick(denial, lead: .south,
                 plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
                 turn: .north)
        setHand(denial, .north, [c(.spades, .ace), c(.spades, .four)])
        XCTAssertEqual(AIPlayer._testDetectTacticalMode(position: .north, state: denial, evaluator: eval),
                       .pointDenial, "调试钩子应识别 POINT_DENIAL")

        // 非最后行动者（队友在后）+ 无分 → NORMAL
        let normal = makeState()
        setTrick(normal, lead: .west,
                 plays: [(.west, [c(.spades, .seven)])],
                 turn: .north)
        setHand(normal, .north, [c(.spades, .ace), c(.spades, .three)])
        XCTAssertEqual(AIPlayer._testDetectTacticalMode(position: .north, state: normal, evaluator: eval),
                       .normal, "调试钩子应识别 NORMAL")
    }

    // 需求 7：TrickContext 聚合一墩公共上下文，派生量正确（纯派生，不改逻辑）。
    func testReq7_TrickContextDerivedFields() {
        let s = makeState()
        // 先手副牌 ♥7，西出 ♥K（10 分，当前领先）；北为本队最后防守人，东为后手对手。
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.hearts, .seven)]), (.west, [c(.hearts, .king)])],
                 turn: .north)
        setHand(s, .north, [c(.hearts, .ace), c(.hearts, .three), c(.spades, .four)])
        let mem = AIContext.build(state: s, ts: ts, tr: tr)
        let tc = TrickContext(position: .north, hand: s.player(.north).hand,
                              state: s, evaluator: eval, memory: mem)

        XCTAssertFalse(tc.isLeading, "本墩已有人出牌")
        XCTAssertEqual(tc.leadCards.map { $0.shortDisplay }, ["♥7"], "先手牌应为 ♥7")
        XCTAssertEqual(tc.leadSuit, .hearts, "先手花色应为 ♥")
        XCTAssertEqual(tc.trickPoints, 10, "本墩分应为 10（♥K）")
        XCTAssertEqual(tc.currentWinner, .west, "当前赢家应为西")
        XCTAssertTrue(tc.opponentWinning, "对手领先")
        XCTAssertFalse(tc.partnerWinning)
        XCTAssertFalse(tc.isLastPlayer, "仅 2 家出牌，我非末手")
        XCTAssertEqual(tc.subsequentPositions, [.east], "我之后仅东未出牌")
        XCTAssertTrue(tc.isLastEffectiveChanceForTeam, "后手无队友 → 我是本队最后防守人")

        // 我方先手（空墩）场景：isLeading 为真，leadSuit 为 nil。
        let leadState = makeState()
        leadState.currentTrick = Trick(leadPosition: .north)
        setHand(leadState, .north, [c(.spades, .ace)])
        let memLead = AIContext.build(state: leadState, ts: ts, tr: tr)
        let tcLead = TrickContext(position: .north, hand: leadState.player(.north).hand,
                                  state: leadState, evaluator: eval, memory: memLead)
        XCTAssertTrue(tcLead.isLeading, "空墩应为我方先手")
        XCTAssertNil(tcLead.currentWinner, "空墩无当前赢家")
        XCTAssertNil(tcLead.leadSuit)
        XCTAssertEqual(tcLead.trickPoints, 0)
    }
}
