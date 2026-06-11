import XCTest
import SwiftUI
import UIKit
@testable import Tractor_Game

/// Renders a realistic dark-mode hand row to a bitmap on the simulator and measures
/// each card's visible height, so card-size issues are verified empirically.
/// This reproduces the real bug context (dark mode: card body is black, distinct from
/// the green table) — a plain self-size render does NOT catch it.
final class CardViewLayoutTests: XCTestCase {

    private let scale: CGFloat = 1.2
    private let renderScale: CGFloat = 2

    /// Per-card visible height (points) in a real hand-row layout, keyed by sample x.
    @MainActor
    private func cardHeights(_ cards: [Card]) -> [CGFloat] {
        let s = scale
        let row = HStack(spacing: -(64 * s * 0.45)) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                CardView(card: c, sizeScale: s)
            }
        }
        .padding(20)
        .background(Color(red: 0.10, green: 0.45, blue: 0.20))   // table green
        .environment(\.colorScheme, .dark)                        // game runs dark

        let renderer = ImageRenderer(content: row)
        renderer.scale = renderScale
        guard let ui = renderer.uiImage, let cg = ui.cgImage else { return [] }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        func isGreen(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return abs(Int(data[i]) - 25) < 45 && abs(Int(data[i+1]) - 115) < 50 && abs(Int(data[i+2]) - 51) < 45
        }
        // sample a column at the centre of each card and measure non-green vertical extent
        let n = cards.count
        var heights: [CGFloat] = []
        for idx in 0..<n {
            // centre x of card idx in the rendered image (points → pixels)
            let frac = (Double(idx) + 0.5) / Double(n)
            let x = min(w - 1, max(0, Int(Double(w) * (0.12 + 0.76 * frac))))
            var minY = h, maxY = -1
            for y in 0..<h where !isGreen(x, y) {
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
            heights.append(maxY >= minY ? CGFloat(maxY - minY + 1) / renderScale : 0)
        }
        return heights
    }

    @MainActor
    func testJokerCardSameHeightAsVectorCardInHand() {
        // small joker | 2♥ | K♠ | A♥ | big joker
        let cards: [Card] = [
            Card(suit: nil, rank: .smallJoker),
            Card(suit: .hearts, rank: .two),
            Card(suit: .spades, rank: .king),
            Card(suit: .hearts, rank: .ace),
            Card(suit: nil, rank: .bigJoker),
        ]
        let heights = cardHeights(cards)
        print("CARD HEIGHTS (pt): \(heights)")
        guard heights.count == cards.count else { XCTFail("render failed: \(heights)"); return }

        // reference = a vector card (2♥)
        let vectorH = heights[1]
        XCTAssertGreaterThan(vectorH, 60, "vector card height looks wrong: \(vectorH)")
        XCTAssertEqual(heights[0], vectorH, accuracy: 6, "small joker height != vector")
        XCTAssertEqual(heights[4], vectorH, accuracy: 6, "big joker height != vector")
    }
}

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

    private func enemiesVoidClubsTrick() -> Trick {
        var t = Trick(leadPosition: .west)
        t.plays.append((position: .west, cards: [c(.clubs, .four)]))
        t.plays.append((position: .north, cards: [c(.diamonds, .four)]))
        t.plays.append((position: .east, cards: [c(.clubs, .five)]))
        t.plays.append((position: .south, cards: [c(.diamonds, .six)]))
        return t
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

    // P2 跟吊主：后手还有未知对手，0 分墩未锁定时，即使手里后续资产很强，
    // 也不应为了抢出牌权把主10这类分牌裸送进去。
    func testSecondHandTrumpPullDoesNotExposePointTrumpIntoUnknownTrick() {
        let s = makeState()
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.spades, .seven)])],
                 turn: .north)
        setHand(s, .north,
                [c(.spades, .ten), c(.spades, .three),
                 c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
                 c(.hearts, .king), c(.clubs, .king), c(.diamonds, .king),
                 c(.hearts, .queen), c(.clubs, .queen), c(.diamonds, .queen)])

        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen[0].pointValue, 0,
                       "P2 吊主未知墩不应裸出主分牌，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertEqual(chosen[0].rank, .three,
                       "应出可用的无分小主，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // P2 跟吊主限制的是分牌暴露，不是主牌强度：
    // 手里有大量待兑现资产时，可以用无分大主争本墩和下一手出牌权。
    func testSecondHandTrumpPullCanUseNonPointControlTrumpForLeadControl() {
        let s = makeState()
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.spades, .seven)])],
                 turn: .north)
        setHand(s, .north,
                [c(.spades, .ace), c(.spades, .three),
                 c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
                 c(.hearts, .king), c(.hearts, .king),
                 c(.clubs, .queen), c(.clubs, .queen),
                 c(.diamonds, .jack), c(.diamonds, .jack)])

        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♠A"],
                       "P2 高主动权需求时应可用无分控制主抢出牌权，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 同样有待兑现资产时，若大牌是主分牌且后手对手仍可能赢，仍应避免把分送入未知墩。
    func testSecondHandTrumpPullStillAvoidsPointControlTrumpExposure() {
        let s = makeState()
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.spades, .seven)])],
                 turn: .north)
        setHand(s, .north,
                [c(.spades, .king), c(.spades, .three),
                 c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
                 c(.hearts, .king), c(.hearts, .king),
                 c(.clubs, .queen), c(.clubs, .queen),
                 c(.diamonds, .jack), c(.diamonds, .jack)])

        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♠3"],
                       "P2 即使需要主动权，也不应把主K送进后手对手可能赢的0分墩，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 开局主牌很多也不应直接领对王；拔主应先用低成本小主，保留最高控制对。
    func testEarlyLeadPreservesJokerPairWhenLowTrumpTransferExists() {
        let s = makeState()
        s.currentTrick = Trick(leadPosition: .north)
        s.currentLeader = .north
        s.currentTurn = .north
        setHand(s, .north,
                [c(nil, .bigJoker), c(nil, .bigJoker),
                 c(.spades, .three), c(.spades, .four), c(.spades, .six),
                 c(.spades, .seven), c(.spades, .eight), c(.spades, .nine),
                 c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)])

        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♠3"],
                       "开局不应直接领对王，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 开局也不应直接领对级牌；即便主牌很长，级牌对仍是后续控墩资源。
    func testEarlyLeadPreservesLevelPairWhenLowTrumpTransferExists() {
        let s = makeState()
        s.currentTrick = Trick(leadPosition: .north)
        s.currentLeader = .north
        s.currentTurn = .north
        setHand(s, .north,
                [c(.hearts, .two), c(.hearts, .two),
                 c(.spades, .three), c(.spades, .four), c(.spades, .six),
                 c(.spades, .seven), c(.spades, .eight), c(.spades, .nine),
                 c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)])

        let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♠3"],
                       "开局不应直接领对级牌，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 多张跟牌时，本门不够且只剩分牌：本门分牌被迫要出，但其他门补牌不能再给对手垫分。
    func testPartialFollowDoesNotPadEnemyWithOffSuitPoints() {
        let s = makeState()
        s.completedTricks = [enemiesVoidClubsTrick()]
        setTrick(s, lead: .south,
                 plays: [(.south, [c(.hearts, .seven), c(.hearts, .seven)])],
                 turn: .west)
        setHand(s, .west, [c(.hearts, .king), c(.clubs, .ten), c(.diamonds, .three)])

        let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 2)
        XCTAssertTrue(chosen.contains { $0.suit == .hearts && $0.rank == .king },
                      "本门剩余♥K 是被迫跟出的分牌，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertTrue(chosen.contains { $0.suit == .diamonds && $0.rank == .three },
                      "补其他门时应选0分♦3，不应垫♣10给对手，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertFalse(chosen.contains { $0.suit == .clubs && $0.rank == .ten },
                       "其他门分牌不是被迫牌，不应额外垫给对手，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 非临界分线：孤立分牌不是必须保护的资产，不能丢王/级牌去保 K。
    func testDiscardCostPrefersIsolatedPointOverTrumpControlWhenNotCritical() {
        let s = makeState(dealerTeam: 0)
        s.attackScore = 0
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.hearts, .seven), c(.hearts, .seven)])],
                 turn: .north)
        let hand = [c(nil, .bigJoker), c(.hearts, .two), c(.clubs, .king), c(.diamonds, .three)]
        setHand(s, .north, hand)

        let ctx = AIContext.build(state: s, ts: ts, tr: tr)
        let chosen = AIPlayer.smartDiscard(
            from: hand,
            count: 2,
            enemyWinning: true,
            ts: ts,
            tr: tr,
            myTeam: PlayerPosition.north.team,
            ctx: ctx,
            state: s,
            position: .north,
            evaluator: eval,
            fullHand: hand
        )

        XCTAssertTrue(chosen.contains { $0.suit == .diamonds && $0.rank == .three },
                      "应先垫0分小副牌，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertTrue(chosen.contains { $0.suit == .clubs && $0.rank == .king },
                      "非临界分线不应丢王/级牌保孤立K，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertFalse(chosen.contains { $0.rank == .bigJoker || $0.rank == tr },
                       "王/级牌是控制资产，应保留，chosen=\(chosen.map { $0.shortDisplay })")
    }

    // 临界分线：只有垫分会让攻方到达关键分数线时，才提升分牌保护权重。
    func testDiscardCostProtectsPointCardOnlyAtCriticalScoreLine() {
        let s = makeState(dealerTeam: 0)
        s.attackScore = 30
        setTrick(s, lead: .west,
                 plays: [(.west, [c(.hearts, .seven), c(.hearts, .seven)])],
                 turn: .north)
        let hand = [c(nil, .bigJoker), c(.hearts, .two), c(.clubs, .king), c(.diamonds, .three)]
        setHand(s, .north, hand)

        let ctx = AIContext.build(state: s, ts: ts, tr: tr)
        let chosen = AIPlayer.smartDiscard(
            from: hand,
            count: 2,
            enemyWinning: true,
            ts: ts,
            tr: tr,
            myTeam: PlayerPosition.north.team,
            ctx: ctx,
            state: s,
            position: .north,
            evaluator: eval,
            fullHand: hand
        )

        XCTAssertTrue(chosen.contains { $0.suit == .diamonds && $0.rank == .three },
                      "仍应优先垫0分小副牌，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertFalse(chosen.contains { $0.suit == .clubs && $0.rank == .king },
                       "攻方30分时垫K会过40分线，应临时保护K，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertFalse(chosen.contains { $0.rank == .bigJoker },
                       "即使临界分线，也应优先保最高控制资产大王，chosen=\(chosen.map { $0.shortDisplay })")
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

    /// A completed trick where East (opponent) shows void in hearts — sets up "the ♥ winner would be ruffed".
    private func eastVoidHeartsTrick() -> Trick {
        var t = Trick(leadPosition: .north)
        t.plays.append((position: .north, cards: [c(.hearts, .five)]))
        t.plays.append((position: .east, cards: [c(.clubs, .three)]))   // East discards ♣ -> void in ♥
        t.plays.append((position: .south, cards: [c(.hearts, .six)]))
        t.plays.append((position: .west, cards: [c(.hearts, .eight)]))
        return t
    }

    // Asset Lifecycle: a side winner would be ruffed now but we have trump control -> pull first, realize later (no blind cash / fire-sale).
    func testAssetLifecyclePullsTrumpBeforeRuffThreatenedWinner() {
        // South leads; East void in ♥ (leading ♥A would be ruffed); South has trump control (♠A♠K♠Q♠J) -> pull trump, not cash ♥A.
        let s = makeState()
        s.completedTricks = [eastVoidHeartsTrick()]
        s.currentTrick = Trick(leadPosition: .south)
        s.currentLeader = .south
        s.currentTurn = .south
        setHand(s, .south, [c(.hearts, .ace), c(.spades, .ace), c(.spades, .king),
                            c(.spades, .queen), c(.spades, .jack), c(.clubs, .four)])
        let chosen = AIPlayer.chooseCards(position: .south, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertTrue(CardComparator.isTrump(chosen[0], trumpSuit: ts, trumpRank: tr),
                      "应先拔主，chosen=\(chosen.map { $0.shortDisplay })")
        XCTAssertFalse(chosen[0].suit == .hearts && chosen[0].rank == .ace,
                       "不应现在兑现会被将吃的♥A")
    }

    // Contrast: no ruff threat -> ♥A is a clean winner and should be cashed (asset still in its high-realization phase).
    func testAssetLifecycleCashesWinnerWhenNoRuffThreat() {
        let s = makeState()
        s.currentTrick = Trick(leadPosition: .south)
        s.currentLeader = .south
        s.currentTurn = .south
        setHand(s, .south, [c(.hearts, .ace), c(.spades, .ace), c(.spades, .king),
                            c(.spades, .queen), c(.spades, .jack), c(.clubs, .four)])
        let chosen = AIPlayer.chooseCards(position: .south, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♥A"],
                       "无将吃威胁应直接兑现♥A，chosen=\(chosen.map { $0.shortDisplay })")
    }

    func testEndgamePreservesTrumpPairByLeadingSideJunk() {
        let s = makeState(dealerTeam: 0)
        s.currentTrick = Trick(leadPosition: .west)
        s.currentLeader = .west
        s.currentTurn = .west
        s.completedTricks = [
            {
                var t = Trick(leadPosition: .south)
                t.plays.append((position: .south, cards: [c(.spades, .three)]))
                t.plays.append((position: .west, cards: [c(.spades, .four)]))
                t.plays.append((position: .north, cards: [c(.hearts, .six)]))
                t.plays.append((position: .east, cards: [c(.diamonds, .six)]))
                return t
            }(),
            {
                var t = Trick(leadPosition: .west)
                t.plays.append((position: .west, cards: [c(.spades, .five)]))
                t.plays.append((position: .north, cards: [c(.clubs, .three)]))
                t.plays.append((position: .east, cards: [c(.spades, .six)]))
                t.plays.append((position: .south, cards: [c(.diamonds, .four)]))
                return t
            }()
        ]
        setHand(s, .west, [c(.spades, .ace), c(.spades, .ace), c(.hearts, .three), c(.clubs, .four)])

        let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertFalse(CardComparator.isTrump(chosen[0], trumpSuit: ts, trumpRank: tr),
                       "残局应先处理副牌垃圾，保留主对子锁最后阶段，chosen=\(chosen.map { $0.shortDisplay })")
    }

    func testEndgamePreservesTrumpTractorByLeadingSideJunk() {
        let s = makeState(dealerTeam: 0)
        s.currentTrick = Trick(leadPosition: .east)
        s.currentLeader = .east
        s.currentTurn = .east
        s.completedTricks = [
            {
                var t = Trick(leadPosition: .south)
                t.plays.append((position: .south, cards: [c(.spades, .three)]))
                t.plays.append((position: .west, cards: [c(.hearts, .six)]))
                t.plays.append((position: .north, cards: [c(.spades, .four)]))
                t.plays.append((position: .east, cards: [c(.clubs, .six)]))
                return t
            }(),
            {
                var t = Trick(leadPosition: .north)
                t.plays.append((position: .north, cards: [c(.spades, .five)]))
                t.plays.append((position: .east, cards: [c(.diamonds, .seven)]))
                t.plays.append((position: .south, cards: [c(.spades, .six)]))
                t.plays.append((position: .west, cards: [c(.clubs, .seven)]))
                return t
            }()
        ]
        setHand(s, .east, [c(.spades, .queen), c(.spades, .queen),
                           c(.spades, .king), c(.spades, .king), c(.hearts, .three)])

        let chosen = AIPlayer.chooseCards(position: .east, state: s, evaluator: eval)
        XCTAssertEqual(chosen.map { $0.shortDisplay }, ["♥3"],
                       "残局应保留主拖拉机，不提前出或拆，chosen=\(chosen.map { $0.shortDisplay })")
    }
}
