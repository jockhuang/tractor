import Foundation

// MARK: - AI Game Memory（从已出的牌推导）

struct AIContext {

    let playedCards: [Card]
    let knownCards: [Card]
    let knownCardsByPlayer: [PlayerPosition: [Card]]
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
        let playedIDs = Set(played.map(\.id))
        var knownByPlayer: [PlayerPosition: [Card]] = [:]
        for event in state.declarationEvents {
            let unplayedRevealed = event.revealedCards.filter { !playedIDs.contains($0.id) }
            guard !unplayedRevealed.isEmpty else { continue }
            knownByPlayer[event.declarer, default: []].append(contentsOf: unplayedRevealed)
        }
        let known = played + knownByPlayer.values.flatMap { $0 }
        let isLast = state.currentTrick.plays.count == 3
        return AIContext(
            playedCards: played,
            knownCards: known,
            knownCardsByPlayer: knownByPlayer,
            voidSuits: voids,
            isLastPlayer: isLast
        )
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

// MARK: - TrickContext（一墩决策的公共上下文）

/// 聚合一墩出牌决策中反复传递的参数（位置 / 手牌 / 状态 / 评估器 / AI 记忆），
/// 并提供常用派生量（先手花色、本墩分、当前赢家、是否末手等）。
/// 纯聚合 / 派生，不改变任何算法逻辑——用于减少各处重复的参数与重复计算。
struct TrickContext {
    let position: PlayerPosition
    let hand: [Card]
    let state: GameState
    let evaluator: TrickEvaluator
    /// 从已出牌推导的 AI 记忆（原各处的 `ctx` 参数）。
    let memory: AIContext

    let trumpSuit: Suit?
    let trumpRank: Rank
    /// 本墩先手牌；为空表示本墩由我方先手（尚无人出牌）。
    let leadCards: [Card]

    init(
        position: PlayerPosition,
        hand: [Card],
        state: GameState,
        evaluator: TrickEvaluator,
        memory: AIContext
    ) {
        self.position = position
        self.hand = hand
        self.state = state
        self.evaluator = evaluator
        self.memory = memory
        self.trumpSuit = state.trumpSuit
        self.trumpRank = state.trumpRank
        self.leadCards = state.currentTrick.leadCards ?? []
    }

    /// 本墩是否由本玩家先手（当前墩还没有人出牌）。
    var isLeading: Bool { state.currentTrick.plays.isEmpty }

    /// 先手逻辑花色；先手为主牌或我方先手时为 nil。
    var leadSuit: Suit? { leadCards.isEmpty ? nil : evaluator.dominantSuit(of: leadCards) }

    /// 本墩当前已累计的分数。
    var trickPoints: Int {
        state.currentTrick.plays.flatMap { $0.cards }.reduce(0) { $0 + $1.pointValue }
    }

    /// 本墩当前赢家；尚无人出牌时为 nil。
    var currentWinner: PlayerPosition? {
        state.currentTrick.plays.isEmpty ? nil : evaluator.winner(of: state.currentTrick)
    }

    /// 当前赢家是否为队友。
    var partnerWinning: Bool { currentWinner.map { $0.team == position.team } ?? false }

    /// 当前赢家是否为对手。
    var opponentWinning: Bool { currentWinner.map { $0.team != position.team } ?? false }

    /// 本墩在我之后仍未出牌的玩家（顺时针）。
    var subsequentPositions: [PlayerPosition] {
        AIPlayer.unplayedSubsequentPositions(after: position, in: state)
    }

    /// 我是否为本墩最后一个出牌者（已有 3 家出牌）。
    var isLastPlayer: Bool { state.currentTrick.plays.count == 3 }

    /// 我是否为本队在本墩的最后一个有效出手机会（后手没有队友）。
    var isLastEffectiveChanceForTeam: Bool {
        !subsequentPositions.contains { $0.team == position.team }
    }
}

// MARK: - AIPlayer

struct AIPlayer {

    struct TractorInfo {
        let pairCount: Int
        let highCard: Card
    }

    enum MoveKind {
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

    enum FollowWinClass {
        case finalWin
        case temporaryWin
        case cannotWin
    }

    enum TrumpControlClass {
        case secureWinner
        case contestingTrump
        case passiveTrump
    }

    struct TrumpControlDecision {
        let classification: TrumpControlClass
        let score: Double
        let leadControlValue: Double
        let cost: Double
    }

    struct AIMove {
        let cards: [Card]
        let kind: MoveKind
    }

    enum LeadAssetTier: Int {
        case cashingWinner = 1
        case safeControlGroup = 2
        case strongStructure = 3
        case initiativeBuilder = 4
        case weakDisposal = 5
    }

    struct LeadAsset {
        let move: AIMove
        let tier: LeadAssetTier
        let score: Double
    }

    struct CardCombination {
        let cards: [Card]
        let pattern: PlayPattern
    }

    struct EndgameControlAsset {
        let combination: CardCombination
        let winProbability: Double
        let trickCountCovered: Int
        let bottomPointCapturePotential: Int
        let structureBreakCost: Double
        let isTrumpBased: Bool
        let isStructureBased: Bool
    }

    static let monteCarloTopMoveCount = 5
    static let monteCarloSimulationCount = 24

    /// 点数暴露风险权重（Point Exposure Risk）。
    /// 「点数的价值在被谁拿走时才结算，而非打出时」——任何让本墩带分的走法，
    /// 都要按"对手最终赢墩概率"折算成风险减分：risk = 本墩总分 × P(对手赢墩) × 权重。
    /// 权重需与 followPointSwingScore 的量级（约 playedPoints × 5）相当，
    /// 才能在"是否把主 10/K 丢进未锁定墩"这类决策上起到决定性作用。
    static let pointExposureWeight = 4.5

    /// 「小主过渡 / Controlled Trump Transfer」最少主牌数：
    /// 先手资产分层已经保证它只在没有兑现/控制组/强结构资产时参与；
    /// 因此不要求主牌特别多，只要有足够主牌且不拆结构，就优先于随手领弱副牌。
    static let trumpTransferMinTrumpCount = 3

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

    // MARK: - 候选动作评分

    static func deduplicatedMoves(_ moves: [AIMove]) -> [AIMove] {
        var seen = Set<String>()
        var result: [AIMove] = []
        for move in moves where !move.cards.isEmpty {
            let key = moveKey(move.cards)
            if seen.insert(key).inserted {
                result.append(move)
            }
        }
        return result
    }

    static func moveKey(_ cards: [Card]) -> String {
        cards.map { $0.id.uuidString }.sorted().joined(separator: "|")
    }

    static func sameCardSet(_ lhs: [Card], _ rhs: [Card]) -> Bool {
        Set(lhs.map(\.id)) == Set(rhs.map(\.id))
    }

    // MARK: - Tactical Mode（战术模式：Monte Carlo 前的确定性识别层）

    /// 当前这一手的战术模式，决定 Monte Carlo 用哪一套目标函数。
    enum TacticalMode {
        case normal             // 常规：保留现有评分（保资产 / 控场 / 不浪费大主）
        case pointDenial        // 阻分：我是本队最后行动者且后面还有对手（无论本墩当前是否有分）
        case pointCapture       // 抢分：能赢下有分的墩
        case forceOpponentCost  // 逼牌：未必能赢，但可迫使后手对手付出更大代价
        case safeDiscard        // 安全垫牌：无分且无需争夺
    }

    /// 候选牌在「阻分（Point Denial）」下的分级，优先级 A > B > C > D。
    /// 目标层级：1 保住/守住本墩 → 2 阻止对手用分牌赢墩 → 3 逼对手付出更高成本 →
    ///          4 不追加不安全的分 → 5 仅在阻分满足后才考虑结构保留。
    enum PointDenialClass: Int {
        case secureWinner   = 0   // A：能确定守住本墩（我方稳赢）
        case strongContest  = 1   // B：未必赢，但显著抬高对手赢墩成本，且不追加分牌
        case passive        = 2   // C：既不赢也不送分，对阻分没有实质帮助
        case riskyExposure  = 3   // D：往一个未锁定的墩里再加分牌（K/10/5 / 拆分对子）
    }

    static func handAfterPlaying(_ cards: [Card], from hand: [Card]) -> [Card] {
        let usedIDs = Set(cards.map { $0.id })
        return hand.filter { !usedIDs.contains($0.id) }
    }

    static func cardStrength(_ card: Card, ts: Suit?, tr: Rank) -> Int {
        CardComparator.isTrump(card, trumpSuit: ts, trumpRank: tr)
            ? CardComparator.trumpWeight(card, trumpSuit: ts, trumpRank: tr)
            : card.rank.rawValue
    }

    static func sameFace(_ a: Card, _ b: Card) -> Bool {
        a.suit == b.suit && a.rank == b.rank
    }

    /// 返回本墩中当前 position 之后、还未出牌的玩家列表（顺时针顺序）
    /// 用于判断"后手是否绝主"以决定是否可以安全加分
    static func unplayedSubsequentPositions(
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

    static func maxCard(in cards: [Card], ts: Suit?, tr: Rank) -> Card {
        cards.max { a, b in CardComparator.beats(b, a, trumpSuit: ts, trumpRank: tr) }!
    }

    static func tractors(in cards: [Card], pairCount: Int,
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

    static func pairs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [[Card]] {
        var grouped: [String: [Card]] = [:]
        for card in cards {
            grouped[pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank), default: []].append(card)
        }
        return grouped.values.compactMap { $0.count >= 2 ? Array($0.prefix(2)) : nil }
    }

    static func tractorInfo(of cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> TractorInfo? {
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

    static func pairRepresentative(of cards: [Card], trumpSuit: Suit?,
                                            trumpRank: Rank) -> Card? {
        guard cards.count == 2,
              pairKey(cards[0], trumpSuit: trumpSuit, trumpRank: trumpRank)
                == pairKey(cards[1], trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return nil }
        return cards[0]
    }

    static func weakerPair(_ a: [Card], than b: [Card],
                                    trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aRep = pairRepresentative(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bRep = pairRepresentative(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aRep, than: bRep, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    static func weakerTractor(_ a: [Card], than b: [Card],
                                       trumpSuit: Suit?, trumpRank: Rank) -> Bool {
        guard let aInfo = tractorInfo(of: a, trumpSuit: trumpSuit, trumpRank: trumpRank),
              let bInfo = tractorInfo(of: b, trumpSuit: trumpSuit, trumpRank: trumpRank)
        else { return false }
        return weakerCard(aInfo.highCard, than: bInfo.highCard,
                          trumpSuit: trumpSuit, trumpRank: trumpRank)
    }

    static func weakestCards(from cards: [Card], count: Int,
                                      trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        Array(cards.sorted {
            discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    /// 优先选无分牌（pointValue==0），再选分牌，同组内按 discardOrder 排序
    /// 用于吊主时非末位出牌，避免把分牌送给后手截胡
    static func weakestNonPointFirst(from cards: [Card], count: Int,
                                              trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        let nonPoint = cards.filter { $0.pointValue == 0 }
        let point    = cards.filter { $0.pointValue > 0 }
        let sorted   = nonPoint.sorted { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
                     + point.sorted    { discardOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank) }
        return Array(sorted.prefix(count))
    }

    static func partnerSupportCards(from cards: [Card], count: Int,
                                             trumpSuit: Suit?, trumpRank: Rank) -> [Card] {
        guard count > 0 else { return [] }
        return Array(cards.sorted {
            partnerSupportOrder($0, before: $1, trumpSuit: trumpSuit, trumpRank: trumpRank)
        }.prefix(count))
    }

    static func weakerCard(_ a: Card, than b: Card,
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

    static func partnerSupportOrder(_ a: Card, before b: Card,
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
    static func leadableSingletons(from hand: [Card], isTrump: Bool, pointOnly: Bool?,
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
    static func findWeakestTrumpPair(in hand: [Card], nonPointFirst: Bool,
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

    static func findPair(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
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

    static func findTractor(in hand: [Card], trumpSuit: Suit?, trumpRank: Rank) -> [Card]? {
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

    static func pairKey(_ card: Card, trumpSuit: Suit?, trumpRank: Rank) -> String {
        CardComparator.pairKey(card, trumpSuit: trumpSuit, trumpRank: trumpRank)
    }
}
