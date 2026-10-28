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

func seat(after position: PlayerPosition, offset: Int) -> PlayerPosition {
    PlayerPosition(rawValue: (position.rawValue + offset) % PlayerPosition.allCases.count)!
}

/// 截图中第 3 墩之前的两墩记录；座次整体轮转后战术条件不变。
func pointExposureRegressionHistory(leader: PlayerPosition) -> [Trick] {
    var first = Trick(leadPosition: leader)
    first.plays = [
        (position: seat(after: leader, offset: 0), cards: [c(.spades, .ace)]),
        (position: seat(after: leader, offset: 1), cards: [c(.spades, .four)]),
        (position: seat(after: leader, offset: 2), cards: [c(.spades, .ten)]),
        (position: seat(after: leader, offset: 3), cards: [c(.spades, .three)])
    ]

    var second = Trick(leadPosition: leader)
    second.plays = [
        (position: seat(after: leader, offset: 0), cards: [c(.spades, .jack), c(.spades, .jack)]),
        (position: seat(after: leader, offset: 1), cards: [c(.spades, .eight), c(.spades, .eight)]),
        (position: seat(after: leader, offset: 2), cards: [c(.spades, .five), c(.spades, .five)]),
        (position: seat(after: leader, offset: 3), cards: [c(.spades, .six), c(.spades, .seven)])
    ]
    return [first, second]
}

func pointExposureRegressionPlays(
    leader: PlayerPosition,
    playsBeforeDecision: Int
) -> [(PlayerPosition, [Card])] {
    let ranks: [Rank] = [.three, .six]
    return (0..<playsBeforeDecision).map { offset in
        (seat(after: leader, offset: offset), [c(.diamonds, ranks[offset])])
    }
}

/// 决策者在第 3 墩出牌前应有 22 张；出完 1 张后与截图的 21 张一致。
func pointExposureRegressionHand(pointRank: Rank, safeTrump: Card? = c(.diamonds, .four)) -> [Card] {
    var hand = [c(.diamonds, pointRank)]
    if let safeTrump { hand.append(safeTrump) }
    let sideRanks: [Rank] = [.three, .four, .five, .six, .seven, .eight,
                             .nine, .ten, .jack, .queen, .king, .ace]
    let sideCards = sideRanks.map { c(.hearts, $0) } + sideRanks.map { c(.clubs, $0) }
    hand += sideCards.prefix(22 - hand.count)
    return hand
}

func controlTrumpRegressionHand() -> [Card] {
    var hand = [
        c(.diamonds, .ace), c(.diamonds, .four),
        c(.hearts, .ace), c(.clubs, .ace), c(.spades, .ace),
        c(.hearts, .king), c(.hearts, .king),
        c(.clubs, .queen), c(.clubs, .queen),
        c(.spades, .jack), c(.spades, .jack)
    ]
    let fillers = [Rank.three, .four, .six, .seven, .eight, .nine]
        .flatMap { [c(.hearts, $0), c(.clubs, $0)] }
    hand += fillers.prefix(22 - hand.count)
    return hand
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

// ── Test 1：当前墩有分，对手领先，AI 有主A可压 → 应压过而非垫小牌 ──
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

// ── Test 2a.0：任意座次领吊主，对手牌力未知时不裸送主分牌 ──
do {
    for position in PlayerPosition.allCases {
        let s = makeState(trump: ts, rank: tr)
        s.currentTrick = Trick(leadPosition: position)
        s.currentLeader = position
        s.currentTurn = position
        s.players[position.rawValue].hand =
            [c(.spades, .king), c(.spades, .three), c(.spades, .four),
             c(.spades, .six), c(.spades, .seven), c(.spades, .eight),
             c(.spades, .nine), c(.hearts, .two)]
        let chosen = AIPlayer.chooseCards(position: position, state: s, evaluator: eval)
        check(chosen.count == 1 && chosen[0].pointValue == 0,
              "Test2a.0 任意座次领吊主不裸送主分牌",
              "seat=\(position.seatName), chosen=\(chosen.map { $0.shortDisplay })")
    }
}

// ── Test 2a：只要后手还有未知对手，有合法 0 分主时就不裸出主 10/K ──
do {
    let screenshotTrump: Suit? = .diamonds
    let screenshotEval = TrickEvaluator(trumpSuit: screenshotTrump, trumpRank: tr)
    for leader in PlayerPosition.allCases {
        for playsBeforeDecision in 1...2 {
            let position = seat(after: leader, offset: playsBeforeDecision)
            for pointRank in [Rank.ten, .king] {
                let s = makeState(trump: screenshotTrump, rank: tr)
                s.completedTricks = pointExposureRegressionHistory(leader: leader)
                setTrick(
                    s,
                    lead: leader,
                    plays: pointExposureRegressionPlays(
                        leader: leader,
                        playsBeforeDecision: playsBeforeDecision
                    ),
                    turn: position
                )
                let safeTrump = c(.diamonds, .four)
                let hand = pointExposureRegressionHand(pointRank: pointRank, safeTrump: safeTrump)
                s.players[position.rawValue].hand = hand
                let alternativeIsLegal = screenshotEval.isValidPlay(
                    selected: [safeTrump], hand: hand, leadCards: s.currentTrick.leadCards!
                )
                let chosen = AIPlayer.chooseCards(position: position, state: s, evaluator: screenshotEval)
                check(alternativeIsLegal && chosen.count == 1 && chosen[0].pointValue == 0,
                      "Test2a 后手有未知对手时不裸出主10/K",
                      "leader=\(leader.seatName), playsBefore=\(playsBeforeDecision), point=\(pointRank), chosen=\(chosen.map { $0.shortDisplay })")
            }
        }
    }
}

// ── Test 2a.0a：限制的是分牌暴露，无分控制主仍可争取主动权 ──
do {
    let screenshotTrump: Suit? = .diamonds
    let screenshotEval = TrickEvaluator(trumpSuit: screenshotTrump, trumpRank: tr)
    for leader in PlayerPosition.allCases {
        for playsBeforeDecision in 1...2 {
            let position = seat(after: leader, offset: playsBeforeDecision)
            let s = makeState(trump: screenshotTrump, rank: tr)
            s.completedTricks = pointExposureRegressionHistory(leader: leader)
            setTrick(
                s,
                lead: leader,
                plays: pointExposureRegressionPlays(
                    leader: leader,
                    playsBeforeDecision: playsBeforeDecision
                ),
                turn: position
            )
            let hand = controlTrumpRegressionHand()
            s.players[position.rawValue].hand = hand
            let chosen = AIPlayer.chooseCards(position: position, state: s, evaluator: screenshotEval)
            let expected = playsBeforeDecision == 2
                ? chosen.map { $0.shortDisplay } == ["♦A"]
                : chosen.count == 1 && chosen[0].pointValue == 0
            check(expected,
                  "Test2a.0a 按后续队友/对手关系决定是否用无分控制主接管",
                  "leader=\(leader.seatName), playsBefore=\(playsBeforeDecision), chosen=\(chosen.map { $0.shortDisplay })")
        }
    }
}

// ── Test 2a.0b：没有 0 分主替代时，任意座次都必须遵守跟主规则 ──
do {
    let screenshotTrump: Suit? = .diamonds
    let screenshotEval = TrickEvaluator(trumpSuit: screenshotTrump, trumpRank: tr)
    for leader in PlayerPosition.allCases {
        for playsBeforeDecision in 1...2 {
            let position = seat(after: leader, offset: playsBeforeDecision)
            for pointRank in [Rank.ten, .king] {
                let s = makeState(trump: screenshotTrump, rank: tr)
                s.completedTricks = pointExposureRegressionHistory(leader: leader)
                setTrick(
                    s,
                    lead: leader,
                    plays: pointExposureRegressionPlays(
                        leader: leader,
                        playsBeforeDecision: playsBeforeDecision
                    ),
                    turn: position
                )
                s.players[position.rawValue].hand =
                    pointExposureRegressionHand(pointRank: pointRank, safeTrump: nil)
                let chosen = AIPlayer.chooseCards(position: position, state: s, evaluator: screenshotEval)
                check(chosen.count == 1 && chosen[0].rank == pointRank,
                      "Test2a.0b 无0分主替代时必须跟出主分牌",
                      "leader=\(leader.seatName), playsBefore=\(playsBeforeDecision), point=\(pointRank), chosen=\(chosen.map { $0.shortDisplay })")
            }
        }
    }
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

// ── Test 17：后手绝门时按分差争墩，大王能锁定时允许使用 ──
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

    let teammateStillActsStrong = makeState(trump: ts, rank: tr)
    teammateStillActsStrong.completedTricks = [playerVoidHeartsTrick(.north)]
    setTrick(
        teammateStillActsStrong,
        lead: .south,
        plays: [(.south, [c(.hearts, .king)])],
        turn: .west
    )
    teammateStillActsStrong.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .ace), c(.clubs, .two), c(.spades, .ten),
        c(nil, .smallJoker), c(.diamonds, .three)
    ]
    let teammateStillActsStrongChosen = AIPlayer.chooseCards(position: .west, state: teammateStillActsStrong, evaluator: eval)
    check(
        teammateStillActsStrongChosen.map(\.shortDisplay) == ["♠10"],
        "Test17a 可用低成本主10争分，不强制主A/级牌",
        "chosen=\(teammateStillActsStrongChosen.map(\.shortDisplay))"
    )

    let noLaterTeammateStrong = makeState(trump: ts, rank: tr)
    noLaterTeammateStrong.completedTricks = [playerVoidHeartsTrick(.east)]
    setTrick(
        noLaterTeammateStrong,
        lead: .south,
        plays: [
            (.south, [c(.hearts, .five)]),
            (.west, [c(.hearts, .king)])
        ],
        turn: .north
    )
    noLaterTeammateStrong.players[PlayerPosition.north.rawValue].hand = [
        c(.clubs, .two), c(.spades, .ten),
        c(nil, .bigJoker), c(.diamonds, .three)
    ]
    let noLaterTeammateStrongChosen = AIPlayer.chooseCards(position: .north, state: noLaterTeammateStrong, evaluator: eval)
    check(
        noLaterTeammateStrongChosen.first?.rank == .bigJoker,
        "Test17b 本队无后手时用大王锁定分墩",
        "chosen=\(noLaterTeammateStrongChosen.map(\.shortDisplay))"
    )

    let teammateStillActsWeak = makeState(trump: ts, rank: tr)
    teammateStillActsWeak.completedTricks = [playerVoidHeartsTrick(.north)]
    setTrick(
        teammateStillActsWeak,
        lead: .south,
        plays: [(.south, [c(.hearts, .king)])],
        turn: .west
    )
    teammateStillActsWeak.players[PlayerPosition.west.rawValue].hand = [
        c(.spades, .ten), c(.spades, .five), c(.diamonds, .three)
    ]
    let teammateStillActsWeakChosen = AIPlayer.chooseCards(position: .west, state: teammateStillActsWeak, evaluator: eval)
    check(
        teammateStillActsWeakChosen.map(\.shortDisplay) == ["♠10"],
        "Test17c 有分墩可用主10争墩，不按带分一律认输",
        "chosen=\(teammateStillActsWeakChosen.map(\.shortDisplay))"
    )

    let noLaterTeammateJokers = makeState(trump: ts, rank: tr)
    noLaterTeammateJokers.completedTricks = [playerVoidHeartsTrick(.east)]
    setTrick(
        noLaterTeammateJokers,
        lead: .south,
        plays: [
            (.south, [c(.hearts, .five)]),
            (.west, [c(.hearts, .king)])
        ],
        turn: .north
    )
    noLaterTeammateJokers.players[PlayerPosition.north.rawValue].hand = [
        c(nil, .bigJoker), c(nil, .smallJoker),
        c(.spades, .ten), c(.diamonds, .three)
    ]
    let noLaterTeammateJokersChosen = AIPlayer.chooseCards(position: .north, state: noLaterTeammateJokers, evaluator: eval)
    check(
        noLaterTeammateJokersChosen.first?.rank == .bigJoker,
        "Test17d 已知后手绝门也允许大王锁定15分",
        "chosen=\(noLaterTeammateJokersChosen.map(\.shortDisplay))"
    )
}

// ── Test 18：无已知大牌/强结构时，普通副牌对子应优先于随机副牌小单 ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.hearts, .seven), c(.hearts, .seven),
        c(.hearts, .nine), c(.clubs, .three), c(.diamonds, .four)
    ]

    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(
        chosen.count == 2 && chosen.allSatisfy { $0.suit == .hearts && $0.rank == .seven },
        "Test18 普通副牌对子优先于随机副牌小单",
        "chosen=\(chosen.map(\.shortDisplay))"
    )
}

// ── Test 19：开局无拖拉机/强对且可吊主时，不随机领副牌小单 ──
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTrick = Trick(leadPosition: .north)
    s.currentLeader = .north
    s.currentTurn = .north
    s.players[PlayerPosition.north.rawValue].hand = [
        c(.spades, .three), c(.spades, .three),
        c(.spades, .six), c(.spades, .six),
        c(.spades, .nine), c(.spades, .nine),
        c(.spades, .queen), c(.spades, .queen),
        c(.hearts, .four), c(.hearts, .seven), c(.hearts, .eight), c(.hearts, .nine)
    ]

    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: eval)
    check(
        chosen.count == 2 && chosen.allSatisfy { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) },
        "Test19 开局空档优先吊主而非随机副牌小单",
        "chosen=\(chosen.map(\.shortDisplay))"
    )
}

// ── Test 20：副牌对子不按分牌分档，只按牌面大小连续排序 ──
do {
    check(
        !AIPlayer.isLeadStrongPair(c(.hearts, .king), ts: ts, tr: tr)
            && !AIPlayer.isLeadStrongPair(c(.hearts, .ten), ts: ts, tr: tr)
            && !AIPlayer.isLeadStrongPair(c(.hearts, .five), ts: ts, tr: tr),
        "Test20a K/10/5副牌对不因带分自动算强对"
    )

    let orderedRanks: [Rank] = [.five, .ten, .jack, .queen, .king]
    let adjustments = orderedRanks.map { rank in
        let pair = [c(.hearts, rank), c(.hearts, rank)]
        return AIPlayer.fallbackLeadShapeAdjustment(
            AIPlayer.AIMove(cards: pair, kind: .bigPair),
            ts: ts,
            tr: tr
        )
    }
    check(
        zip(adjustments, adjustments.dropFirst()).allSatisfy(<),
        "Test20b 普通副牌对子按牌面从小到大连续加权",
        "adjustments=\(adjustments)"
    )
}

// 全面规则与决策审查回归。
do {
    let hand = [Rank.three, .four, .eight, .nine].flatMap { [c(.hearts, $0), c(.hearts, $0)] }
    let lead = [Rank.five, .six, .seven].flatMap { [c(.hearts, $0), c(.hearts, $0)] }
    let chosen = AIPlayer.structuredSuitFollowCards(suitCards: hand, neededPairs: 3, trumpSuit: ts, trumpRank: tr)
    check(eval.isValidPlay(selected: chosen, hand: hand, leadCards: lead),
          "Review1 两段两连对跟三连对有合法解", "chosen=\(chosen.map(\.shortDisplay))")
    check(!eval.isValidLead([c(.hearts, .three), c(.clubs, .four)])
          && eval.isValidLead([c(.hearts, .two), c(.spades, .three)]),
          "Review3 首手拒绝混副花色，允许同逻辑主牌")
}
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south, plays: [(.south, [c(.hearts, .king)]), (.west, [c(.hearts, .three)])], turn: .north)
    let hand = [c(.hearts, .ace), c(.spades, .three)]
    s.player(.north).hand = hand
    let ctx = AIContext.build(state: s, ts: ts, tr: tr)
    check(!AIPlayer.isTrickSecureForTeam(position: .north, hand: hand, state: s, evaluator: eval, ctx: ctx, candidateCards: [hand[0]]),
          "Review2 未知绝门的后手仍可能将吃副A")
    s.currentTrick.plays = [(.south, [c(.hearts, .king), c(.hearts, .king)]),
                            (.west, [c(.hearts, .three), c(.hearts, .four)])]
    let pair = [c(nil, .smallJoker), c(nil, .smallJoker)]
    let pairHand = pair + [c(nil, .bigJoker)]
    s.player(.north).hand = pairHand
    let pairCtx = AIContext.build(state: s, ts: ts, tr: tr)
    check(AIPlayer.isSecureWinningTrumpFollow(pair, position: .north, hand: pairHand, state: s, evaluator: eval, ctx: pairCtx),
          "Review11 外面只剩一张大王不能压小王对")
}
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .north, plays: [], turn: .north)
    let hand = [c(.hearts, .two), c(.hearts, .two), c(.spades, .two), c(.spades, .two),
                c(.spades, .three), c(.spades, .four), c(.hearts, .six), c(.clubs, .seven), c(.diamonds, .eight)]
    s.player(.north).hand = hand
    let ctx = AIContext.build(state: s, ts: ts, tr: tr)
    let assets = AIPlayer.filterAllowedLeadAssets(AIPlayer.buildLeadAssets(position: .north, hand: hand, state: s, ctx: ctx),
                                                  position: .north, hand: hand, state: s)
    let pool = AIPlayer.selectLeadAssetPool(assets)
    check(!pool.isEmpty && pool.allSatisfy { asset in
        !AIPlayer.pairs(in: asset.move.cards, trumpSuit: ts, trumpRank: tr).contains { $0[0].rank == tr }
    }, "Review8 开局级牌保护覆盖拖拉机生成路径")

    let ordinary = [c(.hearts, .queen), c(.hearts, .queen)]
    let weakHand = ordinary + [c(.clubs, .three), c(.clubs, .four), c(.clubs, .six), c(.clubs, .seven)]
    s.player(.north).hand = weakHand
    let weakCtx = AIContext.build(state: s, ts: ts, tr: tr)
    let weakPool = AIPlayer.selectLeadAssetPool(AIPlayer.deduplicatedLeadAssets(
        AIPlayer.buildLeadAssets(position: .north, hand: weakHand, state: s, ctx: weakCtx)))
    check(weakPool.contains { Set($0.move.cards.map(\.id)) == Set(ordinary.map(\.id)) },
          "Review9 普通对子不被长门小副牌挡在模拟池外")
    let ranks: [Rank] = [.five, .ten, .jack, .queen, .king]
    let weights = ranks.map { AIPlayer.pairAssetWeight(c(.hearts, $0), ts: ts, tr: tr) }
    check(zip(weights, weights.dropFirst()).allSatisfy(<), "Review10 对子结构价值按牌力连续递增")
}
do {
    let s = makeState(trump: ts, rank: tr)
    setTrick(s, lead: .south, plays: [(.south, [c(.hearts, .king)])], turn: .west)
    let joker = c(nil, .bigJoker)
    let hand = [joker, c(.clubs, .three)]
    let ctx = AIContext(playedCards: s.currentTrick.plays.flatMap(\.cards), knownCards: [],
                        knownCardsByPlayer: [:], voidSuits: [.north: [Suit.hearts.rawValue]], isLastPlayer: false)
    let moves = hand.map { AIPlayer.AIMove(cards: [$0], kind: .followWin) }
    let filtered = AIPlayer.filterKnownVoidOpponentRuffContest(moves, leadCards: s.currentTrick.leadCards!,
        hand: hand, position: .west, state: s, evaluator: eval, ctx: ctx)
    check(filtered.contains { $0.cards[0].id == joker.id }, "Review4 已知后手绝门时允许大王争分")
    let risky = [AIPlayer.AIMove(cards: [c(.spades, .king)], kind: .followWin),
                 AIPlayer.AIMove(cards: [c(.clubs, .three)], kind: .followDiscard)]
    let tactical = AIPlayer.tacticalCandidateFilter(risky, mode: .pointDenial, hand: risky.flatMap(\.cards),
        position: .west, state: s, evaluator: eval, ctx: ctx)
    check(tactical.contains { $0.cards[0].rank == .king }, "Review14 带分争墩牌与认输走法一起评估")

    var trick = Trick(leadPosition: .south)
    trick.plays = [(.south, [c(.hearts, .king)])]
    var rng = AIPlayer.MonteCarloRNG(seed: 1)
    let follow = AIPlayer.monteCarloFollowCards(hand: [c(.hearts, .ace), c(.hearts, .three)],
        trick: trick, position: .west, evaluator: eval, ts: ts, tr: tr, rng: &rng)
    check(follow[0].rank == .ace, "Review7 模拟对手主动用A争分而非随机跟牌")
    trick.plays.append((.west, [c(.hearts, .three)]))
    let support = AIPlayer.monteCarloFollowCards(hand: [c(.hearts, .ten), c(.hearts, .four)],
        trick: trick, position: .north, evaluator: eval, ts: ts, tr: tr, rng: &rng)
    check(support[0].rank == .four, "Review7 模拟队友K尚未锁定时不盲目垫10")
    trick.plays = [(.south, [c(nil, .bigJoker)]), (.west, [c(.spades, .three)])]
    let safeSupport = AIPlayer.monteCarloFollowCards(hand: [c(.spades, .ten), c(.spades, .four)],
        trick: trick, position: .north, evaluator: eval, ts: ts, tr: tr, rng: &rng)
    check(safeSupport[0].rank == .ten, "Review7 模拟队友大王已锁定时积极垫10")

    let original = AIContext.build(state: s, ts: ts, tr: tr)
    var realized = Trick(leadPosition: .west)
    realized.plays = [(.west, [c(.clubs, .ace), c(.clubs, .ace)])]
    let updated = original.observing(realized, ts: ts, tr: tr)
    check(updated.isEffectivelyBiggest(c(.clubs, .king), ts: ts, tr: tr),
          "Review13 模拟兑现A后更新K的剩余控制价值")
}
do {
    let s = makeState(trump: ts, rank: tr)
    s.currentTurn = .north
    for _ in 0..<3 {
        var t = Trick(leadPosition: .south)
        t.plays = [(.south, [c(.spades, .three)]), (.west, [c(.hearts, .four)]),
                   (.north, [c(.spades, .six)]), (.east, [c(.spades, .seven)])]
        s.completedTricks.append(t)
    }
    check(!AIPlayer.opponentsLikelyNoTrumpOrControl(gameState: s),
          "Review12 同一对手三次绝主不代表两名对手都无主")
}

do {
    // 12 张未知牌：6红桃6梅花。西绝红桃、拿2张梅花；南东各5张。
    // 南家的红桃数服从 Hypergeometric(10,6,5)，均值3、方差2/3。
    let s = makeState(trump: ts, rank: tr)
    let deck = Deck.doubleDeck()
    let ranks: [Rank] = [.three, .four, .six, .seven, .eight, .nine]
    let unknown = ranks.compactMap { rank in deck.first { $0.suit == .hearts && $0.rank == rank } }
        + ranks.compactMap { rank in deck.first { $0.suit == .clubs && $0.rank == rank } }
    let own = deck.first { $0.suit == .spades && $0.rank == .three }!
    let heartAce = deck.first { $0.suit == .hearts && $0.rank == .ace }!
    let clubAce = deck.first { $0.suit == .clubs && $0.rank == .ace }!
    let excluded = Set((unknown + [own, heartAce, clubAce]).map(\.id))
    var voidTrick = Trick(leadPosition: .south)
    voidTrick.plays = [(.south, [heartAce]), (.west, [clubAce])]
    var history = Trick(leadPosition: .south)
    history.plays = [(.south, deck.filter { !excluded.contains($0.id) })]
    s.completedTricks = [voidTrick, history]
    setTrick(s, lead: .north, plays: [], turn: .north)
    s.dealerPosition = .north
    s.player(.north).hand = [own]
    s.player(.west).hand = Array(unknown.prefix(2))
    s.player(.south).hand = Array(unknown.prefix(5))
    s.player(.east).hand = Array(unknown.prefix(5))
    var counts: [Double] = []
    var respectsConstraints = true
    for seed in 1...512 {
        var rng = AIPlayer.MonteCarloRNG(seed: UInt64(seed))
        let sampled = AIPlayer.sampleHiddenHands(currentPosition: .north, currentHand: [own],
            playedCandidate: [], state: s, rng: &rng)
        respectsConstraints = respectsConstraints && sampled[.west]?.count == 2
            && sampled[.south]?.count == 5 && sampled[.east]?.count == 5
            && sampled[.west]!.allSatisfy { $0.suit == .clubs }
        counts.append(Double(sampled[.south]?.filter { $0.suit == .hearts }.count ?? -100))
    }
    let mean = counts.reduce(0, +) / Double(counts.count)
    let variance = counts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(counts.count)
    check(respectsConstraints && abs(mean - 3) < 0.15 && variance > 0.4 && variance < 1.0,
          "Review6 条件抽样尊重绝门且符合真实发牌分布", "mean=\(mean), variance=\(variance)")
}
do {
    func finalTrickScore(kittyHasPoints: Bool) -> Double {
        let s = makeState(trump: ts, rank: tr)
        let deck = Deck.doubleDeck()
        let own = deck.first { $0.rank == .bigJoker }!
        let otherCards = [Suit.hearts, .clubs, .diamonds].map { suit in
            deck.first { $0.suit == suit && $0.rank == .three }!
        }
        let reserved = Set(([own] + otherCards).map(\.id))
        let available = deck.filter { !reserved.contains($0.id) }
        let kitty: [Card]
        if kittyHasPoints {
            let ten = available.first { $0.rank == .ten }!
            kitty = [ten] + available.filter { $0.pointValue == 0 }.prefix(7)
        } else { kitty = Array(available.filter { $0.pointValue == 0 }.prefix(8)) }
        let removed = reserved.union(kitty.map(\.id))
        var history = Trick(leadPosition: .south)
        history.plays = [(.south, deck.filter { !removed.contains($0.id) })]
        s.completedTricks = [history]
        setTrick(s, lead: .west, plays: [], turn: .west)
        s.player(.west).hand = [own]
        s.player(.north).hand = [otherCards[0]]
        s.player(.east).hand = [otherCards[1]]
        s.player(.south).hand = [otherCards[2]]
        // 非庄家视角，即使真实 kitty 内容缺失/不同也只能使用抽样剩余8张。
        s.dealerPosition = .south
        s.kitty = []
        var rng = AIPlayer.MonteCarloRNG(seed: 10)
        return AIPlayer.simulateCurrentTrick(candidate: AIPlayer.AIMove(cards: [own], kind: .trump),
            position: .west, hand: [own], state: s, evaluator: eval, rng: &rng)
    }
    let positive = finalTrickScore(kittyHasPoints: true)
    let zero = finalTrickScore(kittyHasPoints: false)
    check(positive - zero > 200, "Review5 末墩攻方抠底将底牌翻倍计入模拟且不偷看底牌",
          "scores=\(positive)/\(zero)")
}

do {
    let s = makeState(trump: ts, rank: tr)
    var rng = AIPlayer.MonteCarloRNG(seed: 20261025)
    var deck = Deck.doubleDeck()
    deck.shuffle(using: &rng)
    for seat in PlayerPosition.allCases {
        let start = seat.rawValue * 25
        s.player(seat).hand = Array(deck[start..<(start + 25)])
    }
    s.kitty = Array(deck.suffix(8))
    s.dealerPosition = .south
    setTrick(s, lead: .south, plays: [], turn: .south)
    var legal = true
    let started = Date()
    for _ in 0..<16 {
        let seat = s.currentTurn
        let hand = s.player(seat).hand
        let chosen = AIPlayer.chooseCards(position: seat, state: s, evaluator: eval)
        let isLegal = !chosen.isEmpty && (s.currentTrick.leadCards.map {
            eval.isValidPlay(selected: chosen, hand: hand, leadCards: $0)
        } ?? eval.isValidLead(chosen))
        guard isLegal else { legal = false; break }
        s.player(seat).hand = AIPlayer.handAfterPlaying(chosen, from: hand)
        s.currentTrick.plays.append((position: seat, cards: chosen))
        if s.currentTrick.isComplete {
            let winner = eval.winner(of: s.currentTrick)
            s.completedTricks.append(s.currentTrick)
            setTrick(s, lead: winner, plays: [], turn: winner)
        } else { s.currentTurn = AIPlayer.nextPosition(after: seat) }
    }
    check(legal && s.completedTricks.count == 4, "Review 四家完整发牌连续四墩均可合法推进")
    print("Full-hand smoke: \(Date().timeIntervalSince(started))s / 16 decisions")
}

// 截图回归：第三墩队友领♠33♠44，North 应趁组合优势垫出♠K与♠10。
do {
    let screenshotTrump: Suit? = .diamonds
    let screenshotRank: Rank = .five
    let evaluator = TrickEvaluator(trumpSuit: screenshotTrump, trumpRank: screenshotRank)
    let s = makeState(trump: screenshotTrump, rank: screenshotRank)
    s.dealerPosition = .north
    var first = Trick(leadPosition: .north)
    first.plays = [(.north, [c(.diamonds, .two)]), (.east, [c(.diamonds, .six)]),
                   (.south, [c(nil, .bigJoker)]), (.west, [c(.diamonds, .two)])]
    var second = Trick(leadPosition: .south)
    second.plays = [(.south, [c(.clubs, .ace)]), (.west, [c(.clubs, .three)]),
                    (.north, [c(.clubs, .eight)]), (.east, [c(.clubs, .six)])]
    s.completedTricks = [first, second]
    let lead = [c(.spades, .four), c(.spades, .four), c(.spades, .three), c(.spades, .three)]
    setTrick(s, lead: .south, plays: [(.south, lead),
        (.west, [c(.spades, .two), c(.spades, .six), c(.spades, .nine), c(.spades, .jack)])], turn: .north)
    let hand = [Rank.eight, .jack, .queen, .ten, .king].map { c(.spades, $0) }
        + [Rank.two, .three, .four, .six, .seven, .eight, .nine, .ten, .jack, .queen, .king, .ace].map { c(.hearts, $0) }
        + [Rank.two, .four, .seven, .nine, .jack, .queen].map { c(.clubs, $0) }
    s.player(.north).hand = hand
    let played = s.completedTricks.flatMap { $0.plays.flatMap(\.cards) } + s.currentTrick.plays.flatMap(\.cards)
    var remaining = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: played + hand)
    s.kitty = Array(remaining.filter { $0.suit != .spades }.prefix(8))
    let kittyIDs = Set(s.kitty.map(\.id))
    remaining.removeAll { kittyIDs.contains($0.id) }
    for (seat, count) in [(PlayerPosition.south, 19), (.west, 19), (.east, 23)] {
        s.player(seat).hand = Array(remaining.prefix(count))
        remaining.removeFirst(count)
    }
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: evaluator)
    check(evaluator.isValidPlay(selected: chosen, hand: hand, leadCards: lead)
          && chosen.contains { $0.suit == .spades && $0.rank == .king }
          && chosen.contains { $0.suit == .spades && $0.rank == .ten },
          "Screenshot 第三墩给队友垫♠K+♠10，不留K到第四墩被迫送分",
          "chosen=\(chosen.map(\.shortDisplay))")
    let ctx = AIContext.build(state: s, ts: screenshotTrump, tr: screenshotRank)
    var after = s.currentTrick
    after.plays.append((position: .north, cards: chosen))
    let risk = AIPlayer.structuredOvertakeProbability(trick: after, opponent: .east,
        hand: hand, position: .north, state: s, evaluator: evaluator, ctx: ctx)
    var voids = ctx.voidSuits
    voids[.east, default: []].insert(Suit.spades.rawValue)
    let exposedVoid = AIContext(playedCards: ctx.playedCards, knownCards: ctx.knownCards,
        knownCardsByPlayer: ctx.knownCardsByPlayer, voidSuits: voids, isLastPlayer: false)
    let voidRisk = AIPlayer.structuredOvertakeProbability(trick: after, opponent: .east,
        hand: hand, position: .north, state: s, evaluator: evaluator, ctx: exposedVoid)
    let unseen = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: played + hand + s.kitty)
    let blockers = Array(AIPlayer.uniqueCardFaces(unseen.filter {
        CardComparator.isTrump($0, trumpSuit: screenshotTrump, trumpRank: screenshotRank)
    }).prefix(10))
    let controllingHand = Array(hand.prefix(hand.count - blockers.count)) + blockers
    let controlledRisk = AIPlayer.structuredOvertakeProbability(trick: after, opponent: .east,
        hand: controllingHand, position: .north, state: s, evaluator: evaluator, ctx: ctx)
    check(risk < 0.1 && voidRisk > risk && controlledRisk < risk,
          "Screenshot 副牌早期拖拉机低风险，已知绝门提高风险，自己持主进一步降低风险",
          "risk=\(risk), void=\(voidRisk), holdingTrump=\(controlledRisk)")
}

do {
    let lead = [c(.hearts, .three), c(.hearts, .three), c(.hearts, .four), c(.hearts, .four)]
    let hand = [c(.hearts, .six), c(.hearts, .six), c(.hearts, .king), c(.hearts, .ten), c(.hearts, .queen)]
    let support = AIPlayer.supportingSuitFollowCards(from: hand, leadCards: lead,
        evaluator: eval, ts: ts, tr: tr)
    check(eval.isValidPlay(selected: support, hand: hand, leadCards: lead)
          && support.contains { $0.rank == .king } && support.contains { $0.rank == .ten },
          "Support 跟拖拉机先满足对子要求，再用自由位置跑K/10")
    let pairLead = [c(.hearts, .ace), c(.hearts, .ace)]
    let pairHand = [c(.hearts, .six), c(.hearts, .six), c(.hearts, .five), c(.hearts, .five), c(.hearts, .king)]
    let pairSupport = AIPlayer.supportingSuitFollowCards(from: pairHand, leadCards: pairLead,
        evaluator: eval, ts: ts, tr: tr)
    check(eval.isValidPlay(selected: pairSupport, hand: pairHand, leadCards: pairLead)
          && pairSupport.allSatisfy { $0.rank == .five },
          "Support 跟对子仍须出对子，在合法对子中跑分")
}

// 第10墩North仍领♦J，♣JJ最终在15/17墩被拆跟：机会对子应先于普通吊主。
do {
    let rank: Rank = .five
    let trump: Suit? = .diamonds
    let evaluator = TrickEvaluator(trumpSuit: trump, trumpRank: rank)
    func chooseLead(_ hand: [Card]) -> [Card] {
        let s = makeState(trump: trump, rank: rank)
        s.dealerPosition = .north
        setTrick(s, lead: .north, plays: [], turn: .north)
        s.player(.north).hand = hand
        // 排除“其他人没手牌”的测试捷径，允许真实隐藏世界模拟。
        let pool = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: hand)
        var cursor = 0
        for seat in [PlayerPosition.east, .south, .west] {
            s.player(seat).hand = Array(pool[cursor..<(cursor + hand.count)])
            cursor += hand.count
        }
        return AIPlayer.chooseCards(position: .north, state: s, evaluator: evaluator)
    }
    let main = [c(.diamonds, .jack), c(.diamonds, .three), c(.diamonds, .seven), c(.diamonds, .nine)]
    let isolatedJacks = [c(.clubs, .jack), c(.clubs, .jack)]
    let isolated = chooseLead(isolatedJacks + main + [c(.hearts, .six)])
    check(Set(isolated.map(\.id)) == Set(isolatedJacks.map(\.id)),
          "Lead 第10墩式残局：先领孤♣JJ，不继续吊主等对子拆跟", "chosen=\(isolated.map(\.shortDisplay))")
    let isolatedFours = [c(.clubs, .four), c(.clubs, .four)]
    let low = chooseLead(isolatedFours + main + [c(.hearts, .six)])
    check(Set(low.map(\.id)) == Set(isolatedFours.map(\.id)),
          "Lead 低点数副牌孤对也先整出清门", "chosen=\(low.map(\.shortDisplay))")
    for pairRank in [Rank.jack, .queen, .king] {
        let pair = [c(.clubs, pairRank), c(.clubs, pairRank)]
        let hand = pair + main + [c(.clubs, .six), c(.hearts, .eight)]
        let chosen = chooseLead(hand)
        check(Set(chosen.map(\.id)) == Set(pair.map(\.id)),
              "Lead J/Q/K副牌对非孤对时也先于普通吊主试出", "rank=\(pairRank), chosen=\(chosen.map(\.shortDisplay))")
    }
    let lowPair = [c(.clubs, .seven), c(.clubs, .seven)]
    let nonIsolated = chooseLead(lowPair + main + [c(.clubs, .six), c(.hearts, .eight)])
    check((nonIsolated.count == 1 && nonIsolated[0].suit == .diamonds)
          || Set(nonIsolated.map(\.id)) == Set(lowPair.map(\.id)),
          "Lead 非孤低副牌对与小主按局面比较，不机械选弱副牌单张", "chosen=\(nonIsolated.map(\.shortDisplay))")
    // 完整开局手牌：不能用“开局只剩8张、其余80张牌去向不明”的稀疏状态
    // 来判断首次绝门概率，否则会人为放大副A风险。
    let aceFill = [Rank.two, .three, .four, .seven, .eight, .nine, .ten, .jack, .queen, .king].map { c(.hearts, $0) }
        + [Rank.two, .three, .four, .six, .seven, .eight, .nine].map { c(.spades, $0) }
    let withAce = chooseLead(isolatedJacks + main + [c(.hearts, .ace), c(.hearts, .six)] + aceFill)
    check(withAce.count == 1 && withAce[0].rank == .ace && withAce[0].suit == .hearts,
          "Lead 正常兑现窗口先出旁门A，不为未证实的J对继续拖延", "chosen=\(withAce.map(\.shortDisplay))")
    let tractor = [c(.clubs, .jack), c(.clubs, .jack), c(.clubs, .queen), c(.clubs, .queen)]
    let whole = chooseLead(tractor + main + [c(.hearts, .six)])
    check(Set(whole.map(\.id)) == Set(tractor.map(\.id)),
          "Lead 不为提前试J对而拆开JQ拖拉机", "chosen=\(whole.map(\.shortDisplay))")
}

// 同一手牌在不同牌权历史下应采用不同计划，不靠永久抬高小对子权重。
do {
    let pair = [c(.clubs, .seven), c(.clubs, .seven)]
    let hand = pair + [c(.clubs, .three), c(.hearts, .eight),
                       c(.spades, .nine), c(.spades, .jack), c(.spades, .queen)]
    func leadState(history: [Trick]) -> GameState {
        let s = makeState(trump: ts, rank: tr)
        s.completedTricks = history
        setTrick(s, lead: .north, plays: [], turn: .north)
        s.player(.north).hand = hand
        return s
    }
    let opening = leadState(history: [])
    let openingChoice = AIPlayer.chooseCards(position: .north, state: opening, evaluator: eval)
    let openingContext = AIContext.build(state: opening, ts: ts, tr: tr)
    let openingPool = AIPlayer.selectLeadAssetPool(AIPlayer.buildLeadAssets(position: .north,
        hand: hand, state: opening, ctx: openingContext))
    check(AIPlayer.leadControlPlan(position: .north, hand: hand, state: opening, ctx: openingContext) == .seekPartnerLead
          && openingPool.contains { $0.move.kind == .trumpTransfer }
          && ((openingChoice.count == 1 && openingChoice[0].suit == .spades)
              || Set(openingChoice.map(\.id)) == Set(pair.map(\.id))),
          "Plan 首次无兑现资产时保留小主交牌权，也允许更优的小对子方案", "chosen=\(openingChoice.map(\.shortDisplay))")

    var enemyLead = Trick(leadPosition: .west)
    enemyLead.plays = [(.west, [c(.spades, .three)]), (.north, [c(.spades, .ace)]),
                       (.east, [c(.spades, .four)]), (.south, [c(.spades, .six)])]
    let regained = leadState(history: [enemyLead])
    let regainedChoice = AIPlayer.chooseCards(position: .north, state: regained, evaluator: eval)
    check(Set(regainedChoice.map(\.id)) == Set(pair.map(\.id)),
          "Plan 对手领过后拿回牌权，同一手牌改试非孤小对子", "chosen=\(regainedChoice.map(\.shortDisplay))")

    var transfer = Trick(leadPosition: .north)
    transfer.plays = [(.north, [c(.spades, .three)]), (.east, [c(.spades, .four)]),
                      (.south, [c(.spades, .king)]), (.west, [c(.spades, .six)])]
    var partnerLead = Trick(leadPosition: .south)
    partnerLead.plays = [(.south, [c(.hearts, .three)]), (.west, [c(.hearts, .king)]),
                        (.north, [c(.hearts, .ace)]), (.east, [c(.hearts, .six)])]
    let partnerCycle = leadState(history: [transfer, partnerLead])
    let partnerChoice = AIPlayer.chooseCards(position: .north, state: partnerCycle, evaluator: eval)
    check(Set(partnerChoice.map(\.id)) == Set(pair.map(\.id)),
          "Plan 对家接手领牌后再回到自己，不重复默认吊主", "chosen=\(partnerChoice.map(\.shortDisplay))")

    func ownTrumpTrick() -> Trick {
        var t = Trick(leadPosition: .north)
        t.plays = [(.north, [c(.spades, .seven)]), (.east, [c(.spades, .three)]),
                   (.south, [c(.spades, .four)]), (.west, [c(.spades, .six)])]
        return t
    }
    let once = leadState(history: [ownTrumpTrick()])
    let onceContext = AIContext.build(state: once, ts: ts, tr: tr)
    check(AIPlayer.leadControlPlan(position: .north, hand: hand, state: once, ctx: onceContext) == .seekPartnerLead,
          "Plan 一次小主仍由自己赢时，可再尝试过渡")
    let twice = leadState(history: [ownTrumpTrick(), ownTrumpTrick()])
    let twiceChoice = AIPlayer.chooseCards(position: .north, state: twice, evaluator: eval)
    check(Set(twiceChoice.map(\.id)) == Set(pair.map(\.id)),
          "Plan 连续两次小主未交出牌权后重评副牌，避免循环吊主", "chosen=\(twiceChoice.map(\.shortDisplay))")

    let pull = makeState(trump: ts, rank: tr)
    pull.completedTricks = [eastVoidHeartsTrick()]
    setTrick(pull, lead: .south, plays: [], turn: .south)
    let pullHand = [c(.hearts, .ace), c(.spades, .ace), c(.spades, .king),
                    c(.spades, .queen), c(.spades, .jack), c(.clubs, .four)]
    pull.player(.south).hand = pullHand
    let pullContext = AIContext.build(state: pull, ts: ts, tr: tr)
    check(AIPlayer.leadControlPlan(position: .south, hand: pullHand, state: pull, ctx: pullContext) == .pullForSideWinners,
          "Plan 明确要拔主解锁旁门A时，可以继续吊主")

    // 新一局没有历史，不能沿用上局已完成的过渡计划。
    let reset = leadState(history: [])
    let resetContext = AIContext.build(state: reset, ts: ts, tr: tr)
    check(AIPlayer.leadControlPlan(position: .north, hand: hand, state: reset, ctx: resetContext) == .seekPartnerLead,
          "Plan 新局历史清空后重新判断交牌权计划")
}

// 第二轮策略review：每个缺陷均保留独立回归，避免只靠既有场景测通过。
do {
    let trump: Suit? = .diamonds
    let rank: Rank = .five
    let evaluator = TrickEvaluator(trumpSuit: trump, trumpRank: rank)
    func stateFor(_ hand: [Card], history: [Trick] = [], plays: [(PlayerPosition, [Card])] = []) -> GameState {
        let s = makeState(trump: trump, rank: rank)
        s.dealerPosition = .north
        s.completedTricks = history
        setTrick(s, lead: plays.first?.0 ?? .north, plays: plays, turn: .north)
        s.player(.north).hand = hand
        let known = hand + history.flatMap { $0.plays.flatMap(\.cards) } + plays.flatMap { $0.1 }
        var pool = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: known)
        for seat in [PlayerPosition.east, .south, .west] {
            let amount = min(pool.count, hand.count - (plays.contains { $0.0 == seat } ? plays[0].1.count : 0))
            s.player(seat).hand = Array(pool.prefix(amount))
            pool.removeFirst(amount)
        }
        s.kitty = Array(pool.suffix(8))
        return s
    }

    for face in [c(nil, .bigJoker), c(nil, .smallJoker), c(.clubs, .five), c(.diamonds, .ace)] {
        let pair = [face, c(face.suit, face.rank)]
        let hand = pair + [c(.diamonds, .three), c(.diamonds, .six), c(.hearts, .six),
                           c(.clubs, .seven), c(.spades, .nine)]
        let s = stateFor(hand)
        check(!AIPlayer.allowTrumpLead(state: s, position: .north, hand: hand,
            move: AIPlayer.AIMove(cards: [face], kind: .trump)),
            "Review2.1 大主对保护也禁止抽一张领出", "face=\(face.shortDisplay)")
    }
    var pairedHand = [c(nil, .bigJoker), c(nil, .bigJoker), c(.clubs, .five), c(.clubs, .five)]
    for r in [Rank.two, .four, .seven, .nine, .jack] { pairedHand += [c(.diamonds, r), c(.diamonds, r)] }
    pairedHand += Rank.allCases.filter { !$0.isJoker && $0 != rank && $0 != .ace }.map { c(.hearts, $0) }
    let pairState = stateFor(pairedHand)
    let pairChoice = AIPlayer.chooseCards(position: .north, state: pairState, evaluator: evaluator)
    check(!pairChoice.contains { $0.rank == .bigJoker },
          "Review2.1 完整25张牌不再从双大王拆一张吊主", "chosen=\(pairChoice.map(\.shortDisplay))")

    let low = c(.diamonds, .three), joker = c(nil, .bigJoker)
    var protectedHand = [low, joker, c(nil, .bigJoker), c(nil, .smallJoker), c(nil, .smallJoker),
                         c(.diamonds, .ace), c(.diamonds, .ace)]
    for suit in Suit.allCases { protectedHand += [c(suit, rank), c(suit, rank)] }
    protectedHand += [Rank.two, .three, .four, .six, .seven, .eight, .nine, .ten, .jack, .queen].map { c(.clubs, $0) }
    let secure = stateFor(protectedHand, plays: [(.south, [c(.diamonds, .king)]), (.west, [c(.diamonds, .ten)])])
    let secureContext = AIContext.build(state: secure, ts: trump, tr: rank)
    let safeOptions = [AIPlayer.AIMove(cards: [low], kind: .followBaseline),
                       AIPlayer.AIMove(cards: [joker], kind: .followWin)]
    let safeFiltered = AIPlayer.filterTrumpControlMoves(safeOptions, leadCards: secure.currentTrick.leadCards!,
        hand: protectedHand, position: .north, state: secure, evaluator: evaluator, ctx: secureContext)
    let safeChoice = AIPlayer.chooseCards(position: .north, state: secure, evaluator: evaluator)
    check(safeFiltered.count == 1 && safeFiltered[0].cards[0].id == low.id && safeChoice[0].id == low.id,
          "Review2.2 队友已锁定20分主牌墩，不再被迫盖队友")

    let king = c(.diamonds, .king), queen = c(.diamonds, .queen)
    let bank = stateFor([king, queen], plays: [(.south, [c(nil, .bigJoker)]), (.west, [c(.diamonds, .three)])])
    let bankContext = AIContext.build(state: bank, ts: trump, tr: rank)
    let bankOptions = [AIPlayer.AIMove(cards: [king], kind: .followSupport), AIPlayer.AIMove(cards: [queen], kind: .followBaseline)]
    let bankFiltered = AIPlayer.filterUnsafeTrumpPointExposureBeforeUnknownOpponent(bankOptions,
        leadCards: bank.currentTrick.leadCards!, hand: [king, queen], position: .north,
        state: bank, evaluator: evaluator, ctx: bankContext)
    check(bankFiltered.contains { $0.cards[0].id == king.id }
        && AIPlayer.chooseCards(position: .north, state: bank, evaluator: evaluator)[0].id == king.id,
          "Review2.3 队友大王已稳的0分墩允许垫主K跑分")

    var pointTrick = Trick(leadPosition: .south)
    pointTrick.plays = [(.south, [c(.clubs, .ace)]), (.west, [c(.clubs, .three)]),
                        (.north, [c(.clubs, .four)]), (.east, [c(.clubs, .six)])]
    func pointScore(_ assets: Double) -> Double {
        AIPlayer.pointContestSimulationScore(candidate: AIPlayer.AIMove(cards: pointTrick.plays[2].cards, kind: .followSupport),
            trick: pointTrick, winner: .south, position: .north, points: 0, myTeamWon: true,
            ownPoints: 0, opponentWinningBefore: false, assetValue: assets, earlyTrumpPenalty: 0, ts: trump, tr: rank)
    }
    check(pointScore(50) > pointScore(10), "Review2.4 同样得分结果下保留更多控制资产应加分而非扣分")

    let support = c(.hearts, .king)
    let uncertain = stateFor([support, c(.clubs, .eight)],
        plays: [(.south, [c(.hearts, .ace)]), (.west, [c(.hearts, .three)])])
    let uncertainContext = AIContext.build(state: uncertain, ts: trump, tr: rank)
    let risk = AIPlayer.opponentTrickWinProbability(AIPlayer.AIMove(cards: [support], kind: .followSupport),
        hand: uncertain.player(.north).hand, position: .north, state: uncertain, evaluator: evaluator, ctx: uncertainContext)
    check(risk > 0 && risk < 1, "Review2.5 后手首次绝门将吃副A的概率不能是0", "risk=\(risk)")
    let cannotRuff = AIContext(playedCards: uncertainContext.playedCards, knownCards: [], knownCardsByPlayer: [:],
        voidSuits: [.east: ["TRUMP"]], isLastPlayer: false)
    let noRisk = AIPlayer.opponentTrickWinProbability(AIPlayer.AIMove(cards: [support], kind: .followSupport),
        hand: uncertain.player(.north).hand, position: .north, state: uncertain, evaluator: evaluator, ctx: cannotRuff)
    check(noRisk == 0, "Review2.5 后手明确绝主时副A不会被将吃")
    var mixed = Trick(leadPosition: .south)
    mixed.plays = [(.south, [c(.hearts, .ace), c(.hearts, .king), c(.hearts, .king)]),
                   (.west, [c(.hearts, .two), c(.hearts, .three), c(.hearts, .four)]),
                   (.north, [c(.hearts, .six), c(.hearts, .eight), c(.hearts, .nine)])]
    let mixedContext = AIContext(playedCards: mixed.plays.flatMap(\.cards), knownCards: [], knownCardsByPlayer: [:],
                                 voidSuits: [:], isLastPlayer: false)
    let mixedRisk = AIPlayer.structuredOvertakeProbability(trick: mixed, opponent: .east,
        hand: mixed.plays[2].cards, position: .north, state: nil, evaluator: evaluator, ctx: mixedContext)
    check(mixedRisk > 0, "Review2.11 续演中混合甩牌也保留首次绝门将吃风险")

    var failedPair = Trick(leadPosition: .north)
    failedPair.plays = [(.north, [c(.diamonds, .three), c(.diamonds, .three)]),
                        (.east, [c(.diamonds, .four), c(.diamonds, .six)]),
                        (.south, [c(.diamonds, .seven), c(.diamonds, .seven)]),
                        (.west, [c(.diamonds, .eight), c(.diamonds, .eight)])]
    let dealt = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: failedPair.plays.flatMap(\.cards))
    let knownHand = Array(dealt.filter { !CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }.prefix(23))
    let hidden = stateFor(knownHand, history: [failedPair])
    var nonempty = 0, contradictory = 0
    for index in 0..<24 {
        var rng = AIPlayer.MonteCarloRNG(seed: UInt64(index + 1))
        let hands = AIPlayer.sampleHiddenHands(currentPosition: .north, currentHand: knownHand,
            playedCandidate: [], state: hidden, rng: &rng)
        if !hands.isEmpty { nonempty += 1 }
        let main = (hands[.east] ?? []).filter { CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }
        if !AIPlayer.pairs(in: main, trumpSuit: trump, trumpRank: rank).isEmpty { contradictory += 1 }
    }
    check(nonempty == 24 && contradictory == 0,
          "Review2.6 已知未跟出主对的玩家，24个抽样世界均不得重新拥有主对", "valid=\(nonempty), contradictory=\(contradictory)")
    var failedTractor = Trick(leadPosition: .north)
    let leadTractor = [c(.diamonds, .two), c(.diamonds, .two), c(.diamonds, .three), c(.diamonds, .three)]
    failedTractor.plays = [(.north, leadTractor),
        (.east, [c(.diamonds, .six), c(.diamonds, .six), c(.diamonds, .eight), c(.diamonds, .eight)])]
    let structural = stateFor([c(.clubs, .three)], history: [failedTractor])
    let constraints = AIPlayer.publicFollowConstraints(state: structural)
    check(!AIPlayer.respectsPublicFollowConstraints([.east: [c(.diamonds, .seven), c(.diamonds, .seven)]],
        constraints: constraints, excluding: .north, evaluator: evaluator),
          "Review2.6 跟连对时未贡献连对，也约束历史手牌中的可用连对")

    let half = AIPlayer.uniqueCardFaces(Deck.doubleDeck().filter { CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) })
    let emptyContext = AIContext.build(state: makeState(trump: trump, rank: rank), ts: trump, tr: rank)
    check(AIPlayer.unknownTrumpPairThreatFactor(hand: half, ts: trump, tr: rank, ctx: emptyContext) == 0,
          "Review2.7 每种主各持一张时外面无法成对，主对威胁为0")

    let alternatives = [
        AIPlayer.LeadAsset(move: AIPlayer.AIMove(cards: [c(.hearts, .ace)], kind: .bigSingle), tier: .cashingWinner, score: 400),
        AIPlayer.LeadAsset(move: AIPlayer.AIMove(cards: [c(.clubs, .jack), c(.clubs, .jack)], kind: .bigPair), tier: .sidePairOpportunity, score: 200),
        AIPlayer.LeadAsset(move: AIPlayer.AIMove(cards: [c(.diamonds, .three)], kind: .trumpTransfer), tier: .initiativeBuilder, score: 160),
        AIPlayer.LeadAsset(move: AIPlayer.AIMove(cards: [c(.spades, .four)], kind: .weak), tier: .weakDisposal, score: 40)]
    let diversified = AIPlayer.selectLeadAssetPool(alternatives)
    check(diversified.count == alternatives.count, "Review2.8 兑现A、试对、交牌权、清门同时进入比较，不再只取最高层")

    let planHand = [c(.diamonds, .three), c(.diamonds, .seven), c(.diamonds, .nine),
                    c(.clubs, .six), c(.hearts, .eight), c(.spades, .jack), c(.clubs, .ten)]
    var enemyLead = Trick(leadPosition: .east)
    enemyLead.plays = [(.east, [c(.spades, .three)]), (.south, [c(.spades, .six)]),
                       (.west, [c(.spades, .seven)]), (.north, [c(.spades, .ace)])]
    var ownNewPlan = Trick(leadPosition: .north)
    ownNewPlan.plays = [(.north, [c(.clubs, .ace)]), (.east, [c(.clubs, .three)]),
                        (.south, [c(.clubs, .four)]), (.west, [c(.clubs, .seven)])]
    let renewed = stateFor(planHand, history: [enemyLead, ownNewPlan])
    let renewedContext = AIContext.build(state: renewed, ts: trump, tr: rank)
    check(AIPlayer.leadControlPlan(position: .north, hand: planHand, state: renewed, ctx: renewedContext) == .seekPartnerLead,
          "Review2.9 新副牌计划已执行后，旧的对手领牌不永久关闭交牌权")
    let exhausted = AIContext(playedCards: [], knownCards: [], knownCardsByPlayer: [:],
        voidSuits: [.south: ["TRUMP"]], isLastPlayer: false)
    check(AIPlayer.leadControlPlan(position: .north, hand: planHand, state: renewed, ctx: exhausted) == .reassessSideAssets,
          "Review2.9 对家已绝主时不再制定交给对家的吊主计划")

    let values = [Rank.three, .ten, .jack, .queen, .king, .ace].map {
        AIPlayer.protectableSidePairValue(c(.clubs, $0), trumpRank: rank)
    }
    check(zip(values, values.dropFirst()).allSatisfy(<), "Review2.10 拔主保护模型也按牌力连续排序，Q/J不再为0")
    let queens = [c(.clubs, .queen), c(.clubs, .queen), c(.clubs, .king), c(.clubs, .ace)]
    check(AIPlayer.strongestProtectableSidePairValue(in: queens, suit: .clubs, ts: trump, tr: rank, ctx: emptyContext) > 0
        && AIPlayer.strongestProtectableSidePairValue(in: [c(.clubs, .ten), c(.clubs, .ten)],
            suit: .clubs, ts: trump, tr: rank, ctx: emptyContext) == 0,
          "Review2.10 只保护拔主后确能成为赢家的对子，不把任意10对当作恢复赢家")

    let futureHands: [PlayerPosition: [Card]] = [.south: [c(.hearts, .ace), c(.clubs, .ace)],
        .north: [c(.hearts, .king), c(.clubs, .three)], .west: [c(.hearts, .two), c(.clubs, .four)],
        .east: [c(.hearts, .three), c(.clubs, .six)]]
    let future = stateFor(futureHands[.north]!)
    var futureRNG = AIPlayer.MonteCarloRNG(seed: 99)
    let rolled = AIPlayer.simulateContinuation(hands: futureHands, leader: .south, position: .north,
        state: future, context: emptyContext, rng: &futureRNG)
    check(rolled.score > 0 && rolled.hands.values.allSatisfy { $0.isEmpty },
          "Review2.11 模拟对家接手后连续两墩领牌，计入后续K跑分而非只看眼前一墩", "score=\(rolled.score)")
}

// IMG_6554：合法21墩公开历史；三家已绝黑桃，外面只剩一张主，但Q仍有一张在未知底牌。
do {
    let trump: Suit? = .diamonds
    let rank: Rank = .five
    let evaluator = TrickEvaluator(trumpSuit: trump, trumpRank: rank)
    let s = makeState(trump: trump, rank: rank)
    s.dealerPosition = .south
    let spades = [c(.spades, .jack), c(.spades, .ten)]
    s.player(.west).hand = spades + [c(.clubs, .nine), c(.hearts, .eight)]
    s.player(.south).hand = [c(.diamonds, .ace), c(.clubs, .jack), c(.clubs, .eight), c(.hearts, .king)]
    s.player(.north).hand = [c(.hearts, .jack), c(.clubs, .queen), c(.clubs, .seven), c(.hearts, .nine)]
    s.player(.east).hand = [c(.hearts, .ace), c(.hearts, .ten), c(.clubs, .ace), c(.clubs, .queen)]
    s.kitty = [c(.spades, .ace), c(.spades, .ace), c(.spades, .king), c(.spades, .king),
              c(.spades, .queen), c(.hearts, .three), c(.hearts, .four), c(.hearts, .six)]
    let played = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: s.players.flatMap(\.hand) + s.kitty)
    var mains = played.filter { CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }
        .sorted { CardComparator.trumpWeight($0, trumpSuit: trump, trumpRank: rank) < CardComparator.trumpWeight($1, trumpSuit: trump, trumpRank: rank) }
    var clubs = played.filter { $0.suit == .clubs && !CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }
    var hearts = played.filter { $0.suit == .hearts && !CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }
    var sideSpades = played.filter { $0.suit == .spades && !CardComparator.isTrump($0, trumpSuit: trump, trumpRank: rank) }
    let lastSpade = sideSpades.remove(at: sideSpades.firstIndex { $0.rank == .nine }!)
    func appendSingleTrick(_ cards: [Card]) {
        var trick = Trick(leadPosition: .west)
        trick.plays = zip([PlayerPosition.west, .north, .east, .south], cards).map { (position: $0.0, cards: [$0.1]) }
        s.completedTricks.append(trick)
    }
    for _ in 0..<8 {
        let high = mains.removeLast()
        let low = Array(mains.prefix(3)); mains.removeFirst(3)
        appendSingleTrick([high] + low)
    }
    let offSuit = clubs.removeFirst()
    appendSingleTrick([mains[2], mains[0], offSuit, mains[1]])
    for _ in 0..<4 {
        sideSpades.sort { $0.rank < $1.rank }
        let high = sideSpades.removeLast(), low = Array(sideSpades.prefix(3))
        sideSpades.removeFirst(3)
        appendSingleTrick([high] + low)
    }
    for _ in 0..<4 {
        clubs.sort { $0.rank < $1.rank }
        let high = clubs.removeLast(), low = Array(clubs.prefix(3))
        clubs.removeFirst(3)
        appendSingleTrick([high] + low)
    }
    for _ in 0..<3 {
        hearts.sort { $0.rank < $1.rank }
        let high = hearts.removeLast(), low = Array(hearts.prefix(3))
        hearts.removeFirst(3)
        appendSingleTrick([high] + low)
    }
    appendSingleTrick([lastSpade] + hearts)
    setTrick(s, lead: .west, plays: [], turn: .west)
    let ctx = AIContext.build(state: s, ts: trump, tr: rank)
    var replayHands = Dictionary(uniqueKeysWithValues: s.players.map { p in
        (p.position, p.hand + s.completedTricks.flatMap { t in t.plays.filter { $0.position == p.position }.flatMap(\.cards) })
    })
    var legalHistory = true
    for trick in s.completedTricks {
        legalHistory = legalHistory && evaluator.winner(of: trick) == .west
        for play in trick.plays {
            if play.position != .west {
                legalHistory = legalHistory && evaluator.isValidPlay(selected: play.cards,
                    hand: replayHands[play.position]!, leadCards: trick.leadCards!)
            }
            replayHands[play.position] = AIPlayer.handAfterPlaying(play.cards, from: replayHands[play.position]!)
        }
    }
    check(legalHistory && s.completedTricks.count == 21 && replayHands.values.allSatisfy { $0.count == 4 },
          "IMG6554 回归使用完整108张牌、合法21墩历史，不靠稀疏假手牌")
    let hand = s.player(.west).hand
    let candidates = AIPlayer.findSlamLeadCandidates(in: hand, ts: trump, tr: rank,
        myTeam: 1, ctx: ctx, position: .west, state: s)
    check(candidates.contains { AIPlayer.sameCardSet($0, spades) }
        && !AIPlayer.isEffectivelyBiggestSingle(spades[1], hand: hand, ctx: ctx, ts: trump, tr: rank),
          "IMG6554 三家公开绝门后可证明J+10甩牌合法，不要求偷看未知Q是否在底牌")
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: evaluator)
    check(AIPlayer.sameCardSet(chosen, spades), "IMG6554 主只剩一张时优先整甩黑桃J+10，不拆单送将吃",
          "chosen=\(chosen.map(\.shortDisplay))")
    let heldControl = s.player(.south).hand[0]
    s.player(.south).hand[0] = hand[2]
    s.player(.west).hand = spades + [heldControl, hand[3]]
    let preservedChoice = AIPlayer.chooseCards(position: .west, state: s, evaluator: evaluator)
    check(AIPlayer.sameCardSet(preservedChoice, spades),
          "IMG6554 自己留最后一张主控时，残局保底路径也整甩副牌而不拆单",
          "chosen=\(preservedChoice.map(\.shortDisplay))")
    s.player(.south).hand[0] = heldControl
    s.player(.west).hand = hand
    var slamTrick = Trick(leadPosition: .west)
    slamTrick.plays = [(.west, spades)]
    let risk = AIPlayer.structuredOvertakeProbability(trick: slamTrick, opponent: .south,
        hand: hand, position: .west, state: s, evaluator: evaluator, ctx: ctx)
    check(risk == 0, "IMG6554 只剩一张未知主，不能按60%概率将吃两张纯散牌甩牌")
    let early = AIContext(playedCards: [], knownCards: [], knownCardsByPlayer: [:], voidSuits: ctx.voidSuits, isLastPlayer: false)
    check(AIPlayer.findSlamLeadCandidates(in: hand, ts: trump, tr: rank,
        myTeam: 1, ctx: early, position: .west, state: s).isEmpty,
          "IMG6554 主还多时仍保留已知绝门下的早期纯散牌甩牌保护")

    let observation = s.aiObservation(for: .west)
    check(PlayerPosition.allCases.filter { $0 != .west }.allSatisfy {
        observation.player($0).hand.isEmpty && observation.handCount(for: $0) == s.player($0).hand.count
    } && observation.kitty.isEmpty && observation.player(.west).hand == hand,
          "Privacy 决策快照不包含队友/对手真实手牌或非庄家底牌，只保留公开张数")
    let dealerView = s.aiObservation(for: .south)
    check(dealerView.kitty == s.kitty, "Privacy 庄家仍能合法使用自己埋下的底牌")
    let southHand = s.player(.south).hand
    s.player(.south).hand = s.player(.north).hand
    s.player(.north).hand = southHand
    let buriedHeart = s.kitty[5]
    s.kitty[5] = s.player(.north).hand[3]
    s.player(.north).hand[3] = buriedHeart
    check(AIPlayer.sameCardSet(AIPlayer.chooseCards(position: .west, state: s, evaluator: evaluator), chosen),
          "Privacy 公共信息和张数相同，交换真实隐藏手牌/底牌不能改变领出决策")
    s.player(.west).hand = AIPlayer.handAfterPlaying(chosen, from: hand)
    setTrick(s, lead: .west, plays: [(.west, chosen)], turn: .north)
    let follow = AIPlayer.chooseCards(position: .north, state: s, evaluator: evaluator)
    let westCard = s.player(.west).hand[0]
    s.player(.west).hand[0] = s.player(.east).hand[2]
    s.player(.east).hand[2] = westCard
    check(AIPlayer.sameCardSet(AIPlayer.chooseCards(position: .north, state: s, evaluator: evaluator), follow),
          "Privacy 公共信息相同，改变其他人真实牌面不能改变跟牌决策")
}

do {
    let s = makeState(trump: .diamonds, rank: .five)
    var hand = [c(.diamonds, .three), c(.diamonds, .seven), c(.diamonds, .nine)]
    for suit in [Suit.spades, .hearts, .clubs] {
        hand += [Rank.two, .three, .four, .six, .seven, .eight, .jack].map { c(suit, $0) }
    }
    s.dealerPosition = .north
    setTrick(s, lead: .west, plays: [], turn: .west)
    s.player(.west).hand = hand
    var pool = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: hand)
    for seat in [PlayerPosition.north, .east, .south] {
        s.player(seat).hand = Array(pool.prefix(hand.count)); pool.removeFirst(hand.count)
    }
    let context = AIContext.build(state: s, ts: .diamonds, tr: .five)
    let transfer = AIPlayer.findTrumpTransferLeadCandidates(in: hand, ts: .diamonds, tr: .five)[0]
    let weak = AIPlayer.AIMove(cards: [hand[3]], kind: .weak)
    check(AIPlayer.usedBigTrumpEarlyPenalty(state: s, position: .west, hand: hand, move: transfer) == 0
        && AIPlayer.fallbackTrumpTransferPreference(transfer, position: .west, hand: hand, state: s, ctx: context)
            > AIPlayer.fallbackTrumpTransferPreference(weak, position: .west, hand: hand, state: s, ctx: context),
          "Transfer 小主传递不受大主早出重罚，接近同分时优于随手领弱副牌")
    let chosen = AIPlayer.chooseCards(position: .west, state: s, evaluator: TrickEvaluator(trumpSuit: .diamonds, trumpRank: .five))
    check(chosen.count == 1 && chosen[0].suit == .diamonds,
          "Transfer 没有兑现或结构资产时，以低成本吊主传递而非随机小副牌", "chosen=\(chosen.map(\.shortDisplay))")
}

// IMG_6557–6559：只使用截图可见的公开历史与North自己的牌。
// 第8墩有两张被“+2”遮住、末张也不可见，用三个相容手牌变体验证，
// 不把事后看到的队友KK或大王当作North决策时的已知信息。
do {
    let trump: Suit? = .spades
    let rank: Rank = .seven
    let evaluator = TrickEvaluator(trumpSuit: trump, trumpRank: rank)
    func record(_ leader: PlayerPosition, _ plays: [[Card]]) -> Trick {
        var trick = Trick(leadPosition: leader)
        trick.plays = plays.enumerated().map { (seat(after: leader, offset: $0.offset), $0.element) }
        return trick
    }
    let history = [
        record(.north, [[c(.clubs, .ace), c(.clubs, .ace)], [c(.clubs, .three), c(.clubs, .six)],
                        [c(.clubs, .nine), c(.clubs, .four)], [c(.clubs, .king), c(.clubs, .king)]]),
        record(.north, [[c(.clubs, .eight), c(.clubs, .eight)], [c(.clubs, .queen), c(.clubs, .five)],
                        [c(.diamonds, .queen), c(.diamonds, .jack)], [c(.clubs, .four), c(.clubs, .jack)]]),
        record(.north, [[c(.diamonds, .ace)], [c(.diamonds, .three)], [c(.hearts, .six)], [c(.diamonds, .two)]]),
        record(.north, [[c(.clubs, .two), c(.clubs, .two)], [c(.hearts, .three), c(.diamonds, .three)],
                        [c(.hearts, .nine), c(.hearts, .eight)], [c(.clubs, .queen), c(.clubs, .five)]]),
        record(.north, [[c(.hearts, .queen), c(.hearts, .queen)], [c(.hearts, .jack), c(.hearts, .jack)],
                        [c(.hearts, .king), c(.hearts, .king)], [c(.hearts, .two), c(.hearts, .four)]]),
        record(.south, [[c(.clubs, .seven), c(.clubs, .seven)], [c(.spades, .two), c(.spades, .two)],
                        [c(.spades, .seven), c(.spades, .seven)], [c(.spades, .three), c(.spades, .six)]])
    ]
    let visible = [c(.clubs, .ace), c(.clubs, .ace), c(.clubs, .eight), c(.clubs, .eight),
                   c(.clubs, .two), c(.clubs, .two), c(.clubs, .jack), c(.clubs, .ten),
                   c(.hearts, .queen), c(.hearts, .queen), c(.hearts, .ace), c(.hearts, .ten),
                   c(.diamonds, .ace), c(.diamonds, .five), c(.spades, .seven), c(.spades, .seven),
                   c(.spades, .nine), c(.spades, .nine), c(.spades, .ten), c(.spades, .five),
                   c(.spades, .jack), c(nil, .bigJoker)]
    let unseenVariants = [
        [c(.spades, .four), c(.spades, .eight), c(.spades, .king)],
        [c(.spades, .four), c(.hearts, .seven), c(.clubs, .nine)],
        [c(nil, .smallJoker), c(.spades, .eight), c(.diamonds, .six)]
    ]
    for (variant, unseen) in unseenVariants.enumerated() {
        for prefix in [1, 3, 4, 6] {
            let s = makeState(trump: trump, rank: rank)
            s.dealerPosition = .south
            s.completedTricks = Array(history.prefix(prefix))
            setTrick(s, lead: .north, plays: [], turn: .north)
            let northPlayed = s.completedTricks.flatMap { $0.plays.filter { $0.position == .north }.flatMap(\.cards) }
            let hand = AIPlayer.removeKnownFaces(from: visible + unseen, knownCards: northPlayed)
            s.player(.north).hand = hand
            let played = s.completedTricks.flatMap { $0.plays.flatMap(\.cards) }
            let pool = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: hand + played)
            // 其他手牌只提供公开张数；AI入口会隐藏它们，并按历史重采样。
            for (index, position) in [PlayerPosition.east, .south, .west].enumerated() {
                s.player(position).hand = Array(pool[(index * hand.count)..<((index + 1) * hand.count)])
            }
            s.kitty = Array(pool.suffix(8))
            let observation = s.aiObservation(for: .north)
            let ctx = AIContext.build(state: observation, ts: trump, tr: rank)
            let assets = AIPlayer.buildLeadAssets(position: .north, hand: hand, state: observation, ctx: ctx)
            let cashing = AIPlayer.cashingWindowAssets(assets, position: .north, hand: hand, state: observation, ctx: ctx) ?? []
            if prefix == 3 {
                // 小对已是最大对，但持有更多本门牌时，外家绝门概率也会上升；
                // 资产资格与是否安全到能进入兑现窗口必须分开判断。
                check(assets.contains { $0.tier == .cashingWinner && $0.move.cards.count == 2
                        && $0.move.cards.allSatisfy { $0.suit == .clubs && $0.rank == .two } }
                    && cashing.contains { $0.move.cards.count == 1 && $0.move.cards[0].suit == .hearts && $0.move.cards[0].rank == .ace },
                      "Cash 截图第4墩：♣22按已知最大对评估，安全♥A保留兑现窗口（变体\(variant)）")
            } else {
                let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: evaluator)
                check(chosen.count == 1 && chosen[0].rank == .ace
                    && (chosen[0].suit == .hearts || (prefix == 1 && chosen[0].suit == .diamonds)),
                      "Cash 截图第\(prefix + 1)墩：先兑现副A，不试普通对子或已知有将吃风险的♣J（变体\(variant)）",
                      "chosen=\(chosen.map(\.shortDisplay))")
            }
        }
    }

    // 第10墩后两名对手均明确绝主：此时副A不会继续因将吃贬值，
    // 第11墩先跑♦5可以合理，不能把新判断写成任何时候都先出A。
    let safe = makeState(trump: trump, rank: rank)
    safe.completedTricks = [record(.south, [[c(.spades, .three)], [c(.diamonds, .six)],
                                          [c(.spades, .jack)], [c(.diamonds, .four)]])]
    setTrick(safe, lead: .north, plays: [], turn: .north)
    let safeHand = [c(.diamonds, .five), c(.hearts, .ace), c(nil, .bigJoker), c(.clubs, .ten)]
    safe.player(.north).hand = safeHand
    let ctx = AIContext.build(state: safe, ts: trump, tr: rank)
    check(AIPlayer.cashingWindowAssets(AIPlayer.buildLeadAssets(position: .north, hand: safeHand, state: safe, ctx: ctx),
        position: .north, hand: safeHand, state: safe, ctx: ctx) == nil,
          "Cash 两敌已绝主时不强制抢兑副A，允许先跑分与保末墩")
}

// 108张完整牌池、20墩公开历史：旧残局保主分支也不能绕过安全副A的兑现窗口。
do {
    let s = makeState(trump: .spades, rank: .seven)
    s.dealerPosition = .south
    let hand = [c(nil, .bigJoker), c(.hearts, .ace), c(.diamonds, .five), c(.clubs, .ten), c(.diamonds, .six)]
    var rest = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: hand)
    var unknown: [Card] = []
    for (key, count) in [(Suit.hearts.rawValue, 15), (Suit.diamonds.rawValue, 2), (Suit.clubs.rawValue, 3), ("TRUMP", 3)] {
        var available = rest.filter { AIContext.suitKey($0, ts: .spades, tr: .seven) == key }
        if key == Suit.diamonds.rawValue || key == Suit.clubs.rawValue {
            // 外面仍有大♦/大♣，不能把垃圾副牌造成人为已知最大的安全甩牌。
            available.sort { $0.rank.rawValue > $1.rank.rawValue }
        }
        let reserved = Array(available.prefix(count))
        unknown += reserved
        rest = AIPlayer.handAfterPlaying(reserved, from: rest)
    }
    for key in [Suit.hearts.rawValue, Suit.diamonds.rawValue, Suit.clubs.rawValue, "TRUMP"] {
        let cards = rest.filter { AIContext.suitKey($0, ts: .spades, tr: .seven) == key }
        for offset in stride(from: 0, to: cards.count, by: 4) {
            let group = Array(cards[offset..<(offset + 4)]).sorted {
                CardComparator.trumpWeight($0, trumpSuit: .spades, trumpRank: .seven)
                    > CardComparator.trumpWeight($1, trumpSuit: .spades, trumpRank: .seven)
            }
            var trick = Trick(leadPosition: .north)
            trick.plays = group.enumerated().map { (seat(after: .north, offset: $0.offset), [$0.element]) }
            s.completedTricks.append(trick)
        }
    }
    setTrick(s, lead: .north, plays: [], turn: .north)
    s.player(.north).hand = hand
    for (index, position) in [PlayerPosition.east, .south, .west].enumerated() {
        s.player(position).hand = Array(unknown[(index * 5)..<((index + 1) * 5)])
    }
    s.kitty = Array(unknown.suffix(8))
    let observation = s.aiObservation(for: .north)
    let preserves = AIPlayer.shouldPreserveEndgameControlAsset(aiPlayer: observation.player(.north), hand: hand, gameState: observation)
    let chosen = AIPlayer.chooseCards(position: .north, state: s, evaluator: TrickEvaluator(trumpSuit: .spades, trumpRank: .seven))
    check(s.completedTricks.count == 20 && rest.count + unknown.count + hand.count == 108 && preserves
        && chosen.count == 1 && chosen[0].suit == .hearts && chosen[0].rank == .ace,
          "Cash 残局先兑现安全♥A，保留大王不等于先出杂牌拖延A", "preserves=\(preserves), chosen=\(chosen.map(\.shortDisplay))")
}

// IMG_6560：前8墩未提供，构造相容而非臆造原局的完整108张牌池。
// 六墩对子、四墩单张后各剩9张，复用图中第9/10墩和第11墩三家出牌。
// 两张♣A与另一张♣K已出，East的♣K/♣Q均能赢，必须考虑当场收K的10分。
do {
    let s = makeState(trump: ts, rank: tr)
    s.dealerPosition = .south
    var pool = Deck.doubleDeck()
    func take(_ faces: [Card]) -> [Card] {
        var cards: [Card] = []
        for face in faces {
            if let index = pool.firstIndex(where: { AIPlayer.faceKey($0) == AIPlayer.faceKey(face) }) {
                cards.append(pool.remove(at: index))
            }
        }
        return cards
    }
    func append(_ leader: PlayerPosition, _ plays: [[Card]]) {
        var trick = Trick(leadPosition: leader)
        trick.plays = plays.enumerated().map { (seat(after: leader, offset: $0.offset), $0.element) }
        s.completedTricks.append(trick)
    }
    s.player(.south).hand = take([c(.clubs, .three), c(.clubs, .six), c(.spades, .eight),
                                 c(nil, .bigJoker), c(nil, .bigJoker), c(.spades, .ace)])
    s.player(.east).hand = take([c(.clubs, .king), c(.clubs, .queen), c(.hearts, .seven)])
    s.player(.west).hand = take([c(.clubs, .eight), c(.clubs, .queen), c(.hearts, .six)])
    s.player(.north).hand = take([c(.clubs, .nine), c(.clubs, .seven), c(.hearts, .three)])
    let ninth = [take([c(nil, .smallJoker)]), take([c(nil, .smallJoker)]),
                 take([c(.hearts, .five)]), take([c(.spades, .two)])]
    let tenth = [take([c(.spades, .two)]), take([c(.hearts, .four)]),
                 take([c(.diamonds, .three)]), take([c(.hearts, .six)])]
    append(.north, [take([c(.clubs, .ace), c(.clubs, .ace)]), take([c(.clubs, .four), c(.clubs, .five)]),
                    take([c(.clubs, .king), c(.clubs, .ten)]), take([c(.clubs, .four), c(.clubs, .five)])])
    s.kitty = pool.filter { $0.suit == .clubs && $0.rank != tr }
    pool = AIPlayer.handAfterPlaying(s.kitty, from: pool)
    for suit in [Suit.hearts, .diamonds] {
        append(.north, [take([c(suit, .ace), c(suit, .ace)]), take([c(suit, .king), c(suit, .king)]),
                        take([c(suit, .queen), c(suit, .queen)]), take([c(suit, .jack), c(suit, .jack)])])
    }
    let pairs = AIPlayer.pairs(in: pool.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) },
        trumpSuit: ts, trumpRank: tr).sorted {
            CardComparator.trumpWeight($0[0], trumpSuit: ts, trumpRank: tr)
                > CardComparator.trumpWeight($1[0], trumpSuit: ts, trumpRank: tr)
        }
    for offset in stride(from: 0, to: 12, by: 4) {
        append(.north, Array(pairs[offset..<(offset + 4)]))
    }
    pool = AIPlayer.handAfterPlaying(Array(pairs.prefix(12)).flatMap { $0 }, from: pool)
    append(.north, [take([c(.hearts, .ten)]), take([c(.hearts, .eight)]),
                    take([c(.hearts, .nine)]), take([c(.hearts, .ten)])])
    let singles = pool.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.sorted {
        CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr)
            > CardComparator.trumpWeight($1, trumpSuit: ts, trumpRank: tr)
    }
    append(.north, [[singles[1]], [singles[2]], [singles[0]], [singles[3]]])
    pool = AIPlayer.handAfterPlaying(singles, from: pool)
    append(.south, ninth)
    append(.south, tenth)
    for position in PlayerPosition.allCases {
        let needed = 9 - s.player(position).hand.count
        s.player(position).hand += pool.prefix(needed)
        pool.removeFirst(needed)
    }
    // 从初始25张重演，确认这是真实可发、可合法推进的测试局面。
    var replay = Dictionary(uniqueKeysWithValues: s.players.map { ($0.position, $0.hand) })
    for trick in s.completedTricks {
        for play in trick.plays { replay[play.position, default: []] += play.cards }
    }
    let fullDeck = Array(replay.values).flatMap { $0 } + s.kitty
    var legalHistory = true
    var previousWinner: PlayerPosition? = nil
    for trick in s.completedTricks {
        if let previousWinner, trick.leadPosition != previousWinner { legalHistory = false }
        for (offset, play) in trick.plays.enumerated() {
            let hand = replay[play.position]!
            let valid = offset == 0 ? eval.isValidLead(play.cards)
                : eval.isValidPlay(selected: play.cards, hand: hand, leadCards: trick.leadCards!)
            legalHistory = legalHistory && valid
            replay[play.position] = AIPlayer.handAfterPlaying(play.cards, from: hand)
        }
        previousWinner = eval.winner(of: trick)
    }
    check(pool.isEmpty && s.kitty.count == 8 && s.completedTricks.count == 10 && legalHistory
        && fullDeck.count == 108 && Set(fullDeck.map(\.id)).count == 108
        && Dictionary(grouping: fullDeck, by: AIPlayer.faceKey).values.allSatisfy { $0.count == 2 }
        && s.players.allSatisfy { $0.hand.count == 9 },
          "IMG6560 完整108张牌、10墩历史合法且两A一K已出，不靠稀疏状态")
    var current: [(PlayerPosition, [Card])] = []
    for (position, rank) in [(PlayerPosition.south, Rank.three), (.west, .eight), (.north, .nine)] {
        let card = s.player(position).hand.first { $0.suit == .clubs && $0.rank == rank }!
        current.append((position, [card]))
        s.player(position).hand = AIPlayer.handAfterPlaying([card], from: s.player(position).hand)
    }
    setTrick(s, lead: .south, plays: current, turn: .east)
    let hand = s.player(.east).hand
    let ctx = AIContext.build(state: s.aiObservation(for: .east), ts: ts, tr: tr)
    let candidates = AIPlayer.generateFollowCandidates(leadCards: current[0].1,
        hand: hand, position: .east, state: s, evaluator: eval, ctx: ctx)
    check(candidates.contains { $0.cards.count == 1 && $0.cards[0].suit == .clubs && $0.cards[0].rank == .king },
          "IMG6560 Q可赢时仍生成K收分候选，不在模拟前漏掉分牌赢张")
    let chosen = AIPlayer.chooseCards(position: .east, state: s, evaluator: eval)
    check(chosen.count == 1 && chosen[0].suit == .clubs && chosen[0].rank == .king
        && winnerAfter(s, position: .east, cards: chosen, evaluator: eval) == .east,
          "IMG6560 第11墩末家用♣K当场收10分，保留Q不等下轮冒将吃风险",
          "chosen=\(chosen.map(\.shortDisplay))")

    // 同一局面旋转座次，策略不能依赖East的座位编号。
    for rotation in 1...3 {
        let rotated = makeState(trump: ts, rank: tr)
        func rotate(_ position: PlayerPosition) -> PlayerPosition { seat(after: position, offset: rotation) }
        rotated.dealerPosition = rotate(s.dealerPosition)
        for player in s.players { rotated.player(rotate(player.position)).hand = player.hand }
        rotated.kitty = s.kitty
        rotated.completedTricks = s.completedTricks.map { trick in
            var copy = Trick(leadPosition: rotate(trick.leadPosition))
            copy.plays = trick.plays.map { (rotate($0.position), $0.cards) }
            return copy
        }
        setTrick(rotated, lead: rotate(.south), plays: current.map { (rotate($0.0), $0.1) }, turn: rotate(.east))
        let play = AIPlayer.chooseCards(position: rotate(.east), state: rotated, evaluator: eval)
        check(play.count == 1 && play[0].suit == .clubs && play[0].rank == .king,
              "IMG6560 轮转座次\(rotation)仍用K直接收分", "chosen=\(play.map(\.shortDisplay))")
    }
    // 对手已经将吃，K再大也拿不到这一墩：仍必须跟梅花，但不能盲目送K。
    let unsafe = makeState(trump: ts, rank: tr)
    unsafe.player(.east).hand = hand
    setTrick(unsafe, lead: .south, plays: [(.south, [c(.clubs, .three)]), (.west, [c(.clubs, .eight)]),
                                         (.north, [c(.spades, .three)])], turn: .east)
    let losing = AIPlayer.chooseCards(position: .east, state: unsafe, evaluator: eval)
    check(losing.count == 1 && losing[0].suit == .clubs && losing[0].rank == .queen,
          "IMG6560 对手已将吃时跟Q不送K，新候选不能绕过赢墩资格", "chosen=\(losing.map(\.shortDisplay))")
}

// 分牌赢张不能只针对截图的K特判，也不能绕过后手风险或拆结构成本。
do {
    let rank: Rank = .ace
    let evaluator = TrickEvaluator(trumpSuit: .spades, trumpRank: rank)
    func fill(_ core: [Card], count: Int) -> [Card] {
        core + AIPlayer.uniqueCardFaces(Deck.doubleDeck().filter { $0.suit != .clubs })
            .prefix(count - core.count)
    }
    func populate(_ s: GameState, position: PlayerPosition, hand: [Card], priorPlays: Int = 0) {
        s.player(position).hand = hand
        let played = s.completedTricks.flatMap { $0.plays.flatMap(\.cards) } + s.currentTrick.plays.flatMap(\.cards)
        var pool = AIPlayer.removeKnownFaces(from: Deck.doubleDeck(), knownCards: hand + played)
        for other in PlayerPosition.allCases where other != position {
            let currentPlayed = s.currentTrick.plays.contains { $0.position == other } ? 1 : 0
            let count = 25 - priorPlays - currentPlayed
            s.player(other).hand = Array(pool.prefix(count))
            pool.removeFirst(count)
        }
        s.kitty = pool
    }
    for (point, cheap, prior) in [(Rank.king, Rank.queen, [Rank.two, .four, .nine]),
                                  (.ten, .nine, [.two, .three, .eight]),
                                  (.five, .four, [.two, .two, .three])] {
        let s = makeState(trump: .spades, rank: rank)
        setTrick(s, lead: .south, plays: zip([PlayerPosition.south, .west, .north], prior).map {
            ($0.0, [c(.clubs, $0.1)])
        }, turn: .east)
        var priorPlays = 0
        if point == .king {
            // 与截图相同的已知最大K；若A/另一K仍未知，保留K还有额外控牌价值，
            // 不能把那种不同局面也断言为任何时候都必须先收K。
            var aces = Trick(leadPosition: .north)
            aces.plays = [(.north, [c(.clubs, .ace), c(.clubs, .ace)]),
                          (.east, [c(.clubs, .six), c(.clubs, .seven)]),
                          (.south, [c(.clubs, .king), c(.clubs, .ten)]),
                          (.west, [c(.clubs, .eight), c(.clubs, .five)])]
            s.completedTricks = [aces]
            priorPlays = 2
        }
        let hand = fill([c(.clubs, point), c(.clubs, cheap)], count: 25 - priorPlays)
        populate(s, position: .east, hand: hand, priorPlays: priorPlays)
        let chosen = AIPlayer.chooseCards(position: .east, state: s, evaluator: evaluator)
        check(chosen.count == 1 && chosen[0].suit == .clubs && chosen[0].rank == point,
              "CashFollow 末家直接收\(point)的分，不机械出最小赢张\(cheap)", "chosen=\(chosen.map(\.shortDisplay))")
    }

    let unsafe = makeState(trump: .spades, rank: rank)
    var exposed = Trick(leadPosition: .north)
    exposed.plays = [(.north, [c(.clubs, .eight)]), (.east, [c(.hearts, .two)]),
                     (.south, [c(.clubs, .nine)]), (.west, [c(.clubs, .seven)])]
    unsafe.completedTricks = [exposed]
    setTrick(unsafe, lead: .south, plays: [(.south, [c(.clubs, .two)]), (.west, [c(.clubs, .three)])], turn: .north)
    let unsafeHand = fill([c(.clubs, .king), c(.clubs, .queen)], count: 24)
    populate(unsafe, position: .north, hand: unsafeHand, priorPlays: 1)
    let safePlay = AIPlayer.chooseCards(position: .north, state: unsafe, evaluator: evaluator)
    check(safePlay.count == 1 && safePlay[0].rank == .queen && safePlay[0].suit == .clubs,
          "CashFollow 后手对手已绝梅花但仍可能有主时，不为跑分裸送K", "chosen=\(safePlay.map(\.shortDisplay))")

    for structure in [[c(.clubs, .king), c(.clubs, .king)],
                      [c(.clubs, .queen), c(.clubs, .queen), c(.clubs, .king), c(.clubs, .king)]] {
        let s = makeState(trump: .spades, rank: rank)
        setTrick(s, lead: .south, plays: [(.south, [c(.clubs, .two)]), (.west, [c(.clubs, .four)]),
                                        (.north, [c(.clubs, .nine)])], turn: .east)
        let hand = fill(structure + [c(.clubs, .jack)], count: 25)
        populate(s, position: .east, hand: hand)
        let chosen = AIPlayer.chooseCards(position: .east, state: s, evaluator: evaluator)
        check(chosen.count == 1 && chosen[0].suit == .clubs && chosen[0].rank == .jack,
              "CashFollow 有J可赢空墩时保留完整\(structure.count == 2 ? "KK对子" : "QK拖拉机")，不为10分盲拆",
              "chosen=\(chosen.map(\.shortDisplay))")
    }
}

SelfPlayAudit.runRegressions()
SelfPlayAudit.verifySavedSeeds()

if ProcessInfo.processInfo.environment["TRACTOR_AI_FULL_ROUND"] == "1" {
    let env = ProcessInfo.processInfo.environment
    SelfPlayAudit.run(roundCount: max(1, min(100, Int(env["TRACTOR_AI_ROUNDS"] ?? "2") ?? 2)),
        seed: UInt64(env["TRACTOR_AI_SEED"] ?? "1501") ?? 1501,
        reportPath: env["TRACTOR_AI_AUDIT_PATH"], replayPath: env["TRACTOR_AI_REPLAY_PATH"],
        replaySeed: env["TRACTOR_AI_REPLAY_SEED"].flatMap(UInt64.init))
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
