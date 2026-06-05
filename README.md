# Tractor iOS Game — Codebase Knowledge Base

## Project Overview

An iOS Tractor / Shengji card game for 4 players: 1 human player + 3 AI players. Built with Swift and SwiftUI, with LAN multiplayer support.

- **Platform**: iOS (SwiftUI)
- **Architecture**: MVVM, with `GameEngine` as the core controller
- **File Location**: `Tractor/Tractor/`

---

## Folder Structure

```text
Models/
  Card.swift        — Suit, Rank, Card, PlayPattern, GamePhase, Trick, GameState
  Player.swift      — PlayerPosition, Player
  Deck.swift        — Deck generation

Engine/
  CardComparator.swift   — Card strength comparison, trump detection, sorting
  TrickEvaluator.swift   — Follow-play validation and trick winner evaluation
  AIPlayer.swift         — AI play decision-making
  GameEngine.swift       — Main game loop and state machine
  LANMultiplayerManager.swift — LAN multiplayer

Views/
  GameBoardView.swift, PlayerHandView.swift, CardView.swift, ...
```

---

## Core Models

### Suit / Rank / Card

- `Suit`: ♠ ♥ ♦ ♣. Jokers have `suit = nil`.
- `Rank`: 2–A, `smallJoker = 20`, `bigJoker = 21`.
- Scoring cards:
  - 5 = 5 points
  - 10 / K = 10 points

### PlayerPosition

- `.south` = human player
- `.west`, `.north`, `.east` = AI players
- Team rule: `team = rawValue % 2`
  - South + North = Team 0, the dealer/defending side
  - West + East = Team 1, the attacking side

---

## Play Rules — TrickEvaluator

### Trump Detection — `CardComparator.isTrump`

A card is considered trump if it meets any of the following conditions:

1. It is a Joker.
2. Its rank equals the trump rank, regardless of suit.
3. Its suit equals the trump suit and it is not a rank trump.

### Trump Strength — `trumpWeight`

```text
Big Joker = 100
> Small Joker = 90
> Trump-suit rank card = 80
> Off-suit rank card = 70
> Normal trump-suit card, ordered by rank
```

### Follow-play Validation — `isValidPlay`

1. The number of cards played must match the number of cards led.
2. Determine the lead play's "logical suit".
   - All trump cards use `nil` as their logical suit.
   - Non-trump cards use their actual suit.
3. The player must follow with as many cards of the same logical suit as possible.
   - If the player does not have enough same-suit cards, they must play all available same-suit cards, and the rest can be any cards.
4. If the player has enough same-suit cards, they must also satisfy structure priority:
   - **If the lead is a tractor / consecutive pairs**:
     - Follow with as many consecutive pairs as possible first.
     - Then follow with as many isolated pairs as possible.
     - Remaining cards can be singles.
   - **If the lead is a pair**:
     - If the player has a pair in that suit, they must play a pair.
     - Singles are only allowed if they do not have a pair.
   - **If the lead is a single card**:
     - The player must follow suit if possible.
     - No extra structure requirement.
5. If the player has no cards of the same logical suit, they may play any cards.

Implementation details:

- `tractorPairCount` counts pairs that belong to a consecutive pair sequence of length 2 or more.
- `isolatedPairCount` counts pairs that are not part of any consecutive pair sequence.
- These two values together determine the minimum legal follow requirement when following a tractor.

---

## Slam Lead

A lead player may play 2 or more cards of the same logical suit as a slam lead, as long as the cards are not purely a tractor or purely a pair. A slam may contain mixed singles, pairs, and tractors.

### Slam Validation — `TrickEvaluator.slamInfo`

The slam is decomposed into tractor, pair, and single-card components via `decomposeSlam`.

The other three players are checked to see whether they hold a larger card/group of the same component type:

- If the slam contains singles, no opponent may hold a larger single.
- If the slam contains pairs, no opponent may hold a larger pair.
- If the slam contains tractors, no opponent may hold a larger tractor.

### Failed Slam Penalty — `GameEngine.analyzeSlamLead`

If the slam fails:

- Each failed card causes a 10-point penalty deducted from the slam leader's team.
- The opponent who holds the beating card/group is marked as having forced follow cards in `state.forcedFollowCards`. When following, that player must include the forced cards.
- If an opponent has both a larger single and a larger pair, the current implementation automatically chooses the forced group with the larger card count. (Official rules should allow the next player to specify — currently TODO.)
- Forced follow cards are cleared at the end of each trick.

---

## Winner Evaluation — `winner` / `beatsPlay`

Winning logic follows this strict priority:

1. **Combination-type eligibility comes first**
   - A throwaway / invalid structure cannot beat any valid play.
   - If the lead is a tractor, the follow play must also be a tractor with the same number of pairs.
   - If the lead is a pair, the follow play must also be a pair. A trump single cannot beat a non-trump pair.
   - If the lead is a single or a slam, there is no extra combination requirement.
2. **Trump beats non-trump within the same combination type**
   - Trump tractor > non-trump tractor; trump pair > non-trump pair; trump single > non-trump single.
3. **Same-type comparison**
   - Compare the highest card value. If values are equal, the earlier play wins.

If a slam lead is not beaten by trump, the slam leader remains the winner.

The first necessary condition for intercepting a slam with trump is that **all cards played must be trump** (`cards.allSatisfy { cardSuit($0) == nil }`).

### Comparing Multiple Trump Plays Against a Slam — `slamTrumpBeats`

When a slam is led and multiple players play trump, the comparison priority is determined by **the structure of the lead slam**, not a fixed hierarchy:

- Lead contains tractors → compare highest tractor first (more pairs wins; tie: compare highest card), then pairs, then singles.
- Lead contains pairs but no tractors → compare highest pair first, then singles.
- Lead contains only singles → compare highest single only.

Example: North leads Q♥ 10♥ (pure singles slam). East plays ♣3♣3, South plays Big Joker + trump K. Since the lead has no pairs, only the highest single is compared: Big Joker (100) > ♣3 (70) → South wins.

---

## Trump Declaration Rules

- **First round**: The player who declares trump becomes the dealer. `applyDeclaration` calls `setDealer`. A stronger declaration may override the previous one.
- **From the second round onward**: The dealer is determined once at the start of `startNewRound` from the previous round result. Trump declaration only updates the trump suit; `setDealer` must not be called again.

Judging condition: `state.roundNumber == 0`. `resolveRound` increments the round number; `startNewGame` resets it to 0. During the dealing phase of the first round, `roundNumber` remains 0.

### AI Trump Declaration Restrictions — `aiConsiderDeclaration`

| Declaration type | Restriction |
|---|---|
| Single-card declaration (strength = 1) | Only needs to meet the dealing-progress threshold; no extra hand requirement |
| Rank-pair first declaration (cur = 0) | Meets the threshold — no extra restriction |
| Rank-pair counter (cur > 0, different suit) | New suit count must exceed current declared count; if equal, must have more pairs; otherwise no override |
| Joker-pair no-trump (strength = 3) | Hand must contain ≥ 3 Aces and ≥ 3 pairs (tractors count as pairs); otherwise no override |

---

## Dealer Rotation Rules — `resolveRound`

- **Attacking side wins**: New dealer = next player clockwise after the current dealer (`nextPosition(after:)`).
- **Defending side wins**: New dealer = current dealer's partner (`(rawValue + 2) % 4`). This must happen every time the defending side wins, regardless of round number.

Do not add conditions such as `roundNumber > N`. Every defending-side win must set `pendingDealerPosition`.

---

## AI Play Priority — AIPlayer

### Decision Pipeline — `chooseCards`

The AI no longer follows a single fixed priority list. Every decision (lead or follow) runs the same three-stage pipeline:

1. **Generate candidates** — several generators each propose plausible moves (`AIMove` = cards + a `MoveKind` tag). A rule-based baseline move is always included so there is a sensible fallback.
2. **Score heuristically** — `scoreLead` / `scoreFollow` assign each candidate a numeric score; candidates are sorted best-first and (for leads) filtered for legality/policy.
3. **Monte Carlo rollout** — the top `monteCarloTopMoveCount` (= 5) candidates are each simulated `monteCarloSimulationCount` (= 24) times against sampled hidden hands; the move with the best blended score (rollout average + heuristic × 0.03) is played.

If `chooseCards` is called with an empty current trick it leads; otherwise it follows. Forced-follow cards (from a failed enemy slam) bypass the pipeline and go straight to the rule-based path.

### AI Memory — `AIContext`

Built once per decision from `completedTricks` + the current trick. It tracks:

- `playedCards`: every card already seen this round.
- `voidSuits`: which logical suit each player has revealed as void (they failed to follow it).
- `isLastPlayer`: whether the AI is the 4th/last to act this trick.

Derived helpers: `isEffectivelyBiggest` (all higher same-suit cards are exhausted in the double deck), `manyBigTrumpsRemain`, `unplayedSuitPoints`, `allEnemiesVoid` / `voidEnemies`.

### Lead Candidate Generators — `leadCards`

Lead candidates are generated and planned in this order before heuristic scoring:

1. Safe slam leads.
2. Absolute side winners: side-suit Ace, known highest side single, known highest side pair.
3. Legal tractors.
4. Strong pairs.
5. Normal pairs.
6. Long-suit / strategic plans: partner dump, no-trump control, trump lead candidates.
7. Trump transfer leads.
8. Weak cards.

| Generator | Proposes |
|---|---|
| `findSlamLeadCandidates` | Unbeatable slam throws (see below). |
| `findAbsoluteSideWinnerLeadCandidates` | Time-sensitive side winners: side Ace singleton, known highest side single, known highest side pair. |
| `findTractorLeadCandidates` | Legal tractors across logical suits, including trump/no-trump structures when legal and not walking into known void enemies. |
| `findStrongPairLeadCandidates` | Strong pairs such as Ace/rank/joker pairs, trump strong pairs, K/10 pairs, and point pairs. |
| `findPairFirstLeadCandidates` | All pair assets, including ordinary pairs, so they are considered as structures rather than lost to weak single leads. |
| `findPartnerDumpLeadCandidates` | Suits the partner is void in that still hold unplayed points — lead them so the partner can dump points to us. |
| `findNoTrumpControlLeadCandidates` | In no-trump rounds, joker/rank/Ace control pairs and tractors. |
| `findTrumpLeadCandidates` | Weak trump singles; a strong *safe* trump when on the dealer team or holding ≥ 6 trumps; the weakest trump pair. |
| `findTrumpTransferLeadCandidates` | A single low-cost, structure-safe small trump (kept as a candidate; valued via the Initiative/Point-Protection concepts). Only when trumps are sufficient. |
| `findWeakLeadCandidates` | Weakest leadable single (always-available fallback). |
| `leadCardsRuleBased` | The legacy ordered heuristic (below), added as one extra candidate. |

After sorting and `filterAllowedLeadMoves`, Monte Carlo Top-N is widened to forcibly keep important classes:

- Absolute side winners are kept so time-sensitive side A / highest-side winners are not displaced by ordinary pairs.
- Legal tractors are kept so AAKK / KKQQ / QQJJ are not displaced by their component pairs.
- Strong pairs are kept so they are not displaced by singleton control cards.
- Ordinary pairs are kept so Pair First assets still reach simulation.

### Lead Scoring — Six Strategic Concepts (`scoreLead`)

The lead path is built around six high-level concepts instead of a pile of overlapping bonuses/penalties. Each concept has one evaluator, and the readable weight table (`LeadWeight`) expresses the priority.

`scoreLead` is now a safety-gated weighted blend of six terms:

| # | Concept | Function | Weight | Meaning |
|---|---|---|---|---|
| 1 | Trick Security | `leadWinProbability` | 55 | Can our team actually take this trick (0–0.95)? |
| 6 | Point Protection | `leadPointConcept` | 40 | Team point gain (draw partner dumps) minus the risk of cheaply giving away points/lead (ruff risk, unsecured points). Acts as a safety gate. |
| 2 | Control Asset Preservation | `controlSpendCost` | 45 | Value of control assets the move spends — jokers (1.0), level (0.8), trump Ace (0.7), side Ace (0.5), other top card (0.35). |
| 3 | Structure Integrity | `structureFragmentationCost` + `wholeStructureControlValue` | 60 | Penalize partial use of a pair/tractor; reward leading an intact **dominant** structure. AKK is one group, AAKK one tractor. |
| 4 | Asset Decay | `assetDecayRealization` | 25 | Reward cashing a side Ace / side top single while it can still win cleanly (no enemy void yet) — stops the AI holding side aces forever. |
| 5 | Initiative Value | `leadInitiativeValue` | 20 | Only when the lead is securable and we hold assets worth deploying next. |

This single hierarchy replaces the former special cases by construction:

- **AKK / AAKK** are scored as whole structures — `structureFragmentationCost` makes "lead AA out of AAKK" cost a tractor-break, while leading the intact tractor earns `wholeStructureControlValue`, so it is no longer split into AA-then-KK.
- **Splitting any pair** is one tiered cost via `pairAssetWeight` (strong/trump 0.9–1.0, K/10 0.7, point 0.6, normal 0.4) — no longer five competing penalties.
- **Holding side aces too long** is countered by the Asset Decay term rather than ad-hoc cashing rules.
- **Leading a beatable pair before a sure winner** is avoided: `wholeStructureControlValue` only gives full credit to a *dominant* structure (`leadStructureDominant`, via `isEffectivelyBiggestPair` for side suits / strong trump). A non-winning pair like QQ (K/A still out) is discounted to ~30%, so cashing a sure Ace outranks leading a coin-flip pair.
- **Controlled trump transfer** is subsumed by Initiative + Point Protection (a cheap trump that keeps the lead on our side scores well without a dedicated rule).

A `.slam` move is exempt from the structure-fragmentation cost (a validated unbeatable throw) and gets `slamLeadValue`. No-trump rounds get higher `wholeStructureControlValue` for pairs/tractors.

### Lead Legality Filter — `filterAllowedLeadMoves` / `allowTrumpLead`

After scoring, trump leads are gated by `allowTrumpLead`: generally disallowed early unless the AI is short-handed (≤ 5 tricks left), trump-rich (≥ 8 trumps or ≥ 4 strong trumps), has more side cards than trumps, holds many exposed points to protect, or has high side-pair protection value. Non-trump moves always pass.

### Lead Rule-based Baseline — `leadCardsRuleBased`

The legacy ordered heuristic, still generated as one candidate (and the ultimate fallback):

0. **Slam lead** (`findSlamLead`).
1. **Currently-biggest non-trump** — prefer a pair, else the biggest single (skip suits all enemies are void in).
2. **Side-suit Ace** (`bestSideAce`).
3. **Non-trump tractor** (`findTractor`).
4. **Draw points from partner** — partner void + unplayed points in that suit.
5. **Non-trump pair** (`findBestPairAvoidingVoid` → `findPair`).
6. **Small trump** — pointless singleton first, then any singleton, then weakest trump pair.
7. **Few trumps (≤ 3)** — switch to leading the strongest side card/pair.
8. **Weakest card** (final fallback).

### AI Slam Lead Logic — `findSlamLead`

Unbeatable status is evaluated separately for singles and pairs:

- **Unbeatable single** (`isEffectivelyBiggestSingle`): For every higher rank in the same suit, `played + inHand ≥ 2` — both copies are accounted for, so no opponent can hold a bigger single.
- **Unbeatable pair** (`isEffectivelyBiggestPair`): For every higher rank in the same suit, `played + inHand ≥ 1` — opponents have at most one copy of any higher rank, so they cannot form a bigger pair.

Examples:
- Hand contains A♠ K♠ K♠ → KK is the biggest pair (the A is in hand, opponents can have at most one A so AA is impossible); A is the biggest single → valid slam.
- Hand contains A♠ Q♠ Q♠ and also K♠ → QQ is the biggest pair (K and A each have ≥ 1 copy accounted for, no KK or AA possible) → valid slam.

If all opponents are known to be void in the suit, only combinations containing pairs are led as slams (leading pure singles into a void hand is pointless).

---

## AI Follow Strategy — `followCards`

### Follow Pipeline

Like leading, following runs candidate generation → scoring → Monte Carlo:

1. A rule-based baseline (`followCardsRuleBased`) plus generated non-trump/structure candidates (`generateFollowCandidates`) plus unified trump-control candidates (`generateTrumpControlCandidates`).
2. Keep only legal plays (`isValidPlay`), then apply:
   - `filterTrumpControlMoves`: classifies every trump-spending move with the unified Trump Control Decision and, on point-heavy or high-initiative tricks, filters away passive trump plays when secure/contesting options exist.
   - `filterHighInitiativeWinningMoves`: when the AI badly needs initiative (`initiativeNeed` ≥ 100), keep only cheap, non-pair-breaking, non-big-trump winning moves if any exist; trump moves must also be non-passive and positive under Trump Control.
3. Score with `scoreFollow`, take the top 5, and pick via Monte Carlo rollout.

Forced-follow cards (failed enemy slam) skip the pipeline entirely.

### Follow Scoring — `scoreFollow`

`scoreFollow` splits cleanly in two: **any move that spends trump** goes through the unified Trump Control Decision (below); **non-trump moves** use the generic win-class score (`followWinClassScore`). On top of that, both share generic terms: support/dump points only when *secure* (`trickSecureBefore`), suit-clearing bonus, and structure-break penalties (`breakPenalty` ×16–18, `strongBreakPenalty` ×22–24). `MoveKind` nudges: baseline +5, support +8 (partner winning), discard +4 (opponent winning), and non-trump win ±8/−12.

#### Unified Trump Control Decision — `trumpControlScore`

Every trump-spending follow decision — trump-pull follow, ruffing when void, over-ruffing an opponent's ruff, helping a teammate who isn't secure, and fighting for the lead — now goes through **one** model that answers: *is it worth spending this trump to gain, keep, or secure control of this trick?*

The model has three entry points:

- `generateTrumpControlCandidates`: adds every legal trump-control candidate: trump singles/pairs/tractors when following trump, ruffs while void, over-ruffs, and matching trump structures against slam leads.
- `filterTrumpControlMoves`: applies the A/B/C decision to discard passive trump on point-heavy or high-initiative tricks.
- `trumpControlDecision` / `trumpControlScore`: returns a `TrumpControlDecision` with classification, score, lead-control value, and trump cost.

Candidates are classified into `TrumpControlClass`:

- **A — `secureWinner`**: wins the final trick, not merely the current lead. For trump plays this uses `isSecureWinningTrumpFollow`, which accounts for later opponents who can still overtake or ruff.
- **B — `contestingTrump`**: may not be final-safe, but wins now or forces opponents to spend higher trump, reducing cheap scoring risk.
- **C — `passiveTrump`**: spends trump without winning or securing the trick.

Inputs and behavior:

- **Trick points** (tiered 0 / 5 / 10 / 15) scale the reward for A/B and the penalty for C. 0 → conserving (C) is fine; 5 → contest considered; 10+ → secure/contest preferred; 15+ → passive heavily penalized, and `filterTrumpControlMoves` drops passive plays when secure/contesting trump exists.
- **Current winner.** Opponent winning → reward A/B that actually wins, penalize decorative C (and a non-trump-lead ruff that can't win is wasted trump → extra penalty). Teammate winning → if secure, don't overtake or waste trump (−35−cost for an unnecessary win); if not secure and there are points, help secure (A from 5+ points).
- **Trick security**, not just temporary lead, drives the A/B/C split, so a temporary winner with later opponents holding higher unknown trump is *not* treated as safe.
- **Lead-control value** (`trumpLeadControlValue`, from `initiativeNeed` of the hand after the move, capped 25) adds value to winning when the AI has cashable assets / a long-suit plan — so it will spend a reasonable trump to regain initiative.
- **Trump cost** (`trumpControlCost`: jokers 14, level 11, trump-Ace 9, else by weight) is **damped** at high trick points (`trumpCostDamping`: ×1 → ×0.3 from 0 to 15+ points) so conserving never dominates a points-rich or high-initiative trick. Breaking trump pairs/tractors is charged once via the shared `structureBreakPenalty`.

This is the principled replacement for the old "play the smallest legal trump" fallback: a Secure winner when needed and available → a Contesting trump when the trick value/initiative justifies it → a Passive low trump only for low-value or already-secure situations.

### Suit Matching

- First find cards matching the lead play's logical suit.
- If enough same-suit cards are available: try to beat the current winning play; if unable, play the weakest same-suit cards (or support cards when partner is winning).
- If not enough same-suit cards: play all available same-suit cards first, then fill remaining slots by strategy.

### Follow Sub-strategies

| Lead Type | Function | Logic |
|---|---|---|
| Tractor | `followTractor` | Prefer the weakest tractor that can win; if none, play the weakest tractor; if no tractor, play the weakest cards. |
| Pair | `followPair` | Prefer the weakest pair that can win; if none, play the weakest pair; if no pair, play the weakest cards. |
| Single | Inline logic | If a winning card exists, play the weakest one that wins. If unplayed scoring cards in the led suit could still overtake the current winner and a later opponent can still follow suit, use `pointGuardCard`: with no points currently in the trick, play the smallest card that guards the scoring card; with points already in the trick, prefer the smallest card whose higher ranks are fully accounted for, and fall back to the strongest candidate if none is safe. |

### When Partner Is Winning — `partnerWinning`

- Usually play support cards: prefer high-scoring cards (10 / K / 5), then weak non-trump cards (`partnerSupportOrder`).
- When following a single-card lead, if an unplayed scoring card in that suit could overtake the current winner and a later opponent can still act, the AI may overtake its partner with a larger same-suit card (`pointGuardCard`) to protect the trick. If the trick already contains points, it also checks whether higher ranks are still live outside; for example, Q is enough when both A copies are accounted for, but A is required when an outside A may still exist.

### Void-fill Strategy When Partner Is At Risk — `voidFillCards`

If the AI is void in the lead suit, `voidFillCards` now first calls `bestTrumpControlFill`, which asks the same Trump Control model whether a trump fill is worth playing. It only accepts:

- a `secureWinner` with positive value, a 10+ point trick, or meaningful lead-control value; or
- a `contestingTrump` when an opponent is winning and the trick/initiative value justifies contesting.

Only when Trump Control declines does the function fall back to the older conservative discard/support policy. `partnerAtRisk` and `enemySubsequentVoidInLead` still influence the fallback path, but they no longer directly force "smallest trump" or "largest trump" without model approval.

### Partner Slam Support

When the partner leads a slam of ≥ 4 cards containing pairs and is currently winning, play support cards using the tractor-follow strategy to contribute scoring cards (`safePartnerCards`).

### Trumping a Slam Lead

- If the lead slam is pure singles, trump interception only compares the highest single. AI prefers singleton trump cards and avoids breaking trump pairs for this case.
- If the lead slam contains pairs or tractors, a trump interception must match the slam structure. AI builds the weakest matching tractors, pairs, then singles via `buildMatchingSlamTrump`.

### Safe Trump Play — `isSafeTrumpFiller`

When following a trump lead as a non-last player with an unplayed opponent still to act, prefer "safe" trump cards to avoid being intercepted:

- **Always safe**: Big Joker, Small Joker, rank cards, trump-suit Ace or higher.
- **Dynamically safe**: If all scoring cards (K / 10 / 5, excluding rank cards) of higher rank in the trump suit have been fully played (both copies in a double deck), a lower card also becomes safe. For example, once both K's are played, J becomes safe.

### Aggressive Mode

Triggered when the current trick already has ≥ 10 points **and** the attacking team's total score > 60:

- **Not the last player**: Play the strongest card that can beat the current winner.
- **Last player**: Play the weakest card that can beat the current winner.
- **Cannot beat**: Play the weakest card (do not waste scoring cards on an unwinnable trick).

### Discard Priority — `discardOrder`

1. Non-trump before trump.
2. Within the same category: 0-point cards first, then 5-point, then 10-point.
3. Same points: sort by rank from low to high.

### Support Card Priority — `partnerSupportOrder`

1. High-point cards first (10 / K / 5), then 0-point cards.
2. Same points: non-trump first.
3. Then sort by `discardOrder`.

### Following a Trump Tractor When `suitCards` Is Empty and Opponent Is Winning

If the AI has no cards of the same logical suit, it may search the entire hand for a tractor or pair that can beat the current winning play.

---

## Monte Carlo Rollout — `monteCarloBestMove`

Both leading and following finish by simulating the top 5 heuristic candidates:

- For each candidate, run 24 simulations. Each simulation samples the three hidden hands (`sampleHiddenHands`) from the remaining double deck minus all known cards, using a deterministic seeded RNG (`MonteCarloRNG` + `monteCarloSeed`) so results are reproducible. The sampler respects each player's known voids (a player never receives a card in a logical suit they've shown void) and only treats the kitty as known when the deciding AI **is** the dealer; a non-dealer leaves the kitty in the unknown pool, but still excludes cards it can *prove* are buried (when all three opponents are void in a logical suit, every remaining card of that suit must be in the kitty).
- `simulateCurrentTrick` plays the candidate, then lets the remaining players follow with a lightweight policy (`monteCarloFollowCards`) until the trick completes, and scores the outcome: `capturedPoints × 2 + wonTrickValue × 2 + remainingAssetValue + initiative adjustment − earlyTrumpPenalty × 3`, with small extra penalties for handing over points or rewards for winning with zero-point cards.
- Final pick = average rollout score + heuristic score × 0.03 (the heuristic acts as a light tie-breaker). Constants live in `monteCarloTopMoveCount` and `monteCarloSimulationCount`.

---

## Game Flow — GameEngine

```text
startNewGame()
  → startNewRound()
    → dealCardsAnimated()  // Deal cards + AI trump declaration
    → afterDealingComplete()
      → proceedToKittyExchange()  // Kitty exchange
    → startPlaying()
      → Players take turns: humanPlay / aiTakeTurn
      → resolveTrick()   // Resolve one trick
      → resolveRound()   // Resolve the round after the final trick
```

### Trump Declaration

- Trump may be declared during the dealing phase.
- Single-card declaration: `strength = 1`; pair declaration: `strength = 2`; joker-pair no-trump: `strength = 3`.
- A counter-declaration must be strictly stronger than the current declaration.
- If no one declares trump after dealing: human dealer must manually declare; AI dealer is forced to declare.

### Kitty Exchange

- The dealer places 8 cards into the kitty.
- AI strategy: prefer burying weak non-trump cards (reverse `handSortOrder`, take first 8).
- If the attacking side wins the final trick, they capture the kitty points × 2.

### Level-up Rules

Attacking side scores ≥ 80 → attacking side wins. Level-up steps = `(score - 80) / 40`:

- 80–119 pts → 0 levels (dealer changes only)
- 120–159 pts → 1 level up
- 160–199 pts → 2 levels up
- 200+ pts → 3+ levels up

Attacking side scores < 80 → defending side wins:

- 0 pts → 3 levels up
- < 40 pts → 2 levels up
- Otherwise → 1 level up

---

## Key Utility Functions — CardComparator

| Function | Purpose |
|---|---|
| `isTrump` | Determines whether a card is trump |
| `trumpWeight` | Calculates trump strength weight (Big Joker = 100 …) |
| `beats(a, b)` | Checks whether card `a` beats card `b` |
| `pairKey` | Pair matching key: same rank and suit, or same rank-trump |
| `pairOrderValue` | Sort value for pairs and tractors |
| `areAdjacentPairRanks` | Checks whether two pairs are adjacent and form a tractor |
| `handSortOrder` | Sorts hand cards: trump first, non-trump grouped by suit |
| `logicalSuit` | Returns logical suit; trump cards return `nil` |

---

## LAN Multiplayer — LANMultiplayerManager

- The host owns the full game state; clients only receive snapshots.
- Client actions are sent as `MultiplayerAction`: `declareTrump`, `confirmKitty`, `play`.
- The host broadcasts `GameSnapshot`; each player only receives their own hand cards.
- Player identity in multiplayer uses the `MCPeerID` object identity, not `displayName`; multiple devices named "iPhone" must not collide or crash.
- Lobby player count is built from the host's connection cache merged with `session.connectedPeers`, preventing stale lobby snapshots when a new player joins.
- Only the host may advance global flow. Client "Next Round" controls are disabled.
- Once any remote player is connected, fast dealing is disabled for the whole multiplayer room: neither host nor clients show the fast-deal button, and `toggleFastDealing` rejects multiplayer calls.
- When the host leaves, it broadcasts `roomClosed`, disconnects all clients, and everyone returns to the main menu. If a client misses the message but detects host disconnection, it uses the same return-to-menu fallback.

---

## Common Modification Entry Points

| Requirement | File |
|---|---|
| Modify play validation rules | `TrickEvaluator.isValidPlay` |
| Modify slam validation / decomposition logic | `TrickEvaluator.slamInfo` / `decomposeSlam` |
| Modify slam winner comparison logic | `TrickEvaluator.slamTrumpBeats` |
| Modify slam penalty calculation | `TrickEvaluator.slamPenaltyPoints` |
| Modify slam forced-follow logic | `GameEngine.analyzeSlamLead` |
| Modify trick winner evaluation | `TrickEvaluator.beatsPlay` / `winner` |
| Modify AI lead strategy | `AIPlayer.leadCards` (candidates) / `scoreLead` (weights) / `leadCardsRuleBased` (baseline) |
| Tune AI lead scoring weights / priority | `AIPlayer.LeadWeight` (the six concept weights) |
| Tune a single lead concept | `leadWinProbability` (security) · `leadPointConcept` (points) · `controlSpendCost` (control) · `structureFragmentationCost` + `wholeStructureControlValue` + `pairAssetWeight` (structure) · `assetDecayRealization` (decay) · `leadInitiativeValue` (initiative) |
| Tune pair-break / structure penalties | `AIPlayer.structureBreakPenalty` / `strongStructureBreakPenalty` (and their multipliers in `scoreLead` / `scoreFollow`) |
| Modify AI Monte Carlo rollout | `AIPlayer.monteCarloBestMove` / `simulateCurrentTrick` / `monteCarloTopMoveCount` / `monteCarloSimulationCount` |
| Modify AI slam lead conditions | `AIPlayer.findSlamLead` / `isEffectivelyBiggestSingle` / `isEffectivelyBiggestPair` |
| Modify AI follow strategy | `AIPlayer.followCards` (candidates) / `scoreFollow` (weights) / `followTractor` / `followPair` |
| Tune AI follow scoring weights | `AIPlayer.scoreFollow`; trump-spending moves should be tuned through `trumpControlDecision` / `trumpControlCost` / `trumpCostDamping` |
| Modify AI trump-control follow logic | `AIPlayer.generateTrumpControlCandidates` / `filterTrumpControlMoves` / `trumpControlDecision` / `bestTrumpControlFill` / `isSecureWinningTrumpFollow` |
| Modify AI safe trump logic | `AIPlayer.isSafeTrumpFiller` / `isSafeTrump` |
| Modify AI aggressive mode threshold | `AIPlayer.followCards` (`trickPoints` / `attackScore` check) |
| Modify discard / support-card logic | `AIPlayer.discardOrder` / `partnerSupportOrder` |
| Modify trump strength order | `CardComparator.trumpWeight` |
| Modify level-up score thresholds | `GameEngine.resolveRound` |
| Modify AI trump declaration restrictions | `GameEngine.aiConsiderDeclaration` |
