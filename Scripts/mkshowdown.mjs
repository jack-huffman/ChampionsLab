//  mkshowdown.mjs
//  Pull exact move mechanics out of Pokemon Showdown's move table.
//
//      node --experimental-strip-types Scripts/mkshowdown.mjs [path-to-showdown] > data/showdown.json
//
//  Serebii is the authority on what is *legal* in Champions: which forms exist,
//  what Mega Golisopod's typing is, what a Pokemon can learn. It is not a good
//  source for what a move *does*, because it writes that in English and the
//  only way to get it out is to guess at the sentence. That guessing was
//  wrong for ninety-one of the five hundred and ten legal moves: Heat Wave's
//  burn, Crunch's Defence drop, Iron Head's flinch, every Fang move's second
//  effect.
//
//  Showdown writes the same thing as data. This reads it, keyed by a
//  normalised name so the two id conventions do not have to agree -- Serebii
//  keeps the hyphen in "double-edge", Showdown does not.
//
//  Only the declarative parts are taken. Showdown implements the awkward moves
//  as JavaScript event handlers, and those do not translate; anything with a
//  rule this cannot express stays with the sentence parser and shows up in the
//  parity audit if it is wrong.

import { writeFileSync } from 'fs';
import { join } from 'path';
import { pathToFileURL } from 'url';

const root = process.argv[2] ||
  join(process.env.HOME, 'Documents/VSCode/Personal Projects/pokemon-showdown-master');

// A file URL, not a path: node reads a bare "data/moves.ts" as a package name.
const { Moves: Mainline } = await import(pathToFileURL(join(root, 'data/moves.ts')).href);

// Champions is a mod over the main-series table. Showdown's own [Gen 9
// Champions] formats load data/mods/champions/moves.ts on top of data/moves.ts,
// and so does this: an entry marked `inherit: true` is the main-series move
// with the listed fields replaced -- whole objects, so a `flags` here is the
// complete set, and a `secondary: undefined` takes the effect away. The claws
// are why it matters. Champions made Dragon Claw, Shadow Claw, Crush Claw,
// Dire Claw and Metal Claw slicing moves, which is what Mega Absol Z's
// Sharpness boosts, and the main-series table says they are not.
const { Moves: Champions } =
  await import(pathToFileURL(join(root, 'data/mods/champions/moves.ts')).href);
const Moves = {};
let overridden = 0;
for (const [id, base] of Object.entries(Mainline)) {
  const mod = Champions[id];
  if (mod?.inherit) { Moves[id] = { ...base, ...mod }; overridden++; }
  else Moves[id] = base;
}

/// Showdown's stat keys to ours.
const STAT = {
  atk: 'attack', def: 'defense', spa: 'spAttack',
  spd: 'spDefense', spe: 'speed',
  accuracy: 'accuracy', evasion: 'evasion',
};
/// Showdown's status keys to our Ailment raw values.
const STATUS = {
  brn: 'burned', par: 'paralysed', psn: 'poisoned',
  tox: 'badly poisoned', slp: 'asleep', frz: 'frozen',
};

/// One secondary, in the shape the app decodes.
///
/// `stats` holds positive magnitudes for a drop and positive amounts for a
/// self boost, because the kind already says which way it goes.
function shape(sec) {
  const out = [];
  const chance = sec.chance ?? 100;
  if (sec.status && STATUS[sec.status]) {
    out.push({ chance, kind: 'status', status: STATUS[sec.status] });
  }
  if (sec.volatileStatus === 'flinch') out.push({ chance, kind: 'flinch' });
  if (sec.volatileStatus === 'confusion') out.push({ chance, kind: 'confuse' });
  if (sec.boosts) {
    const drops = {}, raises = {};
    for (const [k, v] of Object.entries(sec.boosts)) {
      if (!STAT[k]) continue;
      if (v < 0) drops[STAT[k]] = -v; else raises[STAT[k]] = v;
    }
    if (Object.keys(drops).length) out.push({ chance, kind: 'drops', stats: drops });
    if (Object.keys(raises).length) out.push({ chance, kind: 'targetBoosts', stats: raises });
  }
  if (sec.self?.boosts) {
    const raises = {}, drops = {};
    for (const [k, v] of Object.entries(sec.self.boosts)) {
      if (!STAT[k]) continue;
      if (v > 0) raises[STAT[k]] = v; else drops[STAT[k]] = -v;
    }
    if (Object.keys(raises).length) out.push({ chance, kind: 'selfBoosts', stats: raises });
    if (Object.keys(drops).length) out.push({ chance, kind: 'selfDrops', stats: drops });
  }
  return out;
}

const table = {};
for (const move of Object.values(Moves)) {
  if (!move.name) continue;
  const list = move.secondaries ?? (move.secondary ? [move.secondary] : []);
  const secondaries = list.filter(Boolean).flatMap(shape);
  const flags = move.flags ?? {};
  table[move.name.toLowerCase().replace(/[^a-z0-9]/g, '')] = {
    name: move.name,
    secondaries,
    // Kept so the generator can say what Champions changed. `accuracy: true`
    // in Showdown means the move cannot miss, which this writes as 0 to match
    // how the dataset already spells it.
    // How many blows it lands. A number for a fixed count, a pair for a
    // range. Serebii writes this into its prose and nowhere else -- "Hits 2-5
    // times" -- so a move like Double Hit was being played as a single
    // thirty-five power attack when it is two of them.
    hits: Array.isArray(move.multihit) ? move.multihit
        : (move.multihit ? [move.multihit, move.multihit] : null),
    // Accuracy rolled per blow rather than once, so the attack stops at the
    // first miss: Population Bomb lands about six of its ten, not ten.
    multiaccuracy: !!move.multiaccuracy,
    // Dragon Darts and nothing else: in a double battle the two darts go one
    // to each foe, and both to the same one when only one can be reached.
    smartTarget: !!move.smartTarget,
    power: move.basePower,
    // Who the move is for, in Showdown's words: normal, self, allySide,
    // adjacentAlly, allAdjacentFoes. Serebii writes "Selected Target" for
    // Swords Dance, which is no help to anything that has to know the
    // difference between a move on a foe and one on the user.
    target: move.target,
    // A move whose user leaves the field after it: U-turn, Volt Switch,
    // Parting Shot, Teleport. Baton Pass carries its boosts across and Shed
    // Tail its substitute, and Showdown says which by name.
    // Revival Blessing borrows the flag to open the bench for the revival,
    // and does not leave; a slot condition marks the borrowing.
    selfSwitch: move.selfSwitch && !move.slotCondition
      ? (typeof move.selfSwitch === 'string' ? move.selfSwitch : 'yes') : undefined,
    accuracy: move.accuracy === true ? 0 : move.accuracy,
    type: move.type,
    priority: move.priority,
    // Flags decide which ability answers a move: Tough Claws wants contact,
    // Iron Fist a punch, Strong Jaw a bite, Punk Rock a sound. Emitted as
    // true *and* false, because an absent flag is a fact too -- Serebii
    // marking something as contact that is not needs correcting in both
    // directions. Named as the app names them; Showdown calls one "protect".
    flags: Object.fromEntries([['contact', 'contact'], ['sound', 'sound'],
      ['punch', 'punch'], ['bite', 'bite'], ['slicing', 'slicing'],
      ['bullet', 'bullet'], ['wind', 'wind'], ['powder', 'powder'],
      ['pulse', 'pulse'],
      ['protect', 'protectable'], ['reflectable', 'reflectable']]
      .map(([their, ours]) => [ours, !!flags[their]])),
  };
}

// -------------------------------------------------------------- forms ----
//
// Serebii's Champions pages file a regional form's abilities on its base
// form's card, merged into one list. Ninetales and Alolan Ninetales come back
// carrying Flash Fire, Drought, Snow Cloak and Snow Warning between them, with
// nothing to say which two belong to which -- so the builder would happily
// give a plain Ninetales Snow Warning and an Alolan one Drought.
//
// Showdown files them separately. This is read to split the merged list back
// apart, and for weights, which Serebii also takes from the wrong card: our
// Alolan Raichu had plain Raichu's thirty kilograms rather than its own
// twenty-one, and four moves now work their power out from that.

const { Pokedex } = await import(pathToFileURL(join(root, 'data/pokedex.ts')).href);
const forms = {};
for (const [id, p] of Object.entries(Pokedex)) {
  if (!p.baseStats) continue;
  forms[id] = {
    name: p.name,
    abilities: Object.values(p.abilities ?? {}),
    weight: p.weightkg ?? null,
    types: p.types ?? [],
  };
}

const json = JSON.stringify({
  source: 'pokemon-showdown data/moves.ts with data/mods/champions/moves.ts over it, and data/pokedex.ts',
  generated: new Date().toISOString().slice(0, 10),
  moves: table,
  forms,
}, null, 1);
if (process.argv[3]) writeFileSync(process.argv[3], json + '\n');
else process.stdout.write(json + '\n');
process.stderr.write(`showdown: ${Object.keys(table).length} moves (${overridden} changed by the champions mod), ${Object.keys(forms).length} forms\n`);
