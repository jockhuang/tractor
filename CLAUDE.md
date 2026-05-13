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

### 先手出牌优先级（leadCards）
0. **甩牌**：同一非主花色中有 2+ 张"无法被压制"的牌时一起甩出（`findSlamLead`）
1. **已是最大的非主牌对子**：同花色中最大牌是对子时优先出对子
2. **已是最大的非主牌单张**：同花色中最大单张
3. **旁门 Ace**：手中最强的非主花色 A（`bestSideAce`）
4. **非主花色连对（拖拉机）**：找非主花色中的连对（`findTractor`）
5. **非主花色对子**：找非主花色中的对子，优先出最大对（`findPair`）
6. **引出队友垫分**：队友已绝某花色且该花色有分未出，领出让队友垫分
7. **最小主牌**：手中最弱的主牌
8. **最弱牌**：手中任意最弱的牌

**AI 甩牌判断**（`findSlamLead`）：

单张和对子分量用不同标准判断"无法被压制"：
- **单张最大**（`isEffectivelyBiggestSingle`）：所有更高 rank 在 played+hand ≥ 2（双副牌两张都已知晓，对手无法有更大单张）
- **对子最大**（`isEffectivelyBiggestPair`）：所有更高 rank 在 played+hand ≥ 1（对手至多 1 张，凑不成更大对子）

> 例：手中 A♠K♠K♠ → A 在手故外面最多 1 张 A，KK 是最大对子；A 是最大单张 → 合法甩牌
> 例：手中 A♠Q♠Q♠ 且有 K♠ → K/A 各有 ≥1 张已知晓，QQ 是最大对子 → 合法甩牌

已知对手绝该花色时，只有含对子的组合才甩（纯散牌送将吃毫无意义）。

### 跟牌策略（followCards）

**花色匹配规则：**
- 先找手中与先手同逻辑花色的牌（`suitCards`）
- 有足够同花色牌 → 尝试压牌；无法压牌 → 出最弱同花色牌（若队友赢则出支持牌）
- 同花色不够 → 先出所有同花色，剩余按策略补充

**跟牌子策略：**

| 先手类型 | 处理函数 | 逻辑 |
|---------|---------|------|
| 连对（拖拉机） | `followTractor` | 优先出能压赢的最弱连对；无则出最弱连对；无连对则出最弱牌 |
| 对子 | `followPair` | 优先出能压赢的最弱对子；无则出最弱对子；无对子则出最弱牌 |
| 单牌 | 内联逻辑 | 有能压赢的牌则出最弱能压赢的牌；否则出最弱牌 |

**队友赢时（partnerWinning）：**
- 不尝试压牌
- 出「支持牌」：优先出高分牌（10/K/5），其次出非主的弱牌（`partnerSupportOrder`）

**队友甩牌支持：**
- 队友甩牌 ≥4 张且含对子且当前领先时，以拖拉机策略出支持牌（`safePartnerCards`）

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
| 修改 AI 先手策略 | `AIPlayer.leadCards` |
| 修改 AI 甩牌领出条件 | `AIPlayer.findSlamLead` / `isEffectivelyBiggestSingle` / `isEffectivelyBiggestPair` |
| 修改 AI 跟牌策略 | `AIPlayer.followCards` / `followTractor` / `followPair` |
| 修改 AI 安全出主逻辑 | `AIPlayer.isSafeTrumpFiller` |
| 修改 AI 激进模式阈值 | `AIPlayer.followCards`（`trickPoints` / `attackScore` 判断处）|
| 修改垫牌/支持牌逻辑 | `AIPlayer.discardOrder` / `partnerSupportOrder` |
| 修改主牌大小顺序 | `CardComparator.trumpWeight` |
| 修改升级得分阈值 | `GameEngine.resolveRound` |
| 修改 AI 亮主限制 | `GameEngine.aiConsiderDeclaration` |
