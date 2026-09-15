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

## Swift 6

Every target builds in **Swift 6 language mode** with no warnings, which is
the point of all of the above: the compiler checks that the engine touches no
shared mutable state rather than the author promising it. Two rules keep it
that way.

Anything shared across threads goes through `Memo` — a small cache behind a
lock, which does its work *outside* the lock, because everything cached here
is a pure function of its key and two threads racing to compute the same
entry wastes microseconds where holding the lock across the work would
serialise the very paths that were moved off the main thread. Move
drawbacks, compiled patterns and move quality all use it.

The one deliberate escape hatch is `Builder.Weights.current`, marked
`nonisolated(unsafe)` with the reason beside it: `Tools/calibrate` fits it
against tournament results and writes it once before anything reads it, and
every read is on a hot path.

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

## How a rule gets into the model

There are five places a rule can live, and which one it belongs in is decided
by how the dex writes it — not by taste.

| | when | examples |
|---|---|---|
| **read from the text** | the dex prints the rule in a regular sentence | two-turn moves, drains, secondary effects, stat changes, healing, target drops |
| **a named closed set** | a small family whose sentences read alike but whose effects differ | `Move.protectMoves`, `partyMoves`, `sideMoves`, `allyMoves`, `selfMoves` |
| **named by id** | one-off arithmetic no sentence could carry | Weather Ball, Rising Voltage, Last Respects, Stomping Tantrum, Sucker Punch |
| **a case in the turn model** | a move that changes the shape of a turn | Leech Seed, Taunt, Encore, Parting Shot, Ally Switch, the guards |
| **an ability or item hook** | abilities have no grammar to parse; each is a `case` where it fires | `entryAbility`, `contact`, the pinch abilities, `speed(in:)`, White Herb |

A move's text is parsed **once** into `Move.Rules` and shared (see Swift 6
above): reading a rule from the text is what keeps the model honest, and
memoising it is what makes that affordable.

The hooks a rule can attach to are fixed, and a new rule goes in the one that
matches: arrival, priority, accuracy, the roll, after the hit, the end of the
turn.

## What is implemented, and what is not

`make coverage`, or the **Parity Check** screen in the app, answers this. Both
go through `ParityAudit`, so there is one answer to "is this implemented"
rather than two that can disagree.

Nothing here is a list anybody has to remember to update. The audit plays the
game:

- **moves** are used, and the identical turn is played again without them. Any
  difference between the two boards is what the move did, and nothing the other
  side did can be mistaken for it.
- **abilities and items** are compared against *nothing*: the same turns with
  the trait and with the slot empty, across every weather and terrain, an
  attack of each type in both directions, a provocation from the far side, and
  a set of positions a rule might be waiting for — on one health point, with a
  graveyard, holding a spent item, taunted, under screens.

Four verdicts, and only the first is proof:

| | meaning |
|---|---|
| **Proven** | the battery played it and the game came out differently |
| **Parsed** | the model reads its text into a rule it applies, but the audit does not roll dice, so a 10% paralysis never fired for it. Not a gap |
| **Not proven** | nothing happened and nothing parsed. Where to look |
| **Out of scope** | a decision already made, with a reason. See `ParityAudit.notModelled` |

The headline number is coverage of what people actually bring, because that is
what decides whether the simulator can be trusted. The whole-dex figure sits
behind it and mostly counts Pokémon nobody plays.

**The control runs first and alone.** A made-up ability and a made-up item must
both come back as having no effect. If either changes the game, the battery is
finding differences that are not there, every number behind it is worthless,
and the run stops and says so. This is not decoration: the control caught the
audit reporting 99% ability coverage against a real figure of 78%, because its
baseline was comparing one ability against another instead of against nothing.

**The fingerprint is the audit's eyes.** Two boards are compared by writing one
out as a string, and anything that string leaves out is invisible — a move that
only changes that field reads as doing nothing. Twenty-odd working moves once
read as missing for exactly this reason. `ParityAuditTests` counts the
properties on `Fighter`, `Screens` and `Combatant` and fails when one is added
without the fingerprint learning to see it.

## Keeping up with a new release

Champions will keep adding Pokémon, Megas, moves and items. Three ways to
rebuild `data/champions.json`, and the middle one is almost always the right
one:

```
make data        # rebuild from the page cache — cannot see a release at all
make delta       # re-read the indexes, fetch only what is new
make full-sync   # re-fetch all ~1,400 pages
```

`make data` reuses every cached page, so a release is invisible to it.
`make full-sync` finds everything and costs a few thousand requests to Serebii,
which is somebody's hobby server. `make delta` re-reads the three index pages —
the eighteen type listings, the Attackdex index, the two item lists — works out
what they name that the dataset on disk has never heard of, and fetches detail
pages only for those. A release that adds twelve Pokémon costs twelve species
pages. A species already in the dataset is re-read when the roster now lists a
form of it that was not there before, which is how a new Mega arrives: the
species page is cached and the Mega lives on it.

Every run writes `data/changes.json` — forms, Megas, moves and items added
since the previous build, and anything that disappeared — so a release's
additions are a list rather than a diff of a 1.3 MB file.

Corrections rather than additions are the one case `--delta` cannot catch: if
Serebii fixes a base stat on a page the indexes do not flag, only a full sync
sees it. `MOVE_CORRECTIONS` in the generator is for the opposite case, where
Serebii is wrong and every sibling move agrees it is wrong.

## Checking a change

```
make test        # the suite — must pass
make hitch       # no main-thread stretch past four frames; search reaches depth ≥ 2
make snapshot    # look at build/shots/ — the renders catch layout regressions
make accuracy    # 55.2% on 1,454 games is the floor; a drop is a regression
make coverage    # the parity audit; the control must pass or the rest is noise
```

`make hitch` is only meaningful on a quiet machine. The same commit reads 23 ms
alone, 36 ms with a build running alongside it and 124 ms under real
contention, so a jump is worth re-measuring before it is worth investigating.

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
