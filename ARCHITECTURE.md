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

`Model` and `Damage` know nothing about the app. `Battle` — `TurnModel`,
`TurnGame`, `BattleEngine` — is **isolated to nothing**: it takes a `Board`
(a value) and a `Rulebook` (an immutable, `Sendable` snapshot of the usage
table) and can run on any thread. The only main-actor code on the engine's
path is building a `Board` from two `Team`s, which happens once, at the
boundary. The search runs as a detached task and hops back to the main actor
with its answer; a result for a board that has since moved on is dropped.

`Store` is `@MainActor` and owns the dataset, saved teams, sprite caches and
the analysis caches. Views read it through the environment.

## Invariants worth knowing

- **Hidden information is hidden.** The board keeps the truth (their real
  four, their real items) so a turn can be played, but nothing that advises
  the player reads past what has been seen: their bench shows as `?` with
  odds, the search plays against the likeliest pairs, their Speed is shown
  without the item, and the pre-turn read is taken on the likeliest world.
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

## Checking a change

```
make test        # the suite — must pass
make hitch       # no main-thread stretch past four frames; search reaches depth ≥ 2
make snapshot    # look at build/shots/ — the renders catch layout regressions
make accuracy    # 55.2% on 1,454 games is the floor; a drop is a regression
```

## Known debts

- `TurnHarnessTests` is one long test: its sections share fixtures. Splitting
  it into per-area cases with a shared fixture file is the next step.
- The engine's answer is right for the turn in hand; two plies down it
  follows the likeliest Protect branch rather than blending both.
- Their side of the matrix evaluates your switch plays against your real
  bench. Their switch-in *scoring* sees only your actives; a two-board solve
  (their view vs yours) would close the gap.
- Floette's Eternal Flower form is synthesised by the generator; Serebii's
  Champions listings omit it.
