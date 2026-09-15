# ChampionsLab — architecture

A macOS SwiftUI app for Pokémon Champions team building and battle analysis.
One Swift package, one library, one one-line executable.

```
Package.swift
Sources/ChampionsLab/           the library — everything
  Model/      Form, Move, Item, Team, Stat maths, Rulebook   (Foundation only)
  Data/       Store (loads and owns the dataset), usage feed, team import
  Damage/     the damage calculator, move quality, the one-on-one duel engine
  Battle/     the turn model, the matrix game, the reads, the search
  Analysis/   matchup grid, bring-four, builder, refiner, advisor, forecast…
  UI/         palette, sprites, shared components, the versus banner
  Screens/    one file per screen; RootView holds the sidebar and the scene
Sources/ChampionsLabApp/        `@main`, nothing else
Tests/ChampionsLabTests/        XCTest; `swift test`
Tools/                          snapshot, hitch, accuracy, calibrate — executables
                                that compile the library's sources directly
Scripts/                        build.sh, make-dmg.sh, the data generators
data/                           champions.json, sprites, matches, tournaments
```

## Layering

`Rulebook` is the currency. The dex does not change while a battle is being
played, so everything the engine needs out of it — the forms, the moves, the
usage table, and the derived "what is this move worth" — is snapshotted once
into an immutable `Sendable` value. Anything that takes a `Rulebook` instead
of the `Store` is isolated to nothing and runs on any thread:

- `Model` and `Damage`, including `DuelEngine`
- `Battle`: `TurnModel`, `TurnGame`, `BattleEngine`, and `Board` — including
  `Board.opening`, which chooses their four and works out both sides' bench
  guesses
- `Analysis`: `Matchup` and `BringFour`, which is the whole versus grid

`Store` is `@MainActor` and owns the dataset, the saved teams, the sprite and
analysis caches, and the network refresh. It builds the `Rulebook` and
forwards its own lookups to it, so there is one implementation of each rather
than two. Views read the store through the environment; anything expensive
takes `store.rulebook` and leaves.

The one shared cache inside the `Rulebook` — parsed move quality, because
pricing a move is a parse and the forecast prices every move of every form —
sits behind a lock, and does its work outside it.

## Invariants worth knowing

- **Hidden information is hidden, both ways.** The board keeps the truth
  (their real four, their real items) so a turn can be played, but nothing
  that advises the player reads past what has been seen: their bench shows as
  `?` with odds, the search plays against the likeliest pairs, their Speed is
  shown without the item, and the pre-turn read is taken on the likeliest
  world. Their side is solved the same way in reverse: `Board.asTheySeeIt`
  replaces *your* unseen back two with the pair they expect, and
  `TurnGame(believingTheirs: true)` answers their half of the matrix on that
  board. `HiddenInformationTests` pins the invariant — their mix must not
  move when your hidden bench changes underneath it.
- **The value is zero-sum by construction** (`TurnModel.value`), so the
  matrix game has an equilibrium; regret matching finds it.
- **A played turn rolls; the search averages.** Accuracy, criticals,
  secondary effects and repeat-Protect odds are rolled per target in a played
  turn (`rolling: true`); the search uses expected values and applies only
  certain effects — except repeat Protect, where every branch is weighed.
- **Turn order is re-checked before every action**, never sorted once:
  Tailwind mid-turn speeds the partner immediately; Trick Room inverts.
- **One action, one step.** Everything a move does — to however many — is
  one `Board.Step`; the residuals are one step; switches and arrivals are one
  step each, in Speed order.
- **Rules are read from the text where the text is regular**: two-turn
  moves, drains, secondary effects, target/self stage changes, healing,
  Weather Ball. Closed families that read alike (Protect, the party moves)
  are named.

## Practising

The point of the battle screen is not to watch a game, it is to be told where
you went wrong. Every turn is marked as it is played: what you did, what it
was worth against the mix they were actually playing, and what the engine
would have done instead — both on one scale, so the gap means something.
Judging a choice against what they *happened* to play would reward luck, so
the comparison is always against their mix.

The Review panel reads that back. While a game is running it is in turn
order; once it is over the worst turns come first, because that is what there
is to learn from. Clicking a turn takes the whole game back to the start of
it — the board, the log and the turn number — so the answer to "what should I
have done" is to play it again, not to read about it. The end-of-game card
names the three turns that cost the most.

## Threads

`Store`, `Matchup`, `BringFour` and the views are main-actor. The turn model,
the matrix game and the search are not, so everything expensive runs off the
main thread and hands a value back:

| work | where it runs |
|---|---|
| `BattleEngine.think` | detached task, result applied on the main actor |
| the played turn's solve | detached task, then `resolve(_:mine:solved:)` |
| the versus lobby: two grids, two bring-four searches | detached task |
| `Board.opening`: their four and both sides' bench guesses | detached task, behind the opening flash |
| a turn's resolution, the reads, the previews | main actor; all cheap |
| loading the dataset, saving teams, the usage refresh | main actor, by definition |

Every detached piece carries a ticket — the turn number, or a counter — and
an answer to a position that has since moved on is dropped rather than
applied to the wrong board. The timing harness holds the line: no stretch of
main-thread work longer than four frames.

## Checking a change

```
make test        # the suite — must pass
make hitch       # no main-thread stretch past four frames; search reaches depth ≥ 2
make snapshot    # look at build/shots/ — the renders catch layout regressions
make accuracy    # 55.2% on 1,454 games is the floor; a drop is a regression
```

## The suite

`Tests/ChampionsLabTests` is one case per area over a shared `HarnessCase`,
which owns the dataset, the `check` that prints as well as asserts, and the
teams the cases build their boards out of. A case that wants its own version
of a shared team simply declares it: a local declaration shadows the
inherited one. Add a rule, add a check to the case that owns that area.

| case | what it holds |
|---|---|
| `ImportTests` | the paste importer and the EV-to-SP arithmetic |
| `MatchupGridTests` | the six-against-six grid, move valuation, bring-four |
| `SpeedAndProtectTests` | Speed on the field, Protect in a duel, the clock |
| `SolverTests` | the matrix game, the reads, switching in |
| `MegaEvolutionTests` | one per side, in Speed order, and the weather war |
| `TurnOrderTests` | the order a turn resolves in, and what a move costs |
| `AbilityTests` | abilities during a turn, and what arriving does |
| `HiddenInformationTests` | what neither side can see |
| `MoveRuleTests` | rules belonging to particular moves |
| `DiceTests` | what a played turn rolls and the search averages |
| `StatusTests` | conditions, healing, confusion |
| `EncoreTests` | stages in the roll, ability priority, Encore |
| `StatsAndDamageTests` | the stat and damage arithmetic |

## Known debts

- The two-board solve costs a second matrix, so it runs where the answer
  becomes somebody's orders — the root of a search, the turn being played,
  the line on screen — and not inside the recursion, where the difference is
  second order and the cost is a doubling.
- Floette's Eternal Flower form is synthesised by the generator; Serebii's
  Champions listings omit it.
