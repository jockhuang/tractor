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

final class SlamFailureTests: XCTestCase {

    private let evaluator = TrickEvaluator(trumpSuit: .spades, trumpRank: .two)

    private func c(_ suit: Suit?, _ rank: Rank) -> Card {
        Card(suit: suit, rank: rank)
    }

    func testMultipleFailedSinglesForceSmallestSingle() throws {
        let cards = [
            c(.hearts, .five),
            c(.hearts, .seven),
            c(.hearts, .ace)
        ]
        let slam = try XCTUnwrap(evaluator.slamInfo(of: cards))
        let failure = try XCTUnwrap(evaluator.slamFailure(
            slam: slam,
            opponentHands: [
                .west: [c(.hearts, .six)],
                .north: [c(.clubs, .three)],
                .east: [c(.hearts, .nine)]
            ]
        ))

        XCTAssertEqual(failure.forcedKind, .single)
        XCTAssertEqual(failure.forcedLeadCards.map(\.shortDisplay), ["♥5"])
        XCTAssertEqual(failure.penaltyPoints, 20)
    }

    func testFailedPairsTakePriorityAndForceSmallestPair() throws {
        let cards = [
            c(.hearts, .four), c(.hearts, .four),
            c(.hearts, .seven), c(.hearts, .seven),
            c(.hearts, .ten)
        ]
        let slam = try XCTUnwrap(evaluator.slamInfo(of: cards))
        let failure = try XCTUnwrap(evaluator.slamFailure(
            slam: slam,
            opponentHands: [
                .west: [c(.hearts, .five), c(.hearts, .five)],
                .north: [c(.hearts, .eight), c(.hearts, .eight)],
                .east: [c(.hearts, .jack)]
            ]
        ))

        XCTAssertEqual(failure.forcedKind, .pair)
        XCTAssertEqual(failure.forcedLeadCards.map(\.shortDisplay), ["♥4", "♥4"])
        XCTAssertEqual(failure.penaltyPoints, 50)
    }

    func testFailedTractorsTakePriorityAndForceSmallestTractor() throws {
        let cards = [
            c(.hearts, .three), c(.hearts, .three),
            c(.hearts, .four), c(.hearts, .four),
            c(.hearts, .seven), c(.hearts, .seven),
            c(.hearts, .eight), c(.hearts, .eight),
            c(.hearts, .queen), c(.hearts, .queen),
            c(.hearts, .ace)
        ]
        let slam = try XCTUnwrap(evaluator.slamInfo(of: cards))
        let failure = try XCTUnwrap(evaluator.slamFailure(
            slam: slam,
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
        ))

        XCTAssertEqual(failure.forcedKind, .tractor)
        XCTAssertEqual(failure.forcedLeadCards.map(\.rank), [.three, .three, .four, .four])
        XCTAssertEqual(failure.penaltyPoints, 100)
    }

    @MainActor
    func testGameEngineReturnsOtherCardsAndAIHasNoForcedProofCard() {
        let engine = GameEngine()
        let state = engine.state
        state.phase = .playing
        state.trumpSuit = .spades
        state.trumpRank = .two
        state.dealerTeamIdx = 0
        state.currentLeader = .south
        state.currentTurn = .south
        state.currentTrick = Trick(leadPosition: .south)

        let sixes = [c(.hearts, .six), c(.hearts, .six)]
        let ace = c(.hearts, .ace)
        let attemptedSlam = sixes + [ace]
        state.player(.south).hand = attemptedSlam + [c(.clubs, .three)]

        let fours = [c(.hearts, .four), c(.hearts, .four)]
        state.player(.west).hand = fours
        let threes = [c(.hearts, .three), c(.hearts, .three)]
        let queens = [c(.hearts, .queen), c(.hearts, .queen)]
        state.player(.north).hand = threes + queens
        state.player(.east).hand = [c(.diamonds, .four), c(.diamonds, .four)]

        engine.humanPlay(
            position: .south,
            selectedIDs: Set(attemptedSlam.map(\.id))
        )

        XCTAssertEqual(state.currentTrick.plays.first?.cards.map(\.shortDisplay), ["♥6", "♥6"])
        XCTAssertEqual(state.currentTurn, .west)
        XCTAssertEqual(state.attackScore, 20)
        XCTAssertTrue(state.player(.south).hand.contains { $0.id == ace.id })
        XCTAssertTrue(sixes.allSatisfy { six in
            !state.player(.south).hand.contains { $0.id == six.id }
        })

        engine.humanPlay(position: .west, selectedIDs: Set(fours.map(\.id)))

        // 北家的 ♥Q 对是证明原甩牌失败的牌，但失败后不再强制跟出证明牌。
        // 队友南仍以 ♥6 对领先，AI 应按普通对子策略跟最小的 ♥3 对。
        let chosen = AIPlayer.chooseCards(
            position: .north,
            state: state,
            evaluator: evaluator
        )
        XCTAssertEqual(chosen.map(\.shortDisplay), ["♥3", "♥3"])
        engine.humanPlay(position: .north, selectedIDs: Set(chosen.map(\.id)))

        XCTAssertEqual(state.currentTrick.plays.last?.cards.map(\.shortDisplay), ["♥3", "♥3"])
        XCTAssertTrue(queens.allSatisfy { queen in
            state.player(.north).hand.contains { $0.id == queen.id }
        })
    }
}

/// 真实经过 `AIPlayer.chooseCards` 的组合牌战术测试。
/// 覆盖强制跟型、将吃和盖吃，不以单张代表牌近似组合牌行为。
final class AICombinationTacticsTests: XCTestCase {

    private let ts: Suit? = .spades
    private let tr: Rank = .two
    private var evaluator: TrickEvaluator {
        TrickEvaluator(trumpSuit: ts, trumpRank: tr)
    }

    private func c(_ suit: Suit?, _ rank: Rank) -> Card {
        Card(suit: suit, rank: rank)
    }

    private func makeState(
        lead: PlayerPosition,
        plays: [(PlayerPosition, [Card])],
        turn: PlayerPosition,
        hand: [Card]
    ) -> GameState {
        let state = GameState()
        state.phase = .playing
        state.trumpSuit = ts
        state.trumpRank = tr
        state.dealerTeamIdx = 0
        var trick = Trick(leadPosition: lead)
        for play in plays {
            trick.plays.append((position: play.0, cards: play.1))
        }
        state.currentTrick = trick
        state.currentLeader = lead
        state.currentTurn = turn
        state.player(turn).hand = hand
        return state
    }

    private func choose(
        position: PlayerPosition,
        state: GameState
    ) -> [Card] {
        AIPlayer.chooseCards(
            position: position,
            state: state,
            evaluator: evaluator
        )
    }

    private func ranks(_ cards: [Card]) -> [Rank] {
        cards.map(\.rank).sorted { $0.rawValue < $1.rawValue }
    }

    private func winner(
        state: GameState,
        position: PlayerPosition,
        cards: [Card]
    ) -> PlayerPosition {
        var trick = state.currentTrick
        trick.plays.append((position: position, cards: cards))
        return evaluator.winner(of: trick)
    }

    func testAILeadsSafeSlamAsWholeCombination() throws {
        let hand = [
            c(.hearts, .king), c(.hearts, .king), c(.hearts, .ace),
            c(.clubs, .three)
        ]
        let state = makeState(lead: .north, plays: [], turn: .north, hand: hand)

        let chosen = choose(position: .north, state: state)
        let slam = try XCTUnwrap(evaluator.slamInfo(of: chosen))

        XCTAssertEqual(ranks(chosen), [.king, .king, .ace])
        XCTAssertEqual(slam.pairs.count, 1)
        XCTAssertEqual(slam.singles.count, 1)
    }

    func testAIFollowsPairStructureAndUsesWinningPairForPointTrick() {
        let leadPair = [c(.hearts, .king), c(.hearts, .king)]
        let hand = [
            c(.hearts, .three), c(.hearts, .three),
            c(.hearts, .ace), c(.hearts, .ace),
            c(.clubs, .four)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadPair)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)

        XCTAssertTrue(evaluator.isValidPlay(selected: chosen, hand: hand, leadCards: leadPair))
        XCTAssertEqual(ranks(chosen), [.ace, .ace])
        XCTAssertNotNil(AIPlayer.pairRepresentative(of: chosen, trumpSuit: ts, trumpRank: tr))
        XCTAssertEqual(winner(state: state, position: .west, cards: chosen), .west)
    }

    func testAIFollowsTractorStructureAndUsesWinningTractorForPointTrick() {
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
        let state = makeState(
            lead: .south,
            plays: [(.south, leadTractor)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)

        XCTAssertTrue(evaluator.isValidPlay(selected: chosen, hand: hand, leadCards: leadTractor))
        XCTAssertEqual(ranks(chosen), [.jack, .jack, .queen, .queen])
        XCTAssertEqual(AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount, 2)
        XCTAssertEqual(winner(state: state, position: .west, cards: chosen), .west)
    }

    func testAIPairRuffUsesWeakestWinningTrumpPair() {
        let leadPair = [c(.hearts, .king), c(.hearts, .king)]
        let hand = [
            c(.spades, .three), c(.spades, .three),
            c(.spades, .ace), c(.spades, .ace),
            c(.clubs, .four)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadPair)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)

        XCTAssertEqual(ranks(chosen), [.three, .three])
        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertNotNil(AIPlayer.pairRepresentative(of: chosen, trumpSuit: ts, trumpRank: tr))
        XCTAssertEqual(winner(state: state, position: .west, cards: chosen), .west)
    }

    func testAIPairOverruffUsesWeakestHigherTrumpPair() {
        let leadPair = [c(.hearts, .king), c(.hearts, .king)]
        let firstRuff = [c(.spades, .three), c(.spades, .three)]
        let hand = [
            c(.spades, .four), c(.spades, .four),
            c(.spades, .ace), c(.spades, .ace),
            c(.clubs, .six)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadPair), (.west, firstRuff)],
            turn: .north,
            hand: hand
        )

        let chosen = choose(position: .north, state: state)

        XCTAssertEqual(ranks(chosen), [.four, .four])
        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertNotNil(AIPlayer.pairRepresentative(of: chosen, trumpSuit: ts, trumpRank: tr))
        XCTAssertEqual(winner(state: state, position: .north, cards: chosen), .north)
    }

    func testAITractorRuffUsesWeakestWinningTrumpTractor() {
        let leadTractor = [
            c(.hearts, .nine), c(.hearts, .nine),
            c(.hearts, .ten), c(.hearts, .ten)
        ]
        let hand = [
            c(.spades, .three), c(.spades, .three),
            c(.spades, .four), c(.spades, .four),
            c(.spades, .jack), c(.spades, .jack),
            c(.spades, .queen), c(.spades, .queen),
            c(.clubs, .six)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadTractor)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)

        XCTAssertEqual(ranks(chosen), [.three, .three, .four, .four])
        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertEqual(AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount, 2)
        XCTAssertEqual(winner(state: state, position: .west, cards: chosen), .west)
    }

    func testAITractorOverruffUsesHigherTrumpTractorStructure() {
        let leadTractor = [
            c(.hearts, .nine), c(.hearts, .nine),
            c(.hearts, .ten), c(.hearts, .ten)
        ]
        let firstRuff = [
            c(.spades, .three), c(.spades, .three),
            c(.spades, .four), c(.spades, .four)
        ]
        let hand = [
            c(.spades, .five), c(.spades, .five),
            c(.spades, .six), c(.spades, .six),
            c(.spades, .jack), c(.spades, .jack),
            c(.spades, .queen), c(.spades, .queen),
            c(.clubs, .six)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadTractor), (.west, firstRuff)],
            turn: .north,
            hand: hand
        )

        let chosen = choose(position: .north, state: state)

        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertEqual(AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.pairCount, 2)
        let firstHigh = try? XCTUnwrap(
            AIPlayer.tractorInfo(of: firstRuff, trumpSuit: ts, trumpRank: tr)?.highCard
        )
        let chosenHigh = try? XCTUnwrap(
            AIPlayer.tractorInfo(of: chosen, trumpSuit: ts, trumpRank: tr)?.highCard
        )
        XCTAssertTrue(
            firstHigh != nil && chosenHigh != nil &&
                CardComparator.beats(chosenHigh!, firstHigh!, trumpSuit: ts, trumpRank: tr),
            "盖吃必须使用更高的完整主拖拉机，chosen=\(chosen.map(\.shortDisplay))"
        )
        XCTAssertEqual(winner(state: state, position: .north, cards: chosen), .north)
    }

    func testAIStructuredSlamRuffMatchesPairAndSingle() throws {
        let leadSlam = [
            c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
        ]
        let hand = [
            c(.spades, .three), c(.spades, .three), c(.spades, .four),
            c(.spades, .jack), c(.spades, .jack), c(.spades, .queen),
            c(.clubs, .six)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadSlam)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)
        let structure = try XCTUnwrap(evaluator.slamInfo(of: chosen))

        XCTAssertEqual(ranks(chosen), [.three, .three, .four])
        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertEqual(structure.pairs.count, 1)
        XCTAssertEqual(structure.singles.count, 1)
        XCTAssertEqual(winner(state: state, position: .west, cards: chosen), .west)
    }

    func testAIStructuredSlamOverruffMatchesAndRaisesPair() throws {
        let leadSlam = [
            c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
        ]
        let firstRuff = [
            c(.spades, .three), c(.spades, .three), c(.spades, .four)
        ]
        let hand = [
            c(.spades, .five), c(.spades, .five), c(.spades, .six),
            c(.spades, .jack), c(.spades, .jack), c(.spades, .queen),
            c(.clubs, .six)
        ]
        let state = makeState(
            lead: .south,
            plays: [(.south, leadSlam), (.west, firstRuff)],
            turn: .north,
            hand: hand
        )

        let chosen = choose(position: .north, state: state)
        let structure = try XCTUnwrap(evaluator.slamInfo(of: chosen))

        XCTAssertEqual(ranks(chosen), [.five, .five, .six])
        XCTAssertTrue(chosen.allSatisfy { evaluator.cardSuit($0) == nil })
        XCTAssertEqual(structure.pairs.count, 1)
        XCTAssertEqual(structure.singles.count, 1)
        XCTAssertEqual(winner(state: state, position: .north, cards: chosen), .north)
    }

    func testAIDiscardsOnlySideCardsWhenOpponentSlamsAndRuffStructureIsUnavailable() {
        let leadSlam = [
            c(.hearts, .seven), c(.hearts, .seven), c(.hearts, .king)
        ]
        let jokerPair = [c(nil, .bigJoker), c(nil, .bigJoker)]
        let sideDiscards = [
            c(.clubs, .three), c(.diamonds, .four), c(.clubs, .six)
        ]
        let hand = jokerPair + sideDiscards
        let state = makeState(
            lead: .south,
            plays: [(.south, leadSlam)],
            turn: .west,
            hand: hand
        )

        let chosen = choose(position: .west, state: state)

        XCTAssertTrue(evaluator.isValidPlay(selected: chosen, hand: hand, leadCards: leadSlam))
        XCTAssertEqual(Set(chosen.map(\.id)), Set(sideDiscards.map(\.id)))
        XCTAssertFalse(
            chosen.contains {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            },
            "无法匹配甩牌结构时，有足够副牌可垫就不应拆对大王，chosen=\(chosen.map(\.shortDisplay))"
        )
    }
}

final class AIKittyEndgameTests: XCTestCase {

    private let ts: Suit? = .spades
    private let tr: Rank = .two
    private var evaluator: TrickEvaluator {
        TrickEvaluator(trumpSuit: ts, trumpRank: tr)
    }

    private func c(_ suit: Suit?, _ rank: Rank) -> Card {
        Card(suit: suit, rank: rank)
    }

    private func trumpExhaustionEvidence() -> Trick {
        var trick = Trick(leadPosition: .east)
        trick.plays.append((position: .east, cards: [c(.spades, .seven)]))
        trick.plays.append((position: .south, cards: [c(.hearts, .four)]))
        trick.plays.append((position: .west, cards: [c(.spades, .eight)]))
        trick.plays.append((position: .north, cards: [c(.clubs, .six)]))
        return trick
    }

    private func makeEndgameState(
        dealer: PlayerPosition,
        kitty: [Card]
    ) -> (state: GameState, hand: [Card], context: AIContext) {
        let state = GameState()
        state.phase = .playing
        state.trumpSuit = ts
        state.trumpRank = tr
        state.dealerPosition = dealer
        state.dealerTeamIdx = dealer.team
        state.completedTricks = [trumpExhaustionEvidence()]
        state.currentTrick = Trick(leadPosition: .west)
        state.currentLeader = .west
        state.currentTurn = .west
        state.kitty = kitty

        let hand = [
            c(.spades, .three), c(.spades, .four), c(.spades, .ace),
            c(.hearts, .three), c(.clubs, .four), c(.diamonds, .six)
        ]
        state.player(.west).hand = hand
        let context = AIContext.build(state: state, ts: ts, tr: tr)
        return (state, hand, context)
    }

    func testKnownPointKittyAndTrumpVoidEnemiesLeadSideCardToKeepLastControl() {
        let setup = makeEndgameState(
            dealer: .west,
            kitty: [
                c(.hearts, .five), c(.clubs, .ten),
                c(.hearts, .three), c(.hearts, .four),
                c(.clubs, .six), c(.clubs, .seven),
                c(.diamonds, .eight), c(.diamonds, .nine)
            ]
        )

        XCTAssertTrue(
            setup.context.allEnemiesVoid(myTeam: PlayerPosition.west.team, key: "TRUMP")
        )
        XCTAssertEqual(
            AIPlayer.kittyPointKnowledge(
                position: .west,
                hand: setup.hand,
                state: setup.state,
                ctx: setup.context
            ),
            .knownPositive(15)
        )

        let chosen = AIPlayer.chooseCards(
            position: .west,
            state: setup.state,
            evaluator: evaluator
        )

        XCTAssertEqual(chosen.count, 1)
        XCTAssertFalse(
            chosen.contains {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            },
            "已知底牌有15分且两个对手无主时，应先清副牌并保留末轮主牌，chosen=\(chosen.map(\.shortDisplay))"
        )
    }

    func testKnownZeroPointKittyDoesNotActivateBottomPreservationOverride() {
        let setup = makeEndgameState(
            dealer: .west,
            kitty: [
                c(.hearts, .three), c(.hearts, .four),
                c(.clubs, .six), c(.clubs, .seven),
                c(.diamonds, .eight), c(.diamonds, .nine),
                c(.hearts, .jack), c(.clubs, .queen)
            ]
        )

        XCTAssertEqual(
            AIPlayer.kittyPointKnowledge(
                position: .west,
                hand: setup.hand,
                state: setup.state,
                ctx: setup.context
            ),
            .knownZero
        )
        XCTAssertNil(
            AIPlayer.knownPointKittyEndgameLead(
                position: .west,
                hand: setup.hand,
                state: setup.state,
                evaluator: evaluator,
                ctx: setup.context
            ),
            "已知底牌0分时不应启用专门的保底牌覆盖策略"
        )
    }

    func testNonDealerDoesNotReadActualKittyPointsWithoutInference() {
        let setup = makeEndgameState(
            dealer: .south,
            kitty: [
                c(.hearts, .five), c(.clubs, .ten),
                c(.hearts, .three), c(.hearts, .four),
                c(.clubs, .six), c(.clubs, .seven),
                c(.diamonds, .eight), c(.diamonds, .nine)
            ]
        )

        XCTAssertEqual(
            AIPlayer.kittyPointKnowledge(
                position: .west,
                hand: setup.hand,
                state: setup.state,
                ctx: setup.context
            ),
            .unknown,
            "非庄家不能直接读取真实底牌中的15分"
        )
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
                // 东的两名对手（南、北）都在同一墩明确暴露无主。
                var t = Trick(leadPosition: .west)
                t.plays.append((position: .west, cards: [c(.spades, .three)]))
                t.plays.append((position: .north, cards: [c(.hearts, .six)]))
                t.plays.append((position: .east, cards: [c(.spades, .four)]))
                t.plays.append((position: .south, cards: [c(.diamonds, .six)]))
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
