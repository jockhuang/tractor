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
2. Determine the lead play’s “logical suit”.
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

The slam is decomposed into:

- Tractor components
- Pair components
- Single-card components

This is handled by `decomposeSlam`.

The other three players are checked to see whether they hold a larger card/group of the same component type:

- If the slam contains singles, no opponent may hold a larger single.
- If the slam contains pairs, no opponent may hold a larger pair.
- If the slam contains tractors, no opponent may hold a larger tractor.

### Failed Slam Penalty — `GameEngine.analyzeSlamLead`

If the slam fails:

- Each failed card causes a 10-point penalty.
- The penalty is deducted from the slam leader’s team.
- The opponent who holds the larger card/group is marked as having forced follow cards in `state.forcedFollowCards`.
- When following, that player must include the forced cards.
- If an opponent has both a larger single and a larger pair, the current implementation automatically chooses the forced group with the larger card count.
  - Official rules should allow the next player to specify the required play. This is currently marked as TODO.
- Forced follow cards are cleared at the end of each trick.

---

## Winner Evaluation — `winner` / `beatsPlay`

Winning logic follows this strict priority:

1. **Combination-type eligibility comes first**
   - A throwaway / invalid structure cannot beat any valid play.
   - If the lead is a tractor, the follow play must also be a tractor with the same number of pairs.
   - If the lead is a pair, the follow play must also be a pair.
   - A trump single cannot beat a non-trump pair.
   - If the lead is a single or a slam, there is no extra combination requirement.
2. **Trump beats non-trump within the same combination type**
   - Trump tractor > non-trump tractor
   - Trump pair > non-trump pair
   - Trump single > non-trump single
3. **Same-type comparison**
   - Compare the highest card value.
   - If values are equal, the earlier play wins.

If a slam lead is not beaten by trump, the slam leader remains the winner.

### Comparing Multiple Trump Plays Against a Slam — `slamTrumpBeats`

When the lead is a slam and multiple players play trump, trump plays are compared by structure, not simply by the highest single card:

1. Compare the highest tractor first.
   - More pairs wins.
   - If the number of pairs is the same, compare the highest card.
2. If there is no tractor, compare the highest pair.
3. If there is no pair, compare the highest single card.

---

## Trump Declaration Rules

- **First round**:
  - The player who declares trump becomes the dealer.
  - `applyDeclaration` calls `setDealer`.
  - A stronger declaration may override the previous declaration.
- **From the second round onward**:
  - The dealer is determined once at the start of `startNewRound`, based on the previous round result.
  - Trump declaration only updates the trump suit.
  - It must not call `setDealer` again.

Judging condition:

```swift
state.roundNumber == 0
```

`resolveRound` increments the round number.  
`startNewGame` resets it to 0.  
During the dealing phase of the first round, `roundNumber` remains 0.

---

## Dealer Rotation Rules — `resolveRound`

- If the attacking side wins:
  - New dealer = the next player clockwise after the current dealer.
  - Implemented by `nextPosition(after:)`.
- If the defending side wins:
  - New dealer = the current dealer’s partner.
  - Formula: `(rawValue + 2) % 4`
  - This must happen every time the defending side wins, regardless of the round number.

Important:

Do not add conditions such as `roundNumber > N`.  
Every defending-side win must set `pendingDealerPosition`.

---

## AI Play Priority — AIPlayer

### Lead Play Priority — `leadCards`

1. **Side-suit Ace**
   - Play the strongest non-trump Ace in hand.
   - Implemented by `strongestSideAce`.
2. **Non-trump tractor**
   - Find a tractor in a non-trump suit.
   - Implemented by `findTractor`.
3. **Non-trump pair**
   - Find a pair in a non-trump suit.
   - Prefer the strongest pair.
   - Implemented by `findPair`.
4. **Smallest trump card**
   - Play the weakest trump card.
5. **Weakest card**
   - Play the weakest card in hand.

---

## AI Follow Strategy — `followCards`

### Suit Matching

- First, find cards in hand that match the lead play’s logical suit.
- If the AI has enough same-suit cards:
  - Try to beat the current winning play.
  - If it cannot beat it, play the weakest same-suit cards.
  - If its partner is currently winning, play support cards instead.
- If the AI does not have enough same-suit cards:
  - Play all available same-suit cards first.
  - Fill the remaining slots according to discard strategy.

### Follow Sub-strategies

| Lead Type | Function | Logic |
|---|---|---|
| Tractor | `followTractor` | Prefer the weakest tractor that can win. If none, play the weakest tractor. If no tractor, play the weakest cards. |
| Pair | `followPair` | Prefer the weakest pair that can win. If none, play the weakest pair. If no pair, play the weakest cards. |
| Single | Inline logic | If there is a card that can win, play the weakest winning card. Otherwise, play the weakest card. |

### When Partner Is Winning — `partnerWinning`

- Do not try to beat the current winning play.
- Play support cards instead.
- Support priority:
  1. High scoring cards: 10 / K / 5
  2. Weak non-trump cards
  3. Sorted by `partnerSupportOrder`

### Discard Priority — `discardOrder`

From highest discard priority to lowest:

1. Non-trump cards before trump cards.
2. Within the same category, low-point cards first:
   - 0 points
   - 5 points
   - 10 points
3. If points are the same, sort by rank from low to high.

### Support Card Priority — `partnerSupportOrder`

1. High-point cards first:
   - 10 / K / 5
   - then 0-point cards
2. If points are the same, non-trump cards first.
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
- Single-card declaration has `strength = 1`.
- Pair declaration has `strength = 2`.
- A counter-declaration must be strictly stronger than the current declaration.
- If no one declares trump after dealing:
  - Human dealer must manually declare trump.
  - AI dealer will be forced to declare trump.

### Kitty Exchange

- The dealer places 8 cards into the kitty.
- AI kitty exchange strategy:
  - Prefer burying weak non-trump cards.
  - Sort by reversed `handSortOrder` and take the first 8 cards.
- If the attacking side wins the final trick, they capture the kitty points × 2.

### Level-up Rules

If the attacking side scores 80 or more points:

```text
Attacking side wins.
Level-up steps = (score - 80) / 40
```

Examples:

- 80–119 points → 0 levels up, dealer changes only
- 120–159 points → 1 level up
- 160–199 points → 2 levels up
- 200+ points → 3+ levels up

If the attacking side scores less than 80 points:

```text
Defending side wins.
```

Level-up steps:

- 0 points → 3 levels up
- Less than 40 points → 2 levels up
- Otherwise → 1 level up

---

## Key Utility Functions — CardComparator

| Function | Purpose |
|---|---|
| `isTrump` | Determines whether a card is trump |
| `trumpWeight` | Calculates trump strength weight |
| `beats(a, b)` | Checks whether card `a` beats card `b` |
| `pairKey` | Pair matching key: same rank and suit, or same rank-trump |
| `pairOrderValue` | Sort value for pairs and tractors |
| `areAdjacentPairRanks` | Checks whether two pairs are adjacent and form a tractor |
| `handSortOrder` | Sorts hand cards: trump first, non-trump grouped by suit |
| `logicalSuit` | Returns logical suit; trump cards return `nil` |

---

## LAN Multiplayer — LANMultiplayerManager

- The host owns the full game state.
- Clients only receive snapshots.
- Client actions are sent as `MultiplayerAction`.
  - `declareTrump`
  - `confirmKitty`
  - `play`
- The host broadcasts `GameSnapshot`.
- Each player only receives their own hand cards.

---

## Common Modification Entry Points

| Requirement | File |
|---|---|
| Modify play validation rules | `TrickEvaluator.isValidPlay` |
| Modify slam validation / decomposition logic | `TrickEvaluator.slamInfo` / `decomposeSlam` |
| Modify slam penalty calculation | `TrickEvaluator.slamPenaltyPoints` |
| Modify slam forced-follow logic | `GameEngine.analyzeSlamLead` |
| Modify trick winner evaluation | `TrickEvaluator.beatsPlay` / `winner` |
| Modify AI lead strategy | `AIPlayer.leadCards` |
| Modify AI follow strategy | `AIPlayer.followCards` / `followTractor` / `followPair` |
| Modify discard / support-card logic | `AIPlayer.discardOrder` / `partnerSupportOrder` |
| Modify trump strength order | `CardComparator.trumpWeight` |
| Modify level-up score thresholds | `GameEngine.resolveRound` |
