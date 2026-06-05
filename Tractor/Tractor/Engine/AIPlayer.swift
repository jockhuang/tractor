import Foundation

// MARK: - AI Game Memory（从已出的牌推导）

private struct AIContext {

    let playedCards: [Card]
    /// 每个玩家确认绝掉的逻辑花色 key（同 suitKey 格式）
    let voidSuits: [PlayerPosition: Set<String>]
    /// 当前 AI 是否为本墩最后一个出牌的玩家（3 家已出牌时为 true）
    let isLastPlayer: Bool

    // MARK: Build

    static func build(state: GameState, ts: Suit?, tr: Rank) -> AIContext {
        var played: [Card] = []
        var voids: [PlayerPosition: Set<String>] = [:]

        for trick in state.completedTricks {
            guard let lead = trick.plays.first,
                  let lc   = lead.cards.first else { continue }
            let lk = suitKey(lc, ts: ts, tr: tr)
            for play in trick.plays {
                played.append(contentsOf: play.cards)
                if play.position != lead.position,
                   let fc = play.cards.first,
                   suitKey(fc, ts: ts, tr: tr) != lk {
                    voids[play.position, default: []].insert(lk)
                }
            }
        }
        // 本墩已出的牌也算"已知"
        for play in state.currentTrick.plays {
            played.append(contentsOf: play.cards)
        }
        let isLast = state.currentTrick.plays.count == 3
        return AIContext(playedCards: played, voidSuits: voids, isLastPlayer: isLast)
    }

    // MARK: Helpers

    /// 逻辑花色 key：主牌 → "TRUMP"，副牌 → suit.rawValue
    static func suitKey(_ card: Card, ts: Suit?, tr: Rank) -> String {
        CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? "TRUMP"
            : (card.suit?.rawValue ?? "TRUMP")
    }

    func isVoid(_ pos: PlayerPosition, key: String) -> Bool {
        voidSuits[pos]?.contains(key) ?? false
    }

    /// 该敌方玩家是否确认已绝此花色
    func enemyVoid(_ pos: PlayerPosition, key: String, myTeam: Int) -> Bool {
        pos.team != myTeam && isVoid(pos, key: key)
    }

    /// 所有敌方玩家都绝了此花色
    func allEnemiesVoid(myTeam: Int, key: String) -> Bool {
        PlayerPosition.allCases
            .filter { $0.team != myTeam }
            .allSatisfy { isVoid($0, key: key) }
    }

    /// 指定逻辑花色 key 的敌方绝对玩家列表
    func voidEnemies(myTeam: Int, key: String) -> [PlayerPosition] {
        PlayerPosition.allCases.filter { enemyVoid($0, key: key, myTeam: myTeam) }
    }

    /// 该非主牌是否当前"已是最大"（双副牌中，所有更大的同花色牌均已出完 2 张）
    func isEffectivelyBiggest(_ card: Card, ts: Suit?, tr: Rank) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }

        // 统计已打出的同花色、更大牌的数量
        var higherPlayed: [Int: Int] = [:]
        for c in playedCards
            where c.suit == suit
               && !CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr)
               && c.rank.rawValue > card.rank.rawValue {
            higherPlayed[c.rank.rawValue, default: 0] += 1
        }
        // 每个更大的 rank 需要 2 张都打完（双副牌）
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { (higherPlayed[$0.rawValue] ?? 0) >= 2 }
    }

    /// 大主牌（大小王 + 级牌）是否仍有残留
    /// 双副牌共 4 张王 + 8 张级牌（4花色×2副）= 12 张大主牌
    /// 若已出数量不足一半（<6），则认为场上仍有大主牌威胁
    func manyBigTrumpsRemain(trumpRank: Rank) -> Bool {
        // 双副牌大主牌总张数：大王×2 + 小王×2 + 4花色×2副×1张 = 12
        let totalBigTrumps = 12
        let played = playedCards.filter {
            $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == trumpRank
        }.count
        return played < totalBigTrumps / 2   // 不足一半出完 → 大主牌仍多
    }

    /// 某非主花色剩余未出的分牌张数（双副牌：5,10,K 各 2 张）
    func unplayedSuitPoints(suit: Suit, tr: Rank) -> Int {
        let pointRanks: [Rank] = [.five, .ten, .king]
        var total = 0
        for rank in pointRanks where rank != tr {
            let played = playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            total += max(0, 2 - played)
        }
        return total
    }

}

// MARK: - AIPlayer

struct AIPlayer {

    private struct TractorInfo {
        let pairCount: Int
        let highCard: Card
    }

    private enum MoveKind {
        case slam
        case partnerDump
        case bigSingle
        case bigPair
        case tractor
        case trump
        case trumpTransfer
        case weak
        case ruleBased
        case followBaseline
        case followWin
        case followSupport
        case followDiscard
    }

    private enum FollowWinClass {
        case finalWin
        case temporaryWin
        case cannotWin
    }

    private enum TrumpControlClass {
        case secureWinner
        case contestingTrump
        case passiveTrump
    }

    private struct TrumpControlDecision {
        let classification: TrumpControlClass
        let score: Double
        let leadControlValue: Double
        let cost: Double
    }

    private struct AIMove {
        let cards: [Card]
        let kind: MoveKind
    }

    private static let monteCarloTopMoveCount = 5
    private static let monteCarloSimulationCount = 24

    /// 「小主过渡 / Controlled Trump Transfer」最少主牌数：
    /// 主牌不少于此值时，若没有更好的先手选择，宁可领出一张低成本小主以保住出牌权，
    /// 也不要随手领一张无控制力的小副牌把出牌权随机送给对手。
    private static let trumpTransferMinTrumpCount = 5

    /// AI 决策：选择要出的牌
    static func chooseCards(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = []
    ) -> [Card] {
        let hand = state.player(position).hand
        guard !hand.isEmpty else { return [] }

        let ts = state.trumpSuit
        let tr = state.trumpRank
        let ctx = AIContext.build(state: state, ts: ts, tr: tr)

        if state.currentTrick.plays.isEmpty {
            return leadCards(position: position, hand: hand,
                             state: state, evaluator: evaluator, ctx: ctx)
        }

        let lc = state.currentTrick.leadCards!
        return followCards(leadCards: lc, hand: hand, position: position,
                           state: state, evaluator: evaluator,
                           forcedCards: forcedCards, ctx: ctx)
    }

    // MARK: - 先手策略

    private static func leadCards(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let myTeam = position.team

        var candidates: [AIMove] = []
        // 1. Safe slam leads
        candidates += findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            .map { AIMove(cards: $0, kind: .slam) }
        // 2. Absolute side winners: side A, known highest side single, known highest side pair
        candidates += findAbsoluteSideWinnerLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
        // 3. Legal tractors
        candidates += findTractorLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
        // 4. Strong pairs
        candidates += findStrongPairLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
        // 5. Normal pairs
        candidates += findPairFirstLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
        // 6. Long-suit / strategic plans
        candidates += findPartnerDumpLeadCandidates(in: hand, position: position, ts: ts, tr: tr, ctx: ctx)
        candidates += findNoTrumpControlLeadCandidates(in: hand, trumpSuit: ts, trumpRank: tr)
        candidates += findTrumpLeadCandidates(in: hand, position: position, state: state, ts: ts, tr: tr, ctx: ctx)
        // 7. Trump transfer leads
        candidates += findTrumpTransferLeadCandidates(in: hand, ts: ts, tr: tr)
        // 8. Weak cards
        candidates += findWeakLeadCandidates(in: hand, ts: ts, tr: tr)
        let ruleBasedCards = leadCardsRuleBased(position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx)
        let ruleBasedKind: MoveKind = evaluator.slamInfo(of: ruleBasedCards) != nil ? .slam : .ruleBased
        candidates.append(AIMove(
            cards: ruleBasedCards,
            kind: ruleBasedKind
        ))

        let legal = deduplicatedMoves(candidates)
            .filter { !$0.cards.isEmpty && $0.cards.allSatisfy { card in hand.contains(where: { $0.id == card.id }) } }

        let ranked = legal.sorted {
            let lhsPriority = leadPlanPriority($0, hand: hand, state: state, ctx: ctx)
            let rhsPriority = leadPlanPriority($1, hand: hand, state: state, ctx: ctx)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return scoreLead($0, position: position, hand: hand, state: state, ctx: ctx)
                > scoreLead($1, position: position, hand: hand, state: state, ctx: ctx)
        }
        let allowedRanked = filterAllowedLeadMoves(ranked, position: position, hand: hand, state: state)
        var topMoves = Array(allowedRanked.prefix(monteCarloTopMoveCount))
        // Absolute Side Winner First：副牌绝对赢家比普通对子资产更容易过期，优先进入模拟。
        for winnerMove in allowedRanked where isAbsoluteSideWinnerLead(winnerMove.cards, hand: hand, ts: ts, tr: tr, ctx: ctx) {
            if !topMoves.contains(where: { Set($0.cards.map(\.id)) == Set(winnerMove.cards.map(\.id)) }) {
                topMoves.append(winnerMove)
            }
        }
        // Tractor First：合法拖拉机必须进入 Monte Carlo，不能被 AA/KK 单独对子挤掉。
        for tractorMove in allowedRanked where isTractorLead(tractorMove.cards, ts: ts, tr: tr) {
            if !topMoves.contains(where: { Set($0.cards.map(\.id)) == Set(tractorMove.cards.map(\.id)) }) {
                topMoves.append(tractorMove)
            }
        }
        // 规则 4：强对子候选必须进入 Monte Carlo 备选，不能被单张挤掉
        for sp in allowedRanked where isStrongPairLead(sp.cards, ts: ts, tr: tr) {
            if !topMoves.contains(where: { Set($0.cards.map(\.id)) == Set(sp.cards.map(\.id)) }) {
                topMoves.append(sp)
            }
        }
        // Pair First：普通对子也是牌型资源，至少要进入模拟比较，不能只让散牌候选占满 Top-N。
        for pairMove in allowedRanked where isPairFirstLead(pairMove.cards, ts: ts, tr: tr) {
            if !topMoves.contains(where: { Set($0.cards.map(\.id)) == Set(pairMove.cards.map(\.id)) }) {
                topMoves.append(pairMove)
            }
        }
        return monteCarloBestMove(
            from: topMoves,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            heuristicScore: { scoreLead($0, position: position, hand: hand, state: state, ctx: ctx) }
        )?.cards ?? allowedRanked.first?.cards ?? ranked.first?.cards ?? weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }

    private static func leadCardsRuleBased(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let myTeam = position.team

        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        // ── 0. 甩牌：同一花色有 2+ 张最大牌时一起甩出 ─────────────
        if let slamCards = findSlamLead(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx) {
            return slamCards
        }

        // ── 1. 当前"已是最大"的非主牌中，优先出对子 ──────────────
        // 按花色分组，找有"当前最大"牌的花色（且不是敌方已绝的花色）
        var biggestBySuit: [Suit: [Card]] = [:]
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) {
            guard let suit = card.suit else { continue }
            let key = AIContext.suitKey(card, ts: ts, tr: tr)
            // 敌方已全绝此花色，领出无意义（对方会将吃）
            if ctx.allEnemiesVoid(myTeam: myTeam, key: key) { continue }
            biggestBySuit[suit, default: []].append(card)
        }

        // 找"最大"牌里有对子的花色 → 出对子
        for (_, cards) in biggestBySuit {
            var grouped: [String: [Card]] = [:]
            for c in cards {
                grouped[CardComparator.pairKey(c, trumpSuit: ts, trumpRank: tr), default: []].append(c)
            }
            if let pair = grouped.values.first(where: { $0.count >= 2 }) {
                return Array(pair.prefix(2))
            }
        }

        // 找"最大"单牌，优先出最大的
        if let best = biggestBySuit.values.flatMap({ $0 })
            .sorted(by: { $0.rank.rawValue > $1.rank.rawValue }).first {
            return [best]
        }

        // ── 2. 旁门 Ace（且敌方未绝此花色）─────────────────────
        if let sideAce = bestSideAce(in: hand, trumpSuit: ts, trumpRank: tr,
                                      myTeam: myTeam, ctx: ctx) {
            return [sideAce]
        }

        // ── 3. 非主花色连对 ──────────────────────────────────
        if let tractor = findTractor(in: hand, trumpSuit: ts, trumpRank: tr) {
            return tractor
        }

        // ── 4. 队友绝花色且该花色有分未出 → 引出队友垫分 ────
        // 找队友位置，检查队友已绝的花色里哪些还有分牌未出
        // 领出该花色让队友把手中分牌垫给我们
        if let partnerPos = PlayerPosition.allCases.first(where: { $0.team == myTeam && $0 != position }) {
            // 收集候选：队友已绝 & 该花色有分未出 & AI手中有该花色牌
            var candidates: [(strongest: Card, suitCards: [Card])] = []
            for suit in Suit.allCases {
                let key = suit.rawValue
                guard ctx.isVoid(partnerPos, key: key) else { continue }
                guard ctx.unplayedSuitPoints(suit: suit, tr: tr) > 0 else { continue }
                let sc = sideCards.filter { $0.suit == suit }
                guard let strongest = sc.max(by: {
                    CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
                }) else { continue }
                candidates.append((strongest: strongest, suitCards: sc))
            }
            // 从候选中选最强的花色
            if let best = candidates.max(by: {
                CardComparator.beats($1.strongest, $0.strongest, trumpSuit: ts, trumpRank: tr)
            }) {
                // 有对子则出对子
                if let p = pairs(in: best.suitCards, trumpSuit: ts, trumpRank: tr)
                    .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                    return p
                }
                return [best.strongest]
            }
        }

        // ── 5. 非主花色对子（避免敌方已绝花色）──────────────────
        if let pair = findBestPairAvoidingVoid(in: hand, ts: ts, tr: tr,
                                               myTeam: myTeam, ctx: ctx) {
            return pair
        }
        if let pair = findPair(in: hand, trumpSuit: ts, trumpRank: tr) {
            return pair
        }

        // ── 6. 小主牌（无分孤张优先，再有分，再最弱主对）────
        if let card = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                         trumpSuit: ts, trumpRank: tr).first { return [card] }
        if let card = leadableSingletons(from: hand, isTrump: true, pointOnly: nil,
                                         trumpSuit: ts, trumpRank: tr).first { return [card] }
        if let p = findWeakestTrumpPair(in: hand, nonPointFirst: true,
                                         trumpSuit: ts, trumpRank: tr) { return p }

        // ── 7. 主牌不多时，改从副牌中出较大的 ──────────────
        // 当手中主牌 ≤ 3 张时，主动领副牌大牌以尽量赢墩
        let trumpCount = hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
        if trumpCount <= 3, !sideCards.isEmpty {
            // 按牌力从大到小排，选最强非主牌（忽略是否已是最大）
            let strongest = sideCards.sorted {
                CardComparator.beats($0, $1, trumpSuit: ts, trumpRank: tr)
            }
            // 有对子则出对子（强对）
            if let p = pairs(in: sideCards, trumpSuit: ts, trumpRank: tr)
                .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                return p
            }
            if let card = strongest.first { return [card] }
        }

        // ── 8. 最弱牌（最后兜底）────────────────────────────
        return weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr)
    }

    // MARK: - 跟牌策略

    private static func followCards(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = [],
        ctx: AIContext
    ) -> [Card] {
        if !forcedCards.isEmpty {
            return followCardsRuleBased(
                leadCards: leadCards, hand: hand, position: position,
                state: state, evaluator: evaluator, forcedCards: forcedCards, ctx: ctx
            )
        }

        let baseline = followCardsRuleBased(
            leadCards: leadCards, hand: hand, position: position,
            state: state, evaluator: evaluator, forcedCards: forcedCards, ctx: ctx
        )
        var candidates = [AIMove(cards: baseline, kind: .followBaseline)]
        candidates += generateFollowCandidates(
            leadCards: leadCards, hand: hand, position: position,
            state: state, evaluator: evaluator, ctx: ctx
        )
        candidates += generateTrumpControlCandidates(
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        let legal = deduplicatedMoves(candidates).filter {
            evaluator.isValidPlay(selected: $0.cards, hand: hand, leadCards: leadCards)
        }

        let trumpControlFilteredLegal = filterTrumpControlMoves(
            legal,
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
        let filteredLegal = filterHighInitiativeWinningMoves(
            trumpControlFilteredLegal,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        let ranked = filteredLegal.sorted {
            scoreFollow($0, leadCards: leadCards, hand: hand, position: position,
                        state: state, evaluator: evaluator, ctx: ctx)
                > scoreFollow($1, leadCards: leadCards, hand: hand, position: position,
                              state: state, evaluator: evaluator, ctx: ctx)
        }
        let topMoves = Array(ranked.prefix(monteCarloTopMoveCount))
        return monteCarloBestMove(
            from: topMoves,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            heuristicScore: {
                scoreFollow($0, leadCards: leadCards, hand: hand, position: position,
                            state: state, evaluator: evaluator, ctx: ctx)
            }
        )?.cards ?? ranked.first?.cards ?? baseline
    }

    private static func followCardsRuleBased(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        forcedCards: [Card] = [],
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count

        // 甩牌失败强制出牌
        if !forcedCards.isEmpty {
            var chosen = Array(forcedCards.prefix(count))
            if chosen.count < count {
                let usedIDs = Set(chosen.map { $0.id })
                let rest = hand.filter { !usedIDs.contains($0.id) }
                chosen += smartDiscard(
                    from: rest, count: count - chosen.count,
                    enemyWinning: true, ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx
                )
            }
            return Array(chosen.prefix(count))
        }

        let leadSuit     = evaluator.dominantSuit(of: leadCards)
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let winningCards  = state.currentTrick.plays.first {
            $0.position == currentWinner
        }?.cards ?? leadCards
        let partnerWinning = currentWinner.team == position.team
        let enemyWinning   = !partnerWinning

        let suitCards  = hand.filter { evaluator.cardSuit($0) == leadSuit }
        let trickPoints = state.currentTrick.plays
            .flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
        let trickSecureForTeam = isTrickSecureForTeam(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        // ── 连对 ────────────────────────────────────────────
        if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
            return followTractor(
                leadTractor: leadTractor,
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr,
                position: position,
                leadSuit: leadSuit,
                ctx: ctx,
                trickSecure: trickSecureForTeam
            )
        }

        // ── 对子 ─────────────────────────────────────────────
        if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
            return followPair(
                winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards,
                hand: hand,
                trumpSuit: ts,
                trumpRank: tr,
                position: position,
                leadSuit: leadSuit,
                trickPoints: trickPoints,
                ctx: ctx,
                trickSecure: trickSecureForTeam
            )
        }

        // ── 甩牌 ─────────────────────────────────────────────
        if let slam = evaluator.slamInfo(of: leadCards) {
            return followSlam(
                slam: slam, winningCards: winningCards,
                partnerWinning: partnerWinning,
                suitCards: suitCards, hand: hand,
                position: position, count: count,
                ts: ts, tr: tr, ctx: ctx,
                trickSecure: trickSecureForTeam
            )
        }

        // ── 单牌 ─────────────────────────────────────────────
        var chosen: [Card] = []

        // 吊主保守条件：先手花色为主牌 && 非末位出牌 && 敌方领先 && 仍有大主牌残留
        // 满足时跟牌优先出无分主牌，避免把 5/10/K 送给后手大牌截胡
        let leadIsTrump = leadSuit == nil
        let shouldAvoidPointsWhenFollowing =
            leadIsTrump && !ctx.isLastPlayer && enemyWinning && ctx.manyBigTrumpsRemain(trumpRank: tr)

        if suitCards.count >= count {
            let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
            let canBeat = partnerWinning ? [] : suitCards.filter {
                CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr)
            }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

            if !canBeat.isEmpty {
                let secureCanBeat = canBeat.filter {
                    leadIsTrump
                        ? isSecureWinningTrumpFollow(
                            [$0],
                            position: position,
                            hand: hand,
                            state: state,
                            evaluator: evaluator,
                            ctx: ctx
                        )
                        : isTrickSecureForTeam(
                            position: position,
                            hand: hand,
                            state: state,
                            evaluator: evaluator,
                            ctx: ctx,
                            candidateCards: [$0]
                        )
                }
                // 本墩 ≥10分 且 攻方累计 >60分：局势关键，从大往小出，争胜
                let aggressive = trickPoints >= 10 && state.attackScore > 60
                if let secureWin = secureCanBeat.first {
                    chosen = [secureWin]
                } else if !shouldRiskUnsafeWin(
                    trickPoints: trickPoints,
                    playedPoints: canBeat.first?.pointValue ?? 0,
                    ctx: ctx
                ) {
                    chosen = shouldAvoidPointsWhenFollowing
                        ? weakestNonPointFirst(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
                        : weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
                } else if aggressive {
                    // 末位出牌时无后手威胁，出最小能压赢的即可；非末位才需要出最大牌确保拿墩
                    chosen = ctx.isLastPlayer
                        ? Array(canBeat.prefix(count))
                        : Array(canBeat.reversed().prefix(count))
                } else {
                    if let guardCard = pointGuardCard(
                        from: canBeat,
                        leadSuit: leadSuit,
                        winningRep: winningRep,
                        hand: hand,
                        position: position,
                        state: state,
                        trickPoints: trickPoints,
                        ts: ts,
                        tr: tr,
                        ctx: ctx
                    ) {
                        chosen = [guardCard]
                    } else if leadIsTrump && !ctx.isLastPlayer {
                        // 跟主 + 非末位 + 后手仍有对手时：优先选 A 及以上大牌压住
                        // 防止后手对手用 K 轻松击败我方出的 J/Q 等中等主牌而获分
                        let subsequent = unplayedSubsequentPositions(after: position, in: state)
                        if subsequent.contains(where: { $0.team != position.team }) {
                            let safeCanBeat = canBeat.filter {
                                isSecureWinningTrumpFollow(
                                    [$0],
                                    position: position,
                                    hand: hand,
                                    state: state,
                                    evaluator: evaluator,
                                    ctx: ctx
                                )
                            }
                            chosen = Array((safeCanBeat.isEmpty ? canBeat : safeCanBeat).prefix(count))
                        } else {
                            chosen = Array(canBeat.prefix(count))
                        }
                    } else {
                        chosen = Array(canBeat.prefix(count))
                    }
                }
            } else if partnerWinning {
                if leadIsTrump {
                    let partnerRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    let protectiveCards = suitCards
                        .filter { CardComparator.beats($0, partnerRep, trumpSuit: ts, trumpRank: tr) }
                        .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                    if let guardCard = pointGuardCard(
                        from: protectiveCards,
                        leadSuit: leadSuit,
                        winningRep: partnerRep,
                        hand: hand,
                        position: position,
                        state: state,
                        trickPoints: trickPoints,
                        ts: ts,
                        tr: tr,
                        ctx: ctx
                    ) {
                        chosen = [guardCard]
                    } else {
                        // 跟主且我方领先：只有安全墩才加分，否则出无分主牌，防止后手大主截胡
                        chosen = trickSecureForTeam
                            ? partnerSupportCards(from: suitCards, count: count,
                                                  trumpSuit: ts, trumpRank: tr)
                            : weakestNonPointFirst(from: suitCards, count: count,
                                                   trumpSuit: ts, trumpRank: tr)
                    }
                } else {
                    let partnerRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    let protectiveCards = suitCards
                        .filter { CardComparator.beats($0, partnerRep, trumpSuit: ts, trumpRank: tr) }
                        .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                    if let guardCard = pointGuardCard(
                        from: protectiveCards,
                        leadSuit: leadSuit,
                        winningRep: partnerRep,
                        hand: hand,
                        position: position,
                        state: state,
                        trickPoints: trickPoints,
                        ts: ts,
                        tr: tr,
                        ctx: ctx
                    ) {
                        chosen = [guardCard]
                    } else {
                        chosen = trickSecureForTeam
                            ? partnerSupportCards(from: suitCards, count: count,
                                                  trumpSuit: ts, trumpRank: tr)
                            : weakestNonPointFirst(from: suitCards, count: count,
                                                   trumpSuit: ts, trumpRank: tr)
                    }
                }
            } else if shouldAvoidPointsWhenFollowing {
                // 吊主保守：优先出无分主牌
                chosen = weakestNonPointFirst(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            } else {
                chosen = weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }
        } else {
            // 同花色不够：先出所有同花色
            chosen = suitCards
            let remaining = count - chosen.count
            if remaining > 0 {
                let extra = hand.filter { evaluator.cardSuit($0) != leadSuit }

                // 提前计算后手对手花色信息（截胡和常规策略均需要）
                let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
                let subsequent = unplayedSubsequentPositions(after: position, in: state)
                // 后手对手绝了先手花色 且 还有主牌（可能出主将吃）才需要特殊处理
                // 若后手对手绝花色但也没有主，小主截胡即可，走原有逻辑
                let enemySubsequentVoidInLead = subsequent.contains {
                    $0.team != position.team
                    && ctx.isVoid($0, key: leadKey)
                    && !ctx.isVoid($0, key: "TRUMP")
                }

                // ── 对方大 + 本墩有分 → 主动压牌（优先截胡）──────
                if enemyWinning && trickPoints > 0 {
                    let winRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    // 找能压赢的牌（主牌优先能压非主赢家），按弱到强排序
                    let canBeatExtra = extra.filter {
                        CardComparator.beats($0, winRep, trumpSuit: ts, trumpRank: tr)
                    }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                    if !canBeatExtra.isEmpty {
                        let intercept: [Card]
                        let secureCanBeat = canBeatExtra.filter {
                            isTrickSecureForTeam(
                                position: position,
                                hand: hand,
                                state: state,
                                evaluator: evaluator,
                                ctx: ctx,
                                candidateCards: [$0]
                            )
                        }
                        let aggressive = trickPoints >= 10 && state.attackScore > 60
                        if let secureWin = secureCanBeat.first {
                            intercept = [secureWin]
                        } else if !shouldRiskUnsafeWin(
                            trickPoints: trickPoints,
                            playedPoints: canBeatExtra.first?.pointValue ?? 0,
                            ctx: ctx
                        ) {
                            intercept = []
                        } else if aggressive {
                            // 本墩 ≥10分 且 攻方累计 >60分：局势关键，争胜
                            // 末位出牌时无后手威胁，出最小能压赢的；非末位才出最大牌
                            intercept = ctx.isLastPlayer
                                ? Array(canBeatExtra.prefix(remaining))
                                : Array(canBeatExtra.reversed().prefix(remaining))
                        } else if enemySubsequentVoidInLead && !ctx.isLastPlayer {
                            // 后手对手也绝该花色且还有主牌：出安全主牌（A及以上），
                            // 防止后手对手用稍大主牌截走本墩
                            let safeCanBeat = canBeatExtra.filter {
                                isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx, hand: hand)
                            }
                            intercept = Array((safeCanBeat.isEmpty ? canBeatExtra : safeCanBeat)
                                .prefix(remaining))
                        } else {
                            intercept = Array(canBeatExtra.prefix(remaining))
                        }
                        if intercept.isEmpty {
                            chosen += smartDiscard(
                                from: extra, count: remaining,
                                enemyWinning: true,
                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                            )
                            return Array(chosen.prefix(count))
                        }

                        chosen += intercept
                        // 若还需凑牌（多张跟牌场景），垫分给自己
                        if chosen.count < count {
                            let ids = Set(chosen.map { $0.id })
                            let rest = hand.filter { !ids.contains($0.id) }
                            chosen += smartDiscard(
                                from: rest, count: count - chosen.count,
                                enemyWinning: false,   // 我方已压住，按队友赢策略垫分
                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                            )
                        }
                        return Array(chosen.prefix(count))
                    }
                    // canBeatExtra 为空：手中无牌能压赢当前领先者
                    // 激进模式下不浪费大牌（如小王赔给大王毫无意义），直接出最弱的
                    if trickPoints >= 10 && state.attackScore > 60 {
                        chosen += smartDiscard(
                            from: extra, count: remaining,
                            enemyWinning: true,
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                        )
                        return Array(chosen.prefix(count))
                    }
                }
                // 队友赢 但该花色还有更大的未出牌 → 后续对手可能出大牌压走本墩
                // 此时不应垫分给队友，而要用主将吃保护本墩
                var partnerAtRisk = false
                if partnerWinning, let suit = leadSuit {
                    let winRep = maxCard(in: winningCards, ts: ts, tr: tr)
                    if !CardComparator.isTrump(winRep, trumpSuit: ts, trumpRank: tr) {
                        let trickCards = state.currentTrick.plays.flatMap { $0.cards }
                        let winRankVal = winRep.rank.rawValue
                        for rank in Rank.allCases
                            where rank.rawValue > winRankVal
                               && rank != tr
                               && rank != .smallJoker && rank != .bigJoker {
                            let played  = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
                            let inHand  = hand.filter { $0.suit == suit && $0.rank == rank }.count
                            let inTrick = trickCards.filter { $0.suit == suit && $0.rank == rank }.count
                            if 2 - played - inHand - inTrick > 0 {
                                partnerAtRisk = true
                                break
                            }
                        }
                    }
                }

                let fills = voidFillCards(
                    extra: extra, remaining: remaining,
                    hand: hand,
                    leadSuit: leadSuit,
                    partnerWinning: partnerWinning,
                    enemyWinning: enemyWinning,
                    position: position,
                    state: state,
                    evaluator: evaluator,
                    ts: ts, tr: tr,
                    ctx: ctx,
                    enemySubsequentVoidInLead: enemySubsequentVoidInLead,
                    partnerAtRisk: partnerAtRisk,
                    trickPoints: trickPoints,
                    trickSecure: trickSecureForTeam
                )
                chosen += fills
            }
        }

        if chosen.count < count {
            let ids = Set(chosen.map { $0.id })
            let rest = hand.filter { !ids.contains($0.id) }
            chosen += Array(rest.prefix(count - chosen.count))
        }
        return Array(chosen.prefix(count))
    }

    // MARK: - 绝牌后额外牌策略

    /// 当自己绝了先手花色，需要出 remaining 张额外牌时的决策
    /// - enemySubsequentVoidInLead: 后手中是否有对手也绝了先手花色（需谨慎垫牌）
    private static func voidFillCards(
        extra: [Card],
        remaining: Int,
        hand: [Card],
        leadSuit: Suit?,
        partnerWinning: Bool,
        enemyWinning: Bool,
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext,
        enemySubsequentVoidInLead: Bool = false,
        partnerAtRisk: Bool = false,
        trickPoints: Int = 0,
        trickSecure: Bool = false
    ) -> [Card] {
        guard remaining > 0 else { return [] }

        if let controlMove = bestTrumpControlFill(
            from: extra,
            remaining: remaining,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        ) {
            var result = controlMove
            if result.count < remaining {
                let usedIDs = Set(result.map(\.id))
                let rest = extra.filter { !usedIDs.contains($0.id) }
                result += smartDiscard(
                    from: rest,
                    count: remaining - result.count,
                    enemyWinning: enemyWinning,
                    ts: ts,
                    tr: tr,
                    myTeam: position.team,
                    ctx: ctx
                )
            }
            return Array(result.prefix(remaining))
        }

        if partnerWinning {
            // 队友当前赢，但该花色还有更大的未出牌 → 需用主将吃，不能垫分
            if partnerAtRisk {
                let trumpCards = extra.filter {
                    CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

                if !trumpCards.isEmpty {
                    let chosen: Card
                    if enemySubsequentVoidInLead && trickPoints > 0 {
                        // 后手对手也绝花色且本墩已有分：用最大主抢住，防止被后手截胡拿分。
                        chosen = trumpCards.last!
                    } else if enemySubsequentVoidInLead {
                        let safeTrumps = trumpCards.filter { isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx) }
                        chosen = (safeTrumps.isEmpty ? trumpCards : safeTrumps).first!
                    } else {
                        // 优先将孤张主牌分（10/K/5，不拆对子）垫给队友；无则出最弱主牌
                        var pairMap: [String: [Card]] = [:]
                        for card in trumpCards {
                            pairMap[CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr),
                                    default: []].append(card)
                        }
                        let pairedIDs = Set(pairMap.values.filter { $0.count >= 2 }
                            .flatMap { $0 }.map { $0.id })
                        let pointRanks: Set<Rank> = [.ten, .king, .five]
                        // 孤张主分牌，按分值高→低（10/K 同分则取 K，再取 5）
                        let singletonPointTrump = trumpCards
                            .filter { !pairedIDs.contains($0.id)
                                   && $0.rank != tr
                                   && pointRanks.contains($0.rank) }
                            .sorted { $0.pointValue > $1.pointValue }
                            .first
                        chosen = singletonPointTrump ?? trumpCards.first!
                    }
                    var result = [chosen]
                    if result.count < remaining {
                        let usedIDs = Set(result.map { $0.id })
                        let rest = extra.filter { !usedIDs.contains($0.id) }
                        result += smartDiscard(
                            from: rest, count: remaining - result.count,
                            enemyWinning: false,
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                        )
                    }
                    return Array(result.prefix(remaining))
                }
                // 无主牌可将吃：安全垫牌（不送分）
                return smartDiscard(
                    from: extra, count: remaining,
                    enemyWinning: true,
                    ts: ts, tr: tr, myTeam: position.team, ctx: ctx
                )
            }

            if enemySubsequentVoidInLead {
                // 我方领先，但后手对手也绝了该花色 → 他可能出主将吃本墩
                // 谨慎策略：不加分，出主只用 A 及以上（K 以下容易被对手稍大主牌截走）
                let safePool = extra.filter { card in
                    if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                        return isSafeTrumpFiller(card, ts: ts, tr: tr, ctx: ctx)
                    }
                    return true
                }
                return smartDiscard(
                    from: safePool.isEmpty ? extra : safePool,
                    count: remaining,
                    enemyWinning: true,   // 视同对方可能截胡，避免垫分牌
                    ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx
                )
            }
            return trickSecure
                ? safePartnerCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr, ctx: ctx)
                : smartDiscard(
                    from: extra, count: remaining,
                    enemyWinning: true,
                    ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx
                )
        }

        // 敌方当前赢，且先手花色还有未出的分牌
        if enemyWinning, let leadActualSuit = leadSuit {
            let unplayedPts = ctx.unplayedSuitPoints(suit: leadActualSuit, tr: tr)
            if unplayedPts > 0 {
                let lk = leadActualSuit.rawValue
                let bothEnemiesHave = !ctx.allEnemiesVoid(myTeam: position.team, key: lk)
                    && ctx.voidEnemies(myTeam: position.team, key: lk).count < 2

                // 按牌力从弱到强排好（first = 最弱，last = 最强）
                let trumpCards = extra.filter {
                    CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                }.sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

                if enemySubsequentVoidInLead {
                    // 后手对手也绝花色 → 竞争截胡：优先出王/级牌（最强）
                    // 没有王/级牌则退为安全垫牌，不出小主送分
                    let bigTrumps = trumpCards.filter {
                        $0.rank == .bigJoker || $0.rank == .smallJoker || $0.rank == tr
                    }
                    if let strongest = bigTrumps.last {
                        var result = [strongest]
                        if result.count < remaining {
                            let usedIDs = Set(result.map { $0.id })
                            let rest = extra.filter { !usedIDs.contains($0.id) }
                            result += smartDiscard(
                                from: rest, count: remaining - result.count,
                                enemyWinning: true, ts: ts, tr: tr,
                                myTeam: position.team, ctx: ctx
                            )
                        }
                        return Array(result.prefix(remaining))
                    }
                    // 无王/级牌：安全垫牌（出主只用 A，不出分牌）
                    let safePool = extra.filter { card in
                        if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                            return isSafeTrumpFiller(card, ts: ts, tr: tr, ctx: ctx)
                        }
                        return true
                    }
                    return smartDiscard(
                        from: safePool.isEmpty ? extra : safePool,
                        count: remaining,
                        enemyWinning: true, ts: ts, tr: tr,
                        myTeam: position.team, ctx: ctx
                    )
                }

                if bothEnemiesHave, let smallTrump = trumpCards.first {
                    // 后手对手有该花色：出小主截胡
                    var result = [smallTrump]
                    if result.count < remaining {
                        let usedIDs = Set(result.map { $0.id })
                        let rest = extra.filter { !usedIDs.contains($0.id) }
                        result += smartDiscard(
                            from: rest, count: remaining - result.count,
                            enemyWinning: true, ts: ts, tr: tr,
                            myTeam: position.team, ctx: ctx
                        )
                    }
                    return Array(result.prefix(remaining))
                }
            }
        }

        // 常规智能垫牌
        return smartDiscard(
            from: extra, count: remaining,
            enemyWinning: enemyWinning,
            ts: ts, tr: tr,
            myTeam: position.team, ctx: ctx
        )
    }

    // MARK: - 智能垫牌（利用对手绝牌信息，保留对子，避免垫主牌）

    /// 选出 count 张要垫的牌：
    /// - 优先垫散牌（避免拆对子）
    /// - 非主牌优先于主牌（尽量不垫主）
    /// - 敌方赢时避免垫分牌
    private static func smartDiscard(
        from cards: [Card],
        count: Int,
        enemyWinning: Bool,
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card] {
        guard count > 0, !cards.isEmpty else { return [] }

        // 识别手中的对子组（同一 pairKey 有 ≥2 张）
        var pairGroupMap: [String: [Card]] = [:]
        for card in cards {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: ts, trumpRank: tr), default: []].append(card)
        }
        let pairedIDs: Set<UUID> = Set(
            pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id }
        )

        func isTrump(_ c: Card) -> Bool { CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr) }
        func isPaired(_ c: Card) -> Bool { pairedIDs.contains(c.id) }
        func isEnemyVoid(_ c: Card) -> Bool {
            ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(c, ts: ts, tr: tr))
        }

        // 优先级层次（数字越小越优先垫出）：
        // 0: 非主散牌·敌绝花色   1: 非主散牌·非敌绝
        // 2: 非主配对·敌绝花色   3: 非主配对·非敌绝
        // 4: 主牌散牌             5: 主牌配对（最后才动）
        func tier(_ c: Card) -> Int {
            let t = isTrump(c)
            let p = isPaired(c)
            let v = isEnemyVoid(c)
            switch (t, p, v) {
            case (false, false, true):  return 0
            case (false, false, false): return 1
            case (false, true,  true):  return 2
            case (false, true,  false): return 3
            case (true,  false, _):     return 4
            default:                    return 5   // 主牌配对
            }
        }

        // 散牌按 tier 和分值/rank 排序
        // 队友赢时（!enemyWinning）：同 tier 内高分牌优先（垫分给队友）
        // 敌方赢时（enemyWinning）：同 tier 内低分牌优先（避免送分）
        let singletons = cards
            .filter { !isPaired($0) }
            .sorted { a, b in
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                if a.pointValue != b.pointValue {
                    return enemyWinning ? a.pointValue < b.pointValue : a.pointValue > b.pointValue
                }
                return discardOrder(a, before: b, trumpSuit: ts, trumpRank: tr)
            }

        // 配对组按 tier（取首张代表）排序，同 tier 内分值处理同上
        let pairedGroups = pairGroupMap.values
            .filter { $0.count >= 2 }
            .sorted { a, b in
                let ta = tier(a[0]), tb = tier(b[0])
                if ta != tb { return ta < tb }
                if a[0].pointValue != b[0].pointValue {
                    return enemyWinning ? a[0].pointValue < b[0].pointValue : a[0].pointValue > b[0].pointValue
                }
                return discardOrder(a[0], before: b[0], trumpSuit: ts, trumpRank: tr)
            }

        var result: [Card] = []
        var remaining = count

        // 阶段1：先垫散牌
        for card in singletons {
            if remaining <= 0 { break }
            result.append(card)
            remaining -= 1
        }

        // 阶段2：不得不动对子时，尽量整对垫出；只差1张时取对子中最弱的一张
        for group in pairedGroups {
            if remaining <= 0 { break }
            if remaining >= 2 {
                result.append(contentsOf: Array(group.prefix(2)))
                remaining -= 2
            } else {
                let worst = group.sorted {
                    discardOrder($0, before: $1, trumpSuit: ts, trumpRank: tr)
                }.first!
                result.append(worst)
                remaining -= 1
            }
        }

        return Array(result.prefix(count))
    }

    // MARK: - followTractor / followPair（带 context 版本）

    private static func followTractor(
        leadTractor: TractorInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        ctx: AIContext,
        trickSecure: Bool
    ) -> [Card] {
        let count = leadTractor.pairCount * 2

        if suitCards.count >= count {
            let availableTractors = tractors(in: suitCards, pairCount: leadTractor.pairCount,
                                             trumpSuit: trumpSuit, trumpRank: trumpRank)
            if partnerWinning {
                // 规则：有连对必须出连对；无连对按结构规则选牌（对子 → 散牌）
                if let weakestTractor = availableTractors.sorted(by: {
                    weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }).first {
                    return weakestTractor   // 出最弱连对，保留大牌
                }
                // 无匹配连对：按结构约束选牌，但对子和散牌槽优先出分牌
                return structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: leadTractor.pairCount,
                                                 trumpSuit: trumpSuit, trumpRank: trumpRank,
                                                 partnerWinning: trickSecure)
            }
            if let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beatingTractors = availableTractors
                    .filter { t in
                        guard let info = tractorInfo(of: t, trumpSuit: trumpSuit, trumpRank: trumpRank)
                        else { return false }
                        return CardComparator.beats(info.highCard, winningTractor.highCard,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let t = beatingTractors.first { return t }
            }
            if let weakest = availableTractors.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first { return weakest }
            // 无合适连对：按规则选牌（最大化对子，再填散牌）
            return structuredSuitFollowCards(suitCards: suitCards,
                                             neededPairs: leadTractor.pairCount,
                                             trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        if suitCards.isEmpty,
           !partnerWinning,
           let winningTractor = tractorInfo(of: winningCards, trumpSuit: trumpSuit, trumpRank: trumpRank) {
            let beatingTractors = tractors(in: hand, pairCount: leadTractor.pairCount,
                                           trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { t in
                    guard let info = tractorInfo(of: t, trumpSuit: trumpSuit, trumpRank: trumpRank)
                    else { return false }
                    return CardComparator.beats(info.highCard, winningTractor.highCard,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
            if let t = beatingTractors.first { return t }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest    = hand.filter { !usedIDs.contains($0.id) }
        // 跟连对绝牌时，碎牌主牌无法压连对，不调 voidFillCards（会浪费主牌）
        // 直接智能垫牌
        let extra   = partnerWinning
            ? (trickSecure
               ? safePartnerCards(from: rest, count: count - suitCards.count,
                                  trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
               : smartDiscard(from: rest, count: count - suitCards.count,
                              enemyWinning: true,
                              ts: trumpSuit, tr: trumpRank,
                              myTeam: position.team, ctx: ctx))
            : smartDiscard(from: rest, count: count - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx)
        return suitCards + extra
    }

    private static func followPair(
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        trickPoints: Int,
        ctx: AIContext,
        trickSecure: Bool
    ) -> [Card] {
        let enemyWinning = !partnerWinning

        if suitCards.count >= 2 {
            let availablePairs = pairs(in: suitCards, trumpSuit: trumpSuit, trumpRank: trumpRank)

            if partnerWinning {
                // 规则：有对子必须出对子；无对子才可随意选两张
                if let weakestPair = availablePairs.sorted(by: {
                    weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }).first {
                    return weakestPair   // 出最弱对子，保留大牌
                }
                return trickSecure
                    ? partnerSupportCards(from: suitCards, count: 2,
                                          trumpSuit: trumpSuit, trumpRank: trumpRank)
                    : weakestNonPointFirst(from: suitCards, count: 2,
                                           trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            if let winningPair = pairRepresentative(of: winningCards,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank) {
                let beating = availablePairs
                    .filter { p in
                        guard let rep = pairRepresentative(of: p, trumpSuit: trumpSuit,
                                                           trumpRank: trumpRank) else { return false }
                        return CardComparator.beats(rep, winningPair,
                                                    trumpSuit: trumpSuit, trumpRank: trumpRank)
                    }
                    .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let p = beating.first { return p }
            }
            if let weakest = availablePairs.sorted(by: {
                weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).first { return weakest }
            return weakestCards(from: suitCards, count: 2,
                                trumpSuit: trumpSuit, trumpRank: trumpRank)
        }

        // ── 绝牌（无同花色）路径 ─────────────────────────────────────

        // 尝试用全手牌中的对子压赢者
        if suitCards.isEmpty, enemyWinning {
            let winRep = maxCard(in: winningCards, ts: trumpSuit, tr: trumpRank)
            let canBeatPairs = pairs(in: hand, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .filter { p in
                    guard let rep = pairRepresentative(of: p, trumpSuit: trumpSuit,
                                                       trumpRank: trumpRank) else { return false }
                    return CardComparator.beats(rep, winRep,
                                               trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                .sorted { weakerPair($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }

            // 对方大 + 本墩有分：只要有能赢的对子就出
            if let p = canBeatPairs.first, trickPoints > 0 {
                return p
            }
        }

        let usedIDs = Set(suitCards.map { $0.id })
        let rest    = hand.filter { !usedIDs.contains($0.id) }
        // 跟对子绝牌时，单张主牌无法压对子，不调 voidFillCards（会浪费主牌）
        // 直接智能垫牌：对方赢时避免垫分，队友赢时加分
        let extra   = partnerWinning
            ? (trickSecure
               ? safePartnerCards(from: rest, count: 2 - suitCards.count,
                                  trumpSuit: trumpSuit, trumpRank: trumpRank, ctx: ctx)
               : smartDiscard(from: rest, count: 2 - suitCards.count,
                              enemyWinning: true,
                              ts: trumpSuit, tr: trumpRank,
                              myTeam: position.team, ctx: ctx))
            : smartDiscard(from: rest, count: 2 - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx)
        return suitCards + extra
    }

    // MARK: - 候选动作评分

    private static func deduplicatedMoves(_ moves: [AIMove]) -> [AIMove] {
        var seen = Set<String>()
        var result: [AIMove] = []
        for move in moves where !move.cards.isEmpty {
            let key = move.cards.map { $0.id.uuidString }.sorted().joined(separator: "|")
            if seen.insert(key).inserted {
                result.append(move)
            }
        }
        return result
    }

    /// Lead planning priority before heuristic scoring:
    /// safe slam -> absolute side winners -> tractors -> strong pairs
    /// -> normal pairs -> long-suit/strategic plans -> trump transfer -> weak cards.
    private static func leadPlanPriority(
        _ move: AIMove,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Int {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        if move.kind == .slam {
            return containsTractorComponent(move.cards, ts: ts, tr: tr) ? 0 : 1
        }
        if isAbsoluteSideWinnerLead(move.cards, hand: hand, ts: ts, tr: tr, ctx: ctx) { return 2 }
        if isTractorLead(move.cards, ts: ts, tr: tr) { return 3 }
        if isStrongPairLead(move.cards, ts: ts, tr: tr) { return 4 }
        if isPairFirstLead(move.cards, ts: ts, tr: tr) { return 5 }
        if move.kind == .trumpTransfer { return 7 }
        if move.kind == .weak { return 8 }
        return 6
    }

    private static func findPartnerDumpLeadCandidates(
        in hand: [Card],
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> [AIMove] {
        guard let partner = PlayerPosition.allCases.first(where: { $0.team == position.team && $0 != position })
        else { return [] }

        var moves: [AIMove] = []
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        for suit in Suit.allCases where ctx.isVoid(partner, key: suit.rawValue) {
            guard ctx.unplayedSuitPoints(suit: suit, tr: tr) > 0 else { continue }
            let suitCards = sideCards.filter { $0.suit == suit }
            guard !suitCards.isEmpty else { continue }

            if let pair = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
                .max(by: { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }) {
                moves.append(AIMove(cards: pair, kind: .partnerDump))
            }
            if let strongest = suitCards.max(by: {
                CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
            }) {
                moves.append(AIMove(cards: [strongest], kind: .partnerDump))
            }
        }
        return moves
    }

    private static func findAbsoluteSideWinnerLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        let pairedIDs = pairedCardIDs(in: sideCards, trumpSuit: ts, trumpRank: tr)
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards where ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) {
            guard let suit = card.suit else { continue }
            if ctx.allEnemiesVoid(myTeam: myTeam, key: suit.rawValue) { continue }
            bySuit[suit, default: []].append(card)
        }

        var moves: [AIMove] = []

        // 1) Side-suit A singletons: time-sensitive winners that decay as opponents become void.
        for ace in sideCards
            where ace.rank == .ace
                && !pairedIDs.contains(ace.id)
                && !ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(ace, ts: ts, tr: tr)) {
            moves.append(AIMove(cards: [ace], kind: .bigSingle))
        }

        // 2) Known highest side-suit pairs. Pair "highest" uses pair-specific knowledge:
        // opponents cannot form any higher pair, even if a higher single may remain.
        for pair in pairs(in: sideCards, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  !ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)),
                  isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr) else { continue }
            moves.append(AIMove(cards: pair, kind: .bigPair))
        }

        // 3) Known highest side-suit singletons, excluding paired cards so normal pair assets stay intact.
        for cards in bySuit.values {
            let singletons = cards.filter { !pairedIDs.contains($0.id) }
            if let single = singletons.max(by: {
                CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr)
            }) {
                moves.append(AIMove(cards: [single], kind: .bigSingle))
            }
        }

        return moves
    }

    private static func findTractorLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        var moves: [AIMove] = []
        for logicalSuit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter {
                CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == logicalSuit
            }
            guard !suitCards.isEmpty else { continue }
            if let suit = logicalSuit,
               ctx.allEnemiesVoid(myTeam: myTeam, key: suit.rawValue) {
                continue
            }

            let pairCount = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
            guard pairCount >= 2 else { continue }
            for count in 2...pairCount {
                moves += tractors(in: suitCards, pairCount: count, trumpSuit: ts, trumpRank: tr)
                    .map { AIMove(cards: $0, kind: .tractor) }
            }
        }
        return moves
    }

    /// Pair First：所有对子都作为先手候选参与排序与模拟。
    /// 即使对子本身不大，也比同花色散牌更有牌型价值。
    private static func findPairFirstLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [AIMove] {
        var moves: [AIMove] = []
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            if !CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
               ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)) {
                continue
            }
            moves.append(AIMove(cards: pair, kind: .bigPair))
        }
        return moves
    }

    private static func findNoTrumpControlLeadCandidates(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [AIMove] {
        guard trumpSuit == nil,
              hand.contains(where: { $0.rank == .smallJoker || $0.rank == .bigJoker })
                || pairs(in: hand, trumpSuit: nil, trumpRank: trumpRank).contains(where: {
                    pairRepresentative(of: $0, trumpSuit: nil, trumpRank: trumpRank) != nil
                }) else { return [] }

        var moves: [AIMove] = []
        moves += tractors(in: hand, pairCount: 2, trumpSuit: nil, trumpRank: trumpRank)
            .map { AIMove(cards: $0, kind: .tractor) }

        let controlPairs = pairs(in: hand, trumpSuit: nil, trumpRank: trumpRank)
            .filter {
                guard let rep = pairRepresentative(of: $0, trumpSuit: nil, trumpRank: trumpRank) else { return false }
                return rep.rank == trumpRank || rep.rank == .smallJoker || rep.rank == .bigJoker || rep.rank == .ace
            }
        moves += controlPairs.map { AIMove(cards: $0, kind: .bigPair) }
        return moves
    }

    private static func findTrumpLeadCandidates(
        in hand: [Card],
        position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> [AIMove] {
        let trumpCards = hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        guard !trumpCards.isEmpty else { return [] }

        var moves: [AIMove] = []
        if let weakTrump = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                              trumpSuit: ts, trumpRank: tr).first {
            moves.append(AIMove(cards: [weakTrump], kind: .trump))
        }
        if state.dealerTeamIdx == position.team || trumpCards.count >= 6 {
            if let stronger = trumpCards.sorted(by: {
                CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr)
                    > CardComparator.trumpWeight($1, trumpSuit: ts, trumpRank: tr)
            }).first(where: { isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx, hand: hand) }) {
                moves.append(AIMove(cards: [stronger], kind: .trump))
            }
        }
        if let pair = findWeakestTrumpPair(in: hand, nonPointFirst: true, trumpSuit: ts, trumpRank: tr) {
            moves.append(AIMove(cards: pair, kind: .trump))
        }
        return moves
    }

    /// 小主过渡（Controlled Trump Transfer）：
    /// 无更好先手时，领出一张低成本、不拆主牌结构的小主，尝试把出牌权过渡给队友或我方强主，
    /// 而非随手领一张无控制力的小副牌，把出牌权随机送给对手。
    /// 仅在主牌充足（≥ `trumpTransferMinTrumpCount`）时生成候选。
    private static func findTrumpTransferLeadCandidates(in hand: [Card], ts: Suit?, tr: Rank) -> [AIMove] {
        guard trumpCards(in: hand, ts: ts, tr: tr).count >= trumpTransferMinTrumpCount else { return [] }
        // 最弱的无分、不拆对子的小主单张；排除大主（王 / 级牌 / 主A 等关键主牌）
        guard let small = leadableSingletons(from: hand, isTrump: true, pointOnly: false,
                                             trumpSuit: ts, trumpRank: tr)
            .first(where: { !isBigTrump($0, ts: ts, tr: tr) }) else { return [] }
        // 二次确认不破坏主对子 / 主拖拉机结构
        guard structureBreakPenalty(cards: [small], hand: hand, ts: ts, tr: tr) == 0 else { return [] }
        return [AIMove(cards: [small], kind: .trumpTransfer)]
    }

    private static func findWeakLeadCandidates(in hand: [Card], ts: Suit?, tr: Rank) -> [AIMove] {
        var moves: [AIMove] = []
        if let sideWeak = leadableSingletons(from: hand, isTrump: false, pointOnly: false,
                                             trumpSuit: ts, trumpRank: tr).first {
            moves.append(AIMove(cards: [sideWeak], kind: .weak))
        }
        moves.append(AIMove(cards: weakestCards(from: hand, count: 1, trumpSuit: ts, trumpRank: tr), kind: .weak))
        return moves
    }

    // MARK: - 统一先手评估（六大战略概念，安全门控 + 加权融合）
    //
    // 取代旧版 ~20 个互相冲突的零散加减分。每个概念只有一个权威评估函数，
    // 权重直接读出优先级。详见各 leadXxx 概念函数。

    /// 先手六大概念的权重（数值越大优先级越高）。
    private enum LeadWeight {
        static let security        = 55.0   // 1. Trick Security：能否真正拿下本墩
        static let pointProtection = 40.0   // 6. Point Protection：团队拿分 / 不廉价送分送权（安全门控）
        static let control         = 45.0   // 2. Control Asset Preservation：消耗控制资源的代价
        static let structure       = 60.0   // 3. Structure Integrity：把对子/连对/甩牌当整体
        static let decay           = 25.0   // 4. Asset Decay：及时兑现会贬值的资产
        static let initiative      = 20.0   // 5. Initiative Value：赢墩后是否带来有用出牌权
    }

    private static func scoreLead(
        _ move: AIMove,
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let cards = move.cards
        guard let first = cards.first else { return -.infinity }
        let leadSuit = CardComparator.logicalSuit(first, trumpSuit: ts, trumpRank: tr)
        let isSlam = move.kind == .slam

        // 1. Trick Security ── 我方能否真正拿下这一墩（而非仅暂时领先）
        let security = leadWinProbability(cards, hand: hand, ts: ts, tr: tr, ctx: ctx)
        var score = security * LeadWeight.security

        // 6. Point Protection ── 团队拿分（引出队友垫分等）减去廉价送分/送权的风险
        score += leadPointConcept(cards, leadSuit: leadSuit, position: position,
                                  ts: ts, tr: tr, ctx: ctx, security: security)
            * LeadWeight.pointProtection

        // 2. Control Asset Preservation ── 本手消耗的控制资源价值（王/级牌/主控/旁门A/大牌）
        score -= controlSpendCost(cards, ts: ts, tr: tr, ctx: ctx) * LeadWeight.control

        // 3. Structure Integrity ── 拆散更大结构的代价（AKK 当一组，AAKK 当一拖拉机）；
        //    甩牌已验证为更高价值牌型，豁免结构拆罚。整出强结构则给正向控制价值。
        let fragmentation = isSlam
            ? mixedSlamFragmentationCost(
                cards: cards, hand: hand, position: position, ts: ts, tr: tr, ctx: ctx
            ) * 0.35
            : structureFragmentationCost(cards, hand: hand, ts: ts, tr: tr)
                + mixedSlamFragmentationCost(cards: cards, hand: hand, position: position, ts: ts, tr: tr, ctx: ctx)
        score -= fragmentation * LeadWeight.structure
        score += wholeStructureControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * LeadWeight.structure
        if isSlam {
            score += mixedSlamControlValue(cards, hand: hand, ts: ts, tr: tr, ctx: ctx) * LeadWeight.structure
        }

        // 4. Asset Decay ── 趁旁门 A / 旁门最大单张还能干净赢墩时及时兑现
        score += assetDecayRealization(cards, leadSuit: leadSuit, position: position,
                                       ts: ts, tr: tr, ctx: ctx) * LeadWeight.decay

        // 5. Initiative Value ── 能拿下且手上有可续手的资产时，保住出牌权才有价值
        score += leadInitiativeValue(hand: hand, position: position, state: state,
                                     ctx: ctx, security: security) * LeadWeight.initiative

        if isSlam { score += slamLeadValue(cards, ts: ts, tr: tr) }
        return score
    }

    // ── 概念 6：Point Protection（带符号：团队拿分为正，送分/送权为负）──
    private static func leadPointConcept(
        _ cards: [Card], leadSuit: Suit?, position: PlayerPosition,
        ts: Suit?, tr: Rank, ctx: AIContext, security: Double
    ) -> Double {
        var v = 0.0
        if let suit = leadSuit {
            v += partnerDumpValue(suit: suit, position: position, tr: tr, ctx: ctx) * 1.5   // 引出队友垫分
            v -= riskOfBeingRuffed(suit: suit, cards: cards, position: position, ctx: ctx)   // 被将吃送分送权
        }
        let pts = cards.reduce(0) { $0 + $1.pointValue }
        if pts > 0 { v -= Double(pts) / 10.0 * (1.0 - security) * 1.2 }   // 拿不稳的分牌不要乱送
        return v
    }

    // ── 概念 2：Control Asset Preservation（消耗的控制资源，越高越不该出）──
    private static func controlSpendCost(_ cards: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        var cost = 0.0
        for c in cards {
            if CardComparator.isTrump(c, trumpSuit: ts, trumpRank: tr) {
                if c.rank == .bigJoker || c.rank == .smallJoker { cost += 1.0 }
                else if c.rank == tr { cost += 0.8 }
                else if isBigTrump(c, ts: ts, tr: tr) { cost += 0.7 }   // 主花色 A
                else { cost += 0.15 }
            } else if c.rank == .ace {
                cost += 0.5
            } else if ctx.isEffectivelyBiggest(c, ts: ts, tr: tr) {
                cost += 0.35
            }
        }
        return cost
    }

    // ── 概念 3：Structure Integrity（统一的拆结构代价，取代 5 个旧拆罚函数）──
    private static func structureFragmentationCost(_ cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let sel = Set(cards.map(\.id))
        var cost = 0.0
        // 拆对子：按对子价值分级
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { sel.contains($0.id) }.count
            guard used == 1, let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            cost += pairAssetWeight(rep, ts: ts, tr: tr)
        }
        // 拆连对：额外代价，体现「AAKK 作为一个拖拉机」
        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { sel.contains($0.id) }.count
                if used > 0 && used < tractor.count { cost += 1.2 }
            }
        }
        return cost
    }

    /// 混合甩牌（如 AAK = 对子 + 单张）也是结构资产。
    /// 若只打出安全混合甩牌的一部分（例如从 AAK 中先出 AA），这里统一按结构碎片化扣分。
    private static func mixedSlamFragmentationCost(
        cards: [Card],
        hand: [Card],
        position: PlayerPosition,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        let selected = Set(cards.map(\.id))
        var cost = 0.0
        for slam in findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: position.team, ctx: ctx) {
            guard isMixedStructureSlam(slam, ts: ts, tr: tr) else { continue }
            let slamIDs = Set(slam.map(\.id))
            guard selected != slamIDs else { continue }
            let overlap = selected.intersection(slamIDs).count
            guard overlap > 0 && overlap < slam.count else { continue }

            let structureValue = max(
                mixedSlamControlValue(slam, hand: hand, ts: ts, tr: tr, ctx: ctx),
                0.8
            )
            let fractionUsed = Double(overlap) / Double(slam.count)
            cost = max(cost, structureValue * (0.55 + fractionUsed * 0.45))
        }
        return cost
    }

    /// 对子资产分级（统一口径：强对/分对/普通对）。
    private static func pairAssetWeight(_ rep: Card, ts: Suit?, tr: Rank) -> Double {
        if rep.rank == .bigJoker || rep.rank == .smallJoker || rep.rank == tr || rep.rank == .ace { return 1.0 }
        if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) { return 0.9 }   // 主牌强对子
        if rep.rank == .king || rep.rank == .ten { return 0.7 }
        if rep.pointValue > 0 { return 0.6 }
        return 0.4
    }

    /// 整出完整结构（连对/对子）的正向控制价值；无主局更高。
    /// 关键：只有「绝对赢」的结构才算真正的控制——非绝对赢的对子/连对会被对手压住，
    /// 故大幅打折，避免 AI 先领一个非绝对赢的对子（再去出 A）这种浪费控制权的下法。
    private static func wholeStructureControlValue(
        _ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext
    ) -> Double {
        let dominant = leadStructureDominant(cards, hand: hand, ts: ts, tr: tr, ctx: ctx)
        if tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) != nil {
            let base = ts == nil ? 1.6 : 1.0
            return dominant ? base : base * 0.35
        }
        if isPairMove(cards, ts: ts, tr: tr),
           let rep = pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) {
            let base = pairAssetWeight(rep, ts: ts, tr: tr)
            let value = ts == nil ? base * 1.2 : base * 0.7
            return dominant ? value : value * 0.3
        }
        return 0
    }

    /// 完整混合甩牌的结构控制价值。AAK 这类“对子 + 最大单张”不应被当作普通 slam 小加分，
    /// 而应和对子/连对一样作为完整结构参与 Structure Integrity。
    private static func mixedSlamControlValue(_ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        guard isMixedStructureSlam(cards, ts: ts, tr: tr) else { return 0 }

        let pairedIDs = pairedCardIDs(in: cards, trumpSuit: ts, trumpRank: tr)
        let pairValue = pairs(in: cards, trumpSuit: ts, trumpRank: tr)
            .compactMap { pairRepresentative(of: $0, trumpSuit: ts, trumpRank: tr) }
            .reduce(0.0) { $0 + pairAssetWeight($1, ts: ts, tr: tr) }
        let tractorValue = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr)
            .map { Double($0.pairCount) * 0.8 } ?? 0
        let topSingleValue = cards
            .filter { !pairedIDs.contains($0.id) }
            .reduce(0.0) { partial, card in
                if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                    return partial + (isBigTrump(card, ts: ts, tr: tr) ? 0.45 : 0.2)
                }
                return partial + ((card.rank == .ace || ctx.isEffectivelyBiggest(card, ts: ts, tr: tr)) ? 0.35 : 0.1)
            }

        let noTrumpBoost = ts == nil ? 0.25 : 0
        return min(2.2, 0.35 + pairValue + tractorValue + topSingleValue + noTrumpBoost)
    }

    private static func isMixedStructureSlam(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard cards.count >= 3,
              tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) == nil,
              !isPairMove(cards, ts: ts, tr: tr) else { return false }
        let pairSlots = pairs(in: cards, trumpSuit: ts, trumpRank: tr).count
        guard pairSlots > 0 else { return false }
        return pairSlots * 2 < cards.count
    }

    /// 该结构（对子/连对/单张）当前是否「绝对赢」：
    /// 副牌用对子级别的最大判定（`isEffectivelyBiggestPair`，KK 在一张 A 已现时也算最大对）；
    /// 主牌则要求大主或牌力 ≥ K。
    private static func leadStructureDominant(
        _ cards: [Card], hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext
    ) -> Bool {
        guard let top = cards.max(by: { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }) else {
            return false
        }
        if CardComparator.isTrump(top, trumpSuit: ts, trumpRank: tr) {
            return isBigTrump(top, ts: ts, tr: tr)
                || CardComparator.trumpWeight(top, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue
        }
        return isEffectivelyBiggestPair(top, hand: hand, ctx: ctx, ts: ts, tr: tr)
    }

    // ── 概念 4：Asset Decay（旁门最高控制牌趁能干净赢墩时兑现）──
    private static func assetDecayRealization(
        _ cards: [Card], leadSuit: Suit?, position: PlayerPosition,
        ts: Suit?, tr: Rank, ctx: AIContext
    ) -> Double {
        guard let suit = leadSuit else { return 0 }   // 主牌不计衰减
        let isTopController = cards.allSatisfy {
            $0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr)
        }
        guard isTopController else { return 0 }
        // 敌方尚未绝该花色时，A 还能干净赢 → 趁早兑现；已全绝则会被将吃（风险另计），兑现价值低
        return ctx.allEnemiesVoid(myTeam: position.team, key: suit.rawValue) ? 0.2 : 0.9
    }

    // ── 概念 5：Initiative Value（能赢且有可续手资产时，保住出牌权才有意义）──
    private static func leadInitiativeValue(
        hand: [Card], position: PlayerPosition, state: GameState, ctx: AIContext, security: Double
    ) -> Double {
        guard security >= 0.55 else { return 0 }
        return min(initiativeNeed(position: position, hand: hand, state: state, ctx: ctx) / 220.0, 1.0)
    }

    private static func slamLeadValue(_ cards: [Card], ts: Suit?, tr: Rank) -> Double {
        var v = 18.0
        if containsTractorComponent(cards, ts: ts, tr: tr) { v += 60 }
        return v
    }

    /// 小主过渡的加分：基础分 + 我方有强主 / 主牌富余时更值得过渡。
    /// 数值刻意低于「清门副牌（clearBenefit）」与强对子/大牌等高价值先手，
    /// 但高于无控制力的小副牌，从而把低价值兜底顺序排为：清门 → 小主过渡 → 最弱副牌。
    private static func filterAllowedLeadMoves(
        _ moves: [AIMove],
        position: PlayerPosition,
        hand: [Card],
        state: GameState
    ) -> [AIMove] {
        let allowed = moves.filter {
            allowTrumpLead(state: state, position: position, hand: hand, move: $0)
        }
        if !allowed.isEmpty { return allowed }

        let nonTrump = moves.filter {
            !isTrumpLead($0, ts: state.trumpSuit, tr: state.trumpRank)
        }
        return nonTrump.isEmpty ? moves : nonTrump
    }

    private static func allowTrumpLead(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard isTrumpLead(move, ts: ts, tr: tr) else { return true }
        if ts == nil,
           (isStrongNoTrumpPair(move.cards, trumpRank: tr)
                || tractorInfo(of: move.cards, trumpSuit: ts, trumpRank: tr) != nil) {
            return true
        }

        // 小主过渡：主牌充足时允许领出低成本小主以保住出牌权
        if move.kind == .trumpTransfer,
           trumpCards(in: hand, ts: ts, tr: tr).count >= trumpTransferMinTrumpCount {
            return true
        }

        let remaining = remainingTricks(for: hand)
        if remaining <= 5 { return true }

        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        if trumpCount >= 8 { return true }
        if strongTrumpCount(in: hand, ts: ts, tr: tr) >= 4 { return true }
        if sideCardsRemaining(in: hand, ts: ts, tr: tr) <= trumpCount { return true }
        if exposedPointCardsToProtect(in: hand, ts: ts, tr: tr) >= 25 { return true }
        if sidePairProtectionValue(position: position, hand: hand, state: state, ctx: AIContext.build(state: state, ts: ts, tr: tr)) >= 45 {
            return true
        }
        if state.dealerTeamIdx == position.team && trumpCount >= 6 { return true }

        return false
    }

    private static func generateFollowCandidates(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let partnerWinning = currentWinner.team == position.team
        let winningCards = state.currentTrick.plays.first { $0.position == currentWinner }?.cards ?? leadCards
        let trickSecureForTeam = isTrickSecureForTeam(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        var moves: [AIMove] = []
        if suitCards.count >= count {
            moves.append(AIMove(cards: weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr),
                                kind: partnerWinning ? .followSupport : .followDiscard))
            if partnerWinning && trickSecureForTeam {
                moves.append(AIMove(cards: partnerSupportCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr),
                                    kind: .followSupport))
            }

            if count == 1 {
                let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
                let beating = suitCards
                    .filter { CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr) }
                    .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                if let weakestWin = beating.first {
                    moves.append(AIMove(cards: [weakestWin], kind: .followWin))
                }
                if leadSuit == nil, let secureWin = beating.first(where: {
                    isSecureWinningTrumpFollow(
                        [$0],
                        position: position,
                        hand: hand,
                        state: state,
                        evaluator: evaluator,
                        ctx: ctx
                    )
                }) {
                    moves.append(AIMove(cards: [secureWin], kind: .followWin))
                }
                if !partnerWinning, !ctx.isLastPlayer, let safeWin = beating.first(where: {
                    isSafeTrumpFiller($0, ts: ts, tr: tr, ctx: ctx, hand: hand)
                }) {
                    moves.append(AIMove(cards: [safeWin], kind: .followWin))
                }
            } else if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                moves += tractors(in: suitCards, pairCount: leadTractor.pairCount, trumpSuit: ts, trumpRank: tr)
                    .map { AIMove(cards: $0, kind: .followWin) }
            } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
                moves += pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
                    .map { AIMove(cards: $0, kind: .followWin) }
            }
        } else {
            let usedIDs = Set(suitCards.map { $0.id })
            let extra = hand.filter { !usedIDs.contains($0.id) }
            let remaining = count - suitCards.count
            moves.append(AIMove(
                cards: suitCards + smartDiscard(from: extra, count: remaining,
                                                enemyWinning: !partnerWinning,
                                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx),
                kind: partnerWinning ? .followSupport : .followDiscard
            ))
            if partnerWinning && trickSecureForTeam {
                moves.append(AIMove(cards: suitCards + safePartnerCards(from: extra, count: remaining,
                                                                        trumpSuit: ts, trumpRank: tr, ctx: ctx),
                                    kind: .followSupport))
            }
            if suitCards.isEmpty {
                let winningRep = maxCard(in: winningCards, ts: ts, tr: tr)
                let beatingSingles = extra
                    .filter { CardComparator.beats($0, winningRep, trumpSuit: ts, trumpRank: tr) }
                    .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                if count == 1, let win = beatingSingles.first {
                    moves.append(AIMove(cards: [win], kind: .followWin))
                }
                if count == 2, let leadPair = pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                    let beatingPairs = pairs(in: extra, trumpSuit: ts, trumpRank: tr).filter {
                        guard let rep = pairRepresentative(of: $0, trumpSuit: ts, trumpRank: tr) else { return false }
                        return CardComparator.beats(rep, leadPair, trumpSuit: ts, trumpRank: tr)
                    }
                    moves += beatingPairs.map { AIMove(cards: $0, kind: .followWin) }
                }
            }
        }
        return moves
    }

    /// 统一生成所有“可能花主牌控墩”的跟牌候选。
    /// 覆盖：跟主、绝门将吃、盖吃对手将牌、队友未稳时接管、为续手计划抢回出牌权。
    private static func generateTrumpControlCandidates(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let winningCards = state.currentTrick.plays.first { $0.position == currentWinner }?.cards ?? leadCards

        var moves: [AIMove] = []

        func add(_ cards: [Card]) {
            guard cards.count == count,
                  cards.contains(where: { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }),
                  evaluator.isValidPlay(selected: cards, hand: hand, leadCards: leadCards) else { return }
            moves.append(AIMove(cards: cards, kind: .followWin))
        }

        if suitCards.count >= count {
            guard leadSuit == nil else { return [] }
            if count == 1 {
                let trumps = suitCards
                    .filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
                    .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
                for card in trumps { add([card]) }
            } else if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                for tractor in tractors(in: suitCards, pairCount: leadTractor.pairCount, trumpSuit: ts, trumpRank: tr) {
                    add(tractor)
                }
            } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
                for pair in pairs(in: suitCards, trumpSuit: ts, trumpRank: tr) {
                    add(pair)
                }
            }
            return moves
        }

        let usedIDs = Set(suitCards.map(\.id))
        let extra = hand.filter { !usedIDs.contains($0.id) }
        let trumpPool = extra
            .filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }

        guard !trumpPool.isEmpty else { return [] }

        // 部分有牌时，规则上必须先贡献同花色；补主通常只是填牌，只有模型评估为有意义才会留下。
        func withRequiredSuit(_ cards: [Card]) -> [Card] {
            suitCards + cards
        }

        if count == 1 {
            for card in trumpPool { add([card]) }
        } else if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
            for tractor in tractors(in: trumpPool, pairCount: leadTractor.pairCount, trumpSuit: ts, trumpRank: tr) {
                add(withRequiredSuit(tractor))
            }
        } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
            for pair in pairs(in: trumpPool, trumpSuit: ts, trumpRank: tr) {
                add(withRequiredSuit(pair))
            }
        } else if let slam = evaluator.slamInfo(of: leadCards),
                  suitCards.isEmpty,
                  let trumpCombo = buildMatchingSlamTrump(
                    slam: slam,
                    trumpCards: trumpPool,
                    winningCards: winningCards,
                    ts: ts,
                    tr: tr
                  ) {
            add(trumpCombo)
        } else {
            for card in trumpPool where suitCards.count + 1 <= count {
                let remaining = count - suitCards.count - 1
                let rest = extra.filter { $0.id != card.id }
                let fill = smartDiscard(
                    from: rest,
                    count: remaining,
                    enemyWinning: currentWinner.team != position.team,
                    ts: ts,
                    tr: tr,
                    myTeam: position.team,
                    ctx: ctx
                )
                add(withRequiredSuit([card] + fill))
            }
        }

        return moves
    }

    private static func findRuffWinningMoves(
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        guard let leadCards = state.currentTrick.leadCards else { return [] }
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }
        guard suitCards.isEmpty else { return [] }

        let currentWinner = evaluator.winner(of: state.currentTrick)
        guard currentWinner.team != position.team else { return [] }

        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints >= 10 else { return [] }

        let count = leadCards.count
        let winningCards = state.currentTrick.plays.first { $0.position == currentWinner }?.cards ?? leadCards
        let trumpCards = hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        var moves: [AIMove] = []

        if count == 1 {
            moves += trumpCards.map { AIMove(cards: [$0], kind: .followWin) }
        } else if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
            moves += tractors(in: trumpCards, pairCount: leadTractor.pairCount, trumpSuit: ts, trumpRank: tr)
                .map { AIMove(cards: $0, kind: .followWin) }
        } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
            moves += pairs(in: trumpCards, trumpSuit: ts, trumpRank: tr)
                .map { AIMove(cards: $0, kind: .followWin) }
        } else if let slam = evaluator.slamInfo(of: leadCards),
                  let trumpCombo = buildMatchingSlamTrump(
                    slam: slam,
                    trumpCards: trumpCards,
                    winningCards: winningCards,
                    ts: ts,
                    tr: tr
                  ) {
            moves.append(AIMove(cards: trumpCombo, kind: .followWin))
        }

        return moves
            .filter { shouldRuffToWin(state: state, position: position, hand: hand, move: $0, evaluator: evaluator) }
            .sorted {
                trumpMoveCost($0.cards, ts: ts, tr: tr)
                    < trumpMoveCost($1.cards, ts: ts, tr: tr)
            }
    }

    private static func filterTrumpControlMoves(
        _ moves: [AIMove],
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let opponentWinning = currentWinner.team != position.team
        let leadIsTrump = evaluator.dominantSuit(of: leadCards) == nil
        let initiative = initiativeNeed(position: position, hand: hand, state: state, ctx: ctx)

        let trumpDecisions: [(move: AIMove, decision: TrumpControlDecision)] = moves.compactMap { move in
            guard let decision = trumpControlDecision(
                move,
                leadCards: leadCards,
                hand: hand,
                position: position,
                state: state,
                evaluator: evaluator,
                ctx: ctx
            ) else { return nil }
            return (move, decision)
        }
        guard !trumpDecisions.isEmpty else { return moves }

        let secure = trumpDecisions.filter { $0.decision.classification == .secureWinner }
        let contest = trumpDecisions.filter {
            $0.decision.classification == .secureWinner
                || $0.decision.classification == .contestingTrump
        }

        func sorted(_ decisions: [(move: AIMove, decision: TrumpControlDecision)]) -> [AIMove] {
            decisions.sorted { $0.decision.score > $1.decision.score }.map(\.move)
        }

        if trickPoints >= 15 {
            if !secure.isEmpty { return sorted(secure) }
            if opponentWinning || leadIsTrump, !contest.isEmpty { return sorted(contest) }
        }

        if trickPoints >= 10 && opponentWinning {
            if !secure.isEmpty { return sorted(secure) }
            if !contest.isEmpty { return sorted(contest) }
        }

        if initiative >= 120 && opponentWinning && !contest.isEmpty {
            return sorted(contest)
        }

        if !opponentWinning && trickPoints >= 10 {
            let helpfulSecure = secure.filter { $0.decision.score > 0 }
            if !helpfulSecure.isEmpty { return moves + sorted(helpfulSecure) }
        }

        return moves
    }

    private static func filterRequiredRuffMoves(
        _ moves: [AIMove],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints >= 10,
              currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator),
              aiIsVoidInLeadSuit(hand: hand, state: state, evaluator: evaluator) else { return moves }

        let winningRuffs = moves.filter {
            shouldRuffToWin(state: state, position: position, hand: hand, move: $0, evaluator: evaluator)
        }
        let secureWinningRuffs = winningRuffs.filter {
            isTrickSecureForTeam(
                position: position,
                hand: hand,
                state: state,
                evaluator: evaluator,
                ctx: ctx,
                candidateCards: $0.cards
            )
        }
        if !secureWinningRuffs.isEmpty { return secureWinningRuffs }
        return winningRuffs.isEmpty ? moves : winningRuffs
    }

    /// 大墩主吊（先手出主、对手领先、当前墩 ≥15 分）时，禁止被动送墩：
    /// 若存在能锁定的 Secure(A) 走法则只留 A；否则保留任何能赢/争墩的 A/B，剔除被动 C。
    private static func filterTrumpPullPointContest(
        _ moves: [AIMove],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        guard let leadCards = state.currentTrick.leadCards,
              evaluator.dominantSuit(of: leadCards) == nil,
              currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator) else { return moves }

        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints >= 15 else { return moves }

        // 优先：能锁定的 Secure winner（A）
        let secureWinners = moves.filter {
            isSecureWinningTrumpFollow(
                $0.cards,
                position: position,
                hand: hand,
                state: state,
                evaluator: evaluator,
                ctx: ctx
            )
        }
        if !secureWinners.isEmpty { return secureWinners }

        // 否则：保留任何能赢/争墩的（A/B），剔除被动 C
        let winning = moves.filter {
            candidateWinsTrick($0.cards, position: position, state: state, evaluator: evaluator)
        }
        return winning.isEmpty ? moves : winning
    }

    private static func filterHighInitiativeWinningMoves(
        _ moves: [AIMove],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        guard currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator) else {
            return moves
        }

        let need = initiativeNeed(position: position, hand: hand, state: state, ctx: ctx)
        guard need >= 100 else { return moves }

        let lowCostWinning = moves.filter {
            guard candidateWinsTrick($0.cards, position: position, state: state, evaluator: evaluator),
                  moveCardCost($0.cards, hand: hand, state: state, ctx: ctx) <= 45,
                  structureBreakPenalty(cards: $0.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank) == 0,
                  !containsBigTrump($0.cards, ts: state.trumpSuit, tr: state.trumpRank) else { return false }

            if $0.cards.contains(where: { CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) }),
               let leadCards = state.currentTrick.leadCards {
                guard let decision = trumpControlDecision(
                    $0,
                    leadCards: leadCards,
                    hand: hand,
                    position: position,
                    state: state,
                    evaluator: evaluator,
                    ctx: ctx
                ) else { return false }
                return decision.classification != .passiveTrump && decision.score > 0
            }
            return true
        }

        return lowCostWinning.isEmpty ? moves : lowCostWinning
    }

    private static func scoreFollow(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let partnerWinningBefore = currentWinner.team == position.team
        let trickPoints = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
        let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
        let candidateWins = candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator)
        let winClass = classifyFollowMove(
            move.cards,
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
        let usesTrump = move.cards.contains {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        let trickSecureBefore = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let trickSecureAfter = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator,
            ctx: ctx, candidateCards: move.cards
        )
        let breakPenalty = structureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr)
        let strongBreakPenalty = strongStructureBreakPenalty(cards: move.cards, hand: hand, ts: ts, tr: tr)
        let clearsSuit = clearsLogicalSuit(cards: move.cards, hand: hand, evaluator: evaluator)

        var score = 0.0

        // ── 统一的「用主控墩」决策（Trump Control）──────────────────────
        // 吊主跟牌 / 绝门将吃 / 盖吃对手将牌 / 帮队友锁定 / 抢回出牌权——
        // 所有「是否花主牌去拿、保、抢这一墩」的判断都走同一个模型，避免各处零散加减分互相冲突。
        // 非主走法才用通用赢墩分类分，避免与模型重复计分。
        if usesTrump {
            score += trumpControlScore(
                move, leadCards: leadCards, hand: hand,
                position: position, state: state, evaluator: evaluator, ctx: ctx
            )
        } else {
            score += followWinClassScore(winClass, trickPoints: trickPoints, playedPoints: playedPoints)
        }

        // ── 通用项（主/非主都适用）：垫分、清门、拆结构 ──────────────────
        if partnerWinningBefore {
            score += trickSecureBefore ? Double(playedPoints) * 4 : -Double(playedPoints) * 8
            score += clearsSuit ? 8 : 0
            if candidateWins && !usesTrump { score -= 30 }   // 非主盖队友：罚（主牌盖队友由模型判断）
            score -= breakPenalty * 18
            score -= strongBreakPenalty * 24
            if playedPoints == 0 { score += 4 }
            if !trickSecureBefore && move.kind == .followSupport {
                score -= trickPoints >= 15 ? 80 : 35
            }
        } else {
            if !usesTrump {
                if candidateWins {
                    if trickSecureAfter {
                        score += 48 + Double(trickPoints + playedPoints) * 4
                    } else {
                        score += 18 + Double(trickPoints) * 1.2 - Double(playedPoints) * 4
                        if trickPoints + playedPoints >= 15 && !ctx.isLastPlayer { score -= 90 }
                    }
                    score += ctx.isLastPlayer ? 10 : 0
                    if trickPoints >= 10 && state.attackScore > 60 { score += ctx.isLastPlayer ? 8 : 18 }
                } else {
                    score -= Double(playedPoints) * 5
                    score += move.cards.allSatisfy { $0.pointValue == 0 } ? 8 : 0
                }
                score += initiativeGainScore(
                    move, hand: hand, position: position, state: state, evaluator: evaluator, ctx: ctx
                )
            }
            score += clearsSuit ? 5 : 0
            score -= breakPenalty * 16
            score -= strongBreakPenalty * 22
        }

        switch move.kind {
        case .followBaseline:
            score += 5
        case .followSupport:
            score += partnerWinningBefore ? 8 : 0
        case .followDiscard:
            score += partnerWinningBefore ? 0 : 4
        case .followWin:
            if !usesTrump { score += candidateWins ? 8 : -12 }   // 主牌赢由模型给分
        default:
            break
        }
        return score
    }

    // MARK: - 统一「用主控墩」决策（Trump Control Decision）

    /// 核心问题：为「拿到 / 保住 / 抢回」这一墩的控制权，值不值得花这张主牌？
    /// 覆盖所有用主跟牌的情形：吊主跟牌、绝门将吃、盖吃对手将牌、帮队友锁定、为抢出牌权而争墩。
    /// 仅在候选用到主牌时返回非零；否则返回 0（非主走法由通用赢墩分类分处理）。
    ///
    /// 决策输入：当前墩分（0/5/10/15 阶梯）、当前赢家（敌/友、是否已稳）、
    /// 拿墩安全分级（A=Secure / B=Contesting / C=Passive）、出牌权价值、主牌成本（高分/高价值时弱化）。
    private static func trumpControlScore(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        trumpControlDecision(
            move,
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )?.score ?? 0
    }

    private static func trumpControlDecision(
        _ move: AIMove,
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> TrumpControlDecision? {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard move.cards.contains(where: { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }) else {
            return nil
        }

        let currentWinner = evaluator.winner(of: state.currentTrick)
        let partnerWinning = currentWinner.team == position.team
        let trickPoints = state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
        let pts = Double(trickPoints)
        let leadIsTrump = evaluator.dominantSuit(of: leadCards) == nil
        // 拿墩安全分级：A=finalWin（终局也能赢）、B=temporaryWin（暂赢、后手或可盖）、C=cannotWin（赢不了）
        let winClass = classifyFollowMove(
            move.cards, position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let secureBefore = isTrickSecureForTeam(
            position: position, hand: hand, state: state, evaluator: evaluator, ctx: ctx
        )
        let cost = trumpControlCost(move.cards, ts: ts, tr: tr)
        // 主牌成本权重：墩分越高越不该让“惜主”主导（高分/高价值时弱化成本）
        let costDamp = trumpCostDamping(trickPoints: trickPoints)
        // 抢回出牌权的价值：赢下后手上还有多少可兑现的资产（旁门A、对子/连对、甩牌、长门…）
        let leadControl = trumpLeadControlValue(move: move, hand: hand, position: position, state: state, ctx: ctx)

        var score = 0.0
        let classification: TrumpControlClass

        if partnerWinning {
            // ── 队友领先 ──
            if secureBefore {
                // 已稳：不要盖队友，也不要白扔主牌
                classification = winClass == .cannotWin ? .passiveTrump : .contestingTrump
                if winClass != .cannotWin { score -= 35 + cost }
            } else if trickPoints > 0 {
                // 未稳且有分：可接管帮忙锁定（规则 D）；不要为无分墩抢队友
                switch winClass {
                case .finalWin:
                    classification = .secureWinner
                    score += 40 + pts * 4 - cost * costDamp
                case .temporaryWin:
                    classification = .contestingTrump
                    score += trickPoints >= 10 ? 12 + pts : -8
                case .cannotWin:
                    classification = .passiveTrump
                    score += 0
                }
            } else {
                classification = winClass == .cannotWin ? .passiveTrump : .contestingTrump
            }
            // 队友领先、无分、未稳：保守为主，交给通用项
        } else {
            // ── 对手领先（含对手已将吃 → 盖吃）──
            switch winClass {
            case .finalWin:                       // A：能锁定终局
                classification = .secureWinner
                score += 40 + pts * 6 - cost * costDamp + leadControl
            case .temporaryWin:                   // B：争墩 / 逼对手出更高主
                classification = .contestingTrump
                let contest: Double
                if trickPoints >= 10 { contest = 50 + pts * 4 }
                else if trickPoints >= 5 { contest = 28 + pts * 3 }
                else { contest = ctx.isLastPlayer ? 6 : -12 }   // 无分/低分争墩意义有限
                score += contest - cost * costDamp + leadControl * 0.6
            case .cannotWin:                      // C：被动主牌（赢不了）
                classification = .passiveTrump
                if leadIsTrump {
                    // 跟主吊：可能只有小主、被迫跟；按墩分阶梯（15+ 由 filterTrumpPullPointContest 直接剔除）
                    score += passiveTrumpPenalty(trickPoints)
                } else {
                    // 绝门却扔个赢不了的主：纯浪费（本可垫副牌）→ 重罚
                    score -= 25 + pts * 5
                }
            }
        }
        return TrumpControlDecision(
            classification: classification,
            score: score,
            leadControlValue: leadControl,
            cost: cost
        )
    }

    /// 主牌成本：王 / 级牌 / 大主最贵，普通主按牌力。拆主对/主连对的成本由通用 structureBreakPenalty 统一处理。
    private static func trumpControlCost(_ cards: [Card], ts: Suit?, tr: Rank) -> Double {
        var cost = 0.0
        for card in cards where CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
            if card.rank == .bigJoker || card.rank == .smallJoker { cost += 14 }
            else if card.rank == tr { cost += 11 }
            else if isBigTrump(card, ts: ts, tr: tr) { cost += 9 }      // 主花色 A
            else { cost += Double(CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)) / 18.0 }
        }
        return cost
    }

    /// 墩分越高，越不让“惜主成本”主导决策。
    private static func trumpCostDamping(trickPoints: Int) -> Double {
        if trickPoints >= 15 { return 0.3 }
        if trickPoints >= 10 { return 0.5 }
        if trickPoints >= 5  { return 0.8 }
        return 1.0
    }

    /// 被动主牌（跟主吊却赢不了）的护分阶梯：0 分可接受；分越多越罚。
    private static func passiveTrumpPenalty(_ trickPoints: Int) -> Double {
        let pts = Double(trickPoints)
        if trickPoints == 0  { return 2 }       // 无分被迫小主：可接受
        if trickPoints < 5   { return -pts * 2 }
        if trickPoints < 10  { return -(18 + pts * 3) }
        if trickPoints < 15  { return -(45 + pts * 4) }
        return -(95 + pts * 6)
    }

    /// 抢回出牌权的价值：赢下本墩后，手上仍可兑现的资产越多，赢这一墩越值。上限 25。
    private static func trumpLeadControlValue(
        move: AIMove, hand: [Card], position: PlayerPosition, state: GameState, ctx: AIContext
    ) -> Double {
        let remaining = handAfterPlaying(move.cards, from: hand)
        return min(initiativeNeed(position: position, hand: remaining, state: state, ctx: ctx) / 12.0, 25.0)
    }

    private static func bestTrumpControlFill(
        from extra: [Card],
        remaining: Int,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card]? {
        guard remaining > 0,
              let leadCards = state.currentTrick.leadCards else { return nil }

        let extraIDs = Set(extra.map(\.id))
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let currentWinner = evaluator.winner(of: state.currentTrick)
        let opponentWinning = currentWinner.team != position.team

        let candidates = generateTrumpControlCandidates(
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )

        let usable = candidates.compactMap { move -> (cards: [Card], decision: TrumpControlDecision)? in
            let fillCards = move.cards.filter { extraIDs.contains($0.id) }
            guard !fillCards.isEmpty, fillCards.count <= remaining,
                  let decision = trumpControlDecision(
                    move,
                    leadCards: leadCards,
                    hand: hand,
                    position: position,
                    state: state,
                    evaluator: evaluator,
                    ctx: ctx
                  ) else { return nil }

            switch decision.classification {
            case .secureWinner:
                if decision.score > 0 || trickPoints >= 10 || decision.leadControlValue >= 12 {
                    return (fillCards, decision)
                }
            case .contestingTrump:
                if opponentWinning && (trickPoints >= 10 || decision.leadControlValue >= 16), decision.score > 0 {
                    return (fillCards, decision)
                }
            case .passiveTrump:
                return nil
            }
            return nil
        }

        return usable.sorted { lhs, rhs in
            if lhs.decision.classification != rhs.decision.classification {
                return lhs.decision.classification == .secureWinner
            }
            return lhs.decision.score > rhs.decision.score
        }.first?.cards
    }

    // MARK: - Monte Carlo 候选重排

    private struct MonteCarloRNG: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func monteCarloBestMove(
        from moves: [AIMove],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        heuristicScore: (AIMove) -> Double
    ) -> AIMove? {
        guard moves.count > 1 else { return moves.first }

        var bestMove: AIMove?
        var bestScore = -Double.infinity

        for (moveIndex, move) in moves.enumerated() {
            var total = 0.0
            for simulation in 0..<monteCarloSimulationCount {
                var rng = MonteCarloRNG(seed: monteCarloSeed(
                    move: move,
                    position: position,
                    state: state,
                    moveIndex: moveIndex,
                    simulation: simulation
                ))
                total += simulateCurrentTrick(
                    candidate: move,
                    position: position,
                    hand: hand,
                    state: state,
                    evaluator: evaluator,
                    rng: &rng
                )
            }

            let average = total / Double(monteCarloSimulationCount)
            let score = average + heuristicScore(move) * 0.03
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
        }

        return bestMove
    }

    private static func monteCarloSeed(
        move: AIMove,
        position: PlayerPosition,
        state: GameState,
        moveIndex: Int,
        simulation: Int
    ) -> UInt64 {
        var seed = UInt64(position.rawValue + 1) &* 0x9E37_79B9
        seed ^= UInt64(state.roundNumber + 1) &* 0x85EB_CA6B
        seed ^= UInt64(state.completedTricks.count + 1) &* 0xC2B2_AE35
        seed ^= UInt64(state.currentTrick.plays.count + 1) &* 0x27D4_EB2F
        seed ^= UInt64(moveIndex + 1) &* 0x1656_67B1
        seed ^= UInt64(simulation + 1) &* 0xD3A2_646C
        for card in move.cards {
            let suitValue = UInt64(card.suit?.rawValue.unicodeScalars.first?.value ?? 0)
            seed ^= UInt64(card.rank.rawValue + 31) &* 0x9E37_79B9
            seed ^= suitValue &* 0x85EB_CA6B
        }
        return seed
    }

    private static func simulateCurrentTrick(
        candidate: AIMove,
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        rng: inout MonteCarloRNG
    ) -> Double {
        var trick = state.currentTrick
        guard !trick.plays.contains(where: { $0.position == position }) else { return -1000 }
        trick.plays.append((position: position, cards: candidate.cards))

        var simulatedHands = sampleHiddenHands(
            currentPosition: position,
            currentHand: hand,
            playedCandidate: candidate.cards,
            state: state,
            rng: &rng
        )

        var next = nextPosition(after: position)
        var safety = 0
        while trick.plays.count < 4 && safety < 4 {
            safety += 1
            if trick.plays.contains(where: { $0.position == next }) {
                next = nextPosition(after: next)
                continue
            }

            let nextHand = simulatedHands[next] ?? []
            let play = monteCarloFollowCards(
                hand: nextHand,
                trick: trick,
                evaluator: evaluator,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                rng: &rng
            )
            guard !play.isEmpty else { return -1000 }
            trick.plays.append((position: next, cards: play))
            let usedIDs = Set(play.map { $0.id })
            simulatedHands[next] = nextHand.filter { !usedIDs.contains($0.id) }
            next = nextPosition(after: next)
        }

        guard trick.plays.count == 4 else { return -1000 }
        let winner = evaluator.winner(of: trick)
        let points = trick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        let myTeamWon = winner.team == position.team
        let ownPoints = candidate.cards.reduce(0) { $0 + $1.pointValue }
        let remainingHand = handAfterPlaying(candidate.cards, from: hand)
        let capturedPoints = myTeamWon ? Double(points) : -Double(points)
        let wonTrickValue = winner == position ? 1.0 : (myTeamWon ? 0.5 : -1.0)
        let simContext = AIContext.build(state: state, ts: state.trumpSuit, tr: state.trumpRank)
        let initiative = initiativeNeed(position: position, hand: remainingHand, state: state, ctx: simContext)
        let assetValue = remainingAssetValue(position: position, hand: remainingHand, state: state, ctx: simContext)
        let earlyTrumpPenalty = usedBigTrumpEarlyPenalty(
            state: state,
            position: position,
            hand: hand,
            move: candidate
        )

        var score = capturedPoints * 2
            + wonTrickValue * 2
            + assetValue
            + (myTeamWon ? initiative * 0.3 : -initiative * 0.25)
            - earlyTrumpPenalty * 3

        if !myTeamWon && ownPoints > 0 { score -= Double(ownPoints) * 0.5 }
        if myTeamWon && candidate.cards.allSatisfy({ $0.pointValue == 0 }) { score += 0.5 }
        // 先手拆强对子：在模拟评估中也明确惩罚，抵消「保留单张大牌」带来的 assetValue 偏好。
        // 仅限先手（本墩尚无人出牌）；甩牌豁免（已验证为更高价值牌型）。跟牌不受此罚影响。
        if candidate.kind != .slam, state.currentTrick.plays.isEmpty {
            score -= strongPairBreakLeadPenalty(
                cards: candidate.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank
            ) * 0.05
            score += tractorFirstLeadBonus(cards: candidate.cards, ts: state.trumpSuit, tr: state.trumpRank) * 0.25
            score -= tractorBreakLeadPenalty(
                cards: candidate.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank
            ) * 0.25
            score += absoluteSideWinnerLeadBonus(
                cards: candidate.cards,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: simContext
            ) * 0.25
            score -= trumpPreservationPenalty(
                move: candidate,
                position: position,
                hand: hand,
                state: state,
                ctx: simContext
            ) * 0.25
            score += pairFirstLeadBonus(cards: candidate.cards, ts: state.trumpSuit, tr: state.trumpRank) * 0.25
            score -= pairFirstSingleLeadPenalty(
                move: candidate,
                cards: candidate.cards,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                clearBenefit: 0,
                partnerDump: 0
            ) * 0.25
        }
        return score
    }

    private static func sampleHiddenHands(
        currentPosition: PlayerPosition,
        currentHand: [Card],
        playedCandidate: [Card],
        state: GameState,
        rng: inout MonteCarloRNG
    ) -> [PlayerPosition: [Card]] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        // 各玩家已暴露的绝门（逻辑花色 key）
        let voids = AIContext.build(state: state, ts: ts, tr: tr).voidSuits
        let others = PlayerPosition.allCases.filter { $0 != currentPosition }

        // 已知牌：自己手牌 + 所有已出的牌（已结算 + 本墩）
        var knownCards = currentHand
        knownCards += state.completedTricks.flatMap { $0.plays.flatMap(\.cards) }
        knownCards += state.currentTrick.plays.flatMap(\.cards)

        // 只有庄家本人埋的底牌、知道其内容；其余玩家不知道，底牌进入未知池
        let knowsKitty = currentPosition == state.dealerPosition
        if knowsKitty {
            knownCards += state.kitty
        }

        var unknownDeck = removeKnownFaces(from: Deck.doubleDeck(), knownCards: knownCards)

        // 非庄家也能推断部分底牌：若其余三家都已绝某逻辑花色，
        // 则该花色所有未知牌只可能在底牌里，不应发给任何对手
        if !knowsKitty {
            let inferredKittyKeys = Set(
                unknownDeck
                    .map { AIContext.suitKey($0, ts: ts, tr: tr) }
                    .filter { key in others.allSatisfy { voids[$0]?.contains(key) ?? false } }
            )
            if !inferredKittyKeys.isEmpty {
                unknownDeck.removeAll {
                    inferredKittyKeys.contains(AIContext.suitKey($0, ts: ts, tr: tr))
                }
            }
        }

        unknownDeck.shuffle(using: &rng)

        var hands: [PlayerPosition: [Card]] = [:]
        let playedIDs = Set(playedCandidate.map(\.id))
        hands[currentPosition] = currentHand.filter { !playedIDs.contains($0.id) }
        for pos in others { hands[pos] = [] }

        var need: [PlayerPosition: Int] = [:]
        for pos in others { need[pos] = state.player(pos).hand.count }

        func isVoidFor(_ pos: PlayerPosition, _ card: Card) -> Bool {
            voids[pos]?.contains(AIContext.suitKey(card, ts: ts, tr: tr)) ?? false
        }

        // 受绝门约束更紧（能接收的对手更少）的牌优先分配，避免后期死局
        let ordered = unknownDeck.sorted { a, b in
            others.filter { p in !isVoidFor(p, a) }.count
                < others.filter { p in !isVoidFor(p, b) }.count
        }

        for card in ordered {
            // 仍需补牌、且不绝该花色的对手
            var eligible = others.filter { (need[$0] ?? 0) > 0 && !isVoidFor($0, card) }
            // 没有满足绝门约束的对手时退化为任何仍需补牌的对手（保证终止）
            if eligible.isEmpty {
                eligible = others.filter { (need[$0] ?? 0) > 0 }
            }
            // 多出的牌（已无人需要）即视为底牌，丢弃即可
            guard let pick = eligible.randomElement(using: &rng) else { continue }
            hands[pick, default: []].append(card)
            need[pick]! -= 1
        }

        return hands
    }

    private static func removeKnownFaces(from deck: [Card], knownCards: [Card]) -> [Card] {
        var remainingKnownCounts: [String: Int] = [:]
        for card in knownCards {
            remainingKnownCounts[faceKey(card), default: 0] += 1
        }

        var result: [Card] = []
        for card in deck {
            let key = faceKey(card)
            if let count = remainingKnownCounts[key], count > 0 {
                remainingKnownCounts[key] = count - 1
            } else {
                result.append(card)
            }
        }
        return result
    }

    private static func faceKey(_ card: Card) -> String {
        "\(card.suit?.rawValue ?? "J")_\(card.rank.rawValue)"
    }

    private static func monteCarloFollowCards(
        hand: [Card],
        trick: Trick,
        evaluator: TrickEvaluator,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        guard let leadCards = trick.leadCards else {
            return randomCards(from: hand, count: 1, rng: &rng)
        }

        let count = leadCards.count
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }

        let selected: [Card]
        if suitCards.count >= count {
            if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                let options = tractors(in: suitCards, pairCount: leadTractor.pairCount,
                                       trumpSuit: ts, trumpRank: tr)
                selected = options.randomElement(using: &rng)
                    ?? structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: leadTractor.pairCount,
                                                 trumpSuit: ts, trumpRank: tr)
            } else if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil {
                let options = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
                selected = options.randomElement(using: &rng)
                    ?? randomCards(from: suitCards, count: count, rng: &rng)
            } else if let slam = evaluator.slamInfo(of: leadCards) {
                selected = monteCarloSlamFollowCards(slam: slam, suitCards: suitCards,
                                                     count: count, ts: ts, tr: tr, rng: &rng)
            } else {
                selected = randomCards(from: suitCards, count: count, rng: &rng)
            }
        } else {
            let suitIDs = Set(suitCards.map(\.id))
            let rest = hand.filter { !suitIDs.contains($0.id) }
            selected = suitCards + randomCards(from: rest, count: count - suitCards.count, rng: &rng)
        }

        if evaluator.isValidPlay(selected: selected, hand: hand, leadCards: leadCards) {
            return selected
        }
        return monteCarloFallbackLegalFollow(hand: hand, leadCards: leadCards,
                                             evaluator: evaluator, ts: ts, tr: tr, rng: &rng)
    }

    private static func monteCarloSlamFollowCards(
        slam: TrickEvaluator.SlamInfo,
        suitCards: [Card],
        count: Int,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        let pairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 } + slam.pairs.count
        let handPairs = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
        let requiredPairs = min(handPairs, pairSlots)
        guard requiredPairs > 0 else {
            return randomCards(from: suitCards, count: count, rng: &rng)
        }

        var selected = structuredSuitFollowCards(suitCards: suitCards,
                                                 neededPairs: requiredPairs,
                                                 trumpSuit: ts,
                                                 trumpRank: tr)
        if selected.count < count {
            let usedIDs = Set(selected.map(\.id))
            let rest = suitCards.filter { !usedIDs.contains($0.id) }
            selected += randomCards(from: rest, count: count - selected.count, rng: &rng)
        }
        return Array(selected.prefix(count))
    }

    private static func monteCarloFallbackLegalFollow(
        hand: [Card],
        leadCards: [Card],
        evaluator: TrickEvaluator,
        ts: Suit?,
        tr: Rank,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        let count = leadCards.count
        var samples: [[Card]] = []
        samples.append(weakestCards(from: hand, count: count, trumpSuit: ts, trumpRank: tr))
        samples.append(randomCards(from: hand, count: count, rng: &rng))

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let suitCards = hand.filter { evaluator.cardSuit($0) == leadSuit }
        if suitCards.count >= count {
            samples.append(weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr))
            if let leadTractor = tractorInfo(of: leadCards, trumpSuit: ts, trumpRank: tr) {
                samples.append(structuredSuitFollowCards(suitCards: suitCards,
                                                        neededPairs: leadTractor.pairCount,
                                                        trumpSuit: ts,
                                                        trumpRank: tr))
            }
            if pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil,
               let pair = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).first {
                samples.append(pair)
            }
        } else {
            let suitIDs = Set(suitCards.map(\.id))
            let rest = hand.filter { !suitIDs.contains($0.id) }
            samples.append(suitCards + weakestCards(from: rest, count: count - suitCards.count,
                                                    trumpSuit: ts, trumpRank: tr))
        }

        return samples.first {
            $0.count == count && evaluator.isValidPlay(selected: $0, hand: hand, leadCards: leadCards)
        } ?? Array(hand.prefix(count))
    }

    private static func randomCards(
        from cards: [Card],
        count: Int,
        rng: inout MonteCarloRNG
    ) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.shuffled(using: &rng).prefix(count))
    }

    private static func nextPosition(after position: PlayerPosition) -> PlayerPosition {
        PlayerPosition(rawValue: (position.rawValue + 1) % 4)!
    }

    private static func currentWinnerIsOpponent(
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        evaluator.winner(of: state.currentTrick).team != position.team
    }

    private static func initiativeNeed(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        let slamCount = findSlamLeadCandidates(
            in: hand,
            ts: ts,
            tr: tr,
            myTeam: position.team,
            ctx: ctx
        ).count
        let tractorCount = tractors(in: sideCards, pairCount: 2, trumpSuit: ts, trumpRank: tr).count
        let pairCount = pairs(in: sideCards, trumpSuit: ts, trumpRank: tr).count
        let sideAceCount = sideCards.filter { $0.rank == .ace }.count
        let safeBigSideCount = countSafeBigSideCards(in: hand, ts: ts, tr: tr, ctx: ctx)
        let pointCardCount = hand.filter { $0.pointValue > 0 }.count
        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count

        var score = 0.0
        score += Double(min(slamCount, 3)) * 40
        score += Double(min(tractorCount, 3)) * 35
        score += Double(min(pairCount, 5)) * 20
        score += Double(min(sideAceCount, 4)) * 15
        score += Double(min(safeBigSideCount, 5)) * 12
        score += Double(pointCardCount) * 8

        if sideCards.count > trumpCount {
            score += 25
        }

        return score
    }

    private static func initiativeGainScore(
        _ move: AIMove,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Double {
        guard currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator),
              candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator) else {
            return 0
        }

        let need = initiativeNeed(position: position, hand: hand, state: state, ctx: ctx)
        var score = need * 0.6 - moveCardCost(move.cards, hand: hand, state: state, ctx: ctx) * 0.8

        if need >= 80 {
            score += 70
        }
        if structureBreakPenalty(cards: move.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank) > 0 {
            score -= 40
        }
        if containsBigTrump(move.cards, ts: state.trumpSuit, tr: state.trumpRank) {
            score -= 50
        }

        return score
    }

    private static func moveCardCost(
        _ cards: [Card],
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        return cards.reduce(Double(cards.count) * 2) { partial, card in
            var cost = partial + Double(card.pointValue) * 0.8
            if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                cost += isBigTrump(card, ts: ts, tr: tr) ? 50 : 14
            } else {
                if card.rank == .ace { cost += 12 }
                if ctx.isEffectivelyBiggest(card, ts: ts, tr: tr) { cost += 10 }
            }
            return cost
        } + structureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 20
            + strongStructureBreakPenalty(cards: cards, hand: hand, ts: ts, tr: tr) * 24
    }

    private static func countSafeBigSideCards(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Int {
        hand.filter {
            !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                && ($0.rank == .ace || ctx.isEffectivelyBiggest($0, ts: ts, tr: tr))
        }.count
    }

    private static func aiIsVoidInLeadSuit(
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        guard let leadCards = state.currentTrick.leadCards else { return false }
        let leadSuit = evaluator.dominantSuit(of: leadCards)
        return hand.allSatisfy { evaluator.cardSuit($0) != leadSuit }
    }

    private static func shouldRuffToWin(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove,
        evaluator: TrickEvaluator
    ) -> Bool {
        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints >= 10,
              currentWinnerIsOpponent(position: position, state: state, evaluator: evaluator),
              aiIsVoidInLeadSuit(hand: hand, state: state, evaluator: evaluator),
              move.cards.allSatisfy({
                  CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
              }) else { return false }
        return candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator)
    }

    private static func trumpMoveCost(_ cards: [Card], ts: Suit?, tr: Rank) -> Double {
        cards.reduce(0.0) { partial, card in
            guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return partial }
            return partial + (isBigTrump(card, ts: ts, tr: tr) ? 3.0 : 1.0)
        }
    }

    private static func isPairMove(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) != nil
    }

    private static func isLevelPair(_ cards: [Card], trumpRank: Rank) -> Bool {
        guard cards.count == 2 else { return false }
        return cards.allSatisfy { $0.rank == trumpRank }
    }

    private static func isJokerPair(_ cards: [Card]) -> Bool {
        guard cards.count == 2 else { return false }
        return cards.allSatisfy { $0.rank == .smallJoker }
            || cards.allSatisfy { $0.rank == .bigJoker }
    }

    private static func hasBigJoker(in hand: [Card]) -> Bool {
        hand.contains { $0.rank == .bigJoker }
    }

    private static func isStrongNoTrumpPair(_ cards: [Card], trumpRank: Rank) -> Bool {
        guard let rep = pairRepresentative(of: cards, trumpSuit: nil, trumpRank: trumpRank) else {
            return false
        }
        return rep.rank == trumpRank
            || rep.rank == .smallJoker
            || rep.rank == .bigJoker
            || rep.rank == .ace
    }

    private static func isTrumpLead(_ move: AIMove, ts: Suit?, tr: Rank) -> Bool {
        guard let first = move.cards.first else { return false }
        return CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr)
    }

    private static func containsBigTrump(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        cards.contains { isBigTrump($0, ts: ts, tr: tr) }
    }

    private static func isBigTrump(_ card: Card, ts: Suit?, tr: Rank) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        return card.rank == .bigJoker
            || card.rank == .smallJoker
            || card.rank == tr
            || (card.suit == ts && card.rank == .ace)
    }

    private static func trumpCards(in hand: [Card], ts: Suit?, tr: Rank) -> [Card] {
        hand.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
    }

    private static func sideCardsRemaining(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }.count
    }

    private static func remainingTricks(for hand: [Card]) -> Int {
        hand.count
    }

    private static func strongTrumpCount(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        trumpCards(in: hand, ts: ts, tr: tr).filter {
            isBigTrump($0, ts: ts, tr: tr)
                || CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue
        }.count
    }

    private static func exposedPointCardsToProtect(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            .reduce(0) { $0 + $1.pointValue }
    }

    private static func sidePairProtectionValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let control = ownTrumpControlFactor(in: hand, ts: ts, tr: tr)
        guard control > 0 else { return 0 }

        var bestValue = 0.0
        for suit in Suit.allCases {
            let voidEnemies = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue)
                .filter { !ctx.isVoid($0, key: "TRUMP") }
            guard !voidEnemies.isEmpty else { continue }

            let pairValue = strongestProtectableSidePairValue(in: hand, suit: suit, ts: ts, tr: tr)
            guard pairValue > 0 else { continue }

            let threat = trumpThreatScore(
                from: voidEnemies,
                hand: hand,
                state: state,
                ts: ts,
                tr: tr,
                ctx: ctx
            )
            guard threat > 0 else { continue }

            bestValue = max(bestValue, Double(pairValue) * threat * control)
        }
        return bestValue
    }

    private static func strongestProtectableSidePairValue(
        in hand: [Card],
        suit: Suit,
        ts: Suit?,
        tr: Rank
    ) -> Int {
        let suitCards = hand.filter {
            $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        }
        return pairs(in: suitCards, trumpSuit: ts, trumpRank: tr)
            .compactMap { pair -> Int? in
                guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else {
                    return nil
                }
                return protectableSidePairValue(rep, trumpRank: tr)
            }
            .max() ?? 0
    }

    private static func protectableSidePairValue(_ rep: Card, trumpRank: Rank) -> Int {
        var value = 0
        switch rep.rank {
        case .ace:
            value += 40
        case .king:
            value += 30
        case .ten:
            value += 20
        default:
            break
        }
        if rep.rank == trumpRank { value += 50 }
        if rep.pointValue > 0 { value += 20 }
        return value
    }

    private static func ownTrumpControlFactor(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        let strongCount = strongTrumpCount(in: hand, ts: ts, tr: tr)
        guard trumpCount >= 4, strongCount >= 2 else { return 0 }
        if trumpCount >= 8 && strongCount >= 4 { return 1.25 }
        if trumpCount >= 6 && strongCount >= 3 { return 1.05 }
        return 0.75
    }

    private static func trumpThreatScore(
        from voidEnemies: [PlayerPosition],
        hand: [Card],
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        let unknownPairFactor = unknownTrumpPairThreatFactor(hand: hand, ts: ts, tr: tr, ctx: ctx)
        guard unknownPairFactor > 0 else { return 0 }

        let enemyThreat = voidEnemies.map {
            trumpThreatScore(for: $0, state: state, ts: ts, tr: tr, ctx: ctx)
        }.max() ?? 0
        guard enemyThreat > 0 else { return 0 }

        return min(1.0, unknownPairFactor * enemyThreat)
    }

    private static func unknownTrumpPairThreatFactor(hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        let trumpFaces = uniqueCardFaces(Deck.doubleDeck().filter {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        })
        let pairFaces = trumpFaces.filter { face in
            Deck.doubleDeck().filter { sameFace($0, face) }.count >= 2
        }
        guard !pairFaces.isEmpty else { return 0 }

        let unknownPairFaces = pairFaces.filter { face in
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            return known < total
        }
        guard !unknownPairFaces.isEmpty else { return 0 }

        let highPairFaces = pairFaces.filter {
            CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) >= 12
        }
        let consumedHighPairs = highPairFaces.filter { face in
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            return known >= total
        }.count

        let depletion = highPairFaces.isEmpty
            ? 1.0
            : max(0.25, 1.0 - Double(consumedHighPairs) / Double(highPairFaces.count) * 0.65)
        let remainingDensity = min(1.0, Double(unknownPairFaces.count) / 5.0)
        return remainingDensity * depletion
    }

    private static func trumpThreatScore(
        for position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        if ctx.isVoid(position, key: "TRUMP") { return 0 }
        if failedToFollowTrumpPair(position: position, state: state, ts: ts, tr: tr) {
            return 0
        }

        var score = 1.0
        let trumpPlayed = trumpCardsPlayed(by: position, state: state, ts: ts, tr: tr)
        if trumpPlayed >= 5 {
            score *= 0.35
        } else if trumpPlayed >= 3 {
            score *= 0.55
        } else if trumpPlayed >= 1 {
            score *= 0.8
        }

        return score
    }

    private static func trumpCardsPlayed(by position: PlayerPosition, state: GameState, ts: Suit?, tr: Rank) -> Int {
        let completed = state.completedTricks.flatMap(\.plays)
        let current = state.currentTrick.plays
        return (completed + current)
            .filter { $0.position == position }
            .flatMap(\.cards)
            .filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
            .count
    }

    private static func failedToFollowTrumpPair(
        position: PlayerPosition,
        state: GameState,
        ts: Suit?,
        tr: Rank
    ) -> Bool {
        for trick in state.completedTricks {
            guard let leadCards = trick.leadCards,
                  pairRepresentative(of: leadCards, trumpSuit: ts, trumpRank: tr) != nil,
                  leadCards.allSatisfy({ CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }),
                  let play = trick.plays.first(where: { $0.position == position }) else {
                continue
            }
            let followedWithTrump = play.cards.filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            if followedWithTrump.count >= 2,
               pairRepresentative(of: Array(followedWithTrump.prefix(2)), trumpSuit: ts, trumpRank: tr) == nil {
                return true
            }
        }
        return false
    }

    private static func handAfterPlaying(_ cards: [Card], from hand: [Card]) -> [Card] {
        let usedIDs = Set(cards.map { $0.id })
        return hand.filter { !usedIDs.contains($0.id) }
    }

    private static func remainingAssetValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank

        var value = 0.0
        value += remainingTrumpValue(in: hand, ts: ts, tr: tr) * 2.0
        value += sideControlValue(in: hand, ts: ts, tr: tr, ctx: ctx) * 1.4
        value += structureAssetValue(in: hand, ts: ts, tr: tr) * (ts == nil ? 2.2 : 1.4)
        value += slamOpportunityValue(position: position, hand: hand, state: state, ctx: ctx) * 1.3
        value += clearSuitOpportunityValue(in: hand, ts: ts, tr: tr, ctx: ctx) * 1.1
        value += initiativeNeed(position: position, hand: hand, state: state, ctx: ctx) * 0.2

        return value
    }

    private static func remainingTrumpValue(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        trumpCards(in: hand, ts: ts, tr: tr).reduce(0.0) { partial, card in
            let weight = CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)
            if isBigTrump(card, ts: ts, tr: tr) { return partial + 5.0 }
            if weight >= Rank.king.rawValue { return partial + 2.0 }
            if card.pointValue > 0 { return partial + 0.5 }
            return partial + 1.0
        }
    }

    private static func structureAssetValue(in hand: [Card], ts: Suit?, tr: Rank) -> Double {
        var value = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            value += 2.0
            if isStrongPairAsset(rep, ts: ts, tr: tr) { value += 3.0 }
            if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr) { value += 1.0 }
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let pairCount = tractor.count / 2
                value += Double(pairCount) * 4.0
                if ts == nil { value += 4.0 }
            }
        }

        return value
    }

    private static func slamOpportunityValue(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let slams = findSlamLeadCandidates(
            in: hand,
            ts: state.trumpSuit,
            tr: state.trumpRank,
            myTeam: position.team,
            ctx: ctx
        )

        return slams.reduce(0.0) { partial, cards in
            let points = cards.reduce(0) { $0 + $1.pointValue }
            return partial + Double(cards.count) * 2.0 + Double(points) / 5.0
        }
    }

    private static func clearSuitOpportunityValue(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        var value = 0.0

        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            guard !suitCards.isEmpty, suitCards.count <= 2 else { continue }

            let points = suitCards.reduce(0) { $0 + $1.pointValue }
            value += 2.0
            value += Double(points) / 5.0
            if suitCards.contains(where: { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) {
                value += 3.0
            }
        }

        return value
    }

    private static func sideControlValue(in hand: [Card], ts: Suit?, tr: Rank, ctx: AIContext) -> Double {
        var value = 0.0
        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
            guard !suitCards.isEmpty else { continue }
            if suitCards.contains(where: { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }) {
                value += 2.0
            }
            if suitCards.count >= 3 { value += 0.8 }
            value += Double(suitCards.reduce(0) { $0 + $1.pointValue }) / 20.0
        }
        return value
    }

    private static func countUnclearedSideSuits(in hand: [Card], ts: Suit?, tr: Rank) -> Int {
        Suit.allCases.filter { suit in
            hand.contains {
                $0.suit == suit && !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
            }
        }.count
    }

    private static func usedBigTrumpEarlyPenalty(
        state: GameState,
        position: PlayerPosition,
        hand: [Card],
        move: AIMove
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard isTrumpLead(move, ts: ts, tr: tr) else { return 0 }

        let remaining = remainingTricks(for: hand)
        let sideSuits = countUnclearedSideSuits(in: hand, ts: ts, tr: tr)
        var penalty = 0.0

        if remaining > 5 && sideSuits >= 2 {
            penalty += 30
        }

        if remaining > 5 && sideCardsRemaining(in: hand, ts: ts, tr: tr) > trumpCards(in: hand, ts: ts, tr: tr).count {
            penalty += 80
        }

        if state.dealerTeamIdx != position.team && remaining > 5 {
            penalty += 12
        }

        for card in move.cards {
            if isBigTrump(card, ts: ts, tr: tr) {
                penalty += 25
            } else if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
                penalty += 8
            }
        }

        if containsBigTrump(move.cards, ts: ts, tr: tr) && remaining > 5 {
            penalty += 20
        }

        return penalty
    }

    // MARK: - Absolute Side Winner First / Trump Preservation

    /// Absolute Side Winner First 只适用于副牌：
    /// 副牌 A、已知最大副牌单张、已知最大副牌对子会随绝门增加而贬值，应优先兑现。
    private static func absoluteSideWinnerLeadBonus(
        cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let first = cards.first,
              !CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr),
              cards.allSatisfy({ !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }),
              let suit = first.suit,
              cards.allSatisfy({ $0.suit == suit }) else { return 0 }

        if cards.count == 1 {
            let isAce = first.rank == .ace
            let isKnownBiggest = ctx.isEffectivelyBiggest(first, ts: ts, tr: tr)
            guard isAce || isKnownBiggest else { return 0 }
            return isKnownBiggest ? 88 : 84
        }

        if cards.count == 2,
           let rep = pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr),
           isEffectivelyBiggestPair(rep, hand: hand, ctx: ctx, ts: ts, tr: tr) {
            return 96
        }

        return 0
    }

    private static func isAbsoluteSideWinnerLead(
        _ cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        absoluteSideWinnerLeadBonus(cards: cards, hand: hand, ts: ts, tr: tr, ctx: ctx) > 0
    }

    /// Trump Preservation 高于 Absolute Side Winner：主牌控制资源默认保留。
    /// 只有吊主、抢分/保护分、控场或残局需求明确时，保留惩罚才明显减弱。
    private static func trumpPreservationPenalty(
        move: AIMove,
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Double {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        guard move.kind != .trumpTransfer,
              isTrumpLead(move, ts: ts, tr: tr) else { return 0 }

        var penalty = 0.0
        for card in move.cards where CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) {
            if card.rank == .bigJoker || card.rank == .smallJoker {
                penalty += 120
            } else if card.rank == tr {
                penalty += 95
            } else if card.suit == ts && card.rank == .ace {
                penalty += 90
            } else if CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue {
                penalty += 35
            }
        }
        guard penalty > 0 else { return 0 }

        return hasStrategicTrumpLeadNeed(position: position, hand: hand, state: state, ctx: ctx)
            ? penalty * 0.25
            : penalty
    }

    private static func hasStrategicTrumpLeadNeed(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        ctx: AIContext
    ) -> Bool {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let remaining = remainingTricks(for: hand)
        if remaining <= 5 { return true }  // 残局

        let trumpCount = trumpCards(in: hand, ts: ts, tr: tr).count
        let strongCount = strongTrumpCount(in: hand, ts: ts, tr: tr)
        if state.dealerTeamIdx == position.team && trumpCount >= 7 { return true } // 吊主
        if trumpCount >= 8 || strongCount >= 4 { return true }                     // 控场
        if sideCardsRemaining(in: hand, ts: ts, tr: tr) <= trumpCount { return true }
        if exposedPointCardsToProtect(in: hand, ts: ts, tr: tr) >= 25 { return true } // 抢分/保分
        if sidePairProtectionValue(position: position, hand: hand, state: state, ctx: ctx) >= 45 {
            return true
        }
        return false
    }

    private static func leadWinProbability(
        _ cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let first = cards.first else { return 0 }
        if CardComparator.isTrump(first, trumpSuit: ts, trumpRank: tr) {
            let high = cards.map { CardComparator.trumpWeight($0, trumpSuit: ts, trumpRank: tr) }.max() ?? 0
            return min(0.95, 0.35 + Double(high) / 120.0)
        }

        let allBig = cards.allSatisfy { ctx.isEffectivelyBiggest($0, ts: ts, tr: tr) }
        if allBig { return 0.78 }
        if cards.contains(where: { $0.rank == .ace }) { return 0.62 }
        let high = cards.map(\.rank.rawValue).max() ?? 0
        return min(0.55, Double(high) / 24.0)
    }

    private static func partnerDumpValue(
        suit: Suit,
        position: PlayerPosition,
        tr: Rank,
        ctx: AIContext
    ) -> Double {
        guard let partner = PlayerPosition.allCases.first(where: { $0.team == position.team && $0 != position }),
              ctx.isVoid(partner, key: suit.rawValue) else { return 0 }
        return Double(ctx.unplayedSuitPoints(suit: suit, tr: tr)) / 20.0
    }

    private static func riskOfBeingRuffed(
        suit: Suit,
        cards: [Card],
        position: PlayerPosition,
        ctx: AIContext
    ) -> Double {
        let voidEnemies = ctx.voidEnemies(myTeam: position.team, key: suit.rawValue).count
        let pointLoad = cards.reduce(0) { $0 + $1.pointValue }
        var risk = Double(voidEnemies) * 0.45
        if pointLoad == 0 { risk += 0.12 }
        if cards.count >= 3 { risk += 0.18 }
        return min(1.0, risk)
    }

    private static func structureBreakPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let selected = Set(cards.map(\.id))
        var penalty = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let count = pair.filter { selected.contains($0.id) }.count
            if count == 1 { penalty += 1 }
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { selected.contains($0.id) }.count
                if used > 0 && used < tractor.count { penalty += 1.5 }
            }
        }
        return penalty
    }

    private static func strongStructureBreakPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let selected = Set(cards.map(\.id))
        var penalty = 0.0

        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { selected.contains($0.id) }.count
            guard used == 1,
                  let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            penalty += isStrongPairAsset(rep, ts: ts, tr: tr) ? 2.5 : 0.8
        }

        for suit in Set(hand.map { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) }) {
            let suitCards = hand.filter { CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == suit }
            for tractor in tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr) {
                let used = tractor.filter { selected.contains($0.id) }.count
                guard used > 0 && used < tractor.count else { continue }
                penalty += ts == nil ? 3.5 : 2.8
            }
        }

        return penalty
    }

    private static func isStrongPairAsset(_ representative: Card, ts: Suit?, tr: Rank) -> Bool {
        if representative.rank == .bigJoker || representative.rank == .smallJoker { return true }
        if representative.rank == tr { return true }
        if representative.rank == .ace { return true }
        if CardComparator.isTrump(representative, trumpSuit: ts, trumpRank: tr),
           isBigTrump(representative, ts: ts, tr: tr) { return true }
        return false
    }

    // MARK: - Tractor First Principle（优先保留并使用连对结构）

    private static func isTractorLead(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) != nil
    }

    private static func containsTractorComponent(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        if isTractorLead(cards, ts: ts, tr: tr) { return true }
        for logicalSuit in Set(cards.map({ CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) })) {
            let suitCards = cards.filter {
                CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == logicalSuit
            }
            if tractors(in: suitCards, pairCount: 2, trumpSuit: ts, trumpRank: tr).isEmpty == false {
                return true
            }
        }
        return false
    }

    private static func tractorFirstLeadBonus(cards: [Card], ts: Suit?, tr: Rank) -> Double {
        guard let info = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) else { return 0 }
        var bonus = Double(info.pairCount) * 85
        if isHighValueTractor(cards, ts: ts, tr: tr) { bonus += 80 }
        if CardComparator.isTrump(info.highCard, trumpSuit: ts, trumpRank: tr) { bonus += 30 }
        return bonus
    }

    private static func tractorBreakLeadPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        guard !isTractorLead(cards, ts: ts, tr: tr) else { return 0 }
        let selected = Set(cards.map(\.id))
        var penalty = 0.0

        for tractor in tractorCandidates(in: hand, ts: ts, tr: tr) {
            let used = tractor.filter { selected.contains($0.id) }.count
            guard used > 0 && used < tractor.count else { continue }
            var candidatePenalty = 120 + Double(used) * 35
            if isHighValueTractor(tractor, ts: ts, tr: tr) { candidatePenalty += 80 }
            penalty = max(penalty, candidatePenalty)
        }
        return penalty
    }

    private static func tractorCandidates(in hand: [Card], ts: Suit?, tr: Rank) -> [[Card]] {
        var result: [[Card]] = []
        for logicalSuit in Set(hand.map({ CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) })) {
            let suitCards = hand.filter {
                CardComparator.logicalSuit($0, trumpSuit: ts, trumpRank: tr) == logicalSuit
            }
            let pairCount = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
            guard pairCount >= 2 else { continue }
            for count in 2...pairCount {
                result += tractors(in: suitCards, pairCount: count, trumpSuit: ts, trumpRank: tr)
            }
        }
        return result
    }

    private static func isHighValueTractor(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard let info = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) else { return false }
        if CardComparator.isTrump(info.highCard, trumpSuit: ts, trumpRank: tr) { return true }
        let reps = pairRepresentatives(in: cards, ts: ts, tr: tr)
        return reps.contains { rep in
            rep.rank == .ace || rep.rank == .king || rep.rank == .queen || rep.pointValue > 0
        }
    }

    private static func pairRepresentatives(in cards: [Card], ts: Suit?, tr: Rank) -> [Card] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: ts, trumpRank: tr), default: []].append(card)
        }
        return grouped.values.compactMap { group in
            guard group.count >= 2 else { return nil }
            return group[0]
        }
    }

    // MARK: - 先手保强对子（不要把 A 对等强对子拆成单张）

    /// 先手「强对子」分级（仅用于先手保对子逻辑，不影响跟牌评分）。
    /// 返回 (拆对子的重罚, 出整对的加分)；非强对子返回 (0, 0)。
    /// 强对子定义：A对 / 级牌对 / 王对 / K对 / 10对 / 含分牌对子(5) / 主牌强对子。
    private static func leadStrongPairWeights(_ rep: Card, ts: Suit?, tr: Rank)
        -> (breakPenalty: Double, leadBonus: Double) {
        // 顶级：王对 / 级牌对 / A对
        if rep.rank == .bigJoker || rep.rank == .smallJoker || rep.rank == tr || rep.rank == .ace {
            return (140, 60)
        }
        // 主牌强对子（大主 或 牌力 ≥ K）
        if CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
           isBigTrump(rep, ts: ts, tr: tr)
            || CardComparator.trumpWeight(rep, trumpSuit: ts, trumpRank: tr) >= Rank.king.rawValue {
            return (120, 50)
        }
        // K对 / 10对（注意：必须在「含分对子」之前判断，K/10 本身也是分牌）
        if rep.rank == .king || rep.rank == .ten { return (100, 40) }
        // 其他含分对子（5对）→ 中等
        if rep.pointValue > 0 { return (70, 30) }
        return (0, 0)
    }

    private static func isLeadStrongPair(_ rep: Card, ts: Suit?, tr: Rank) -> Bool {
        leadStrongPairWeights(rep, ts: ts, tr: tr).breakPenalty > 0
    }

    /// 规则 1：把手中所有强对子都作为先手候选加入（避免被漏掉而只剩单张候选）。
    private static func findStrongPairLeadCandidates(
        in hand: [Card], ts: Suit?, tr: Rank, myTeam: Int, ctx: AIContext
    ) -> [AIMove] {
        var moves: [AIMove] = []
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr),
                  isLeadStrongPair(rep, ts: ts, tr: tr) else { continue }
            // 敌方已全绝的副花色，领出会被将吃 → 跳过
            if !CardComparator.isTrump(rep, trumpSuit: ts, trumpRank: tr),
               ctx.allEnemiesVoid(myTeam: myTeam, key: AIContext.suitKey(rep, ts: ts, tr: tr)) { continue }
            moves.append(AIMove(cards: pair, kind: .bigPair))
        }
        return moves
    }

    /// 规则 2：先手单张（或任何走法）若拆掉了强对子，按分级重罚。
    private static func strongPairBreakLeadPenalty(cards: [Card], hand: [Card], ts: Suit?, tr: Rank) -> Double {
        let selected = Set(cards.map(\.id))
        var penalty = 0.0
        for pair in pairs(in: hand, trumpSuit: ts, trumpRank: tr) {
            let used = pair.filter { selected.contains($0.id) }.count
            guard used == 1,
                  let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { continue }
            penalty += leadStrongPairWeights(rep, ts: ts, tr: tr).breakPenalty
        }
        return penalty
    }

    /// 某走法是否是「先手强对子」整对出牌。
    private static func isStrongPairLead(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard cards.count == 2,
              let rep = pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) else { return false }
        return isLeadStrongPair(rep, ts: ts, tr: tr)
    }

    // MARK: - Pair First Principle（同花色有对子时，散牌默认降权）

    /// 普通对子也属于牌型资源；出整对获得基础加分，拖拉机按对子数加分。
    private static func pairFirstLeadBonus(cards: [Card], ts: Suit?, tr: Rank) -> Double {
        if let tractor = tractorInfo(of: cards, trumpSuit: ts, trumpRank: tr) {
            return Double(tractor.pairCount) * 18
        }
        return isPairFirstLead(cards, ts: ts, tr: tr) ? 24 : 0
    }

    /// 当某逻辑花色中仍有对子，先领同花色散牌会让后续跟牌更容易被迫拆对，默认降权。
    /// 清门、队友垫分、甩牌、小主过渡这类明确战略走法不受该默认罚分约束。
    private static func pairFirstSingleLeadPenalty(
        move: AIMove,
        cards: [Card],
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        clearBenefit: Double,
        partnerDump: Double
    ) -> Double {
        guard cards.count == 1,
              let card = cards.first,
              move.kind != .slam,
              move.kind != .partnerDump,
              move.kind != .trumpTransfer,
              clearBenefit == 0,
              partnerDump == 0 else { return 0 }

        let suit = CardComparator.logicalSuit(card, trumpSuit: ts, trumpRank: tr)
        guard hasPairAsset(in: hand, logicalSuit: suit, ts: ts, tr: tr) else { return 0 }

        var penalty = 46.0
        if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) { penalty += 10 }
        if card.pointValue > 0 { penalty += 8 }
        return penalty
    }

    private static func isPairFirstLead(_ cards: [Card], ts: Suit?, tr: Rank) -> Bool {
        guard cards.count == 2,
              pairRepresentative(of: cards, trumpSuit: ts, trumpRank: tr) != nil else {
            return false
        }
        return true
    }

    private static func hasPairAsset(in hand: [Card], logicalSuit: Suit?, ts: Suit?, tr: Rank) -> Bool {
        pairs(in: hand, trumpSuit: ts, trumpRank: tr).contains { pair in
            guard let rep = pairRepresentative(of: pair, trumpSuit: ts, trumpRank: tr) else { return false }
            return CardComparator.logicalSuit(rep, trumpSuit: ts, trumpRank: tr) == logicalSuit
        }
    }

    private static func candidateWinsTrick(
        _ cards: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator
    ) -> Bool {
        var trick = state.currentTrick
        trick.plays.append((position: position, cards: cards))
        return evaluator.winner(of: trick) == position
    }

    private static func classifyFollowMove(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> FollowWinClass {
        guard candidateWinsTrick(cards, position: position, state: state, evaluator: evaluator) else {
            return .cannotWin
        }
        if cards.contains(where: {
            CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }) {
            return isSecureWinningTrumpFollow(
                cards,
                position: position,
                hand: hand,
                state: state,
                evaluator: evaluator,
                ctx: ctx
            ) ? .finalWin : .temporaryWin
        }
        return isTrickSecureForTeam(
            position: position,
            hand: hand,
            state: state,
            evaluator: evaluator,
            ctx: ctx,
            candidateCards: cards
        ) ? .finalWin : .temporaryWin
    }

    private static func followWinClassScore(
        _ winClass: FollowWinClass,
        trickPoints: Int,
        playedPoints: Int
    ) -> Double {
        switch winClass {
        case .finalWin:
            return 90 + Double(trickPoints) * 5 + Double(playedPoints)
        case .temporaryWin:
            return 20 + Double(trickPoints) * 1.2 - Double(playedPoints) * 2
        case .cannotWin:
            return -Double(playedPoints) * 4
        }
    }

    private static func isSecureWinningTrumpFollow(
        _ cards: [Card],
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> Bool {
        guard candidateWinsTrick(cards, position: position, state: state, evaluator: evaluator),
              let leadCards = state.currentTrick.leadCards,
              cards.allSatisfy({
                  CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
              }) else { return false }

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let futureOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team }
        if futureOpponents.isEmpty { return true }

        let trumpThreatOpponents: [PlayerPosition]
        if leadSuit == nil {
            trumpThreatOpponents = futureOpponents.filter { !ctx.isVoid($0, key: "TRUMP") }
        } else {
            trumpThreatOpponents = futureOpponents.filter {
                ctx.isVoid($0, key: leadKey) && !ctx.isVoid($0, key: "TRUMP")
            }
        }
        if trumpThreatOpponents.isEmpty { return true }

        guard let highTrump = cards.max(by: {
            CardComparator.beats($1, $0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
        }) else { return false }
        return noUnknownHigherTrumpThan(highTrump, hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx)
    }

    private static func clearsLogicalSuit(cards: [Card], hand: [Card], evaluator: TrickEvaluator) -> Bool {
        guard let first = cards.first else { return false }
        let suit = evaluator.cardSuit(first)
        let handCount = hand.filter { evaluator.cardSuit($0) == suit }.count
        let selectedCount = cards.filter { evaluator.cardSuit($0) == suit }.count
        return handCount == selectedCount
    }

    // MARK: - 甩牌跟牌

    /// 跟甩牌：有同花色正常出弱牌；无同花色时只在能组成匹配将牌结构时才出主，否则垫非主牌
    private static func followSlam(
        slam: TrickEvaluator.SlamInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        count: Int,
        ts: Suit?, tr: Rank,
        ctx: AIContext,
        trickSecure: Bool
    ) -> [Card] {
        // 有足够同花色：按结构优先（连对 > 对子 > 散牌），与跟连对规则一致
        if suitCards.count >= count {
            let slamPairSlots = slam.tractors.reduce(0) { $0 + $1.count / 2 } + slam.pairs.count
            let handPairs     = pairs(in: suitCards, trumpSuit: ts, trumpRank: tr).count
            let requiredPairs = min(handPairs, slamPairSlots)

            // 无对子要求（纯散牌甩牌）：直接出最弱的
            if requiredPairs == 0 {
                return partnerWinning && trickSecure
                    ? partnerSupportCards(from: suitCards, count: count,
                                          trumpSuit: ts, trumpRank: tr)
                    : weakestCards(from: suitCards, count: count, trumpSuit: ts, trumpRank: tr)
            }

            // 先按结构取配对牌（连对 > 孤立对子），剩余散牌用弱牌/支持牌填充
            // 队友赢时：对子和散牌槽也优先出分牌
            let pairPart  = structuredSuitFollowCards(
                suitCards: suitCards, neededPairs: requiredPairs,
                trumpSuit: ts, trumpRank: tr,
                partnerWinning: partnerWinning && trickSecure
            )
            let usedIDs   = Set(pairPart.map { $0.id })
            let leftover  = suitCards.filter { !usedIDs.contains($0.id) }
            let fillCount = count - pairPart.count
            guard fillCount > 0 else { return Array(pairPart.prefix(count)) }
            let fill = partnerWinning && trickSecure
                ? partnerSupportCards(from: leftover, count: fillCount,
                                      trumpSuit: ts, trumpRank: tr)
                : weakestCards(from: leftover, count: fillCount, trumpSuit: ts, trumpRank: tr)
            return pairPart + fill
        }

        // 先出所有同花色
        var chosen = suitCards
        let remaining = count - chosen.count
        guard remaining > 0 else { return chosen }

        let usedIDs   = Set(chosen.map { $0.id })
        let extra     = hand.filter { !usedIDs.contains($0.id) }
        let trumpPool = extra.filter {  CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        let nonTrump  = extra.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }

        // 完全绝牌且敌方赢 → 尝试组成匹配甩牌结构的将牌将吃
        if suitCards.isEmpty && !partnerWinning {
            if let trumpCombo = buildMatchingSlamTrump(
                slam: slam, trumpCards: trumpPool,
                winningCards: winningCards, ts: ts, tr: tr
            ) {
                return trumpCombo
            }
        }

        // 无法将吃或队友赢：优先垫非主牌，不浪费主牌
        // 队友甩牌 ≥4 张且含对子（结构有意义的大甩牌）且当前领先 → 视同拖拉机策略，主动垫分支持
        let slamIsStrong = partnerWinning
            && trickSecure
            && slam.count >= 4
            && (!slam.pairs.isEmpty || !slam.tractors.isEmpty)
        var fills = slamIsStrong
            ? safePartnerCards(from: nonTrump, count: remaining,
                               trumpSuit: ts, trumpRank: tr, ctx: ctx)
            : smartDiscard(from: nonTrump, count: remaining,
                           enemyWinning: !partnerWinning,
                           ts: ts, tr: tr, myTeam: position.team, ctx: ctx)
        // 非主牌不够时才补最弱主牌
        if fills.count < remaining {
            let usedIDs2    = Set(fills.map { $0.id })
            let trumpLeft   = trumpPool.filter { !usedIDs2.contains($0.id) }
            fills += weakestCards(from: trumpLeft, count: remaining - fills.count,
                                  trumpSuit: ts, trumpRank: tr)
        }
        chosen += Array(fills.prefix(remaining))
        return Array(chosen.prefix(count))
    }

    /// 在主牌中构造与甩牌结构完全匹配的最弱组合，并检查能否压过当前赢家
    /// 找不到合格组合时返回 nil
    private static func buildMatchingSlamTrump(
        slam: TrickEvaluator.SlamInfo,
        trumpCards: [Card],
        winningCards: [Card],
        ts: Suit?, tr: Rank
    ) -> [Card]? {
        let pureSingleSlam = slam.tractors.isEmpty && slam.pairs.isEmpty
        let pairedTrumpIDs = pairedCardIDs(in: trumpCards, trumpSuit: ts, trumpRank: tr)
        let tractorSizes = slam.tractors
            .compactMap { tractorInfo(of: $0, trumpSuit: ts, trumpRank: tr)?.pairCount }
            .sorted(by: >)

        // 贪心构造：依次取最弱的连对 → 对子 → 单张
        var pool   = trumpCards
        var result = [Card]()

        for neededSize in tractorSizes {
            let candidates = tractors(in: pool, pairCount: neededSize,
                                      trumpSuit: ts, trumpRank: tr)
                .sorted { weakerTractor($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard let weakest = candidates.first else { return nil }
            result += weakest
            let ids = Set(weakest.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
        }

        for _ in 0..<slam.pairs.count {
            let candidates = pairs(in: pool, trumpSuit: ts, trumpRank: tr)
                .sorted { weakerPair($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard let weakest = candidates.first else { return nil }
            result += weakest
            let ids = Set(weakest.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
        }

        for _ in 0..<slam.singles.count {
            let sorted = pool.sorted { a, b in
                if pureSingleSlam {
                    let aPaired = pairedTrumpIDs.contains(a.id)
                    let bPaired = pairedTrumpIDs.contains(b.id)
                    if aPaired != bPaired { return !aPaired }
                }
                return discardOrder(a, before: b, trumpSuit: ts, trumpRank: tr)
            }
            guard let weakest = sorted.first else { return nil }
            result.append(weakest)
            pool = pool.filter { $0.id != weakest.id }
        }

        guard result.count == slam.count else { return nil }

        // 判断能否压过当前赢家
        let winnerIsTrump = winningCards.first.map {
            CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
        } ?? false

        if !winnerIsTrump { return result }  // 主牌必然大于非主赢家

        // 赢家也是主牌：用最高牌近似比较（足够 AI 决策）
        let comboHigh  = result.max      { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }!
        let winnerHigh = winningCards.max { CardComparator.beats($1, $0, trumpSuit: ts, trumpRank: tr) }!
        guard CardComparator.beats(comboHigh, winnerHigh, trumpSuit: ts, trumpRank: tr) else {
            return nil  // 压不过 → 不浪费主牌
        }
        return result
    }

    private static func pairedCardIDs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Set<UUID> {
        var pairMap: [String: [Card]] = [:]
        for card in cards {
            pairMap[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank),
                    default: []].append(card)
        }
        return Set(pairMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })
    }

    // MARK: - 领出辅助

    /// 队友赢时决定是否扔分牌：只有「本墩最后出牌」或「大主牌已基本耗尽」时才贡献分牌
    /// 否则用安全垫牌（避免后手对手用大王截胡）
    private static func safePartnerCards(
        from cards: [Card], count: Int,
        trumpSuit: Suit?, trumpRank: Rank,
        ctx: AIContext
    ) -> [Card] {
        let safe = !ctx.isLastPlayer && ctx.manyBigTrumpsRemain(trumpRank: trumpRank)
        if safe {
            // 不贡献分牌：出最弱的非主牌，再补主牌
            return weakestCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        return partnerSupportCards(from: cards, count: count, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    /// 找甩牌候选：同一非主花色中"无法被压制"的牌组合在一起领出（甩牌）
    ///
    /// 合法甩牌要求（按分量分别判断）：
    /// - 单张分量：所有更高 rank 在 played+hand 中合计 ≥ 2（两张都已知晓，对手无法有更大单张）
    /// - 对子分量：所有更高 rank 在 played+hand 中合计 ≥ 1（对手最多只有 1 张，凑不成更大对子）
    ///
    /// 例：手中 A♠K♠K♠ → KK 是最大对子（A 在手里，外面最多 1 张 A 凑不成 AA 对），A 是最大单张 → 合法甩牌
    ///     手中 A♠Q♠Q♠ 且手中还有 K♠ → QQ 是最大对子（K/A 各有 ≥1 张在手，外面凑不成 KK/AA），A 最大单张 → 合法甩牌
    ///
    /// - 对手已确认绝该花色：仅当组合含对子时才甩
    /// 优先选张数最多的花色，张数相同时优先含对子的花色
    private static func findSlamLeadCandidates(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [[Card]] {
        let sideCards = hand.filter { !CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        var bySuit: [Suit: [Card]] = [:]
        for card in sideCards {
            guard let suit = card.suit else { continue }
            bySuit[suit, default: []].append(card)
        }

        var candidates: [[Card]] = []
        for (suit, suitCards) in bySuit {
            let unbeatableSingles = suitCards.filter {
                isEffectivelyBiggestSingle($0, hand: hand, ctx: ctx, ts: ts, tr: tr)
            }

            var rankGroups: [Rank: [Card]] = [:]
            for card in suitCards { rankGroups[card.rank, default: []].append(card) }

            var unbeatablePairCards: [Card] = []
            for cards in rankGroups.values where cards.count >= 2 {
                if isEffectivelyBiggestPair(cards[0], hand: hand, ctx: ctx, ts: ts, tr: tr) {
                    unbeatablePairCards += Array(cards.prefix(2))
                }
            }

            var candidateIds = Set(unbeatableSingles.map { $0.id })
            for card in unbeatablePairCards { candidateIds.insert(card.id) }
            let candidateCards = suitCards.filter { candidateIds.contains($0.id) }
            guard candidateCards.count >= 2 else { continue }
            if candidateCards.count == 2,
               pairKey(candidateCards[0], trumpSuit: ts, trumpRank: tr)
                    == pairKey(candidateCards[1], trumpSuit: ts, trumpRank: tr) { continue }

            let hasVoidEnemy = ctx.voidEnemies(myTeam: myTeam, key: suit.rawValue).count > 0
            let hasPairs = !unbeatablePairCards.isEmpty
            if hasVoidEnemy && !hasPairs { continue }

            candidates.append(candidateCards)

            // 大甩牌风险较高时，也提供较小的安全子集给评分器选择。
            if candidateCards.count > 3, !unbeatablePairCards.isEmpty {
                let pairOnly = suitCards.filter { card in unbeatablePairCards.contains(where: { $0.id == card.id }) }
                if pairOnly.count >= 2 { candidates.append(pairOnly) }
            }
        }
        return candidates
    }

    private static func findSlamLead(
        in hand: [Card],
        ts: Suit?, tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card]? {
        findSlamLeadCandidates(in: hand, ts: ts, tr: tr, myTeam: myTeam, ctx: ctx)
            .max { lhs, rhs in
                let lSuit = lhs.first?.suit?.rawValue ?? ""
                let rSuit = rhs.first?.suit?.rawValue ?? ""
                let lRisk = Double(ctx.voidEnemies(myTeam: myTeam, key: lSuit).count)
                let rRisk = Double(ctx.voidEnemies(myTeam: myTeam, key: rSuit).count)
                let lScore = Double(lhs.reduce(0) { $0 + $1.pointValue }) + Double(lhs.count * 2) - lRisk * 20
                let rScore = Double(rhs.reduce(0) { $0 + $1.pointValue }) + Double(rhs.count * 2) - rRisk * 20
                return lScore < rScore
            }
    }

    /// 单张"最大"检查：所有比它大的同花色 rank，played + inHand ≥ 2（双副牌两张都已知晓，对手无法有更大单张）
    private static func isEffectivelyBiggestSingle(
        _ card: Card, hand: [Card], ctx: AIContext, ts: Suit?, tr: Rank
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        for rank in higherRanks {
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            if played + inHand < 2 { return false }
        }
        return true
    }

    /// 对子"最大"检查：所有比它大的同花色 rank，played + inHand ≥ 1（对手最多只有 1 张，凑不出更大对子）
    private static func isEffectivelyBiggestPair(
        _ card: Card, hand: [Card], ctx: AIContext, ts: Suit?, tr: Rank
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              let suit = card.suit else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        for rank in higherRanks {
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            // 对手凑成对子需要 2 张；played+inHand ≥ 1 则对手至多 1 张 → 凑不成对子
            if played + inHand < 1 { return false }
        }
        return true
    }

    /// 旁门 Ace（且敌方未全绝此花色，出才有意义；且不是对子中的一张，对子留给步骤1/4）
    private static func bestSideAce(
        in hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> Card? {
        // 找出所有配对的 pairKey，Ace 若有对子则不单独领出（步骤1已处理配对 Ace）
        var pairGroupMap: [String: [Card]] = [:]
        for card in hand {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank),
                         default: []].append(card)
        }
        let pairedIDs = Set(pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })

        return hand.first {
            $0.rank == .ace
                && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                && !pairedIDs.contains($0.id)   // 不拆对子 Ace
                && !ctx.allEnemiesVoid(myTeam: myTeam,
                                       key: AIContext.suitKey($0, ts: trumpSuit, tr: trumpRank))
        }
    }

    /// 在非绝牌花色中找对子（避免领出敌方已绝花色的单牌）
    private static func findBestPairAvoidingVoid(
        in hand: [Card],
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext
    ) -> [Card]? {
        var seen: [String: [Card]] = [:]
        for card in hand {
            let key = pairKey(card, trumpSuit: ts, trumpRank: tr)
            seen[key, default: []].append(card)
        }
        let candidates = seen.filter { entry in
            guard entry.value.count >= 2 else { return false }
            let card = entry.value[0]
            if CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) { return false }
            let sk = AIContext.suitKey(card, ts: ts, tr: tr)
            return !ctx.allEnemiesVoid(myTeam: myTeam, key: sk)
        }
        if let best = candidates.max(by: { a, b in a.value[0].rank < b.value[0].rank }) {
            return Array(best.value.prefix(2))
        }
        return nil
    }

    // MARK: - 后手位置辅助

    /// 判断某张主牌是否适合在「我方绝牌且后手对手也绝花色」时用作安全垫牌
    /// 安全：大小王、级牌（逻辑强度高，压不走）/ 主花色 A
    /// 不安全：主花色 K 及以下（容易被后手稍大的主牌截走）
    /// 判断一张主牌是否"安全"（出了不容易被后手对手用更大主牌顺手截分）
    /// 始终安全：大王 / 小王 / 级牌 / 主花色 A 及以上
    /// 动态安全：比该牌大的主花色分牌（K/10/5，排除级牌）已全部出完（双副牌各 2 张）
    private static func isTrickSecureForTeam(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext,
        candidateCards: [Card] = []
    ) -> Bool {
        var trick = state.currentTrick
        if !candidateCards.isEmpty,
           !trick.plays.contains(where: { $0.position == position }) {
            trick.plays.append((position: position, cards: candidateCards))
        }

        let currentWinner = evaluator.winner(of: trick)
        guard currentWinner.team == position.team,
              let winningCards = trick.plays.first(where: { $0.position == currentWinner })?.cards,
              let leadCards = trick.leadCards else { return false }

        let futureOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team }
        if futureOpponents.isEmpty { return true }

        let leadSuit = evaluator.dominantSuit(of: leadCards)
        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let winningRep = maxCard(in: winningCards, ts: state.trumpSuit, tr: state.trumpRank)

        if CardComparator.isTrump(winningRep, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank),
           isSafeTrump(winningRep, hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx) {
            return true
        }

        let allFutureOpponentsMustFollow = futureOpponents.allSatisfy {
            !ctx.isVoid($0, key: leadKey)
        }
        if allFutureOpponentsMustFollow {
            return isProtectedAgainstHigher(
                winningRep,
                leadSuit: leadSuit,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: ctx
            )
        }

        let allFutureOpponentsNoTrump = futureOpponents.allSatisfy {
            ctx.isVoid($0, key: "TRUMP")
        }
        if allFutureOpponentsNoTrump {
            if CardComparator.isTrump(winningRep, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) {
                return true
            }
            return isProtectedAgainstHigher(
                winningRep,
                leadSuit: leadSuit,
                hand: hand,
                ts: state.trumpSuit,
                tr: state.trumpRank,
                ctx: ctx
            )
        }

        return false
    }

    private static func shouldRiskUnsafeWin(
        trickPoints: Int,
        playedPoints: Int,
        ctx: AIContext
    ) -> Bool {
        if ctx.isLastPlayer { return true }
        let totalPoints = trickPoints + playedPoints
        if totalPoints >= 15 { return false }
        if totalPoints >= 5 { return playedPoints == 0 }
        return true
    }

    private static func isSafeTrump(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        if card.rank == .bigJoker || card.rank == .smallJoker { return true }
        if card.rank == tr { return true }
        if card.rank.rawValue >= Rank.ace.rawValue { return true }   // 主花色 A（不含 K）

        return noUnknownHigherTrumpThan(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }

    private static func noUnknownHigherTrumpThan(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }

        let higherTrumpFaces = uniqueCardFaces(
            Deck.doubleDeck().filter {
                CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr)
                    && CardComparator.beats($0, card, trumpSuit: ts, trumpRank: tr)
            }
        )

        for face in higherTrumpFaces {
            let total = Deck.doubleDeck().filter { sameFace($0, face) }.count
            let known = ctx.playedCards.filter { sameFace($0, face) }.count
                + hand.filter { sameFace($0, face) }.count
            if known < total { return false }
        }
        return true
    }

    private static func isSafeTrumpFiller(
        _ card: Card,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext,
        hand: [Card] = []
    ) -> Bool {
        isSafeTrump(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }

    private static func uniqueCardFaces(_ cards: [Card]) -> [Card] {
        var seen = Set<String>()
        var result: [Card] = []
        for card in cards {
            let key = "\(card.suit?.rawValue ?? "J")-\(card.rank.rawValue)"
            if seen.insert(key).inserted {
                result.append(card)
            }
        }
        return result
    }

    /// 跟单牌时，如果后手对手可能用本门分牌反超，优先出能压住该分牌的最小牌。
    /// leadSuit == nil 表示主牌；本墩已有分时，候选牌还必须挡住更高牌的后手反超。
    private static func pointGuardCard(
        from candidates: [Card],
        leadSuit: Suit?,
        winningRep: Card,
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        trickPoints: Int,
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Card? {
        guard !candidates.isEmpty, !ctx.isLastPlayer else { return nil }

        let leadKey = leadSuit.map { $0.rawValue } ?? "TRUMP"
        let subsequent = unplayedSubsequentPositions(after: position, in: state)
        let opponentsAfter = subsequent.filter { $0.team != position.team && !ctx.isVoid($0, key: leadKey) }.count
        let partnersAfter = subsequent.filter { $0.team == position.team && !ctx.isVoid($0, key: leadKey) }.count
        guard opponentsAfter > partnersAfter else { return nil }

        for pointCard in pointThreatCards(leadSuit: leadSuit, ts: ts, tr: tr) {
            guard remainingUnknownCopies(of: pointCard, hand: hand, ctx: ctx) > 0 else { continue }
            guard CardComparator.beats(pointCard, winningRep, trumpSuit: ts, trumpRank: tr) else {
                continue
            }

            let guardCandidates = candidates
                .filter { CardComparator.beats($0, pointCard, trumpSuit: ts, trumpRank: tr) }
                .sorted { weakerCard($0, than: $1, trumpSuit: ts, trumpRank: tr) }
            guard !guardCandidates.isEmpty else { continue }
            if trickPoints > 0 {
                if let safeCard = guardCandidates.first(where: {
                    isProtectedAgainstHigher($0, leadSuit: leadSuit, hand: hand, ts: ts, tr: tr, ctx: ctx)
                }) {
                    return safeCard
                }
                return guardCandidates.last
            }
            return guardCandidates.first
        }

        return nil
    }

    private static func pointThreatCards(leadSuit: Suit?, ts: Suit?, tr: Rank) -> [Card] {
        let pointRanks: [Rank] = [.king, .ten, .five]
        let cards: [Card]

        if let suit = leadSuit {
            cards = pointRanks
                .filter { $0 != tr }
                .map { Card(suit: suit, rank: $0) }
        } else {
            var trumpPoints: [Card] = []
            for rank in pointRanks {
                if rank == tr {
                    trumpPoints += Suit.allCases.map { Card(suit: $0, rank: rank) }
                } else if let trumpSuit = ts {
                    trumpPoints.append(Card(suit: trumpSuit, rank: rank))
                }
            }
            cards = trumpPoints.filter { CardComparator.isTrump($0, trumpSuit: ts, trumpRank: tr) }
        }

        return cards.sorted {
            cardStrength($0, ts: ts, tr: tr) > cardStrength($1, ts: ts, tr: tr)
        }
    }

    private static func cardStrength(_ card: Card, ts: Suit?, tr: Rank) -> Int {
        CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)
            : card.rank.rawValue
    }

    private static func remainingUnknownCopies(of card: Card, hand: [Card], ctx: AIContext) -> Int {
        let played = ctx.playedCards.filter { sameFace($0, card) }.count
        let inHand = hand.filter { sameFace($0, card) }.count
        return max(0, 2 - played - inHand)
    }

    private static func sameFace(_ a: Card, _ b: Card) -> Bool {
        a.suit == b.suit && a.rank == b.rank
    }

    private static func isProtectedAgainstHigher(
        _ card: Card,
        leadSuit: Suit?,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        if let suit = leadSuit {
            return isSideSuitProtectedAgainstHigher(card, suit: suit, hand: hand, ts: ts, tr: tr, ctx: ctx)
        }
        return isTrumpProtectedAgainstHigher(card, hand: hand, ts: ts, tr: tr, ctx: ctx)
    }

    private static func isTrumpProtectedAgainstHigher(
        _ card: Card,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr) else { return false }
        if card.rank == .bigJoker || card.rank == .smallJoker { return true }
        if card.rank == tr { return true }

        guard let suit = card.suit, suit == ts else { return false }
        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { rank in
            let higherCard = Card(suit: suit, rank: rank)
            return remainingUnknownCopies(of: higherCard, hand: hand, ctx: ctx) == 0
        }
    }

    private static func isSideSuitProtectedAgainstHigher(
        _ card: Card,
        suit: Suit,
        hand: [Card],
        ts: Suit?,
        tr: Rank,
        ctx: AIContext
    ) -> Bool {
        guard !CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr),
              card.suit == suit else { return false }

        let higherRanks = Rank.allCases.filter {
            !$0.isJoker && $0 != tr && $0.rawValue > card.rank.rawValue
        }
        return higherRanks.allSatisfy { rank in
            let played = ctx.playedCards.filter { $0.suit == suit && $0.rank == rank }.count
            let inHand = hand.filter { $0.suit == suit && $0.rank == rank }.count
            return played + inHand >= 2
        }
    }

    /// 返回本墩中当前 position 之后、还未出牌的玩家列表（顺时针顺序）
    /// 用于判断"后手是否绝主"以决定是否可以安全加分
    private static func unplayedSubsequentPositions(
        after position: PlayerPosition,
        in state: GameState
    ) -> [PlayerPosition] {
        let played = Set(state.currentTrick.plays.map { $0.position })
        var result: [PlayerPosition] = []
        var pos = PlayerPosition(rawValue: (position.rawValue + 1) % 4)!
        for _ in 0..<3 {
            if !played.contains(pos) {
                result.append(pos)
            }
            pos = PlayerPosition(rawValue: (pos.rawValue + 1) % 4)!
        }
        return result
    }

    // MARK: - Utility Helpers（与原版一致）

    /// 从同花色牌中按结构优先选出 neededPairs*2 张牌：
    /// 连对优先 → 孤立对子 → 散牌，避免出弱牌时拆散对子
    ///
    /// - partnerWinning: 队友赢时为 true，此时孤立对子和散牌优先选分多的（加分给队友）
    private static func structuredSuitFollowCards(
        suitCards: [Card],
        neededPairs: Int,
        trumpSuit: Suit?,
        trumpRank: Rank,
        partnerWinning: Bool = false
    ) -> [Card] {
        let count = neededPairs * 2
        var pool = suitCards
        var result = [Card]()
        var pairsLeft = neededPairs

        // 1. 贡献尽可能多的连对（取最弱的优先，从最大可用 size 往下贪心）
        //    队友赢时也保留最强连对，以备后续进攻
        var improved = true
        while pairsLeft >= 2 && improved {
            improved = false
            for size in stride(from: pairsLeft, through: 2, by: -1) {
                let candidates = tractors(in: pool, pairCount: size,
                                          trumpSuit: trumpSuit, trumpRank: trumpRank)
                    .sorted { weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                if let t = candidates.first {
                    result += t
                    let ids = Set(t.map { $0.id })
                    pool = pool.filter { !ids.contains($0.id) }
                    pairsLeft -= size
                    improved = true
                    break
                }
            }
        }

        // 2. 贡献孤立对子
        //    队友赢：优先出分多的对子（同分再出弱对保大牌）
        //    否则：出最弱对子
        while pairsLeft > 0 {
            let available = pairs(in: pool, trumpSuit: trumpSuit, trumpRank: trumpRank)
                .sorted { a, b in
                    if partnerWinning {
                        if a[0].pointValue != b[0].pointValue { return a[0].pointValue > b[0].pointValue }
                    }
                    return weakerPair(a, than: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
            guard let p = available.first else { break }
            result += p
            let ids = Set(p.map { $0.id })
            pool = pool.filter { !ids.contains($0.id) }
            pairsLeft -= 1
        }

        // 3. 用散牌填充剩余张数
        //    队友赢：用 partnerSupportCards（分多优先）；否则用最弱散牌
        let needed = count - result.count
        if needed > 0 {
            if partnerWinning {
                result += partnerSupportCards(from: pool, count: needed,
                                              trumpSuit: trumpSuit, trumpRank: trumpRank)
            } else {
                result += weakestCards(from: pool, count: needed,
                                       trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
        }

        return Array(result.prefix(count))
    }

    private static func maxCard(in cards: [Card], ts: Suit?, tr: Rank) -> Card {
        cards.max { a, b in CardComparator.beats(b, a, trumpSuit: ts, trumpRank: tr) }!
    }

    private static func tractors(in cards: [Card], pairCount: Int,
                                  trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        guard pairCount >= 2 else { return [] }
        let pairGroups = pairs(in: cards, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bySuit = Dictionary(grouping: pairGroups) { pair in
            CardComparator.logicalSuit(pair[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        var result: [[Card]] = []
        for groups in bySuit.values {
            let ordered = groups.sorted {
                CardComparator.pairOrderValue($0[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                    < CardComparator.pairOrderValue($1[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            guard ordered.count >= pairCount else { continue }
            for start in 0...(ordered.count - pairCount) {
                let window = Array(ordered[start..<(start + pairCount)])
                let reps = window.map { $0[0] }
                let isConsec = zip(reps, reps.dropFirst()).allSatisfy {
                    CardComparator.areAdjacentPairRanks($0, $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
                }
                if isConsec { result.append(window.flatMap { $0 }) }
            }
        }
        return result
    }

    private static func pairs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        return grouped.values.compactMap { $0.count >= 2 ? Array($0.prefix(2)) : nil }
    }

    private static func tractorInfo(of cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> TractorInfo? {
        guard cards.count >= 4, cards.count.isMultiple(of: 2) else { return nil }
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let pairCount = cards.count / 2
        guard grouped.count == pairCount,
              grouped.values.allSatisfy({ $0.count == 2 }) else { return nil }
        let reps = grouped.values.compactMap(\.first)
        guard let suit = reps.first.map({
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }), reps.allSatisfy({
            CardComparator.logicalSuit($0, trumpSuit: trumpSuit, trumpRank: trumpRank) == suit
        }) else { return nil }
        let ordered = reps.sorted {
            CardComparator.pairOrderValue($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
                < CardComparator.pairOrderValue($1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        for (lo, hi) in zip(ordered, ordered.dropFirst()) {
            guard CardComparator.areAdjacentPairRanks(lo, hi,
                                                       trumpSuit: trumpSuit, trumpRank: trumpRank)
            else { return nil }
        }
        guard let highCard = ordered.last else { return nil }
        return TractorInfo(pairCount: pairCount, highCard: highCard)
    }

    private static func pairRepresentative(of cards: [Card], trumpSuit: Suit?,
                                            trumpRank: Rank) -> Card? {
        guard cards.count == 2,
              pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                == pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return nil }
        return cards[0]
    }

    private static func weakerPair(_ a: [Card], than b: [Card],
                                    trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aRep = pairRepresentative(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bRep = pairRepresentative(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aRep, than: bRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakerTractor(_ a: [Card], than b: [Card],
                                       trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aInfo = tractorInfo(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bInfo = tractorInfo(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aInfo.highCard, than: bInfo.highCard,
                          trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    private static func weakestCards(from cards: [Card], count: Int,
                                      trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        Array(cards.sorted {
            discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    /// 优先选无分牌（pointValue==0），再选分牌，同组内按 discardOrder 排序
    /// 用于吊主时非末位出牌，避免把分牌送给后手截胡
    private static func weakestNonPointFirst(from cards: [Card], count: Int,
                                              trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        let nonPoint = cards.filter { $0.pointValue == 0 }
        let point    = cards.filter { $0.pointValue > 0 }
        let sorted   = nonPoint.sorted { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                     + point.sorted    { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
        return Array(sorted.prefix(count))
    }

    private static func partnerSupportCards(from cards: [Card], count: Int,
                                             trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.sorted {
            partnerSupportOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    private static func weakerCard(_ a: Card, than b: Card,
                                    trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        CardComparator.beats(b, a, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    static func discardOrder(_ a: Card, before b: Card,
                              trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        let aT = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aT != bT { return !aT }
        if aT {
            return CardComparator.trumpWeight(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
                 < CardComparator.trumpWeight(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if a.pointValue != b.pointValue { return a.pointValue < b.pointValue }
        return a.rank.rawValue < b.rank.rawValue
    }

    private static func partnerSupportOrder(_ a: Card, before b: Card,
                                             trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        if a.pointValue != b.pointValue { return a.pointValue > b.pointValue }
        let aT = CardComparator.isTrump(a, trumpSuit: trumpSuit, trumpRank: trumpRank)
        let bT = CardComparator.isTrump(b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        if aT != bT { return !aT }
        return discardOrder(a, before: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    /// 领出用散牌候选：返回手中真正"孤张"（无对子搭档）的指定类型牌，按 weakest 排序
    /// - isTrump: true=只看主牌, false=只看非主牌
    /// - pointOnly: true=只含分牌, false=只含无分牌, nil=不限
    private static func leadableSingletons(from hand: [Card], isTrump: Bool, pointOnly: Bool?,
                                            trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        // 计算配对 ID（同一 pairKey 有 ≥2 张）
        var pairGroupMap: [String: [Card]] = [:]
        for card in hand {
            pairGroupMap[CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank),
                         default: []].append(card)
        }
        let pairedIDs = Set(pairGroupMap.values.filter { $0.count >= 2 }.flatMap { $0 }.map { $0.id })

        return hand.filter { card in
            let t = CardComparator.isTrump(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
            guard t == isTrump else { return false }
            guard !pairedIDs.contains(card.id) else { return false }   // 排除有对子搭档的牌
            if let wantPoint = pointOnly { return wantPoint ? card.pointValue > 0 : card.pointValue == 0 }
            return true
        }.sorted { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
    }

    /// 在主牌中找最弱对子；nonPointFirst=true 时优先选无分对子
    private static func findWeakestTrumpPair(in hand: [Card], nonPointFirst: Bool,
                                              trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        let trumpPairs = pairs(in: hand.filter {
            CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }, trumpSuit: trumpSuit, trumpRank: trumpRank)
        guard !trumpPairs.isEmpty else { return nil }

        let sorted = trumpPairs.sorted { a, b in
            if nonPointFirst && a[0].pointValue != b[0].pointValue {
                return a[0].pointValue < b[0].pointValue   // 无分对子优先
            }
            return weakerPair(a, than: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        return sorted.first
    }

    private static func findPair(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        var seen: [String: [Card]] = [:]
        for card in hand {
            seen[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        let p = seen.filter {
            $0.value.count >= 2
                && !CardComparator.isTrump($0.value[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
        }
        if let best = p.max(by: { a, b in a.value[0].rank < b.value[0].rank }) {
            return Array(best.value.prefix(2))
        }
        return nil
    }

    private static func findTractor(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
        for suit in Suit.allCases {
            let suitCards = hand.filter {
                $0.suit == suit
                    && !CardComparator.isTrump($0, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }
            let candidates = tractors(in: suitCards, pairCount: 2,
                                      trumpSuit: trumpSuit, trumpRank: trumpRank)
            if let strongest = candidates.sorted(by: {
                weakerTractor($0, than: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
            }).last { return strongest }
        }
        return nil
    }

    private static func pairKey(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> String {
        CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }
}
