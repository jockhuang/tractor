import Foundation

// MARK: - AIPlayer 跟牌策略（结构性拆分，逻辑未改）

extension AIPlayer {


    // MARK: - 跟牌策略

    static func followCards(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let baseline = followCardsRuleBased(
            leadCards: leadCards, hand: hand, position: position,
            state: state, evaluator: evaluator, ctx: ctx
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

        let exposureFilteredLegal = filterUnsafeSecondHandTrumpPointExposure(
            legal,
            leadCards: leadCards,
            hand: hand,
            position: position,
            state: state,
            evaluator: evaluator,
            ctx: ctx
        )
        let trumpControlFilteredLegal = filterTrumpControlMoves(
            exposureFilteredLegal,
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

        // 确定性战术识别层：判断本手属于常规 / 守分 / 抢分 / 逼牌 / 安全垫牌，
        // 据此（1）裁掉违背战术的候选，（2）让 Monte Carlo 切换目标函数。
        let mode = detectTacticalMode(
            position: position, hand: hand, state: state,
            evaluator: evaluator, legalMoves: filteredLegal, ctx: ctx
        )
        let tacticalLegal = tacticalCandidateFilter(
            filteredLegal, mode: mode, hand: hand, position: position,
            state: state, evaluator: evaluator, ctx: ctx
        )

        let ranked = tacticalLegal.sorted {
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
            mode: mode,
            heuristicScore: {
                scoreFollow($0, leadCards: leadCards, hand: hand, position: position,
                            state: state, evaluator: evaluator, ctx: ctx)
            }
        )?.cards ?? ranked.first?.cards ?? baseline
    }


    static func followCardsRuleBased(
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [Card] {
        let ts = state.trumpSuit
        let tr = state.trumpRank
        let count = leadCards.count

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
                state: state,
                evaluator: evaluator,
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
                state: state,
                evaluator: evaluator,
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
                state: state, evaluator: evaluator,
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
                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                                state: state, position: position, evaluator: evaluator, fullHand: hand
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
                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                                state: state, position: position, evaluator: evaluator, fullHand: hand
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
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                            state: state, position: position, evaluator: evaluator, fullHand: hand
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
    static func voidFillCards(
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
                    ctx: ctx,
                    state: state,
                    position: position,
                    evaluator: evaluator,
                    fullHand: hand
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
                            ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                            state: state, position: position, evaluator: evaluator, fullHand: hand
                        )
                    }
                    return Array(result.prefix(remaining))
                }
                // 无主牌可将吃：安全垫牌（不送分）
                return smartDiscard(
                    from: extra, count: remaining,
                    enemyWinning: true,
                    ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                    state: state, position: position, evaluator: evaluator, fullHand: hand
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
                    myTeam: position.team, ctx: ctx,
                    state: state, position: position, evaluator: evaluator, fullHand: hand
                )
            }
            return trickSecure
                ? safePartnerCards(from: extra, count: remaining, trumpSuit: ts, trumpRank: tr, ctx: ctx)
                : smartDiscard(
                    from: extra, count: remaining,
                    enemyWinning: true,
                    ts: ts, tr: tr,
                    myTeam: position.team, ctx: ctx,
                    state: state, position: position, evaluator: evaluator, fullHand: hand
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
                                myTeam: position.team, ctx: ctx,
                                state: state, position: position, evaluator: evaluator, fullHand: hand
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
                        myTeam: position.team, ctx: ctx,
                        state: state, position: position, evaluator: evaluator, fullHand: hand
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
                            myTeam: position.team, ctx: ctx,
                            state: state, position: position, evaluator: evaluator, fullHand: hand
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
            myTeam: position.team, ctx: ctx,
            state: state, position: position, evaluator: evaluator, fullHand: hand
        )
    }


    // MARK: - 智能垫牌（利用对手绝牌信息，保留对子，避免垫主牌）

    /// 选出 count 张要垫的牌：
    /// - 优先垫散牌（避免拆对子）
    /// - 非主牌优先于主牌（尽量不垫主）
    /// - 敌方赢时避免垫分牌
    static func smartDiscard(
        from cards: [Card],
        count: Int,
        enemyWinning: Bool,
        ts: Suit?,
        tr: Rank,
        myTeam: Int,
        ctx: AIContext,
        state: GameState? = nil,
        position: PlayerPosition? = nil,
        evaluator: TrickEvaluator? = nil,
        fullHand: [Card]? = nil
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

        if enemyWinning {
            let ordered = cards.sorted { a, b in
                if let state, let position, let evaluator {
                    let handForCost = fullHand ?? cards
                    let trickContext = TrickContext(
                        position: position,
                        hand: handForCost,
                        state: state,
                        evaluator: evaluator,
                        memory: ctx
                    )
                    let ac = discardCost(card: a, hand: handForCost, gameState: state, trickContext: trickContext)
                    let bc = discardCost(card: b, hand: handForCost, gameState: state, trickContext: trickContext)
                    if ac != bc { return ac < bc }
                } else if a.pointValue != b.pointValue {
                    return a.pointValue < b.pointValue
                }
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                let pa = isPaired(a), pb = isPaired(b)
                if pa != pb { return !pa }
                return discardOrder(a, before: b, trumpSuit: ts, trumpRank: tr)
            }
            return Array(ordered.prefix(count))
        }

        let partnerTrickContext: TrickContext? = {
            guard let state, let position, let evaluator else { return nil }
            return TrickContext(position: position, hand: fullHand ?? cards, state: state,
                                evaluator: evaluator, memory: ctx)
        }()

        func partnerDiscardScore(_ group: [Card]) -> Double? {
            guard let state, let trickContext = partnerTrickContext else { return nil }
            let handForCost = fullHand ?? cards
            return partnerWonDiscardScore(
                candidate: CardCombination(
                    cards: group,
                    pattern: playPattern(for: group, ts: ts, tr: tr)
                ),
                hand: handForCost,
                gameState: state,
                trickContext: trickContext
            )
        }

        // 队友赢时按未来处置风险排序：安全可兑现的分牌晚于小副牌等未来输张。
        let singletons = cards
            .filter { !isPaired($0) }
            .sorted { a, b in
                if let aScore = partnerDiscardScore([a]), let bScore = partnerDiscardScore([b]),
                   aScore != bScore { return aScore > bScore }
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                return discardOrder(a, before: b, trumpSuit: ts, trumpRank: tr)
            }

        // 对子仍整组处理，但同样先比较未来风险而不是即时分值。
        let pairedGroups = pairGroupMap.values
            .filter { $0.count >= 2 }
            .sorted { a, b in
                let aPair = Array(a.prefix(2)), bPair = Array(b.prefix(2))
                if let aScore = partnerDiscardScore(aPair), let bScore = partnerDiscardScore(bPair),
                   aScore != bScore { return aScore > bScore }
                let ta = tier(a[0]), tb = tier(b[0])
                if ta != tb { return ta < tb }
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

    static func followTractor(
        leadTractor: TractorInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        state: GameState,
        evaluator: TrickEvaluator,
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
                              myTeam: position.team, ctx: ctx,
                              state: state, position: position, evaluator: evaluator, fullHand: hand))
            : smartDiscard(from: rest, count: count - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx,
                           state: state, position: position, evaluator: evaluator, fullHand: hand)
        return suitCards + extra
    }


    static func followPair(
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        trumpSuit: Suit?,
        trumpRank: Rank,
        position: PlayerPosition,
        leadSuit: Suit?,
        trickPoints: Int,
        state: GameState,
        evaluator: TrickEvaluator,
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
                              myTeam: position.team, ctx: ctx,
                              state: state, position: position, evaluator: evaluator, fullHand: hand))
            : smartDiscard(from: rest, count: 2 - suitCards.count,
                           enemyWinning: true,
                           ts: trumpSuit, tr: trumpRank,
                           myTeam: position.team, ctx: ctx,
                           state: state, position: position, evaluator: evaluator, fullHand: hand)
        return suitCards + extra
    }


    static func generateFollowCandidates(
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
                                                ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                                                state: state, position: position, evaluator: evaluator, fullHand: hand),
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


    /// P2 跟吊主时，限制对象是 Point Exposure，不是 Trump Strength：
    /// 后手仍有未知对手且本墩未锁定时，不把主 5/10/K 裸送进 0 分墩；
    /// 无分大主仍交给 Trump Control / leadControlNeed 评分决定是否值得抢出牌权。
    static func filterUnsafeSecondHandTrumpPointExposure(
        _ moves: [AIMove],
        leadCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        state: GameState,
        evaluator: TrickEvaluator,
        ctx: AIContext
    ) -> [AIMove] {
        guard moves.count > 1,
              evaluator.dominantSuit(of: leadCards) == nil,
              state.currentTrick.plays.count == 1 else { return moves }

        let futureUnknownOpponents = unplayedSubsequentPositions(after: position, in: state)
            .filter { $0.team != position.team && !ctx.isVoid($0, key: "TRUMP") }
        guard !futureUnknownOpponents.isEmpty else { return moves }

        let trickPoints = state.currentTrick.plays.flatMap(\.cards).reduce(0) { $0 + $1.pointValue }
        guard trickPoints == 0 else { return moves }

        let nonRisky = moves.filter { move in
            let playedPoints = move.cards.reduce(0) { $0 + $1.pointValue }
            if playedPoints == 0 { return true }
            guard candidateWinsTrick(move.cards, position: position, state: state, evaluator: evaluator),
                  let highTrump = move.cards
                    .filter({ CardComparator.isTrump($0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank) })
                    .max(by: {
                        CardComparator.beats($1, $0, trumpSuit: state.trumpSuit, trumpRank: state.trumpRank)
                    }) else { return false }
            return noUnknownHigherTrumpThan(highTrump, hand: hand, ts: state.trumpSuit, tr: state.trumpRank, ctx: ctx)
        }
        return nonRisky.isEmpty ? moves : nonRisky
    }


    /// 统一生成所有“可能花主牌控墩”的跟牌候选。
    /// 覆盖：跟主、绝门将吃、盖吃对手将牌、队友未稳时接管、为续手计划抢回出牌权。
    static func generateTrumpControlCandidates(
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
                    ctx: ctx,
                    state: state,
                    position: position,
                    evaluator: evaluator,
                    fullHand: hand
                )
                add(withRequiredSuit([card] + fill))
            }
        }

        return moves
    }


    static func findRuffWinningMoves(
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


    static func filterTrumpControlMoves(
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


    static func filterRequiredRuffMoves(
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
    static func filterTrumpPullPointContest(
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


    static func filterHighInitiativeWinningMoves(
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

        let secondHandTrumpPull = state.currentTrick.leadCards.map {
            isSecondHandTrumpPull(
                leadCards: $0,
                position: position,
                state: state,
                evaluator: evaluator,
                ctx: ctx
            )
        } ?? false

        let lowCostWinning = moves.filter {
            guard candidateWinsTrick($0.cards, position: position, state: state, evaluator: evaluator),
                  moveCardCost($0.cards, hand: hand, state: state, ctx: ctx) <= 45,
                  structureBreakPenalty(cards: $0.cards, hand: hand, ts: state.trumpSuit, tr: state.trumpRank) == 0 else {
                return false
            }

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
                if secondHandTrumpPull {
                    let playedPoints = $0.cards.reduce(0) { $0 + $1.pointValue }
                    let exposureRisk = secondHandTrumpPointExposureRisk(
                        $0,
                        hand: hand,
                        position: position,
                        state: state,
                        evaluator: evaluator,
                        ctx: ctx
                    )
                    let winConfidence = secondHandTrumpWinConfidence(
                        $0,
                        hand: hand,
                        position: position,
                        state: state,
                        evaluator: evaluator,
                        ctx: ctx
                    )
                    return decision.classification != .passiveTrump
                        && decision.score > 0
                        && leadControlNeed(position: position, hand: hand, state: state, ctx: ctx) >= 5.0
                        && winConfidence >= 0.62
                        && (playedPoints == 0 || exposureRisk <= 0.05)
                }
                guard !containsBigTrump($0.cards, ts: state.trumpSuit, tr: state.trumpRank) else {
                    return false
                }
                return decision.classification != .passiveTrump && decision.score > 0
            }
            return true
        }

        return lowCostWinning.isEmpty ? moves : lowCostWinning
    }


    // MARK: - 甩牌跟牌

    /// 跟甩牌：有同花色正常出弱牌；无同花色时只在能组成匹配将牌结构时才出主，否则垫非主牌
    static func followSlam(
        slam: TrickEvaluator.SlamInfo,
        winningCards: [Card],
        partnerWinning: Bool,
        suitCards: [Card],
        hand: [Card],
        position: PlayerPosition,
        count: Int,
        ts: Suit?, tr: Rank,
        ctx: AIContext,
        state: GameState,
        evaluator: TrickEvaluator,
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
                           ts: ts, tr: tr, myTeam: position.team, ctx: ctx,
                           state: state, position: position, evaluator: evaluator, fullHand: hand)
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
    static func buildMatchingSlamTrump(
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


    static func pairedCardIDs(in cards: [Card], trumpSuit: Suit?, trumpRank: Rank) -> Set<UUID> {
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
    static func safePartnerCards(
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


    // MARK: - Utility Helpers（与原版一致）

    /// 从同花色牌中按结构优先选出 neededPairs*2 张牌：
    /// 连对优先 → 孤立对子 → 散牌，避免出弱牌时拆散对子
    ///
    /// - partnerWinning: 队友赢时为 true，此时孤立对子和散牌优先选分多的（加分给队友）
    static func structuredSuitFollowCards(
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
}
