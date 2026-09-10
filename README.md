# ChampionsLab

A native macOS app for building Pokémon Champions teams in **Regulation Set M-C**
(9 September – 2 December 2026).

It bundles the whole legal roster, every move, item and ability, a damage
calculator that uses Champions' own stat maths, and an analysis pass that grades
a team against the format and tells you what it loses to.

It links only against system frameworks and ships its dataset inside the bundle,
so there is nothing to install alongside it and it never touches the network.

## Build

```sh
./build.sh                  # → ~/Applications/ChampionsLab.app
./build.sh /Applications    # or anywhere else
./make-dmg.sh               # → build/ChampionsLab-<version>.dmg
```

Universal (arm64 + x86_64), macOS 13+. Bump `VERSION` to re-version. The icon is
generated on demand by `mkicon.py`; the dataset in `data/` is committed, so a
clean checkout builds without network access.

## What it does

- **Overview** — the M-C briefing. All six new Mega Evolutions with their real
  Champions stats and abilities, all twelve new items, and a written read on what
  changed and how to attack it.
- **Teams** — build, save, duplicate and import teams. A team opens **locked**:
  read-only, and instant, because the editable form has to build several hundred
  picker rows per slot and a locked one builds none. The padlock in the toolbar
  toggles it. Slot editor covers ability,
  item, Stat Points, Stat Alignment and four moves, and flags
  species-clause, item-clause and SP-cap violations as you go. Teams persist in
  `~/Library/Application Support/ChampionsLab/teams.json`.
- **Assist** — the guided builder. Reads the archetype off the abilities and moves
  actually on the team, reports which of the fourteen roles are filled and which
  of the five essential ones are not, runs the Regulation M-C checks (Megas
  registered vs usable, whether a stone is actually held, terrain exposure, the
  contact tax), then ranks additions — roles you lack first, then what you are
  weak to, then quality — with an Add button on each.
- **Analysis** — a 0–100 grade weighted by each threat's usage, a defensive matrix
  across all 18 attacking types, offensive coverage, speed tiers against the field,
  and ranked suggestions for what would patch the holes.
- **Threats** — every tracked threat individually, with how much damage you do to
  it, how much it does to you, which of your Pokémon check it, and which lose.
- **Versus** — your team against a whole opposing team: a six-by-six grid of
  one-on-one outcomes with damage both ways and who moves first, plus a verdict
  that names which of their Pokémon you have no answer to and which of yours is
  not earning its slot. Opponents can be one of the bundled meta archetypes or
  another team you have saved.
- Every slot in a team carries an **ƒ** button that opens it in the calculator with
  the build it was registered with — ability, item, Stat Points, alignment and its
  first damaging move. A slot holding a Mega Stone opens as the Mega, using the
  Mega's ability, since that is what actually fights.
- **Calculator** — full damage calc with weather, terrain, screens, crits, the
  spread penalty, items and abilities. Battle stages get a −6…+6 stepper per stat
  with the resulting number beside it, and a row of one-click sources read from
  that Pokémon's own learnset: its setup moves, an ability proc like Thermal
  Exchange, and Intimidate. Glaive Rush's Wide Open is a defender toggle, since
  it doubles what its user takes until its next action.
- **Forecast** — format predictions and anti-meta picks. The attacking-type
  landscape, the speed gaps and the pick ranking are computed: every legal form is
  run against the whole weighted field with a standard build and the real damage
  calculator, then ranked. The written predictions sit below and each states
  whether it is arithmetic or judgement.
- **Database** — every legal form, all 902 moves, 246 items and 199 abilities,
  searchable and filterable.

## Importing and exporting

⌘I, or the import button above the team list, takes Showdown / Pokepaste text.
Because Champions has no EVs, the importer converts them on the way in at the
game's own rate — the first Stat Point costs 4 EVs and each one after costs 8,
so a 252 EV investment lands exactly on the 32 SP cap. Export (the share button
in the team toolbar) converts back, so a team round-trips through other tools.

The importer resolves both spellings of a form — `Charizard-Mega-Y` and `Mega
Charizard Y`, `Indeedee-F` and `Indeedee (Female)` — and refuses to invent data:
a Pokémon that is not in the M-C roster, a move the form cannot learn, or an
unknown item is reported as a warning rather than silently imported.

Champions' own **Replica Team codes** are expanded by the game's servers, so the
app cannot turn one into a team. There is a field to store the code alongside an
imported list as a label.

## The stat system is not the one you know

Champions dropped IVs and EVs. Every Pokémon is treated as having 31 IVs, and
customisation happens through **Stat Points**: 66 to spend, at most 32 in any one
stat, each worth exactly +1 at Level 50. Natures survive as "Stat Alignment" with
the usual ±10%. At Level 50 that reduces to:

```
HP    = Base + 75 + SP
other = floor((Base + 20 + SP) × alignment)
```

`Stats.swift` implements exactly this. A calculator built on 252 EVs would be
wrong here, which is the main reason this app exists rather than reusing a
standard VGC one.

There is also **no Terastallization** in Champions, whatever some secondary
sources say — Mega Evolution is the only battle gimmick, and a Mega must hold its
stone. Pastes written for Scarlet/Violet keep their `Tera Type:` lines; the
importer drops them.

## Where the data comes from

`mkdata.py` scrapes Serebii's Champions-specific Pokédex and Attackdex:

```sh
./mkdata.py                # incremental, uses .cache/
./mkdata.py --refresh      # re-fetch everything
./mkdata.py --only-roster  # skip the slow move pass
```

Serebii is the right source because it is Champions-specific — PokéAPI has no idea
Mega Golisopod is Bug/Steel with Tough Claws, because that form only exists in this
game. Raw HTML is cached under `.cache/`, and the generated
`data/champions.json` is committed so the app never scrapes at runtime.

The roster comes from the **eighteen type listings**, not from
`/pokedex-champions/stat/all.shtml`. That page looks like the obvious source and
is a trap: it is sorted by base stat total and cut off at 300 rows, so everything
below 465 BST silently vanishes — which quietly dropped Pelipper, Politoed and
about fifty others. The type pages have no cap and carry abilities inline.

`mkassets.py` copies the artwork out of the sibling `PkHex Mac` checkout:

- **Sprites** — PKHeX's 512×512 HOME renders (`PKHeX.Mac/Assets/hires`),
  downscaled to 256px on the way in. Base forms are named by dex number;
  alternate forms resolve through `hires/forms.json`, which is keyed by PokéAPI
  slug, so `garchomp-mega-z` → `10309` → `hires/forms/10309.png`.
- **Type icons** — `upstream/PKHeX/.../img/types/square`, 18 badges.
- **Item icons** — `PKHeX.Mac/Assets/img/items`, indexed by PKHeX item ID. That
  set stops at ID 1606, so the Gen 9 items fall back to `img/items-artwork`.

These are game-ripped assets from PKHeX, kept here for personal use. If the
checkout is missing, the app still builds — type badges fall back to coloured
pills and sprites to a placeholder glyph.

Only Mega Glalie has no dedicated render upstream and falls back to base Glalie.

### Caveats worth knowing

- **Usage numbers are not M-C numbers.** M-C only opened on 9 September 2026, so it
  has no ladder history. The percentages in the app are the last measured
  Regulation M-A/M-B figures; the M-C arrivals are marked **projected** and placed
  by their stats and abilities, not by data. Treat those as an argument, not a
  measurement, and edit `data/overlay.json` as the meta settles.
- **Serebii was still filling in the M-C dex** when this was built. Eleven of the
  new arrivals — Wigglytuff, both Persians, both Farfetch'd, both Mr. Mimes,
  Thievul, Perrserker, Pincurchin, Squawkabilly — had not landed yet. `mkdata.py`
  prints exactly which are missing on every run; re-run it to pick them up.
- **Mega Stones are held items here**, so a Mega spends its item slot on its stone
  and counts against the item clause. Champions registers the *base* Pokémon
  holding the stone — a team lists `Charizard @ Charizardite Y` — so the app links
  the two: a slot holding a stone is analysed with the Mega's stats, typing and
  ability, and the slot header shows `→ Mega Charizard Y`. 45 Megas have a
  published stone name; the rest use a generic `Mega Stone` entry.
- **Regional forms share a pooled ability list.** Serebii lists abilities per
  species, so Alolan Ninetales shows the whole family's pool. Mega forms are
  matched exactly; regional ones need you to pick the right ability.

## Verifying it

```sh
./tools/verify.sh     # stat and damage maths against hand-computed values
./tools/matchup.sh    # importer, EV<->SP conversion, and the versus engine
./tools/snapshot.sh   # render the screens to build/shots/*.png
```

Battle stages matter more than almost anything else the calculator exposes — a
Swords Dance is 2.0x, and a Swords Dance plus a Thermal Exchange proc is 2.5x, or
249 Attack to 622 on Mega Baxcalibur. They used to be a mini popup menu buried in
the stat row, which made the most consequential control the hardest to find.

Setup moves are parsed out of the effect text ("Boosts the user's Attack and Speed
stats by 1 stage"), so the shortcut row is generated rather than hand-kept — 28
moves across the dex.

`verify.sh` checks the Champions stat formulas, the type chart (including
ability-driven immunities like Levitate), the doubles spread penalty, Grassy
Terrain halving Earthquake, Tough Claws, Aura Guard, Tera STAB stacking, and the
EV↔SP conversion both ways.

Stat Points are drawn the way the game draws them: a rail of 32 per stat with the
invested portion filled, an arrow on whichever stats the alignment raises and
lowers, and the 66-point total enforced while you drag rather than reported
afterwards — a stat can only reach what the remaining budget allows, and the rest
of its rail dims.

Saved teams decode leniently, field by field: a default value on a property does
*not* make a key optional to Swift's synthesised decoder, so adding one field to
`Team` would otherwise make every previously saved team fail to load. It did
exactly that once, and `try?` turned it into an empty team list with no message.
Loading now salvages per element, keeps a `teams.backup.json` generation, and
surfaces anything it had to skip.

`matchup.sh` imports a real Showdown list, round-trips it back out, and runs the
versus engine against a bundled archetype. It also checks that a team against
*itself* scores exactly zero — which is how the speed-tie handling got fixed, since
scoring ties as losses made every mirror match read negative.

`mkdata.py` also audits the ability descriptions on every run. Serebii puts every
ability for a form in one table cell separated by `<br />`, so a parser that gets
the boundaries wrong produces text that reads fine until you notice Farigiraf's
Armor Tail explaining Sap Sipper. That was true of 99 of 214 abilities until it
was caught; the audit now fails loudly on the signature.

`mkdata.py` additionally audits `overlay.json` on every run: every Pokémon, move
and item named in the curated usage table has to exist in the scraped data and be
legal on the form it is attached to. That check exists because it caught real
mistakes — an early draft listed Amoonguss, Pelipper and Ursaluna, none of which
are in Champions' 205-species roster, and gave a Pokémon Spore, which no
Champions learnset has.

### How the advisor ranks

Roles are detected, never assumed: Tailwind and Trick Room from the moves,
redirection from Follow Me and Rage Powder, terrain from a Surge ability, and so
on. Candidates are probed against their **whole learnset** rather than their
attacking moves — every support role is a status move, so probing with attacks
alone made redirection undetectable, and the advisor would report "no
redirection" and then never suggest a redirector.

Scoring puts an unfilled essential role first (4.0), then resisting what the team
is weak to, then archetype fit, then the candidate's own standing against the
field from the Forecast engine (2.5) — enough to separate Sinistcha from Ariados,
both of which technically have Rage Powder, without letting raw quality outrank a
missing role. A second Mega is penalised, since only one can be used per battle.

### A note on the forecast maths

Ranking a candidate's moves by raw base power hands everything a Giga Impact or a
Focus Punch and scores it as though those were free. `Move.isImmediateAttack`
filters to moves that can be clicked for their damage on the turn you want it,
reading Serebii's own effect text — "gains the Recharging status", "gains the
Charging status", "The user faints" — with a short explicit list for the handful
whose Battle Effect field is blank.

### Why the long lists are not Pickers

macOS SwiftUI builds every row of a `Picker` into an NSMenu the moment the view
appears, whichever row is selected. The slot editor had an item list of ~300 and
four move lists of ~60, so opening a six-Pokémon team constructed roughly 3,400
menu rows before it could draw — which is exactly what the delay was. Long lists
now use `LookupField`, a button that opens a searchable popover and builds only
the rows it shows. Locked: 0 rows. Unlocked: 144. The calculator went from 1,460
to 42.

`snapshot.sh` renders screens without launching the app, which is useful for
checking both palettes at once. Two known limits of `ImageRenderer`: it produces
an empty image for a `ScrollView` (screens expose a `content` property and an
`\.snapshotMode` environment flag to work around it), and it draws AppKit controls
— pickers, toggles, sliders — as placeholder glyphs rather than real controls.
