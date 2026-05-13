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

### Lead Play Priority — `leadCards`

0. **Slam lead**: If 2 or more unbeatable cards exist in the same non-trump suit, lead them together as a slam (`findSlamLead`).
1. **Biggest non-trump pair**: If the highest cards in a suit form a pair, prefer leading that pair.
2. **Biggest non-trump single**: Lead the highest single in a suit where the AI holds the top card.
3. **Side-suit Ace**: Play the strongest non-trump Ace (`bestSideAce`).
4. **Non-trump tractor**: Find a consecutive pair in a non-trump suit (`findTractor`).
5. **Non-trump pair**: Find a pair in a non-trump suit; prefer the strongest (`findPair`).
6. **Draw scoring cards from partner**: If partner is void in a suit that still has unplayed scoring cards, lead that suit to let partner discard points.
7. **Smallest trump card**: Play the weakest trump card.
8. **Weakest card**: Play the weakest card in hand.

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

### Suit Matching

- First find cards matching the lead play's logical suit.
- If enough same-suit cards are available: try to beat the current winning play; if unable, play the weakest same-suit cards (or support cards when partner is winning).
- If not enough same-suit cards: play all available same-suit cards first, then fill remaining slots by strategy.

### Follow Sub-strategies

| Lead Type | Function | Logic |
|---|---|---|
| Tractor | `followTractor` | Prefer the weakest tractor that can win; if none, play the weakest tractor; if no tractor, play the weakest cards. |
| Pair | `followPair` | Prefer the weakest pair that can win; if none, play the weakest pair; if no pair, play the weakest cards. |
| Single | Inline logic | If a winning card exists, play the weakest one that wins; otherwise play the weakest card. |

### When Partner Is Winning — `partnerWinning`

- Do not try to beat the current winning play.
- Play support cards: prefer high-scoring cards (10 / K / 5), then weak non-trump cards (`partnerSupportOrder`).

### Partner Slam Support

When the partner leads a slam of ≥ 4 cards containing pairs and is currently winning, play support cards using the tractor-follow strategy to contribute scoring cards (`safePartnerCards`).

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
| Modify AI lead strategy | `AIPlayer.leadCards` |
| Modify AI slam lead conditions | `AIPlayer.findSlamLead` / `isEffectivelyBiggestSingle` / `isEffectivelyBiggestPair` |
| Modify AI follow strategy | `AIPlayer.followCards` / `followTractor` / `followPair` |
| Modify AI safe trump logic | `AIPlayer.isSafeTrumpFiller` |
| Modify AI aggressive mode threshold | `AIPlayer.followCards` (`trickPoints` / `attackScore` check) |
| Modify discard / support-card logic | `AIPlayer.discardOrder` / `partnerSupportOrder` |
| Modify trump strength order | `CardComparator.trumpWeight` |
| Modify level-up score thresholds | `GameEngine.resolveRound` |
| Modify AI trump declaration restrictions | `GameEngine.aiConsiderDeclaration` |
