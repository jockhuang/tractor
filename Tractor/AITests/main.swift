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

func sortedRanks(_ cards: [Card]) -> [Rank] {
    cards.map(\.rank).sorted { $0.rawValue < $1.rawValue }
}

func winnerAfter(
    _ state: GameState,
    position: PlayerPosition,
    cards: [Card],
    evaluator: TrickEvaluator
) -> PlayerPosition {
    var trick = state.currentTrick
    trick.plays.append((position: position, cards: cards))
    return evaluator.winner(of: trick)
}

func enemiesVoidClubsTrick() -> Trick {
    var t = Trick(leadPosition: .west)
    t.plays.append((position: .west, cards: [c(.clubs, .four)]))
    t.plays.append((position: .north, cards: [c(.diamonds, .four)]))
    t.plays.append((position: .east, cards: [c(.clubs, .five)]))
    t.plays.append((position: .south, cards: [c(.diamonds, .six)]))
    return t
}

func enemiesVoidTrumpTrick() -> Trick {
    var t = Trick(leadPosition: .east)
    t.plays.append((position: .east, cards: [c(.spades, .three)]))
    t.plays.append((position: .south, cards: [c(.hearts, .six)]))
    t.plays.append((position: .west, cards: [c(.spades, .four)]))
    t.plays.append((position: .north, cards: [c(.diamonds, .six)]))
    return t
}

func completedClubsRank(_ rank: Rank) -> Trick {
    var t = Trick(leadPosition: .east)
    t.plays.append((position: .east, cards: [c(.clubs, rank)]))
    t.plays.append((position: .south, cards: [c(.clubs, rank)]))
    t.plays.append((position: .west, cards: [c(.clubs, .six)]))
    t.plays.append((position: .north, cards: [c(.clubs, .seven)]))
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

// ── Safe Banked Point Winner：队友稳大时先清未来输张，不急着垫可自行兑现的分牌 ──
do {
    func chosenDiscard(pointCard: Card, higherRanksPlayed: [Rank]) -> (Card, Bool, Double, Double) {
        let s = makeState(trump: ts, rank: tr)
        s.completedTricks = [enemiesVoidTrumpTrick()] + higherRanksPlayed.map(completedClubsRank)
        setTrick(s, lead: .east,
                 plays: [(.east, [c(.hearts, .ace)]), (.south, [c(.hearts, .three)])],
                 turn: .west)
        let loser = c(.diamonds, .three)
        let hand = [pointCard, loser]
        s.players[PlayerPosition.west.rawValue].hand = hand
        let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)[0]
        let banked = AIPlayer.CardCombination(cards: [pointCard], pattern: .single(pointCard))
        let danger = AIPlayer.CardCombination(cards: [loser], pattern: .single(loser))
        return (
            chosen,
            AIPlayer.isSafeBankedPointWinner(candidate: banked, hand: hand, gameState: s),
            AIPlayer.futureDiscardRisk(candidate: banked, hand: hand, gameState: s),
            AIPlayer.futureDiscardRisk(candidate: danger, hand: hand, gameState: s)
        )
    }

    let trumpTen = chosenDiscard(pointCard: c(.spades, .ten), higherRanksPlayed: [])
    check(trumpTen.0.suit == .diamonds && trumpTen.0.rank == .three && trumpTen.1 && trumpTen.3 > trumpTen.2,
          "Test12a 队友稳大保留安全主10，先垫小副3",
          "chosen=\(trumpTen.0.shortDisplay), banked=\(trumpTen.1), risks=\(trumpTen.2)/\(trumpTen.3)")

    let biggestKing = chosenDiscard(pointCard: c(.clubs, .king), higherRanksPlayed: [.ace])
    check(biggestKing.0.suit == .diamonds && biggestKing.0.rank == .three && biggestKing.1,
          "Test12b 队友稳大保留已知最大K，先垫小副3",
          "chosen=\(biggestKing.0.shortDisplay), banked=\(biggestKing.1)")

    let biggestTen = chosenDiscard(
        pointCard: c(.clubs, .ten), higherRanksPlayed: [.jack, .queen, .king, .ace]
    )
    check(biggestTen.0.suit == .diamonds && biggestTen.0.rank == .three && biggestTen.1,
          "Test12c 队友稳大保留已知最大10，先垫小副3",
          "chosen=\(biggestTen.0.shortDisplay), banked=\(biggestTen.1)")
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

// ── Test 2a.0a：P2 跟吊主限制的是分牌暴露，不是大主强度；高主动权需求可用无分主A抢出牌权 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .west,
             plays: [(.west, [c(.spades, .seven)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .ace), c(.spades, .three),
         c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
         c(.hearts, .king), c(.hearts, .king),
         c(.clubs, .queen), c(.clubs, .queen),
         c(.diamonds, .jack), c(.diamonds, .jack)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.map { $0.shortDisplay } == ["♠A"],
          "Test2a.0a P2高主动权需求可用无分控制主抢出牌权",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a.0b：同样需要主动权时，主K仍因 Point Exposure 被压下去 ──
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .west,
             plays: [(.west, [c(.spades, .seven)])],
             turn: .north)
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.spades, .king), c(.spades, .three),
         c(.hearts, .ace), c(.clubs, .ace), c(.diamonds, .ace),
         c(.hearts, .king), c(.hearts, .king),
         c(.clubs, .queen), c(.clubs, .queen),
         c(.diamonds, .jack), c(.diamonds, .jack)]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.map { $0.shortDisplay } == ["♠3"],
          "Test2a.0b P2不把主K送进后手对手可能赢的0分墩",
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

// ── Test 2a.4：非临界分线，孤立分牌不能压过王/级牌控制资产 ──
do {
    let s = makeState(trump: ts, rank: tr, dealerTeam: 0)
    s.attackScore = 0
    setTrick(s, lead: .west,
             plays: [(.west, [c(.hearts, .seven), c(.hearts, .seven)])],
             turn: .north)
    let hand = [c(nil, .bigJoker), c(.hearts, .two), c(.clubs, .king), c(.diamonds, .three)]
    s.players[PlayerPosition.north.rawValue].hand = hand
    let ctx = AIContext.build(state: s, ts: ts, tr: tr)
    let chosen = AIPlayer.smartDiscard(from: hand, count: 2,
                                       enemyWinning: true,
                                       ts: ts, tr: tr,
                                       myTeam: PlayerPosition.north.team,
                                       ctx: ctx,
                                       state: s,
                                       position: .north,
                                       evaluator: eval,
                                       fullHand: hand)
    let dropsSmallSide = chosen.contains { $0.suit == .diamonds && $0.rank == .three }
    let dropsPoint = chosen.contains { $0.suit == .clubs && $0.rank == .king }
    let preservesControl = !chosen.contains { $0.rank == .bigJoker || $0.rank == tr }
    check(chosen.count == 2 && dropsSmallSide && dropsPoint && preservesControl,
          "Test2a.4 非临界分线：垫孤立K，不丢王/级牌保K",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 2a.5：临界分线，只有此时才提升分牌保护权重 ──
do {
    let s = makeState(trump: ts, rank: tr, dealerTeam: 0)
    s.attackScore = 30
    setTrick(s, lead: .west,
             plays: [(.west, [c(.hearts, .seven), c(.hearts, .seven)])],
             turn: .north)
    let hand = [c(nil, .bigJoker), c(.hearts, .two), c(.clubs, .king), c(.diamonds, .three)]
    s.players[PlayerPosition.north.rawValue].hand = hand
    let ctx = AIContext.build(state: s, ts: ts, tr: tr)
    let chosen = AIPlayer.smartDiscard(from: hand, count: 2,
                                       enemyWinning: true,
                                       ts: ts, tr: tr,
                                       myTeam: PlayerPosition.north.team,
                                       ctx: ctx,
                                       state: s,
                                       position: .north,
                                       evaluator: eval,
                                       fullHand: hand)
    let dropsSmallSide = chosen.contains { $0.suit == .diamonds && $0.rank == .three }
    let protectsPoint = !chosen.contains { $0.suit == .clubs && $0.rank == .king }
    let preservesBigJoker = !chosen.contains { $0.rank == .bigJoker }
    check(chosen.count == 2 && dropsSmallSide && protectsPoint && preservesBigJoker,
          "Test2a.5 临界分线：临时保护K，但仍保最高控制大王",
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

// ── Test 9：队友已绝某副牌且该门仍有分未出 → 优先引出该门，不被小主过渡抢走 ──
func southVoidHeartsTrick() -> Trick {
    var t = Trick(leadPosition: .west)
    t.plays.append((position: .west, cards: [c(.hearts, .seven)]))
    t.plays.append((position: .north, cards: [c(.hearts, .eight)]))
    t.plays.append((position: .east, cards: [c(.hearts, .nine)]))
    t.plays.append((position: .south, cards: [c(.clubs, .three)]))
    return t
}
do {
    let s = makeState(trump: ts, rank: tr)
    s.completedTricks = [southVoidHeartsTrick()]
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand =
        [c(.hearts, .four),
         c(.spades, .three), c(.spades, .four), c(.spades, .six),
         c(.clubs, .four), c(.diamonds, .six), c(.clubs, .seven)]

    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(chosen.map { $0.shortDisplay } == ["♥4"],
          "Test9 队友绝红桃且红桃有分未出 → 领红桃引队友垫分",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 10：Endgame Control Asset Preservation — 主对子 + 副牌垃圾，残局先处理副牌 ──
do {
    let s = makeState(trump: ts, rank: tr, dealerTeam: 0)
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
    s.players[PlayerPosition.west.rawValue].hand =
        [c(.spades, .ace), c(.spades, .ace), c(.hearts, .three), c(.clubs, .four)]
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(chosen.count == 1 && !CardComparator.isTrump(chosen[0], trumpSuit: ts, trumpRank: tr),
          "Test10 残局主对子+副牌垃圾 → 先出副牌保留主对子",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 11：Endgame Control Asset Preservation — 主拖拉机 + 副牌，不提前出拖拉机或拆拖拉机 ──
do {
    let s = makeState(trump: ts, rank: tr, dealerTeam: 0)
    s.currentTrick = Trick(leadPosition: .east)
    s.currentLeader = .east
    s.currentTurn = .east
    s.completedTricks = [
        {
            // 东的两名对手（南、北）都在同一墩明确暴露无主。
            var t = Trick(leadPosition: .west)
            t.plays.append((position: .west, cards: [c(.spades, .three)]))
            t.plays.append((position: .north, cards: [c(.hearts, .six)]))
            t.plays.append((position: .east, cards: [c(.spades, .four)]))
            t.plays.append((position: .south, cards: [c(.diamonds, .six)]))
            return t
        }()
    ]
    s.players[PlayerPosition.east.rawValue].hand =
        [c(.spades, .queen), c(.spades, .queen), c(.spades, .king), c(.spades, .king), c(.hearts, .three)]
    let chosen = AIPlayer.chooseCards(position: .east, state: s, evaluator: eval)
    check(chosen.count == 1 && chosen[0].suit == .hearts && chosen[0].rank == .three,
          "Test11 残局主拖拉机+副牌 → 先出副牌保留拖拉机",
          "chosen=\(chosen.map { $0.shortDisplay })")
}

// ── Test 13：甩牌失败后由甩牌方自动领出最小失败组件 ──
do {
    let singleSlamCards = [
        c(.hearts, .five),
        c(.hearts, .seven),
        c(.hearts, .ace)
    ]
    let singleSlam = eval.slamInfo(of: singleSlamCards)!
    let singleFailure = eval.slamFailure(
        slam: singleSlam,
        opponentHands: [
            .west: [c(.hearts, .six)],
            .north: [c(.clubs, .three)],
            .east: [c(.hearts, .nine)]
        ]
    )
    check(
        singleFailure?.forcedKind == .single &&
            singleFailure?.forcedLeadCards.map(\.shortDisplay) == ["♥5"] &&
            singleFailure?.penaltyPoints == 20,
        "Test13a 多个单张甩牌失败 → 强制出最小失败单张",
        "forced=\(singleFailure?.forcedLeadCards.map { $0.shortDisplay } ?? []), penalty=\(singleFailure?.penaltyPoints ?? -1)"
    )

    let pairSlamCards = [
        c(.hearts, .four), c(.hearts, .four),
        c(.hearts, .seven), c(.hearts, .seven),
        c(.hearts, .ten)
    ]
    let pairSlam = eval.slamInfo(of: pairSlamCards)!
    let pairFailure = eval.slamFailure(
        slam: pairSlam,
        opponentHands: [
            .west: [c(.hearts, .five), c(.hearts, .five)],
            .north: [c(.hearts, .eight), c(.hearts, .eight)],
            .east: [c(.hearts, .jack)]
        ]
    )
    check(
        pairFailure?.forcedKind == .pair &&
            pairFailure?.forcedLeadCards.map(\.shortDisplay) == ["♥4", "♥4"] &&
            pairFailure?.penaltyPoints == 50,
        "Test13b 对子和单张同时失败 → 优先出最小失败对子",
        "forced=\(pairFailure?.forcedLeadCards.map { $0.shortDisplay } ?? []), penalty=\(pairFailure?.penaltyPoints ?? -1)"
    )

    let tractorSlamCards = [
        c(.hearts, .three), c(.hearts, .three),
        c(.hearts, .four), c(.hearts, .four),
        c(.hearts, .seven), c(.hearts, .seven),
        c(.hearts, .eight), c(.hearts, .eight),
        c(.hearts, .queen), c(.hearts, .queen),
        c(.hearts, .ace)
    ]
    let tractorSlam = eval.slamInfo(of: tractorSlamCards)!
    let tractorFailure = eval.slamFailure(
        slam: tractorSlam,
        opponentHands: [
            .west: [
                c(.hearts, .five), c(.hearts, .five),
                c(.hearts, .six), c(.hearts, .six)
            ],
            .north: [
                c(.hearts, .nine), c(.hearts, .nine),
                c(.hearts, .ten), c(.hearts, .ten)
            ],
            .east: [c(.hearts, .king), c(.hearts, .king)]
        ]
    )
    check(
        tractorFailure?.forcedKind == .tractor &&
            tractorFailure?.forcedLeadCards.map(\.rank) == [.three, .three, .four, .four] &&
            tractorFailure?.penaltyPoints == 100,
        "Test13c 拖拉机/对子同时失败 → 优先出最小失败拖拉机",
        "forced=\(tractorFailure?.forcedLeadCards.map { $0.shortDisplay } ?? []), penalty=\(tractorFailure?.penaltyPoints ?? -1)"
    )
}

// ── Test 14：AI 组合牌战术（甩牌、强制跟型、将吃、盖吃） ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.hearts, .king), c(.hearts, .king), c(.hearts, .ace),
        c(.clubs, .three)
    ]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let slam = eval.slamInfo(of: chosen)
    check(
        sortedRanks(chosen) == [.king, .king, .ace] &&
            slam?.pairs.count == 1 && slam?.singles.count == 1,
        "Test14a AI 把安全 A+KK 作为完整甩牌领出",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    // 模拟甩牌失败已收缩为 ♥6 对：北家的 ♥Q 对曾证明失败，
    // 但现在只按普通对子跟牌，队友领先时出最小 ♥3 对。
    let s = makeState(trump: ts, rank: tr)
    let leadPair = [c(.hearts, .six), c(.hearts, .six)]
    setTrick(
        s,
        lead: .south,
        plays: [
            (.south, leadPair),
            (.west, [c(.hearts, .four), c(.hearts, .four)])
        ],
        turn: .north
    )
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.hearts, .three), c(.hearts, .three),
        c(.hearts, .queen), c(.hearts, .queen)
    ]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(
        sortedRanks(chosen) == [.three, .three],
        "Test14b 甩牌失败后 AI 无证明牌强制约束",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadPair = [c(.hearts, .king), c(.hearts, .king)]
    let hand = [
        c(.hearts, .three), c(.hearts, .three),
        c(.hearts, .ace), c(.hearts, .ace),
        c(.clubs, .four)
    ]
    setTrick(s, lead: .south, plays: [(.south, leadPair)], turn: .west)
    s.players[PlayerPosition.west.rawValue].hand = hand
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(
        eval.isValidPlay(selected: chosen, hand: hand, leadCards: leadPair) &&
            sortedRanks(chosen) == [.ace, .ace] &&
            AIPlayer.pairRepresentative(of: chosen, trumpSuit: ts, trumpRank: tr) != nil &&
            winnerAfter(s, position: .west, cards: chosen, evaluator: eval) == .west,
        "Test14c AI 强制跟对子并用 AA 抢 20 分墩",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadTractor = [
        c(.hearts, .nine), c(.hearts, .nine),
        c(.hearts, .ten), c(.hearts, .ten)
    ]
    let hand = [
        c(.hearts, .three), c(.hearts, .three),
        c(.hearts, .four), c(.hearts, .four),
        c(.hearts, .jack), c(.hearts, .jack),
        c(.hearts, .queen), c(.hearts, .queen),
        c(.clubs, .four)
    ]
    setTrick(s, lead: .south, plays: [(.south, leadTractor)], turn: .west)
    s.players[PlayerPosition.west.rawValue].hand = hand
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(
        eval.isValidPlay(selected: chosen, hand: hand, leadCards: leadTractor) &&
            sortedRanks(chosen) == [.jack, .jack, .queen, .queen] &&
            AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount == 2 &&
            winnerAfter(s, position: .west, cards: chosen, evaluator: eval) == .west,
        "Test14d AI 强制跟拖拉机并用 JQ 拖拉机抢分",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadPair = [c(.hearts, .king), c(.hearts, .king)]
    s.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .three), c(.spades, .three),
        c(.spades, .ace), c(.spades, .ace),
        c(.clubs, .four)
    ]
    setTrick(s, lead: .south, plays: [(.south, leadPair)], turn: .west)
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(
        sortedRanks(chosen) == [.three, .three] &&
            chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            winnerAfter(s, position: .west, cards: chosen, evaluator: eval) == .west,
        "Test14e AI 用最小主对子将吃副牌对子",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadPair = [c(.hearts, .king), c(.hearts, .king)]
    let firstRuff = [c(.spades, .three), c(.spades, .three)]
    setTrick(
        s,
        lead: .south,
        plays: [(.south, leadPair), (.west, firstRuff)],
        turn: .north
    )
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.spades, .four), c(.spades, .four),
        c(.spades, .ace), c(.spades, .ace),
        c(.clubs, .six)
    ]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(
        sortedRanks(chosen) == [.four, .four] &&
            chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            winnerAfter(s, position: .north, cards: chosen, evaluator: eval) == .north,
        "Test14f AI 用更高主对子盖吃",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadTractor = [
        c(.hearts, .nine), c(.hearts, .nine),
        c(.hearts, .ten), c(.hearts, .ten)
    ]
    setTrick(s, lead: .south, plays: [(.south, leadTractor)], turn: .west)
    s.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .three), c(.spades, .three),
        c(.spades, .four), c(.spades, .four),
        c(.spades, .jack), c(.spades, .jack),
        c(.spades, .queen), c(.spades, .queen),
        c(.clubs, .six)
    ]
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(
        sortedRanks(chosen) == [.three, .three, .four, .four] &&
            chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount == 2 &&
            winnerAfter(s, position: .west, cards: chosen, evaluator: eval) == .west,
        "Test14g AI 用完整主拖拉机将吃副牌拖拉机",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadTractor = [
        c(.hearts, .nine), c(.hearts, .nine),
        c(.hearts, .ten), c(.hearts, .ten)
    ]
    let firstRuff = [
        c(.spades, .three), c(.spades, .three),
        c(.spades, .four), c(.spades, .four)
    ]
    setTrick(
        s,
        lead: .south,
        plays: [(.south, leadTractor), (.west, firstRuff)],
        turn: .north
    )
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.spades, .five), c(.spades, .five),
        c(.spades, .six), c(.spades, .six),
        c(.spades, .jack), c(.spades, .jack),
        c(.spades, .queen), c(.spades, .queen),
        c(.clubs, .six)
    ]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let firstHigh = AIPlayer.tractorInfo(
        of: firstRuff, trumpSuit: ts, trumpRank: tr
    )?.highCard
    let chosenHigh = AIPlayer.tractorInfo(
        of: chosen, trumpSuit: ts, trumpRank: tr
    )?.highCard
    let raises = firstHigh.flatMap { first in
        chosenHigh.map {
            CardComparator.beats($0, first, trumpSuit: ts, trumpRank: tr)
        }
    } ?? false
    check(
        chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount == 2 &&
            raises &&
            winnerAfter(s, position: .north, cards: chosen, evaluator: eval) == .north,
        "Test14h AI 用更高完整主拖拉机盖吃",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadSlam = [
        c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
    ]
    setTrick(s, lead: .south, plays: [(.south, leadSlam)], turn: .west)
    s.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .three), c(.spades, .three), c(.spades, .four),
        c(.spades, .jack), c(.spades, .jack), c(.spades, .queen),
        c(.clubs, .six)
    ]
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    let structure = eval.slamInfo(of: chosen)
    check(
        sortedRanks(chosen) == [.three, .three, .four] &&
            chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            structure?.pairs.count == 1 && structure?.singles.count == 1 &&
            winnerAfter(s, position: .west, cards: chosen, evaluator: eval) == .west,
        "Test14i AI 用匹配的主对子+单张将吃甩牌",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadSlam = [
        c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
    ]
    let firstRuff = [
        c(.spades, .three), c(.spades, .three), c(.spades, .four)
    ]
    setTrick(
        s,
        lead: .south,
        plays: [(.south, leadSlam), (.west, firstRuff)],
        turn: .north
    )
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.spades, .five), c(.spades, .five), c(.spades, .six),
        c(.spades, .jack), c(.spades, .jack), c(.spades, .queen),
        c(.clubs, .six)
    ]
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    let structure = eval.slamInfo(of: chosen)
    check(
        sortedRanks(chosen) == [.five, .five, .six] &&
            chosen.allSatisfy { eval.cardSuit($0) == nil } &&
            structure?.pairs.count == 1 && structure?.singles.count == 1 &&
            winnerAfter(s, position: .north, cards: chosen, evaluator: eval) == .north,
        "Test14j AI 用更高匹配结构盖吃甩牌",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

do {
    let s = makeState(trump: ts, rank: tr)
    let leadSlam = [
        c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
    ]
    let jokerPair = [c(nil, .bigJoker), c(nil, .bigJoker)]
    let sideDiscards = [
        c(.clubs, .three), c(.diamonds, .four), c(.clubs, .six)
    ]
    let hand = jokerPair + sideDiscards
    setTrick(s, lead: .south, plays: [(.south, leadSlam)], turn: .west)
    s.players[PlayerPosition.west.rawValue].hand = hand

    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: eval)
    check(
        eval.isValidPlay(selected: chosen, hand: hand, leadCards: leadSlam) &&
            Set(chosen.map(\.id)) == Set(sideDiscards.map(\.id)) &&
            !chosen.contains {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            },
        "Test14k 对手甩牌且无法匹配将吃结构 → 只垫副牌不拆主牌",
        "chosen=\(chosen.map { $0.shortDisplay })"
    )
}

// ── Test 15：残局保留最后一手主牌控制，争取有分底牌 ──
do {
    func trumpExhaustionEvidence() -> Trick {
        var trick = Trick(leadPosition: .east)
        trick.plays.append((position: .east, cards: [c(.spades, .seven)]))
        trick.plays.append((position: .south, cards: [c(.hearts, .four)]))
        trick.plays.append((position: .west, cards: [c(.spades, .eight)]))
        trick.plays.append((position: .north, cards: [c(.clubs, .six)]))
        return trick
    }

    func endgameState(dealer: PlayerPosition, kitty: [Card]) -> (GameState, [Card], AIContext) {
        let s = makeState(trump: ts, rank: tr, dealerTeam: dealer.team)
        s.dealerPosition = dealer
        s.completedTricks = [trumpExhaustionEvidence()]
        s.currentTrick = Trick(leadPosition: .west)
        s.currentLeader = .west
        s.currentTurn = .west
        s.kitty = kitty
        let hand = [
            c(.spades, .three), c(.spades, .four), c(.spades, .ace),
            c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)
        ]
        s.players[PlayerPosition.west.rawValue].hand = hand
        return (s, hand, AIContext.build(state: s, ts: ts, tr: tr))
    }

    let pointKitty = [
        c(.hearts, .five), c(.clubs, .ten),
        c(.hearts, .three), c(.hearts, .four),
        c(.clubs, .six), c(.clubs, .seven),
        c(.diamonds, .eight), c(.diamonds, .nine)
    ]
    let positive = endgameState(dealer: .west, kitty: pointKitty)
    let positiveKnowledge = AIPlayer.kittyPointKnowledge(
        position: .west,
        hand: positive.1,
        state: positive.0,
        ctx: positive.2
    )
    let positiveChoice = AIPlayer.chooseCards(
        position: .west,
        state: positive.0,
        evaluator: eval
    )
    check(
        positive.2.allEnemiesVoid(myTeam: PlayerPosition.west.team, key: "TRUMP") &&
            positiveKnowledge == .knownPositive(15) &&
            positiveChoice.count == 1 &&
            !positiveChoice.contains {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            },
        "Test15a 已知底牌有分且对手无主 → 先清副牌保留末轮主控",
        "knowledge=\(positiveKnowledge), chosen=\(positiveChoice.map { $0.shortDisplay })"
    )

    let zero = endgameState(
        dealer: .west,
        kitty: [
            c(.hearts, .three), c(.hearts, .four),
            c(.clubs, .six), c(.clubs, .seven),
            c(.diamonds, .eight), c(.diamonds, .nine),
            c(.hearts, .jack), c(.clubs, .queen)
        ]
    )
    let zeroKnowledge = AIPlayer.kittyPointKnowledge(
        position: .west,
        hand: zero.1,
        state: zero.0,
        ctx: zero.2
    )
    let zeroOverride = AIPlayer.knownPointKittyEndgameLead(
        position: .west,
        hand: zero.1,
        state: zero.0,
        evaluator: eval,
        ctx: zero.2
    )
    check(
        zeroKnowledge == .knownZero && zeroOverride == nil,
        "Test15b 已知底牌0分 → 不启用专门保底覆盖策略",
        "knowledge=\(zeroKnowledge), override=\(zeroOverride?.map { $0.shortDisplay } ?? [])"
    )

    let hidden = endgameState(dealer: .south, kitty: pointKitty)
    let hiddenKnowledge = AIPlayer.kittyPointKnowledge(
        position: .west,
        hand: hidden.1,
        state: hidden.0,
        ctx: hidden.2
    )
    check(
        hiddenKnowledge == .unknown,
        "Test15c 非庄家不能偷看真实底牌分",
        "knowledge=\(hiddenKnowledge)"
    )
}

// ── Test 16：AI 审查回归——信息推断、甩牌盖吃、隐藏牌约束与战术模式 ──
do {
    var partialFollow = Trick(leadPosition: .south)
    partialFollow.plays = [
        (.south, [c(.hearts, .seven), c(.hearts, .seven)]),
        (.west, [c(.hearts, .king), c(.clubs, .three)]),
        (.north, [c(.hearts, .four), c(.hearts, .five)]),
        (.east, [c(.hearts, .six), c(.hearts, .eight)])
    ]

    let completedState = makeState(trump: ts, rank: tr)
    completedState.completedTricks = [partialFollow]
    let completedContext = AIContext.build(state: completedState, ts: ts, tr: tr)
    check(
        completedContext.isVoid(.west, key: Suit.hearts.rawValue),
        "Test16a 部分跟牌后正确记录绝门"
    )

    let currentState = makeState(trump: ts, rank: tr)
    currentState.currentTrick = partialFollow
    let currentContext = AIContext.build(state: currentState, ts: ts, tr: tr)
    check(
        currentContext.isVoid(.west, key: Suit.hearts.rawValue),
        "Test16b 当前墩绝门立即进入AI记忆"
    )

    let leadSlam = [
        c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
    ]
    let leadInfo = eval.slamInfo(of: leadSlam)!
    let highSingleWinner = [
        c(.spades, .three), c(.spades, .three), c(.spades, .ace)
    ]
    let structurallyHigher = [
        c(.spades, .five), c(.spades, .five), c(.spades, .six)
    ]
    let structuralBuild = AIPlayer.buildMatchingSlamTrump(
        slam: leadInfo,
        trumpCards: structurallyHigher,
        winningCards: highSingleWinner,
        ts: ts,
        tr: tr
    )
    var structuralTrick = Trick(leadPosition: .south)
    structuralTrick.plays = [
        (.south, leadSlam),
        (.west, highSingleWinner),
        (.north, structuralBuild ?? [])
    ]
    check(
        structuralBuild != nil && eval.winner(of: structuralTrick) == .north,
        "Test16c 甩牌盖吃按对子结构而非最高单张比较",
        "built=\(structuralBuild?.map { $0.shortDisplay } ?? [])"
    )

    let pairSlotSlam = [
        c(.hearts, .seven), c(.hearts, .seven),
        c(.hearts, .nine), c(.hearts, .jack), c(.hearts, .king)
    ]
    let lowerTractorWithAce = [
        c(.spades, .three), c(.spades, .three),
        c(.spades, .four), c(.spades, .four),
        c(.spades, .ace)
    ]
    let higherTractorWithLowSingle = [
        c(.spades, .five), c(.spades, .five),
        c(.spades, .six), c(.spades, .six),
        c(.spades, .seven)
    ]
    var tractorCoversPairTrick = Trick(leadPosition: .south)
    tractorCoversPairTrick.plays = [
        (.south, pairSlotSlam),
        (.west, lowerTractorWithAce),
        (.north, higherTractorWithLowSingle)
    ]
    check(
        eval.winner(of: tractorCoversPairTrick) == .north,
        "Test16c.1 连对覆盖甩牌对子槽时仍按最高对子比较"
    )

    let lowAndWinningPairs = [
        c(.spades, .three), c(.spades, .three), c(.spades, .four),
        c(.spades, .seven), c(.spades, .seven)
    ]
    let mediumWinner = [
        c(.spades, .five), c(.spades, .five), c(.spades, .six)
    ]
    let searchedBuild = AIPlayer.buildMatchingSlamTrump(
        slam: leadInfo,
        trumpCards: lowAndWinningPairs,
        winningCards: mediumWinner,
        ts: ts,
        tr: tr
    )
    check(
        searchedBuild?.filter { $0.rank == .seven }.count == 2,
        "Test16d 最弱结构压不过时继续搜索更大可赢组合",
        "built=\(searchedBuild?.map { $0.shortDisplay } ?? [])"
    )

    let sampleState = makeState(trump: ts, rank: tr)
    sampleState.dealerPosition = .south
    var voidEvidence = Trick(leadPosition: .west)
    voidEvidence.plays = [
        (.west, [c(.hearts, .three)]),
        (.north, [c(.clubs, .three)]),
        (.east, [c(.diamonds, .three)]),
        (.south, [c(.hearts, .four)])
    ]
    sampleState.completedTricks = [voidEvidence]
    let afterPlayed = AIPlayer.removeKnownFaces(
        from: Deck.doubleDeck(),
        knownCards: voidEvidence.plays.flatMap(\.cards)
    )
    let currentKnownHand = Array(afterPlayed.prefix(24))
    sampleState.kitty = Array(afterPlayed.dropFirst(24).prefix(8))
    sampleState.players[PlayerPosition.south.rawValue].hand = currentKnownHand
    for position in [PlayerPosition.west, .north, .east] {
        // 隐藏牌内容不会被读取；这里只需要公开的剩余手牌张数。
        sampleState.players[position.rawValue].hand = Array(afterPlayed.prefix(24))
    }
    var allSamplesRespectKnowledge = true
    for seed in 1...20 {
        var sampleRNG = AIPlayer.MonteCarloRNG(seed: UInt64(seed))
        let sampled = AIPlayer.sampleHiddenHands(
            currentPosition: .south,
            currentHand: currentKnownHand,
            playedCandidate: [],
            state: sampleState,
            rng: &sampleRNG
        )
        let correctCounts = [PlayerPosition.west, .north, .east].allSatisfy {
            sampled[$0, default: []].count == 24
        }
        let voidViolation = [PlayerPosition.north, .east].contains { position in
            sampled[position, default: []].contains {
                AIContext.suitKey($0, ts: ts, tr: tr) == Suit.hearts.rawValue
            }
        }
        allSamplesRespectKnowledge = allSamplesRespectKnowledge
            && correctCounts
            && !voidViolation
    }
    check(
        allSamplesRespectKnowledge,
        "Test16e 蒙特卡洛发牌严格遵守绝门和手牌容量"
    )

    let emptyState = makeState(trump: ts, rank: tr)
    let emptyContext = AIContext.build(state: emptyState, ts: ts, tr: tr)
    check(
        !AIPlayer.isSafeTrump(c(nil, .smallJoker), hand: [], ts: ts, tr: tr, ctx: emptyContext) &&
            AIPlayer.isSafeTrump(c(nil, .bigJoker), hand: [], ts: ts, tr: tr, ctx: emptyContext),
        "Test16f 小王仍有未知大王时不能判定锁定"
    )

    let ownControlledHigher = [
        c(.hearts, .king), c(.hearts, .ace), c(.hearts, .ace)
    ]
    check(
        emptyContext.isEffectivelyBiggest(
            ownControlledHigher[0],
            ts: ts,
            tr: tr,
            hand: ownControlledHigher
        ),
        "Test16g 自己持有全部更大牌时正确识别当前最大"
    )

    let modeState = makeState(trump: ts, rank: tr)
    setTrick(
        modeState,
        lead: .south,
        plays: [(.south, [c(.hearts, .ten)])],
        turn: .west
    )
    modeState.players[PlayerPosition.west.rawValue].hand = [
        c(.hearts, .king), c(.hearts, .three)
    ]
    check(
        AIPlayer._testDetectTacticalMode(
            position: .west,
            state: modeState,
            evaluator: eval
        ) == .forceOpponentCost,
        "Test16h 暂时压过但未锁定时进入逼牌模式"
    )

    let seed0 = AIPlayer.monteCarloSeed(
        position: .west,
        state: modeState,
        simulation: 0
    )
    let seed0Again = AIPlayer.monteCarloSeed(
        position: .west,
        state: modeState,
        simulation: 0
    )
    let seed1 = AIPlayer.monteCarloSeed(
        position: .west,
        state: modeState,
        simulation: 1
    )
    check(
        seed0 == seed0Again && seed0 != seed1,
        "Test16i 同轮候选共享隐藏世界且不同模拟仍有独立种子"
    )
}

// ── Test 17：P2/P3 已知后手对手也绝门时，只用主A/级牌竞争 ──
do {
    func playerVoidHeartsTrick(_ voidPosition: PlayerPosition) -> Trick {
        var trick = Trick(leadPosition: .south)
        let ranks: [PlayerPosition: Rank] = [
            .south: .three,
            .west: .four,
            .north: .six,
            .east: .seven
        ]
        for position in PlayerPosition.allCases {
            let card = position == voidPosition
                ? c(.clubs, .eight)
                : c(.hearts, ranks[position]!)
            trick.plays.append((position: position, cards: [card]))
        }
        return trick
    }

    let p2Strong = makeState(trump: ts, rank: tr)
    p2Strong.completedTricks = [playerVoidHeartsTrick(.north)]
    setTrick(
        p2Strong,
        lead: .south,
        plays: [(.south, [c(.hearts, .king)])],
        turn: .west
    )
    p2Strong.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .ace), c(.clubs, .two), c(.spades, .ten),
        c(nil, .smallJoker), c(.diamonds, .three)
    ]
    let p2StrongChosen = AIPlayer.chooseCards(position: .west, state: p2Strong, evaluator: eval)
    check(
        p2StrongChosen.map(\.shortDisplay) == ["♠A"],
        "Test17a P2用最小可赢主A/级牌竞争，不用主分或王",
        "chosen=\(p2StrongChosen.map(\.shortDisplay))"
    )

    let p3Strong = makeState(trump: ts, rank: tr)
    p3Strong.completedTricks = [playerVoidHeartsTrick(.east)]
    setTrick(
        p3Strong,
        lead: .south,
        plays: [
            (.south, [c(.hearts, .five)]),
            (.west, [c(.hearts, .king)])
        ],
        turn: .north
    )
    p3Strong.players[PlayerPosition.north.rawValue].hand = [
        c(.clubs, .two), c(.spades, .ten),
        c(nil, .bigJoker), c(.diamonds, .three)
    ]
    let p3StrongChosen = AIPlayer.chooseCards(position: .north, state: p3Strong, evaluator: eval)
    check(
        p3StrongChosen.map(\.shortDisplay) == ["♣2"],
        "Test17b P3有级牌时用级牌竞争，不用主分或王",
        "chosen=\(p3StrongChosen.map(\.shortDisplay))"
    )

    let p2Weak = makeState(trump: ts, rank: tr)
    p2Weak.completedTricks = [playerVoidHeartsTrick(.north)]
    setTrick(
        p2Weak,
        lead: .south,
        plays: [(.south, [c(.hearts, .king)])],
        turn: .west
    )
    p2Weak.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .ten), c(.spades, .five), c(.diamonds, .three)
    ]
    let p2WeakChosen = AIPlayer.chooseCards(position: .west, state: p2Weak, evaluator: eval)
    check(
        p2WeakChosen.map(\.shortDisplay) == ["♦3"],
        "Test17c P2只有弱主/主分时垫0分副牌",
        "chosen=\(p2WeakChosen.map(\.shortDisplay))"
    )

    let p3Jokers = makeState(trump: ts, rank: tr)
    p3Jokers.completedTricks = [playerVoidHeartsTrick(.east)]
    setTrick(
        p3Jokers,
        lead: .south,
        plays: [
            (.south, [c(.hearts, .five)]),
            (.west, [c(.hearts, .king)])
        ],
        turn: .north
    )
    p3Jokers.players[PlayerPosition.north.rawValue].hand = [
        c(nil, .bigJoker), c(nil, .smallJoker),
        c(.spades, .ten), c(.diamonds, .three)
    ]
    let p3JokersChosen = AIPlayer.chooseCards(position: .north, state: p3Jokers, evaluator: eval)
    check(
        p3JokersChosen.map(\.shortDisplay) == ["♦3"],
        "Test17d P3该类竞争不动大小王，改垫0分副牌",
        "chosen=\(p3JokersChosen.map(\.shortDisplay))"
    )
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
