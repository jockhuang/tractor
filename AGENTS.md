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

> 实现细节：`maximumTractorPairs` 在实际跟牌槽数内求可实现的最大连对贡献，再要求总对子数最大化。例如两段两连对跟三连对时，要求贡献两对连对加一对对子，不能要求无法组成的三对连对。首手必须通过 `isValidLead`，只允许同一逻辑花色。

### 甩牌（Slam Lead）
领出者可将同一逻辑花色中 2 张及以上不构成纯连对/纯对子的牌一起甩出（混合单张、对子、连对均可）。

**甩牌合法性检测**（`TrickEvaluator.slamInfo`）：
- 拆解为连对组件 + 对子组件 + 单张组件（`decomposeSlam`）
- 检查其余三家手中是否有**同类型且更大**的牌张：
  - 甩牌含单张 → 三家不能有大于该单张的单张
  - 甩牌含对子 → 三家不能有大于该对子的对子
  - 甩牌含连对 → 三家不能有大于该连对的连对

**甩牌失败后果**（`TrickEvaluator.slamFailure` / `GameEngine.resolveSlamLead`）：
- 每张失败的牌罚 10 分（从甩牌方所在队扣除）
- 甩牌方自动改为领出一个「最小失败组件」，其余甩牌退回手牌
- 组件优先级：失败拖拉机 > 失败对子 > 失败单张；同类有多个失败组件时取其中最小的
- 后续三家只按普通跟牌规则出牌，不设置任何强制跟牌约束

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

1. **生成候选**：多个生成器各自提出合理走法（`AIMove` = 牌 + `MoveKind` 标签）；跟牌始终加入规则基线走法作兜底，先手由资产分层和弱处置兜底负责。
2. **启发式打分**：先手用 `leadAssetScore` 给资产类别先验和实际安全性评分，保留不同目的的候选；跟牌用 `scoreFollow` 给候选打分。
3. **蒙特卡洛模拟**：先手在兑现、结构、试对、牌权计划、清门之间保留代表，跟牌按启发式排序，最多 `monteCarloTopMoveCount`（=5）个候选。共享最多 `monteCarloSimulationCount`（=24）个合法隐藏世界，模拟当前墩并续演最多两墩，选综合分（模拟均分 + 启发式分 × 0.03）最高者出牌。

`chooseCards`：当前墩无人出牌则先手，否则跟牌。

**隐藏信息边界**：`chooseCards` 首先构造 `GameState.aiObservation(for:)`。决策对象只含本人手牌、公开历史/亮牌/得分/各家剩余张数，以及本人是庄家时的底牌；其他玩家的 `hand` 为空，非庄家底牌为空。剩余张数通过 `handCount(for:)` 获取，不能从真实牌面推断或直接读取其他人手牌。规则执行器为判断甩牌失败而检查各家真牌，属于规则裁决，不得把结果提前提供给AI候选生成。

### AI 记忆（AIContext）

每次决策从 `completedTricks` + 当前墩构建一次，记录：

- `playedCards`：本局已见的所有牌
- `voidSuits`：每个玩家已暴露绝掉的逻辑花色（没跟上该花色）
- `isLastPlayer`：本墩 AI 是否最后一手

派生判断：`isEffectivelyBiggest`（双副牌中所有更大同花色牌已出完）、`manyBigTrumpsRemain`、`unplayedSuitPoints`、`allEnemiesVoid` / `voidEnemies`。

### 先手资产分层（leadCards）

`leadCards` 把走法包装成 `LeadAsset`。先由 `cashingWindowAssets` 保护正常兑现窗口；窗口外以下类别提供评分先验，`selectLeadAssetPool` 在不同目的之间保留代表，让风险较高的 A、整对、低成本交牌权和清门可以在同一批隐藏世界中比较。

**副牌兑现窗口（`cashingWindowAssets`）**：

- 旁门 A、已知最大单张/对子、完整安全控制组，在无明确先拔主需求且团队控墩概率 ≥0.8 时进入窗口；若敌方已知绝该副门且尚未绝主，则门槛提高到 ≥0.95，避免裸 A 送将吃。
- 窗口内仍由原评分和共享隐藏世界模拟比较这些兑现资产，不让未证实最大的普通对子、随机副单或常规吊主继续拖延。已知最大的小对子可以和 A 一起比较；AKK / AAKK 等整体仍压制子走法。
- 窗口在残局保主/保底覆盖前判断，保留最后主控不能把安全副 A 当成杂牌延后。
- 两名对手均已明确绝主时，副牌赢家不再因将吃而贬值，不强制抢兑；允许先跑分、安排清门与末墩。明确将吃威胁或具体拔主解锁计划仍走跨类别比较。

资产层级：

1. **Cashing Time-Sensitive Winners**：旁门 A、已知最大副牌单张、已知最大副牌对子、安全旁门控制组。它们会随敌方绝门而贬值，应尽早兑现。
2. **Safe Slam / Control Groups**：安全甩牌或完整控制组，按整体评估；若存在 AKK / AAKK 这类组合，会压制其子走法，避免拆成 A、KK、AA、KK 分别比较。
3. **Strong Structures**：拖拉机、级牌对、王对、强主对。它们是稳定控制资产，优先作为结构使用。
4. **Side Pair Opportunity**：副牌孤对（该逻辑副花色仅剩这两张，任意大小）和 J/Q/K 等高副牌对优先整出，先于普通吊主；经历牌权周转、重新组织副牌时，其他小对子也进入此层。不拆拖拉机或安全控制组，有明确先拔主保护计划时仍等待。
5. **Initiative Building**：队友垫分计划、其他普通副牌对子、受控吊主、小主过渡，按本段牌权计划评估收益。
6. **Weak Disposal**：弱单、弱对、低价值清理，作为低成本替代参加比较，不限于其他类别为空时。

| 生成器 | 提出的走法 |
|---|---|
| `buildLeadAssets` | 汇总全部先手资产，去重，并保留每组牌的最高资产层级 |
| `findSlamLeadCandidates` | 无法被压制的甩牌 / 控制组；安全组合会压制其子走法 |
| `findAbsoluteSideWinnerLeadCandidates` | 时效性副牌赢家：旁门 A、已知最大副牌单张、已知最大副牌对子；若属于安全控制组则不单独出 |
| `findTractorLeadCandidates` | 强结构层候选：所有逻辑花色中的合法拖拉机，跳过敌方已全绝的副花色 |
| `findStrongPairLeadCandidates` | 强结构层候选：A/级牌/王对子与高主对；K/10/5 副牌对不因带分自动晋级，已知最大副牌对由兑现赢家路径处理；大主对子会先过 `bigTrumpPairLeadAllowed` 保护 |
| `findNoTrumpControlLeadCandidates` | 无主局中的王/级牌/A 控制对子与连对；大主控制对子同样会先过 `bigTrumpPairLeadAllowed` |
| `findTimelySidePairLeadCandidates` | 机会副牌对层：副牌孤对、J 以上副牌对，以及牌权周转后的小副牌对，先于普通吊主，避免留到被迫拆跟 |
| `findPartnerDumpLeadCandidates` | 主动权建设：队友已绝且仍有未出分牌的花色——领出让队友垫分 |
| `findLongSuitDevelopmentLeadCandidates` | 弱处置层：无兑现资产时发展长门，小单不得以长门名义压过普通副牌对子 |
| `findTrumpLeadCandidates` / `findTrumpTransferLeadCandidates` | 主动权建设：受控吊主或低成本小主过渡；主牌不套用旁门兑现紧迫性。小主过渡门槛为主牌 ≥3 且不拆结构 |
| `findWeakLeadCandidates` / `findWeakPairDisposalLeadCandidates` | 弱单和低价值清理作兜底；普通副牌对子提升至主动权建设层，不按分牌分档，只按牌面大小连续加权 |

兑现窗口外，`selectLeadAssetPool` 在兑现（含安全控制组）、结构、机会对子、主动权建设、弱处置这五类目的中各取评分最高的代表，不足五个再按分补齐。小主过渡不再独占候选池。AKK / AAKK 等安全整体仍抑制其子候选；有将吃风险的 A 可以延后，普通对子则不能在正常兑现窗口里靠短期抽样挤掉安全 A。

**吊主计划与牌权周转（`leadControlPlan`）**：

- `seekPartnerLead`：最近一段计划尚未完成交牌权时，可用低成本小主争取对家接手，前提是公开牌池中对家确实还可能有能接手的主。已经执行新的副牌兑现/发展计划后，可重新开始交牌权计划，不能让本局早期一次他人领牌永久关闭它。
- `reassessSideAssets`：最近一段计划中，对家已领牌或对手领牌后自己拿回牌权，则重评副牌对子与清门；连续两次小主交牌权未果也重评。不再自动叠加空档期吊主奖励，小对子可先于普通吊主出。
- `pullForSideWinners`：若拔主能明确解锁待兑现副牌或保护副牌对子，仍允许有目的地继续拔主；不因已周转就一律禁主。
- 对家已明确绝主时不再以交给对家为默认计划；两名对手都明确绝主时不再把拔主作为目标。
- 计划由本局公开出牌历史和已知绝门推导，不读取其他玩家手牌，不增加联机私有状态，新局随历史重置。

**大主对子开局保护（`bigTrumpPairLeadAllowed`）**：
- 王对、级牌对、主 A 对是全局最强控制 / 将吃资源，不能因为“主牌多”或“这对牌自身带分”就在开局/中盘主动领出。
- `bigTrumpPairLeadAllowed` 只在残局（手牌 ≤6）主动放行这类大主对子；若全手无其他合法兜底，最终仍可出牌。
- 拔主计划优先用低成本小主过渡或普通主牌，不用最高控制对裸拔。
- `allowTrumpLead` 对所有生成路径统一执行大主对子保护，包含主拖拉机和无主控制组。
- 保护按手牌与所出牌的交集检查：从王对/级牌对/主A对抽一张也受保护。最强主单张生成器不抽取对子成员；开中盘领孤张大主还需要具体的副牌拔主目标，且没有普通无分主单张替代。
- 副牌对子/拖拉机的等待拔主判断必须存在相应主结构威胁；只剩一张未知主、或对手已证明无主对，不能据此拖延安全对子。保护副牌对的价值按 rank 连续排序，并确认拔主后它确能成为最大对，不再给 K/10 特殊档位或把 Q/J 记成 0。

**残局保底牌控制（`knownPointKittyEndgameLead`）**：
- 手牌 ≤8、两名对手都已明确绝主、AI 仍有主牌和副牌，并且 AI 能确认底牌有分时，不再继续吊主；优先领副牌，保留最后一手主牌控制来争取末墩。
- 庄家知道自己埋下的底牌，可确认有分或 0 分；非庄家不能读取真实 `state.kitty`，只能通过已出牌、自己手牌、亮牌和绝门信息推断。无法确认时保持 `unknown`。
- 已知底牌 0 分时不启用专门的保底覆盖策略，回到普通残局资产决策。
- “对手无主”只统计当前 AI 的两名敌方玩家，不能把自己或队友的绝主证据误算进去。

### 先手打分——点数优先的资产评分（leadAssetScore）

先手路径由 `leadAssetScore` 对资产类别先验、点数、结构、牌权计划评分，再乘实际安全性折扣（`leadTeamControlProbability`）；不是只按牌面 rank 近似安全。跨类别候选也能进入同一批模拟，`leadAssetTieBreakScore` 仅负责稳定决胜。

`leadAssetScore` 的核心原则：

- 时效性旁门赢家先兑现，不把旁门 A 的紧迫性套到主牌控制牌上。
- 安全控制组按整体出牌评估，并压制其子候选。
- 结构保留是成本，不是绝对目标；只有当没有更高层资产需要兑现时才主导。
- 主动权建设低于实分兑现和稳定结构。
- 弱牌清理只作为兜底。

这套资产分层从结构上消除了原来的特例：

- **AKK / AAKK** 作为整体评估——`structureFragmentationCost` 让「从 AAKK 里抽 AA 出」付出拆拖拉机的代价，整出拖拉机则得 `wholeStructureControlValue`，因此不再被拆成 AA→KK。
- **拆任何对子**使用 `pairAssetWeight`：王/级牌/A 为 1.0、普通主对 0.9，其余副牌对按 rank 连续加权（0.25 + rank/28），不单列 K/10/5。跟牌模拟在传入公开 `AIContext` 时，对已证明最大的副牌对子额外计控制资产损耗；不能把已成最大对的33仍只按裸rank低估。该成本仍随当前墩分压力衰减。
- **旁门 A 攥太久**通过兑现窗口约束、实际安全性和后续两墩分差共同处理；已知最大对、完整控制组仍可与 A 比较，窗口外保留有目的的替代方案。
- **非绝对赢的对子**不能虚报控制价值：`wholeStructureControlValue` 对非主导结构打折，最终与兑现 A 的实际收益比较，不保证任何牌型无条件先出。
- **小主过渡**属于主动权建设候选；有清门、兑现或对子方案时仍可比较，但不能凭标签垄断模拟。

安全甩牌 / 控制组作为 Tier 1 或 Tier 2 的整体资产评估；无主局对子/连对的 `wholeStructureControlValue` 更高。

### 先手合法性过滤（filterAllowedLeadAssets / allowTrumpLead）

资产生成后由 `filterAllowedLeadAssets` 过滤；主牌先手由 `allowTrumpLead` 把关。小主过渡可在主动权建设层空档期通过；其他主牌早期一般不许领，除非手牌偏少（剩 ≤5 墩）、主牌多（≥8 张或 ≥4 张强主）、副牌比主牌还多、需保护的暴露分多、主牌保对价值高，或需要拔主来解锁等待拔主的副牌赢家。非主走法始终放行。

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

已知对手绝该花色时，纯散牌甩牌按阶段处理：

- 外面主牌还多时保留早期保护，不主动用纯散牌大甩冒险。
- 主牌已消耗到较少时，`latePureSlamAllowed` 按公开剩余主牌、甩牌张数和完整将吃概率放行；安全整组会抑制其拆单候选，优先兑现。
- 甩 N 张纯散牌必须由 N 张全主将吃，主牌不要求成对；外面总共只剩一张未知主时，不能将吃两张或更多的甩牌。
- 三家已公开绝该副门时，即使更大副牌尚未全部出现，也可以证明它们不在其他人手上（可能在底牌）；不能因此漏掉合法甩牌，更不能偷看队友确认。

### 跟牌策略（followCards）

**跟牌流程：** 与先手一致，走 候选生成 → 打分 → 蒙特卡洛：

1. 规则基线（`followCardsRuleBased`）+ 非主/结构候选（`generateFollowCandidates`）+ 统一主牌控墩候选（`generateTrumpControlCandidates`）。
2. 仅保留合法走法（`isValidPlay`），再过三道滤网：
   - `filterUnsafeTrumpPointExposureBeforeUnknownOpponent`：跟吊主的 0 分墩、后手仍有未知对手且本队未锁定时，有合法 0 分替代才过滤不安全主分牌；队友大王等已锁定时允许跑 K/10/5，不要求自己盖过队友。候选出后是否安全按整副组合检查，不能只检查最高单张。
   - `filterTrumpControlMoves`：所有花主牌的候选统一用 Trump Control Decision 分类；高分墩或高主动权需求时，若存在锁定/争墩主牌，会剔除被动主牌。
   - `filterHighInitiativeWinningMoves`：当急需主动权（`initiativeNeed` ≥ 100）时，若存在「便宜、不拆对子、不动大主」的取胜走法则只保留它们；主牌走法还必须在 Trump Control 下不是被动且得分为正。
3. 用 `scoreFollow` 打分，取前 5 名，再由蒙特卡洛择优。

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
- 多张跟牌且本门不够时，本门剩余分牌属于规则强制，必须出；但其他门补牌不是强制牌。若对手当前赢，补牌应优先 0 分牌，不得因为敌方已绝某门或保对子而额外垫 10/K/5 给对手。

**跟牌子策略：**

| 先手类型 | 处理函数 | 逻辑 |
|---------|---------|------|
| 连对（拖拉机） | `followTractor` | 优先出能压赢的最弱连对；无则出最弱连对；无连对则出最弱牌 |
| 对子 | `followPair` | 优先出能压赢的最弱对子；无则出最弱对子；无对子则出最弱牌 |
| 单牌 | 内联逻辑 + `generateFollowCandidates` | 最弱能赢的牌是基线；额外提出不拆对子/拖拉机的同门单张（优先0分），避免只剩“拆小对”的机械跟牌；副牌同门所有能赢的 K/10/5 同时进入候选，按安全性、当场收分、拆结构成本和模拟比较，不能因为 Q 已能赢就漏掉 K。`pointGuardCard` 在后手有对手时保护本门分牌：空墩压住潜在分牌，有分时进一步考虑未知更大牌 |

**队友赢时（partnerWinning）：**
- 若队友已经严格锁定，即使主牌墩达到15分，也不得由控主过滤强制盖队友；存在合法不接管支持牌时优先保留这些牌。
- 跑分候选不要求先严格证明稳赢：始终生成满足跟牌结构、尽量垫出 K/10/5 的支持走法，并保证最高分支持候选有一个 Monte Carlo 名额，避免仅因后手尚未知绝门就把跑分方案提前删掉。最终仍按抽样后的团队得分与将吃风险选择；严格锁定判断本身不放宽。
- 跟多张组合时，`structuredOvertakeProbability` 按剩余牌池与后手手牌张数估计完整对子/拖拉机的持有概率；副牌将吃还需同时满足绝门。自己的主牌和已出主牌会阻断未知主结构，副牌前几次出牌的低绝门风险也通过剩余张数自然反映。队友领先时，不再把“自己不能压过队友”按无法拿分惩罚，支持走法按团队预期得分计分。
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
- 安全证明按实际组合类型检查：单牌、对子和拖拉机分别判断后手是否可能组成更大的合法走法；未知绝门保留首次将吃的可能性。
- 小王、级牌、主A不能仅凭牌面类别判定安全；外面只有一张更大的主牌时，不能据此认定它能压一个对子。

**激进模式：**
- 触发条件：本墩已积分 ≥ 10 且攻方总得分 > 60
- 非最后出牌位：出最强的能压牌
- 最后出牌位：出最弱的能压牌
- 无法压时：出最弱牌（不再贡献分牌给对手）

**垫牌优先级（discardOrder，从先到后）：**
1. 非主牌优先于主牌
2. 同类牌中，低分牌优先（0分 > 5分 > 10分）
3. 同分中，按 rank 从小到大

**智能垫牌（smartDiscard）：**
- 对手当前赢时，`smartDiscard` 使用 `discardCost`，不再只按 `pointValue` 排序。成本由 ImmediatePointRisk + FuturePointRealization - FuturePointLossRisk，并叠加 ControlAssetValue 与 StructureIntegrity。
- 王、级牌、主控制牌、主对子、拖拉机核心、AKK / AAKK 核心、副牌 A、已知最大副牌对子/拖拉机等是控制资产，不能为了保孤立 5/10/K 轻易丢掉。
- 分牌保护必须有条件：孤立 5/10/K 如果未来大概率送给对手，且当前垫出不会让攻方跨关键分线，可以被当作较低价值资产先垫；若垫分会让攻方达到 40 分倍数关键线，才临时提高分牌保护权重。
- 对手当前赢且有 0 分自由补牌时，仍应优先补 0 分牌，不能因为敌方已绝某门或保对子而额外垫 10/K/5 给对手。
- 队友当前赢且本墩安全时，才按支持逻辑优先垫高分牌。
- 因跟牌规则被迫出的本门分牌不受此限制；限制只针对补其他门的自由填牌。

**支持牌优先级（partnerSupportOrder）：**
1. 高分牌优先（10/K/5 > 0分）
2. 同分中，非主牌优先
3. 再按 discardOrder 排序

### 跟主色连对时（suitCards 为空且对手赢）
若手中无同花色，会从全手牌中寻找能压赢的连对/对子进行截胡

### 蒙特卡洛择优（monteCarloBestMove）

先手使用跨类别的最多五个候选；跟牌使用启发式前五名（保留一个最高分支持名额）：

- 每个候选模拟 24 次。每次从「双副牌减去所有已知牌」中抽样其余三家手牌（`sampleHiddenHands`），用确定性种子随机数（`MonteCarloRNG` + `monteCarloSeed`）保证可复现。抽样会尊重各家已暴露的绝门（不会把某逻辑花色的牌发给已绝该门的玩家）；底牌只有当决策 AI **本人是庄家**时才视为已知，非庄家把底牌留在未知池，但仍会剔除可推断必在底牌中的牌（当三家对手都绝某逻辑花色时，该花色剩余的牌必然都在底牌里）。
- `simulateCurrentTrick` 完成当前墩后，`simulateContinuation` 让赢家继续领出最多两墩，未来分差按 0.65、0.65² 折扣，覆盖对家接手跑分、失去牌权和末墩底分；每位模拟玩家只读自己的牌及公开记忆，不偷看其他抽样手牌。只在各家剩余张数平衡时续演，不把稀疏测试状态当成真实完整局面。
- 当前墩以 `capturedPoints×8×pointPressureBonus` 为核心，结合后续分差和续演后的剩余资产。争分模式下剩余资产同样是正向价值，不能因切换模式把保留好牌变成惩罚或跳过结构成本。普通跟牌也显式扣除本次 `structureFragmentationCost×16×structureDamp`，与争分模式的分数单位成本相对应；不能只看两墩后的资产而把当前无谓拆对成本抹掉。跟牌只在本队最终拿分的抽样世界按点数压力降低拆结构成本，输墩世界保持完整成本，不能因为对手后手垫了更多分就把无效拆对打折。
- 隐藏牌抽样按花色分配方案的组合数及后续可行完成数加权，保持绝门条件下的均匀发牌分布；无约束部分直接洗牌分配。
- `publicFollowConstraints` 从公开历史重建结构短缺，抽样必须能合法重演该玩家过去的跟牌，涵盖无对、连对不足及甩牌结构槽不足。条件均匀抽样后按这些证据拒绝不合法世界；每世界重试有上限，不能满足就跳过，全部失败则启发式兜底，绝不伪造违背记忆的手牌。
- 候选共享24个世界与单次决策内的 `HiddenSamplingMemo` 组合计数缓存；`referenceDeck` 是只读计数模板，真实发牌仍生成独立牌实例。
- 模拟跟牌按最终团队控制概率选择赢牌、支持或垫牌，不把队友“暂时领先”当成可以无条件垫分。已见牌和绝门经 `AIContext.observing` 更新，再计算剩余资产。
- 单张盖牌概率按未知池、公开亮牌和手牌张数计算“同门大牌”与“首次绝门且持主”两个互斥事件；不能再把未暴露绝门当作必须跟门。
- 纯散牌甩牌将吃概率按超几何分布计算“绝门且持有至少N张主”；若已有主牌将吃，还要求其中有能盖过当前最高主的牌。不能按“可能有一张主”固定计60%风险。
- 普通无分、不拆结构的小主传递不套用早期消耗大主的全局扣分。`seekPartnerLead` 或 `pullForSideWinners` 下存在公开可行的小主过渡时，`filterUnplannedSideFallback` 逐走法剔除无目标的9及以下无分副单；持有另一副牌对子不能让这张小单免检，已明确拔主保护副牌也不能绕过过滤。对子/拖拉机、已知赢家、清门、高副单试探，以及对家已绝该门且仍有未出分的配合目标都保留比较；重新评估副牌计划时也不一律禁用小副。纯兜底时仍优先低成本吊主，不靠抽样中假想的队友大牌领随机副单。
- 末墩攻方获胜时计入底牌 ×2；庄家使用自己的底牌，非庄家只能使用本次抽样世界推导的底牌。
- 已知后手绝门不再禁止用王或主分牌争墩；带分但未锁定的争分候选不再由 `tacticalCandidateFilter` 一刀切删除。风险由评分和模拟判断。
- 残局“对手可能无主”不再累加同一玩家重复垫牌的次数。
- 最终选择 = 模拟均分 + 启发式分 × 0.03（启发式仅作轻量决胜）。常量见 `monteCarloTopMoveCount` / `monteCarloSimulationCount`。

### AI 验证

- `cd Tractor && ./run_ai_tests.sh`：完整战术与策略回归。
- `TRACTOR_AI_TEST_OPTIMIZE=1 TRACTOR_AI_FULL_ROUND=1 ./run_ai_tests.sh`（在 `Tractor/` 内）：优化编译，另跑有主、无主两局完整自对弈与决策耗时统计。
- 可附加 `TRACTOR_AI_ROUNDS=10` 扩大到10局，`TRACTOR_AI_SEED` 指定起始种子，`TRACTOR_AI_AUDIT_PATH=/private/tmp/tractor-self-play.json` 保存完整初始发牌、逐手选择、公开墩记录及待复核机会。审计由 `AITests/SelfPlayAudit.swift` 执行，只在事后裁判/重放时读取完整手牌，战术筛查使用决策者自己的观察快照；可疑标记须人工判断，不能直接视为错误或用真实隐藏手牌反推当时策略。
- 已审查种子及配置登记在 `AITests/SelfPlay/seeds.json`，完整记录按批次保留。每批新审计完成后用 `AITests/archive_self_play.py` 归档并登记，禁止覆盖旧批次；不要仅将结果留在临时目录。复核某个旧种子应使用 `TRACTOR_AI_REPLAY_PATH` 和 `TRACTOR_AI_REPLAY_SEED`，从原始配置/初始牌重跑，不能只改起始种子而意外重置主花色/级牌/座次。默认测试校验归档的种子发牌及历史合法性；具体命令见 `AITests/SelfPlay/README.md`。
- `AITests/Fixtures/self-play-1501-1510.json`、`self-play-1511-1520.json` 与 `self-play-1521-1530.json` 保存自对弈发现的20个精确回放目标，默认测试会自动载入；覆盖同门散张替代拆对、已知最大对子、当前跟牌拆结构成本、兑现后交牌权、拔主保护副牌，以及大主控制/带分保护/公开对家配合的例外。`TRACTOR_AI_AUDIT_DIAG=1` 可在失败时打印候选启发式和共享世界模拟分，用来区分候选缺失、评分偏差和合理策略分歧。
- 截图回归保留在 `AITests/main.swift`，修改策略必须一起运行：IMG6550 的队友拖拉机跑 K/10、IMG6551 的孤对/J以上对子与牌权周转、IMG6554 的主少时整甩及隐藏牌隔离、IMG6555/6557–6559 的副 A 兑现窗口与残局保主例外、IMG6560 的末家 K 收分与四座次轮转。截图遮住或缺失的牌须标注为相容变体，不能当作原局完整重放。
- IMG6560 主回归用完整108张牌与可合法重演的10墩历史，另覆盖10/5收分、已被将吃、后手绝门仍可将吃、对子/拖拉机保留等反例；不能仅测候选存在而不验证最终出牌。
- IMG6554 回归使用完整108张牌和合法21墩公开历史：验证早期不甩、主少时优先整甩J+10、单主不能将吃两张、未知底牌大牌不妨碍公开绝门证明，以及隐藏手牌/非庄家底牌置换不改变决策。

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
| 修改甩牌失败组件选择 / 罚分计算 | `TrickEvaluator.slamFailure` |
| 修改甩牌失败后的实际领出 | `GameEngine.resolveSlamLead` |
| 修改赢墩判断 | `TrickEvaluator.beatsPlay` / `winner` |
| 修改 AI 先手策略 | `AIPlayer.leadCards` / `buildLeadAssets` / `selectLeadAssetPool` |
| 调整 AI 先手打分权重 / 优先级 | `AIPlayer.leadAssetScore` / `LeadAssetTier` |
| 调整单个先手概念 | `findAbsoluteSideWinnerLeadCandidates`（兑现赢家）·`findSlamLeadCandidates`（安全控制组）·`findTractorLeadCandidates` / `findStrongPairLeadCandidates`（强结构）·`findTrumpTransferLeadCandidates` / `findLongSuitDevelopmentLeadCandidates`（主动权建设） |
| 调整开局大主对子保护（王对 / 级牌对 / 主A对） | `AIPlayer.bigTrumpPairLeadAllowed` |
| 调整残局已知有分底牌的末轮控制 | `AIPlayer.knownPointKittyEndgameLead` / `kittyPointKnowledge` / `endgameSideDisposalLeadAssets` |
| 调整拆对子/结构惩罚 | `AIPlayer.structureBreakPenalty` / `strongStructureBreakPenalty`（跟牌）与 `structureFragmentationCost` / `mixedSlamFragmentationCost`（先手资产完整性） |
| 修改 AI 蒙特卡洛模拟 | `AIPlayer.monteCarloBestMove` / `simulateCurrentTrick` / `monteCarloTopMoveCount` / `monteCarloSimulationCount` |
| 修改 AI 甩牌领出条件 | `AIPlayer.findSlamLead` / `isEffectivelyBiggestSingle` / `isEffectivelyBiggestPair` |
| 修改 AI 跟牌策略 | `AIPlayer.followCards`（候选）/ `scoreFollow`（权重）/ `followTractor` / `followPair` |
| 调整 AI 跟牌打分权重 | `AIPlayer.scoreFollow`；花主牌走法优先调 `trumpControlDecision` / `trumpControlCost` / `trumpCostDamping` |
| 修改跟吊主时「后手有未知对手」的 0 分墩裸出分牌过滤 | `AIPlayer.filterUnsafeTrumpPointExposureBeforeUnknownOpponent` |
| 修改 AI 主牌控墩逻辑（吊主、将吃、盖吃、保队友、抢主动权） | `AIPlayer.generateTrumpControlCandidates` / `filterTrumpControlMoves` / `trumpControlDecision` / `bestTrumpControlFill` / `isSecureWinningTrumpFollow` |
| 修改 AI 绝花色后填牌逻辑（将吃 / 垫分） | `AIPlayer.voidFillCards` / `bestTrumpControlFill`（`partnerAtRisk` / `enemySubsequentVoidInLead` 只影响回退路径）|
| 修改 AI 安全出主逻辑 | `AIPlayer.isSafeTrumpFiller` / `isSafeTrump` |
| 修改 AI 激进模式阈值 | `AIPlayer.followCards`（`trickPoints` / `attackScore` 判断处）|
| 修改垫牌/支持牌逻辑 | `AIPlayer.smartDiscard` / `discardOrder` / `partnerSupportOrder` |
| 修改主牌大小顺序 | `CardComparator.trumpWeight` |
| 修改升级得分阈值 | `GameEngine.resolveRound` |
| 修改 AI 亮主限制 | `GameEngine.aiConsiderDeclaration` |
