# Playbook

What strong VGC players say they do, set against what this engine actually
does. Drawn from [vgcguide.com](https://www.vgcguide.com) — thirteen concept
articles and three annotated games, listed at the bottom.

It is a gap analysis rather than a summary. Each idea is marked:

- **In** — modelled, and where
- **Partly** — some of it is there, with what is missing
- **Out** — not modelled, with a note on whether it is worth doing

Measured claims carry their numbers. Anything unmeasured says so.

---

## Team preview and the four you bring

**Identify a strong lead matchup, decide the back two, make sure the four
answer every one of theirs.** — *Team Preview*

**In.** `BringFour` ranks every legal four against their six, weighted by what
they are likely to bring. Measured: over 2,400 games the four it ranks first
wins 60% and one from the bottom half 42%, a gap of 18 ± 5. Its *score* is
calibrated too, not merely ordered — a +30 four wins 76%. Re-check with
`make lab ARGS="--calibrate"`.

**Look for Pokémon to exclude: poor typing either way, redundant roles, combo
pieces that should not be split.** — *Team Preview*

**In.** The grid handles typing and matchup, and `BringFour.abandoned` now
*scores* the jobs a four leaves at home — the only speed control is worth 10
points off, the only redirection 7, the only Fake Out 5. It used to say
"this four has no speed control: Whimsicott is staying home" in prose and then
rank the four as though nothing had happened. A warning nobody is scored
against is a warning nobody takes.

**A good team makes team preview easier: more viable leads, more flexibility.**

**In.** The per-team report counts how many of the fours a team actually
brought won at least half their games. One good four is one plan.

---

## Leads and the opening

**"I'll lead Farigiraf into that, they always open Fake Out."**

**In.** `Opening.swift` scores the exchange that happens before any damage:
whose Fake Out lands and whose is refused by a priority-blocking ability,
whether an Intimidate bites or is handed back by a Defiant, who gets speed
control up, who can redirect. The lead pair is chosen on the damage race plus
that, against their worst-case lead.

    ordinary pair into a Fake Out lead    -0.49
    Armor Tail into the same lead         +0.38

**Unmeasured.** Whether this makes the *ranking* better has not been tested.
Re-run `make lab ARGS="--calibrate"` and compare rank one against its 60%
baseline.

---

## Pressure

**"The threat of proactive action is how I define pressure."** Proactive moves
advance your goal; reactive ones — switching, Protecting, healing — answer a
threat. — *What Is Pressure*

**Partly, and implicitly.** `TurnGame` solves a simultaneous-move equilibrium,
so a threatened knockout already shows up as a payoff the other side must
answer. That *is* pressure, arrived at from the other end.

**Still out**, and deliberately: the article's *diagnostic* — being told which
of your Pokémon is under pressure and why — is an interface feature rather than
an engine one. It would not make the engine play better, which is what the rest
of this file is about.

---

## Predictions

**When ahead, predict only if it wins outright and failing does not throw the
lead. When even, only if being right swings the game. When behind, predict
when no safe play covers everything and losing without a read is otherwise
certain.** — *Predictions*

**In, and it was the biggest of the three wins.** The solver used to be
risk-*neutral*: it maximised material, so it played a position it was winning
by three exactly as it played one it was losing by three, and a coin flip
worth ±1 looked the same from both.

A turn is now scored by how far it moves the *chance of winning* rather than
by how much material it gains — `TurnModel.winChance` puts the material margin
through a logistic curve, and the payoff matrix is built from the change in
that. The curve is flat at both ends, so at +3 another point of material buys
almost no extra chance of winning while a slip costs a great deal, and at −3
the reverse. The caution when ahead and the willingness when behind are not
rules bolted on; they are what the curve does.

Measured at 57.5% ± 2.2 against an engine still playing for material
(`make lab ARGS="--ab-win"`).

**"You won't be able to predict everything, especially in best-of-1."**

**In.** The equilibrium is a *mixture*, and `SelfPlay` samples from it rather
than always playing the favourite — which is the game-theoretic form of the
same advice.

---

## Protect

**Reasons to: stop a knockout, dodge a Fake Out, stall a field effect, run
Trick Room or Tailwind down, reposition, force a commitment.** — *Protect in
Battle*

**Partly.** Protect is modelled as a move and the search prices it by outcome,
so stopping a knockout and dodging a Fake Out fall out naturally. Stalling a
field effect deliberately does not: the engine has no notion of "there are two
turns of Trick Room left and I want them gone."

**"The odds of getting back-to-back Protects are ⅓."**

**In.** `protectChance` is `(1/3)^streak`, and the search weighs the branches
rather than betting on either.

**A Protect on a redirection Pokémon usually backfires — they simply
double-target the other one.** — *Sandover vs Ferraris*

**Not a rule, and it should not be one.** Tested, and it is conditional:
drawing the fire trades the redirector's health for the partner's, so which way
it goes depends on which of the two is worth more. With no weights the engine
can only compare health, so it shelters the frail redirector and lets the Mega
take two hits. Told what they are worth — Charizard 1.12 against Indeedee
0.81 — it moves 0.225 towards drawing the fire. The maxim is a consequence of
valuing your Pokémon properly rather than a rule to bolt on.
See `testDrawingFireDependsOnWhatThePartnerIsWorth`.

---

## Switching

**Switch to avoid a knockout, to improve the matchup, to exploit a field
effect, or to preserve a Pokémon for later.** — *Switching*

**Partly.** The first three are priced by the search. "Preserve for later" is
now partly in: `Worth` makes a Pokémon that beats much of their team expensive
to trade, which is measured at 57.3% ± 2.2 against a flat engine
(`make lab ARGS="--ab"`).

**The incoming Pokémon is "entirely defenseless" and excessive switching leaves
you too weak to capitalise.**

**In.** Switching costs a turn in the search, and hazards bite on the way in.

---

## Disruption and stat stages

**Cycling an Intimidate in and out to keep chipping Attack is real value.**

**In, and it was worth a lot.** Stat stages used to be worth exactly nothing to
the evaluation, so every disruption move looked like a wasted turn. They are
now priced off the damage multiplier a stage actually produces — +1 is half
again, −1 is a third off — and a stage on the attacking stat a Pokémon does not
use is worth almost nothing. Measured at 57.0% ± 2.2 against an engine without
it (`make lab ARGS="--ab-stages"`).

---

## 1 HP is infinitely more than 0 HP

**"All of your Pokemon will function in exactly the same way no matter how much
health they have left."** — *1 HP Is Infinitely More Than 0 HP*

**Tunable now, and being measured.** `value()` prices a living Pokémon at
`floor + (1 − floor) × health`, and the floor is a per-side setting rather than
a number buried in an expression. The article's argument is that a Pokémon's
*function* does not degrade at all — only its survivability does — which says
the old 0.35 is too low. `make lab ARGS="--ab-floor"` settles it.

---

## Trick Room

**Ask: can I stop it going up, and how bad is it if it does. Then minimise the
turns they get to use it.** — *Battling Against Trick Room*

**Mostly in.** Having a Trick Room up is now worth something to whichever side
is slower on the field, scaled by the turns left — so setting one is not a
spent turn and running one down is an achievement, which is what makes the
engine stall it rather than ignore it. It already priced a Tailwind set under a
room correctly.

Still out: the trick of deliberately *not* knocking out their support, so the
other side wastes its own Trick Room turns on a Pokémon that cannot use them.
That is a second-order idea and no attempt has been made at it.

---

## Reviewing a game

**"In Pokémon, luck is a skill."** Review the decisive turn first, then failed
predictions, then the six-to-four, then the lead. Beware results-based
analysis. — *How To Analyze A Battle*

**In.** The Review panel ranks turns by how much the engine thinks each cost,
which is the same idea: it names the decisive turn rather than the last one,
and it judges the decision rather than the outcome.

---

## Risk and variance

**Accept a luck-dependent play only when it creates a major advantage, no
better option exists, and failing will not decide the match.** — *Less Luck
Than You Think*

**Partly**, through the same change as the prediction gap: an 80% line worth
10 and a 100% line worth 8 no longer look identical once both are read as
changes in the chance of winning rather than in material, because the curve is
not linear.

**Accuracy is now handled too.** The search averages, so a Stone Edge was
scored as 80% of a knockout — which reads exactly like a guaranteed hit for 80%
of the damage, and those are different bets. `TurnGame.asWinChance` splits the
gain back into the branch that lands and the branch that does not and puts each
through the curve separately. Ahead, the miss costs more than the hit buys and
the engine wants the sure thing; behind, it takes the swing.

Still averaged: the *damage roll* itself. A move that does 40–60 and one that
reliably does 50 look the same. That needs the search to carry distributions
rather than means, which is a much larger job.

---

## Best of 1 against best of 3

**Bo1 rewards surprise and risk-averse leads; Bo3 rewards consistency, carrying
information between games, and countering the lead they just showed you.**

**Out of scope.** The app plays single games. Worth revisiting if a series mode
ever exists.

---

## Sources

Concepts: [less luck than you think](https://www.vgcguide.com/competitive-pokemon-is-less-luck-than-you-think) ·
[knowledge base](https://www.vgcguide.com/building-up-a-knowledge-base) ·
[bo1 vs bo3](https://www.vgcguide.com/approaching-best-of-1-vs-best-of-3) ·
[analysing their team](https://www.vgcguide.com/analyzing-your-opponents-teams) ·
[team preview](https://www.vgcguide.com/team-preview) ·
[game plan](https://www.vgcguide.com/what-is-a-game-plan) ·
[pressure](https://www.vgcguide.com/what-is-pressure) ·
[predictions](https://www.vgcguide.com/predictions) ·
[protect](https://www.vgcguide.com/protect-in-battle) ·
[switching](https://www.vgcguide.com/switching) ·
[trick room](https://www.vgcguide.com/battling-against-trick-room) ·
[1 HP](https://www.vgcguide.com/1-hp-is-infinitely-more-than-0-hp) ·
[analysing a battle](https://www.vgcguide.com/how-to-analyze-a-battle)

Annotated games: [Tansley vs Dunlop, Worlds 2017](https://www.vgcguide.com/battling-example-will-tansley-vs-nils-dunlop-worlds-2017) ·
[Bros vs Chua, NAIC 2019](https://www.vgcguide.com/battling-examples-diana-bros-vs-paul-chua-naic-2019) ·
[Sandover vs Giunipero Ferraris](https://www.vgcguide.com/battling-example-alister-sandover-vs-edoardo-giunipero-ferraris)
