# Tractor (拖拉机) iOS 游戏 — 代码库知识库

## 项目概述

iOS 拖拉机升级游戏，4 人（1 真人 + 3 AI），Swift/SwiftUI 实现，支持局域网联机。

- **平台**：iOS (SwiftUI)
- **架构**：MVVM，`GameEngine` 为核心控制器
- **文件位置**：`Tractor/Tractor/`

---

## 目录结构

```
Models/
  Card.swift        — Suit, Rank, Card, PlayPattern, GamePhase, Trick, GameState
  Player.swift      — PlayerPosition, Player
  Deck.swift        — 牌组生成

Engine/
  CardComparator.swift   — 牌力比较、主牌判断、排序
  TrickEvaluator.swift   — 跟牌合法性、赢家判断
  AIPlayer.swift         — AI 出牌决策
  GameEngine.swift       — 游戏主循环、状态机
  LANMultiplayerManager.swift — 局域网联机

Views/
  GameBoardView.swift, PlayerHandView.swift, CardView.swift, ...
```

---

## 核心模型

### Suit / Rank / Card
- `Suit`: ♠ ♥ ♦ ♣（Joker 的 suit = nil）
- `Rank`: 2–A, smallJoker=20, bigJoker=21
- 得分牌：5 → 5分，10/K → 10分

### PlayerPosition
- `.south`（真人） / `.west` / `.north` / `.east`（AI）
- 队伍：`team = rawValue % 2`，即 south+north = team 0（庄方），west+east = team 1（攻方）

---

## 出牌规则（TrickEvaluator）

### 主牌判断（CardComparator.isTrump）
满足任意一条即为**主牌（trump）**：
1. Joker（大王 / 小王）
2. rank == trumpRank（级牌，无论花色）
3. suit == trumpSuit（主花色的非级牌）

### 主牌内部大小（trumpWeight）
```
大王 = 100 > 小王 = 90 > 主花色级牌 = 80 > 非主花色级牌 = 70 > 主花色普通牌（按rank）
```

### 跟牌合法性（isValidPlay）
1. 出牌数量必须等于先手张数
2. 确定先手「逻辑花色」（主牌统一为 nil，其他按实际花色）
3. 必须出尽可能多的同花色牌（同花色不足时全出，其余随意）
4. 同花色足够时，还需满足结构优先级：
   - **先手出连对（N 对）**：同花色中先贡献最多的连对对数，再贡献最多的孤立对子数，剩余才用散牌
   - **先手出对子**：同花色中有对子就必须出对子，不足一对才可以出散牌
   - **先手出单牌**：有同花色必须出同花色，无额外结构要求
5. 手中无同花色 → 可随意出牌

> 实现细节：`tractorPairCount` 统计属于连续序列（≥2对相邻对子）的对子总对数；`isolatedPairCount` 统计不属于任何连续序列的孤立对子数。两者共同决定跟连对时的最低合法要求。

### 甩牌（Slam Lead）
领出者可将同一逻辑花色中 2 张及以上不构成纯连对/纯对子的牌一起甩出（混合单张、对子、连对均可）。

**甩牌合法性检测**（`TrickEvaluator.slamInfo`）：
- 拆解为连对组件 + 对子组件 + 单张组件（`decomposeSlam`）
- 检查其余三家手中是否有**同类型且更大**的牌张：
  - 甩牌含单张 → 三家不能有大于该单张的单张
  - 甩牌含对子 → 三家不能有大于该对子的对子
  - 甩牌含连对 → 三家不能有大于该连对的连对

**甩牌失败后果**（`GameEngine.analyzeSlamLead`）：
- 每张失败的牌罚 10 分（从甩牌方所在队扣除）
- 有大牌的对手被标记为「强制出牌」（`state.forcedFollowCards`），跟牌时必须包含其中的强制牌
- 若对手同时有大于单张和大于对子的牌，自动取张数最多的一类强制出（正式规则应由下家指定，TODO）
- 强制跟牌在每墩结束时清除

### 赢家判断（winner / beatsPlay）
压牌严格按以下优先级判断：
1. **组合类型资格**（最优先）：垫牌（不满足组合要求的跟牌）无法压任何牌
   - 先手连对 → 跟牌必须是相同对数的连对，否则为垫牌
   - 先手对子 → 跟牌必须是对子（主牌单张也不能压副牌对子），否则为垫牌
   - 先手单牌/甩牌 → 无额外组合要求
2. **将牌 > 副牌**（同组合类型内）：主牌连对/对子/单张 > 同组合类型的副牌
3. **同类型比大小**：比最高牌点数；同大小先出者胜

> 甩牌未被将吃时，甩牌者为大（无人打出主牌则先手始终是赢家）

> 将吃甩牌的第一必要条件：出的牌**全部**是主牌（`cards.allSatisfy { cardSuit($0) == nil }`）

**甩牌时多家出主牌的比较**（`slamTrumpBeats`）：
比较层级由**领出甩牌的结构**决定，而非固定优先级：
- 领出含连对 → 先比最高连对（对数多者优先，同对数比最高牌），再比对子，再比单张
- 领出含对子（无连对）→ 先比最高对子，再比单张
- 领出纯散牌 → 仅比最高单张

> 例：北甩 Q♥10♥（纯散牌），东出 ♣3♣3，南出大王+主K → 领出无对子，只比最高单张：大王(100) > ♣3(70) → 南赢

**亮主规则**：
- **第 1 局**：亮主者成为庄家（`applyDeclaration` 调用 `setDealer`，反主可覆盖）
- **第 2 局起**：庄家在 `startNewRound` 开始时由上局结果一次性确定，亮主**只更新主花色**，不得再调用 `setDealer`
- 判断依据：`state.roundNumber == 0`（`resolveRound` 结束时自增，`startNewGame` 重置为 0；发牌期间第 1 局 roundNumber 始终为 0）

**庄家轮换规则**（`resolveRound`）：
- 攻方胜：新庄家 = 当前庄家顺时针下一位（`nextPosition(after:)`）
- 守方胜：新庄家 = 当前庄家的搭档（`(rawValue + 2) % 4`），**无论第几局都轮换**
  - ⚠️ 切勿加 `roundNumber > N` 之类的条件保护，每次守方赢都必须设置 `pendingDealerPosition`

---

## AI 出牌优先级（AIPlayer）

### Point-Centric Strategy（点数优先）

AI 的首要目标是最终得分结果，而不是单纯赢墩数量或保留牌型资源。

所有战略决策都以预期分差为第一口径：

1. 预期己方得分
2. 预期拒绝对手得分
3. 拿墩安全
4. 出牌权控制
5. 结构与主牌保全

赢下 25 分墩的价值远高于赢多个空墩。`leadAssetScore` / `scoreFollow` / `trumpControlDecision` / `simulateCurrentTrick` 都应围绕 expected point swing 评分；当分差收益足够大时，可以牺牲对子、连对、主牌和控制牌保全。

### 决策流程（chooseCards）

AI 已不再走单一固定优先级表。无论先手还是跟牌，都走同一套三段式流程：

1. **生成候选**：多个生成器各自提出合理走法（`AIMove` = 牌 + `MoveKind` 标签）；并始终加入一个规则基线走法作兜底。
2. **启发式打分**：先手用 `leadAssetScore` 在当前资产层内部排序；跟牌用 `scoreFollow` 给候选打分。
3. **蒙特卡洛模拟**：取分数最高的前 `monteCarloTopMoveCount`（=5）个候选，各模拟 `monteCarloSimulationCount`（=24）次对未知手牌的随机抽样对局，选综合分（模拟均分 + 启发式分 × 0.03）最高者出牌。

`chooseCards`：当前墩无人出牌则先手，否则跟牌；甩牌失败的强制跟牌牌（`forcedCards`）跳过整套流程直接走规则路径。

### AI 记忆（AIContext）

每次决策从 `completedTricks` + 当前墩构建一次，记录：

- `playedCards`：本局已见的所有牌
- `voidSuits`：每个玩家已暴露绝掉的逻辑花色（没跟上该花色）
- `isLastPlayer`：本墩 AI 是否最后一手

派生判断：`isEffectivelyBiggest`（双副牌中所有更大同花色牌已出完）、`manyBigTrumpsRemain`、`unplayedSuitPoints`、`allEnemiesVoid` / `voidEnemies`。

### 先手资产分层（leadCards）

先手不再把 Pair First / Tractor First / Slam Bonus / Absolute Winner Bonus 等局部规则堆到同一个候选池里互相抢分。`leadCards` 先把走法包装成 `LeadAsset`，按资产类别选择当前最该兑现的一层，再只在该层内部排序和 Monte Carlo。

资产层级：

1. **Cashing Time-Sensitive Winners**：旁门 A、已知最大副牌单张、已知最大副牌对子、安全旁门控制组。它们会随敌方绝门而贬值，应尽早兑现。
2. **Safe Slam / Control Groups**：安全甩牌或完整控制组，按整体评估；若存在 AKK / AAKK 这类组合，会压制其子走法，避免拆成 A、KK、AA、KK 分别比较。
3. **Strong Structures**：拖拉机、级牌对、王对、强主对、强副牌对。它们是稳定控制资产，优先作为结构使用。
4. **Initiative Building**：没有更高价值资产需要兑现时，才考虑队友垫分计划、长门发展、受控吊主、小主过渡。
5. **Weak Disposal**：弱单、弱对、低价值清理。只有更高层资产都不存在时才进入选择。

| 生成器 | 提出的走法 |
|---|---|
| `buildLeadAssets` | 汇总全部先手资产，去重，并保留每组牌的最高资产层级 |
| `findSlamLeadCandidates` | 无法被压制的甩牌 / 控制组；安全组合会压制其子走法 |
| `findAbsoluteSideWinnerLeadCandidates` | 时效性副牌赢家：旁门 A、已知最大副牌单张、已知最大副牌对子；若属于安全控制组则不单独出 |
| `findTractorLeadCandidates` | 强结构层候选：所有逻辑花色中的合法拖拉机，跳过敌方已全绝的副花色 |
| `findStrongPairLeadCandidates` | 强结构层候选：A/级牌/王对子、强主对、K/10 对、分牌对子 |
| `findNoTrumpControlLeadCandidates` | 无主局中的王/级牌/A 控制对子与连对 |
| `findPartnerDumpLeadCandidates` | 主动权建设：队友已绝且仍有未出分牌的花色——领出让队友垫分 |
| `findLongSuitDevelopmentLeadCandidates` | 主动权建设：无兑现资产时发展长门 |
| `findTrumpLeadCandidates` / `findTrumpTransferLeadCandidates` | 主动权建设：受控吊主或低成本小主过渡；主牌不套用旁门兑现紧迫性。小主过渡门槛为主牌 ≥3 且不拆结构 |
| `findWeakLeadCandidates` / `findWeakPairDisposalLeadCandidates` | 弱处置层：弱单、弱对、低价值清理 |

`selectLeadAssetPool` 只取当前存在的最高资产层级进入 Monte Carlo。这样旁门 A 不会再被普通对子挤掉，AKK / AAKK 不会被拆成局部候选互相比较，普通对子只在弱处置层参与。Tier 4 内部若没有队友垫分计划且存在合法小主过渡，只让小主过渡进入模拟，避免空档期随手领弱副牌。

### 先手打分——点数优先的资产评分（leadAssetScore）

先手路径由 `leadAssetScore` 在资产层内部排序；跨层级优先级只由 `LeadAssetTier` 决定。若同层同分，只用 `leadAssetTieBreakScore` 按点数、安全性、张数和清门做稳定决胜，不再回落到旧的局部 bonus 评分。

`leadAssetScore` 的核心原则：

- 时效性旁门赢家先兑现，不把旁门 A 的紧迫性套到主牌控制牌上。
- 安全控制组按整体出牌评估，并压制其子候选。
- 结构保留是成本，不是绝对目标；只有当没有更高层资产需要兑现时才主导。
- 主动权建设低于实分兑现和稳定结构。
- 弱牌清理只作为兜底。

这套资产分层从结构上消除了原来的特例：

- **AKK / AAKK** 作为整体评估——`structureFragmentationCost` 让「从 AAKK 里抽 AA 出」付出拆拖拉机的代价，整出拖拉机则得 `wholeStructureControlValue`，因此不再被拆成 AA→KK。
- **拆任何对子**统一为 `pairAssetWeight` 的分级代价（强对/主对 0.9–1.0、K/10 0.7、分对 0.6、普通 0.4），不再是五个互相打架的惩罚。
- **旁门 A 攥太久**由 Tier 1 Cashing Time-Sensitive Winners 解决，而非临时的「兑现」规则。
- **先领非绝对赢的对子（再去出 A）**已避免：`wholeStructureControlValue` 只对「绝对赢」的结构给满额控制价值（`leadStructureDominant`，副牌用 `isEffectivelyBiggestPair`、主牌要大主/高主）。像 QQ（K/A 未现）这种非绝对赢的对子控制价值打到 ~30%，因此兑现一张稳赢的 A 会排在领一个「赌一把」的对子之前。
- **小主过渡**被放入主动权建设层；只有没有兑现/控制组/强结构资产时才参与比较。

安全甩牌 / 控制组作为 Tier 1 或 Tier 2 的整体资产评估；无主局对子/连对的 `wholeStructureControlValue` 更高。

### 先手合法性过滤（filterAllowedLeadAssets / allowTrumpLead）

资产生成后由 `filterAllowedLeadAssets` 过滤；主牌先手由 `allowTrumpLead` 把关。小主过渡可在 Tier 4 空档期通过；其他主牌早期一般不许领，除非手牌偏少（剩 ≤5 墩）、主牌多（≥8 张或 ≥4 张强主）、副牌比主牌还多、需保护的暴露分多、或主牌保对价值高。非主走法始终放行。

### 先手规则基线（leadCardsRuleBased）

旧版有序启发式保留为函数实现参考，但 `leadCards` 不再把它作为额外候选；真实先手选择由 `buildLeadAssets` 的资产分层驱动。

0. **甩牌**（`findSlamLead`）
1. **当前已是最大的非主牌**——优先对子，否则最大单张（跳过敌方全绝的花色）
2. **旁门 A**（`bestSideAce`）
3. **非主花色连对**（`findTractor`）
4. **引出队友垫分**——队友绝花色且该花色有未出分
5. **非主花色对子**（`findBestPairAvoidingVoid` → `findPair`）
6. **小主牌**——无分孤张优先，再任意孤张，再最弱主对
7. **主牌少（≤3）时**——改领最强副牌/副牌对
8. **最弱牌**（最终兜底）

**AI 甩牌判断**（`findSlamLead`）：

单张和对子分量用不同标准判断"无法被压制"：
- **单张最大**（`isEffectivelyBiggestSingle`）：所有更高 rank 在 played+hand ≥ 2（双副牌两张都已知晓，对手无法有更大单张）
- **对子最大**（`isEffectivelyBiggestPair`）：所有更高 rank 在 played+hand ≥ 1（对手至多 1 张，凑不成更大对子）

> 例：手中 A♠K♠K♠ → A 在手故外面最多 1 张 A，KK 是最大对子；A 是最大单张 → 合法甩牌
> 例：手中 A♠Q♠Q♠ 且有 K♠ → K/A 各有 ≥1 张已知晓，QQ 是最大对子 → 合法甩牌

已知对手绝该花色时，只有含对子的组合才甩（纯散牌送将吃毫无意义）。

### 跟牌策略（followCards）

**跟牌流程：** 与先手一致，走 候选生成 → 打分 → 蒙特卡洛：

1. 规则基线（`followCardsRuleBased`）+ 非主/结构候选（`generateFollowCandidates`）+ 统一主牌控墩候选（`generateTrumpControlCandidates`）。
2. 仅保留合法走法（`isValidPlay`），再过两道滤网：
   - `filterTrumpControlMoves`：所有花主牌的候选统一用 Trump Control Decision 分类；高分墩或高主动权需求时，若存在锁定/争墩主牌，会剔除被动主牌。
   - `filterHighInitiativeWinningMoves`：当急需主动权（`initiativeNeed` ≥ 100）时，若存在「便宜、不拆对子、不动大主」的取胜走法则只保留它们；主牌走法还必须在 Trump Control 下不是被动且得分为正。
3. 用 `scoreFollow` 打分，取前 5 名，再由蒙特卡洛择优。

甩牌失败的强制跟牌跳过整套流程。

**跟牌打分（scoreFollow）：**

`scoreFollow` 分为两类：

- **花主牌的走法**：统一走 Trump Control Decision（见下），不再分别在吊主、将吃、盖吃、队友保护、抢主动权里写零散规则。
- **非主走法**：走通用 `FollowWinClass` / `followWinClassScore`。锁定赢墩奖励最高，暂时赢墩按分数和送分风险折扣，无法赢时尽量垫 0 分牌。

主/非主都共享通用项：先计算 `followPointSwingScore`，安全时才奖励垫分、不安全垫分受罚、清门小奖、拆结构惩罚（`structureBreakPenalty` / `strongStructureBreakPenalty`）。拆结构惩罚会按 `pointPressureDamping` 随当前墩总分降低，确保 20–25 分争夺能压过保结构。`MoveKind` 微调：baseline +5、support +8（队友领先时）、discard +4（对手领先时），非主 win ±8/−12。

**统一主牌控墩模型（Trump Control Decision）：**

所有跟牌阶段“是否花主牌控墩”的判断都走同一个模型，核心问题是：这张主牌是否值得用来拿到、保住或抢回本墩控制权？

入口：

- `generateTrumpControlCandidates`：生成所有合法主牌控墩候选，包括跟主单/对/拖拉机、绝门将吃、盖吃对手将牌、甩牌匹配主牌结构。
- `filterTrumpControlMoves`：按 A/B/C 分类，在高分墩或高主动权需求时剔除被动主牌。
- `trumpControlDecision` / `trumpControlScore`：返回 `TrumpControlDecision`（分类、得分、主动权价值、主牌成本）。

候选分类（`TrumpControlClass`）：

- **A `secureWinner`**：能赢最终墩，不只是当前暂时领先。主牌用 `isSecureWinningTrumpFollow` 判断后手对手是否还能盖主/将吃。
- **B `contestingTrump`**：暂时能赢或能迫使对手花更高主，减少廉价拿分风险。
- **C `passiveTrump`**：花了主牌但不能赢、不能保墩、不能有效争墩。

决策输入：

- **当前墩分**：0 分可保守；5 分开始考虑争墩；10+ 分强烈偏向锁定/争墩；15+ 分若有 A/B，`filterTrumpControlMoves` 会剔除 C。
- **当前赢家**：对手赢时奖励 A/B，严罚装饰性小主；队友赢且已稳时不盖队友，未稳且有分时允许接管锁定。
- **最终安全性**：不把“当前领先”当作安全，后手对手仍可能盖主/将吃时只算 B。
- **主动权价值**：`trumpLeadControlValue` 基于出完该牌后的 `initiativeNeed`（上限 25），手里还有旁门 A、绝对赢家、对子/拖拉机/甩牌/长门计划时，赢下这一墩更值。
- **主牌成本**：`trumpControlCost` 对王、级牌、主 A、高主计成本；`trumpCostDamping` 在高分墩降低惜主权重，避免因为保主而送掉大分墩。拆主对/主拖拉机仍由共享结构惩罚处理。

因此旧的“小主默认跟出”回退顺序被替换为：需要且可行时出 Secure winner → 分数/主动权足够时出 Contesting trump → 低价值或已稳时才允许 Passive low trump。

**花色匹配规则：**
- 先找手中与先手同逻辑花色的牌（`suitCards`）
- 有足够同花色牌 → 尝试压牌；无法压牌 → 出最弱同花色牌（若队友赢则出支持牌）
- 同花色不够 → 先出所有同花色，剩余按策略补充

**跟牌子策略：**

| 先手类型 | 处理函数 | 逻辑 |
|---------|---------|------|
| 连对（拖拉机） | `followTractor` | 优先出能压赢的最弱连对；无则出最弱连对；无连对则出最弱牌 |
| 对子 | `followPair` | 优先出能压赢的最弱对子；无则出最弱对子；无对子则出最弱牌 |
| 单牌 | 内联逻辑 | 有能压赢的牌则出最弱能压赢的牌；若本门仍有可反超当前赢家的未出分牌且后手有对手未出，启用 `pointGuardCard`：本墩无分时出能压住分牌的最小牌，本墩已有分时优先出所有更大牌已知晓的最小牌（无安全牌则出最大候选）；否则出最弱牌 |

**队友赢时（partnerWinning）：**
- 有足够同花色牌时：通常出「支持牌」：优先出高分牌（10/K/5），其次出非主的弱牌（`partnerSupportOrder`）
- 跟单牌且本门仍有可反超当前赢家的未出分牌时，若后手还有对手未出，会用同门大牌接管保护本墩（`pointGuardCard`）；本墩已有分时会进一步判断外面是否还可能有更大牌，必要时用 A 等大牌而不是仅压住分牌
- 自己绝了领出花色时（`voidFillCards`）先调用 `bestTrumpControlFill`，由 Trump Control 判断是否值得用主牌填牌：
  - 接受正价值的 `secureWinner`，或 10+ 分 / 高主动权价值下的锁定主牌。
  - 对手赢且分数/主动权足够时，接受正价值的 `contestingTrump`。
  - 拒绝 `passiveTrump`，避免装饰性小主。
  - Trump Control 不接受时才回退到旧的保守垫牌/支持策略；`partnerAtRisk` 与 `enemySubsequentVoidInLead` 仍影响回退路径，但不再直接强制“最小主”或“最大主”。

**队友甩牌支持：**
- 队友甩牌 ≥4 张且含对子且当前领先时，以拖拉机策略出支持牌（`safePartnerCards`）

**甩牌将吃结构：**
- 甩牌是纯散牌时，主牌将吃只比较最高单张；AI 构造主牌组合时优先用散主，避免为了散牌甩牌拆主对子
- 甩牌含对子/连对时，主牌将吃必须匹配甩牌结构；AI 依次构造最弱可用连对、对子、单张（`buildMatchingSlamTrump`）

**安全出主**（`isSafeTrumpFiller`）：
- 跟主牌时，若非最后出牌位且后面还有对方未出牌，只从"安全牌"中选最弱能压的，避免被后手截胡
- 安全牌定义：大王 / 小王 / 级牌 / 主花色 A 及以上始终安全
- 动态安全：若该牌 rank 以上的主花色分牌（K/10/5，排除级牌）已全部打出（双副牌各 2 张），则该牌也视为安全（例：两张 K 都出了，J 变为安全牌）

**激进模式：**
- 触发条件：本墩已积分 ≥ 10 且攻方总得分 > 60
- 非最后出牌位：出最强的能压牌
- 最后出牌位：出最弱的能压牌
- 无法压时：出最弱牌（不再贡献分牌给对手）

**垫牌优先级（discardOrder，从先到后）：**
1. 非主牌优先于主牌
2. 同类牌中，低分牌优先（0分 > 5分 > 10分）
3. 同分中，按 rank 从小到大

**支持牌优先级（partnerSupportOrder）：**
1. 高分牌优先（10/K/5 > 0分）
2. 同分中，非主牌优先
3. 再按 discardOrder 排序

### 跟主色连对时（suitCards 为空且对手赢）
若手中无同花色，会从全手牌中寻找能压赢的连对/对子进行截胡

### 蒙特卡洛择优（monteCarloBestMove）

先手只对当前最高资产层级内 `leadAssetScore` 排名前 5 的候选做模拟；跟牌仍对启发式排名前 5 的候选做模拟：

- 每个候选模拟 24 次。每次从「双副牌减去所有已知牌」中抽样其余三家手牌（`sampleHiddenHands`），用确定性种子随机数（`MonteCarloRNG` + `monteCarloSeed`）保证可复现。抽样会尊重各家已暴露的绝门（不会把某逻辑花色的牌发给已绝该门的玩家）；底牌只有当决策 AI **本人是庄家**时才视为已知，非庄家把底牌留在未知池，但仍会剔除可推断必在底牌中的牌（当三家对手都绝某逻辑花色时，该花色剩余的牌必然都在底牌里）。
- `simulateCurrentTrick` 打出候选后，让其余玩家用轻量策略（`monteCarloFollowCards`）跟到本墩结束，并对结果评分：以 `capturedPoints×8×pointPressureBonus` 为核心，辅以很小的赢墩值、折扣后的剩余资产、主动权调整和高分场景下衰减后的保主惩罚。模拟目标是最终分差，不是空墩数量。
- 最终选择 = 模拟均分 + 启发式分 × 0.03（启发式仅作轻量决胜）。常量见 `monteCarloTopMoveCount` / `monteCarloSimulationCount`。

---

## 游戏流程（GameEngine）

```
startNewGame()
  → startNewRound()
    → dealCardsAnimated()  // 发牌 + AI 亮主
    → afterDealingComplete()
      → proceedToKittyExchange()  // 换底
    → startPlaying()
      → 轮流出牌（humanPlay / aiTakeTurn）
      → resolveTrick()   // 结算一墩
      → resolveRound()   // 结算一局（最后一墩后）
```

### 亮主规则
- 发牌过程中可亮主
- 单张亮主 strength=1，对子亮主 strength=2，对王无主 strength=3
- 反主需严格大于当前 strength
- 发牌结束若无人亮主：真人庄家手动亮主；AI 庄家强制亮主

**AI 亮主限制**（`aiConsiderDeclaration`）：

| 亮主类型 | 限制条件 |
|---------|---------|
| 单张亮主（strength=1） | 仅须满足发牌进度门槛，无额外手牌要求 |
| 对级牌首次亮主（cur=0） | 满足进度门槛即可 |
| 对级牌反不同花色（cur>0） | 新花色级牌数 > 当前声明数；相同则需更多对子；否则不反 |
| 对王反无主（strength=3） | 手中需 ≥3 张 A 且 ≥3 对子（含连对），否则不反 |

### 底牌换底
- 庄家将 8 张牌压入底牌
- AI 换底：优先压非主的弱牌（按 handSortOrder 逆序取前 8）
- 攻方最后一墩赢家吃底牌 × 2 得分

### 升级规则
- 攻方得分 ≥ 80 → 攻方胜，升级步数：`(得分 - 80) / 40`（整除）
  - 80–119 → 升0级（只变庄，不升级）；120–159 → 升1级；160–199 → 升2级；200+ → 升3级……
- 攻方得分 < 80 → 庄方胜，升级步数：= 0 升3，< 40 升2，其余升1

---

## 关键工具函数（CardComparator）

| 函数 | 用途 |
|------|------|
| `isTrump` | 判断是否主牌 |
| `trumpWeight` | 主牌内部权重（大王100…） |
| `beats(a, b)` | a 是否大于 b |
| `pairKey` | 对子配对 key（同点同花色或同级牌） |
| `pairOrderValue` | 对子/连对排序用的数值 |
| `areAdjacentPairRanks` | 两个对子是否相邻（构成连对） |
| `handSortOrder` | 手牌排序（主牌前，非主按花色分组） |
| `logicalSuit` | 逻辑花色（主牌返回 nil） |

---

## 联机（LANMultiplayerManager）

- Host 持有完整游戏状态，客户端只接收 snapshot
- 客户端操作发送 `MultiplayerAction`（declareTrump / confirmKitty / play）
- Host 广播 `GameSnapshot`（每个玩家只收到自己的手牌）
- 联机内部玩家身份以 `MCPeerID` 对象身份区分，不以 `displayName` 作为唯一 key；多个设备都叫 "iPhone" 时也不能合并或崩溃
- 房间人数由 host 的连接缓存 + `session.connectedPeers` 合并生成，避免新人加入时 lobby 快照少人
- 多人局中只有 host 能推进全局流程；客户端的「下一局」按钮禁用
- 一旦有远端玩家加入，快进发牌功能关闭，房主和加入者都不显示快进按钮；`toggleFastDealing` 底层也会拒绝多人局调用
- Host 退出时发送 `roomClosed`，踢出所有客户端并让所有人回主界面；客户端若未收到消息但检测到 host 断线，也走同样回主界面的兜底逻辑

---

## 常见修改入口

| 需求 | 文件 |
|------|------|
| 修改出牌合法性规则 | `TrickEvaluator.isValidPlay` |
| 修改甩牌检测 / 拆解逻辑 | `TrickEvaluator.slamInfo` / `decomposeSlam` |
| 修改甩牌赢家比较逻辑 | `TrickEvaluator.slamTrumpBeats` |
| 修改甩牌罚分计算 | `TrickEvaluator.slamPenaltyPoints` |
| 修改甩牌强制出牌逻辑 | `GameEngine.analyzeSlamLead` |
| 修改赢墩判断 | `TrickEvaluator.beatsPlay` / `winner` |
| 修改 AI 先手策略 | `AIPlayer.leadCards` / `buildLeadAssets` / `selectLeadAssetPool` |
| 调整 AI 先手打分权重 / 优先级 | `AIPlayer.leadAssetScore` / `LeadAssetTier` |
| 调整单个先手概念 | `findAbsoluteSideWinnerLeadCandidates`（兑现赢家）·`findSlamLeadCandidates`（安全控制组）·`findTractorLeadCandidates` / `findStrongPairLeadCandidates`（强结构）·`findTrumpTransferLeadCandidates` / `findLongSuitDevelopmentLeadCandidates`（主动权建设） |
| 调整拆对子/结构惩罚 | `AIPlayer.structureBreakPenalty` / `strongStructureBreakPenalty`（跟牌）与 `structureFragmentationCost` / `mixedSlamFragmentationCost`（先手资产完整性） |
| 修改 AI 蒙特卡洛模拟 | `AIPlayer.monteCarloBestMove` / `simulateCurrentTrick` / `monteCarloTopMoveCount` / `monteCarloSimulationCount` |
| 修改 AI 甩牌领出条件 | `AIPlayer.findSlamLead` / `isEffectivelyBiggestSingle` / `isEffectivelyBiggestPair` |
| 修改 AI 跟牌策略 | `AIPlayer.followCards`（候选）/ `scoreFollow`（权重）/ `followTractor` / `followPair` |
| 调整 AI 跟牌打分权重 | `AIPlayer.scoreFollow`；花主牌走法优先调 `trumpControlDecision` / `trumpControlCost` / `trumpCostDamping` |
| 修改 AI 主牌控墩逻辑（吊主、将吃、盖吃、保队友、抢主动权） | `AIPlayer.generateTrumpControlCandidates` / `filterTrumpControlMoves` / `trumpControlDecision` / `bestTrumpControlFill` / `isSecureWinningTrumpFollow` |
| 修改 AI 绝花色后填牌逻辑（将吃 / 垫分） | `AIPlayer.voidFillCards` / `bestTrumpControlFill`（`partnerAtRisk` / `enemySubsequentVoidInLead` 只影响回退路径）|
| 修改 AI 安全出主逻辑 | `AIPlayer.isSafeTrumpFiller` / `isSafeTrump` |
| 修改 AI 激进模式阈值 | `AIPlayer.followCards`（`trickPoints` / `attackScore` 判断处）|
| 修改垫牌/支持牌逻辑 | `AIPlayer.discardOrder` / `partnerSupportOrder` |
| 修改主牌大小顺序 | `CardComparator.trumpWeight` |
| 修改升级得分阈值 | `GameEngine.resolveRound` |
| 修改 AI 亮主限制 | `GameEngine.aiConsiderDeclaration` |
