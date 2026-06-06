import Foundation

// MARK: - AIPlayer 调试 / 测试钩子（结构性拆分，逻辑未改）

extension AIPlayer {


    #if DEBUG
    /// 测试钩子：在给定局面下返回检测到的战术模式（仅用单张合法候选近似 legalMoves，足够覆盖单张墩测试）。
    static func _testDetectTacticalMode(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> TacticalMode {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let ctx = AIContext.build(state: state, ts: ts, tr: tr)
        let hand = state.player(position).hand
        let leadCards = state.currentTrick.leadCards ?? []
        let legal: [AIMove] = leadCards.isEmpty ? [] : hand
            .filter { evaluator.isValidPlay(selected: [$0], hand: hand, leadCards: leadCards) }
            .map { AIMove(cards: [$0], kind: .followWin) }
        return detectTacticalMode(
            position: position, hand: hand, state: state,
            evaluator: evaluator, legalMoves: legal, ctx: ctx
        )
    }
    #endif
}
