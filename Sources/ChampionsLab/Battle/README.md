# The battle model

One turn of doubles, played the way the game plays it, in fifteen files that each
own one aspect of it. This is the map. Every file's header says what it owns and
why; this says how they fit.

## The shape

```
                          TurnModel          the orchestrator: resolve, outcomes
                     ┌───────┼────────┬──────────────┐
                 TurnOrder  Strikes  Residuals   Switching
                            ┌──┴──────────┬──────┐
                     SupportMoves    Protection  MoveHistory  Accuracy
                            └──────┬────────┘
                               Ailments
                                   │
                              StatChanges
                     ─────────────────────────────────
                      Board            Dice          Evaluation
                     (the state)     (the RNG)    (scores a Board)
```

Arrows point downward at what a file is allowed to call. **Board** and **Dice**
depend on nothing. **Nothing depends on TurnModel.** There are no cycles.
`BattleModelShapeTests` asserts all three and fails the build otherwise.

## The aspects

| File | Owns | One-line rule |
|---|---|---|
| `Board.swift` | Fighter, Screens, Board, Choice, Play | State and its readers. Decides nothing. |
| `TurnModel.swift` | `resolve`, `outcomes` | The order things happen in, and nothing else. |
| `TurnOrder.swift` | who acts when | Bracket first, then Speed; After You and Quash; the mid-turn re-read. The explainer walks the same code. |
| `Strikes.swift` | the action pipeline | Can it be used, who does it reach, what it does to each, what it costs. |
| `SupportMoves.swift` | the status moves | Each is its own rule, found by name. Hands a `Followup` up rather than calling down. |
| `Switching.swift` | entering and leaving | Entry abilities, Mega Evolution, Regenerator, Emergency Exit; and the Board's arrival methods, as an extension. |
| `Residuals.swift` | end of turn | Weather, terrain healing, poison, Leech Seed, berries, every field clock. |
| `Ailments.swift` | status conditions | `inflict` is the one door; Misty, Safeguard, immunities and Synchronize live behind it. |
| `ChampionsRules.swift` | the numbers Champions changed | Paralysis, sleep, freeze, Healer -- each with the line of Showdown's champions mod beside it. |
| `StatChanges.swift` | stat stages | `change` is the one door; the clamp, Contrary, Defiant, White Herb live behind it. |
| `Protection.swift` | Protect | The streak and the odds. |
| `MoveHistory.swift` | what a Pokemon just did | For Encore, Stomping Tantrum, two-turn moves. |
| `Accuracy.swift` | whether a move lands | The only place that knows a move's accuracy. |
| `Evaluation.swift` | what a position is worth | Health, stages, speed control, Trick Room, through the win-chance curve. |
| `Dice.swift` | the RNG | The one genuinely global thing. |

Not part of the turn but in the directory: `TurnGame` solves a turn as a matrix
game, `BattleEngine` searches, `SelfPlay` plays whole games, `TurnRead`
describes a turn in words.

## The rules that keep it this way

**One door per effect.** A stat changes through `StatChanges.change`. A status
lands through `Ailments.inflict`. A move's accuracy is read through
`Accuracy.chanceToHit`. Who goes first is decided by `TurnOrder.next`. If a
second path to any of these appears, the two will drift -- they did, three
times, and each time a real rule was lost: Covert Cloak stopped one copy of a
Fake Out's flinch and not the other; Misty Terrain stopped a Scald's burn and
not a Will-O-Wisp.

**A damaging move is data, not code.** Power, type, accuracy, crit rate,
secondaries, drops, drain and recoil all come from the dataset through
`MoveRules`, and the same pipeline resolves all nine hundred. A damaging move
named by hand anywhere in this directory has to be declared in
`MoveDataOwnershipTests` with a reason. Status moves are the exception, each
being its own rule, and they live in one file.

**An explanation is the thing it explains.** The turn explainer, the review
panel and the search read `TurnOrder`, `Accuracy` and `Evaluation` -- the same
functions the played turn reads. Nothing describes the turn by working it out
again.

**The ratchet.** `BattleModelShapeTests` holds each file to a line budget set a
little above where it stands, names the four functions allowed to be long and
why, and asserts the graph above. Adding a fifth long function, or a file over
budget, or an edge upward, fails the build -- which is the point. It forces the
question to be asked once, out loud.

## Where to look

Something about who moves first: `TurnOrder`. A move doing the wrong damage:
`Strikes`, then `Damage/DamageCalc`. A status that should not have landed:
`Ailments.inflict`. A stat that moved wrong: `StatChanges.change`. A status
move doing the wrong thing: `SupportMoves`, by the move's name. Something
happening at the end of a turn: `Residuals`. Something on arrival: `Switching`.
