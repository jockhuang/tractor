import Foundation

// Standalone tactical-mode test harness for the AI engine.
// Compiled separately with swiftc against the SwiftUI-free engine/model files.
// Run: ./run_ai_tests.sh   (see repo root)

func c(_ s: Suit?, _ r: Rank) -> Card { Card(suit: s, rank: r) }

func makeState(trump: Suit?, rank: Rank, dealerTeam: Int = 0) -> GameState {
    let s = GameState()
    s.phase = .playing
    s.trumpSuit = trump
    s.trumpRank = rank
    s.dealerTeamIdx = dealerTeam
    return s
}

/// 设置一墩已出的牌（按出牌顺序），并把当前轮到的玩家设好。
func setTrick(_ s: GameState, lead: PlayerPosition, plays: [(PlayerPosition, [Card])], turn: PlayerPosition) {
    var trick = Trick(leadPosition: lead)
    for p in plays { trick.plays.append((position: p.0, cards: p.1)) }
    s.currentTrick = trick
    s.currentLeader = lead
    s.currentTurn = turn
}

func enemiesVoidClubsTrick() -> Trick {
    var t = Trick(leadPosition: .west)
    t.plays.append((position: .west, cards: [c(.clubs, .four)]))
    t.plays.append((position: .north, cards: [c(.diamonds, .four)]))
    t.plays.append((position: .east, cards: [c(.clubs, .five)]))
    t.plays.append((position: .south, cards: [c(.diamonds, .six)]))
    return t
}

var failures: [String] = []
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { print("✅ \(name)") }
    else { let d = detail(); failures.append(name + (d.isEmpty ? "" : " — \(d)")); print("❌ \(name) \(d)") }
}

let ts: Suit? = .spades
let tr: Rank = .two
let eval = TrickEvaluator(trumpSuit: ts, trumpRank: tr)
let win10 = c(.spades, .ten)   // 当前对手领先牌（♠10，10 分）

// ── Test 1：当前墩有分，对手领先，AI(北=P3) 有主A可压 → 应压过而非垫小牌 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ace), c(.spades, .queen), c(.spades, .king),
         c(.spades, .four), c(.spades, .three), c(.hearts, .six), c(.hearts, .seven)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let beats = chosen.count == 1 && CardComparator.beats(chosen[0], win10, trumpSuit: ts, trumpRank: tr)
    let nonPoint = chosen.allSatisfy { $0.pointValue == 0 }
    check(beats && nonPoint, "Test1 有分防守用非分大牌压过(不垫小牌/不用K)",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2：当前墩无分，且我非本队最后行动者（西先手，队友南在我之后）→ 非阻分，应保留大主出小牌 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .west,
             plays: [(.west, [c(.spades, .seven)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ace), c(.spades, .three), c(.hearts, .six)]
    let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
    check(mode == .normal, "Test2 无分且非最后行动者 → normal", "mode=\(mode)")
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.count == 1 && chosen[0].rank == .three, "Test2 无分不浪费大主(出♠3保留♠A)",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a：P2 跟吊主，后手还有未知对手，0 分墩不裸送主分牌 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .west,
             plays: [(.west, [c(.spades, .seven)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ten), c(.spades, .three),
         c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
         c(.hearts, .king), c(.clubs, .king), c(.diamonds, .king),
         c(.hearts, .queen), c(.clubs, .queen), c(.diamonds, .queen)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.count == 1 && chosen[0].pointValue == 0 && chosen[0].rank == .three,
          "Test2a P2吊主未知0分墩不裸送主分牌",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a.1：开局主牌多也不直接领对王 ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand =
        [c(nil, .bigJoker), c(nil, .bigJoker),
         c(.spades, .three), c(.spades, .four), c(.spades, .six),
         c(.spades, .seven), c(.spades, .eight), c(.spades, .nine),
         c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.map { $0.shortDisplay } == ["♠3"],
          "Test2a.1 开局保留对王，先领低成本小主",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a.2：开局主牌多也不直接领对级牌 ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.hearts, .two), c(.hearts, .two),
         c(.spades, .three), c(.spades, .four), c(.spades, .six),
         c(.spades, .seven), c(.spades, .eight), c(.spades, .nine),
         c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.map { $0.shortDisplay } == ["♠3"],
          "Test2a.2 开局保留对级牌，先领低成本小主",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a.3：多张跟牌本门分牌被迫出，但其他门补牌不额外垫分给对手 ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.completedTricks = [enemiesVoidClubsTrick()]
    setTrick(s, lead: .south,
             plays: [(.south, [c(.hearts, .seven), c(.hearts, .seven)])],
             turn: .west)
    s.players[PlayerPosition.west.rawValue].hand =
        [c(.hearts, .king), c(.clubs, .ten), c(.diamonds, .three)]
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    let forcedPoint = chosen.contains { $0.suit == .hearts && $0.rank == .king }
    let usesSafeFill = chosen.contains { $0.suit == .diamonds && $0.rank == .three }
    let avoidsOffSuitPoint = !chosen.contains { $0.suit == .clubs && $0.rank == .ten }
    check(chosen.count == 2 && forcedPoint && usesSafeFill && avoidsOffSuitPoint,
          "Test2a.3 本门分牌被迫出，其他门补0分牌不垫分",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2b：无分但我是本队最后行动者且后手有对手 → 仍进入 Point Denial ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.spades, .seven)]), (.west, [c(.spades, .nine)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ace), c(.spades, .three), c(.hearts, .six)]
    let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
    check(mode == .pointDenial, "Test2b 无分+最后行动者+后手有对手 → POINT_DENIAL", "mode=\(mode)")
}

// ── Test 3：当前墩有分，AI 有多张可压牌 → 应选择能赢的牌，而非垫最小牌被轻松丢分 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .jack), c(.spades, .queen), c(.spades, .ace), c(.spades, .three)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let beats = chosen.count == 1 && CardComparator.beats(chosen[0], win10, trumpSuit: ts, trumpRank: tr)
    check(beats && chosen.allSatisfy { $0.pointValue == 0 }, "Test3 多可压牌时选择赢牌(非垫小牌)",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 4：AI 是本队最后一手且有分 → 触发 POINT_DENIAL ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ace), c(.spades, .four), c(.hearts, .six)]
    let mode = AIPlayer._testDetectTacticalMode(position: .north, state: s, evaluator: eval)
    check(mode == .pointDenial, "Test4 最后防守人+有分 → POINT_DENIAL", "mode=\(mode)")
}

// ── Test 5：A 是最大牌(代价高)，但不压就丢分 → 仍应压过(资产/早出大主只能轻微 tie-break) ──
do {
    let s = makeState(trump: ts, rank: tr, dealerTeam: 0)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.spades, .king)]), (.west, [c(.spades, .ace)])],  // 对手♠A领先, 墩内10分(K)
             turn: .north)
    // 北只有"小王"能压对手的♠A（A 上面是 级牌2/小王/大王）
    s.players[PlayerPosition.north.rawValue].hand =
        [c(nil, .smallJoker), c(.spades, .four), c(.spades, .three), c(.hearts, .six)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let beats = chosen.count == 1 && CardComparator.beats(chosen[0], c(.spades, .ace), trumpSuit: ts, trumpRank: tr)
    check(beats, "Test5 高代价大牌也要为守分压过(不因保主垫小牌)",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 6（需求6）：调试钩子已拆入 AIPlayer+Debug.swift，且各场景行为正确 ──
do {
    let defense = makeState(trump: ts, rank: tr)
    setTrick(defense, lead: .south,
             plays: [(.south, [c(.spades, .seven)]), (.west, [win10])],
             turn: .north)
    defense.players[PlayerPosition.north.rawValue].hand = [c(.spades, .ace), c(.spades, .four)]
    let m1 = AIPlayer._testDetectTacticalMode(position: .north, state: defense, evaluator: eval)

    let normal = makeState(trump: ts, rank: tr)
    setTrick(normal, lead: .west,
             plays: [(.west, [c(.spades, .seven)])],
             turn: .north)
    normal.players[PlayerPosition.north.rawValue].hand = [c(.spades, .ace), c(.spades, .three)]
    let m2 = AIPlayer._testDetectTacticalMode(position: .north, state: normal, evaluator: eval)

    check(m1 == .pointDenial && m2 == .normal, "Test6 调试钩子(Debug文件)识别 POINT_DENIAL / NORMAL",
          "m1=\(m1) m2=\(m2)")
}

// ── Test 7（需求7）：TrickContext 派生量正确 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south,
             plays: [(.south, [c(.hearts, .seven)]), (.west, [c(.hearts, .king)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.hearts, .ace), c(.hearts, .three), c(.spades, .four)]
    let mem = AIContext.build(state: s, ts: ts, tr: tr)
    let tc = TrickContext(position: .north, hand: s.player(.north).hand,
                          state: s, evaluator: eval, memory: mem)
    let ok = !tc.isLeading
        && tc.leadCards.map { $0.shortDisplay } == ["♥7"]
        && tc.leadSuit == .hearts
        && tc.trickPoints == 10
        && tc.currentWinner == .west
        && tc.opponentWinning && !tc.partnerWinning
        && !tc.isLastPlayer
        && tc.subsequentPositions == [.east]
        && tc.isLastEffectiveChanceForTeam
    check(ok, "Test7 TrickContext 派生量(先手花色/墩分/赢家/末手/最后防守人)正确")

    let leadState = makeState(trump: ts, rank: tr)
    leadState.currentTrick = Trick(leadPosition: .north)
    leadState.players[PlayerPosition.north.rawValue].hand = [c(.spades, .ace)]
    let memLead = AIContext.build(state: leadState, ts: ts, tr: tr)
    let tcLead = TrickContext(position: .north, hand: leadState.player(.north).hand,
                              state: leadState, evaluator: eval, memory: memLead)
    check(tcLead.isLeading && tcLead.currentWinner == nil && tcLead.leadSuit == nil && tcLead.trickPoints == 0,
          "Test7 TrickContext 空墩(我方先手)派生量正确")
}

// ── Test 8: Asset Lifecycle — a side winner ruffed now but with trump control → pull first, realize later ──
func eastVoidHeartsTrick() -> Trick {
    var t = Trick(leadPosition: .north)
    t.plays.append((position: .north, cards: [c(.hearts, .five)]))
    t.plays.append((position: .east, cards: [c(.clubs, .three)]))   // East discards ♣ -> void in ♥
    t.plays.append((position: .south, cards: [c(.hearts, .six)]))
    t.plays.append((position: .west, cards: [c(.hearts, .eight)]))
    return t
}
do {
    let s = makeState(trump: ts, rank: tr)
    s.completedTricks = [eastVoidHeartsTrick()]
    s.currentTrick = Trick(leadPosition: .south)
    s.currentLeader = .south
    s.currentTurn = .south
    s.players[PlayerPosition.south.rawValue].hand =
        [c(.hearts, .ace), c(.spades, .ace), c(.spades, .king),
         c(.spades, .queen), c(.spades, .jack), c(.clubs, .four)]
    let chosen = AIPlayer.chooseCards(position: .south, state: s, evaluator: eval)
    let isTrump = chosen.count == 1 && CardComparator.isTrump(chosen[0], trumpSuit: ts, trumpRank: tr)
    let notHeartAce = !(chosen.first?.suit == .hearts && chosen.first?.rank == .ace)
    check(isTrump && notHeartAce, "Test8 会被将吃的♥A → 先拔主(不盲目兑现)",
          "chosen=\(chosen.map { $0.shortDisplay })")

    // Contrast: no ruff threat -> cash ♥A directly
    let s2 = makeState(trump: ts, rank: tr)
    s2.currentTrick = Trick(leadPosition: .south)
    s2.currentLeader = .south
    s2.currentTurn = .south
    s2.players[PlayerPosition.south.rawValue].hand =
        [c(.hearts, .ace), c(.spades, .ace), c(.spades, .king),
         c(.spades, .queen), c(.spades, .jack), c(.clubs, .four)]
    let chosen2 = AIPlayer.chooseCards(position: .south, state: s2, evaluator: eval)
    check(chosen2.map { $0.shortDisplay } == ["♥A"], "Test8 无威胁 → 直接兑现♥A",
          "chosen=\(chosen2.map { $0.shortDisplay })")
}

print(String(repeating: "─", count: 40))
if failures.isEmpty {
    print("ALL TESTS PASSED ✅")
    exit(0)
} else {
    print("FAILED \(failures.count) test(s):")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
