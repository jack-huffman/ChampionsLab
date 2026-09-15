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
const { Moves } = await import(pathToFileURL(join(root, 'data/moves.ts')).href);

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
    // Flags decide which ability answers a move: Tough Claws wants contact,
    // Iron Fist a punch, Strong Jaw a bite, Punk Rock a sound. Emitted as
    // true *and* false, because an absent flag is a fact too -- Serebii
    // marking something as contact that is not needs correcting in both
    // directions. Named as the app names them; Showdown calls one "protect".
    flags: Object.fromEntries([['contact', 'contact'], ['sound', 'sound'],
      ['punch', 'punch'], ['bite', 'bite'], ['slicing', 'slicing'],
      ['bullet', 'bullet'], ['wind', 'wind'], ['powder', 'powder'],
      ['protect', 'protectable'], ['reflectable', 'reflectable']]
      .map(([their, ours]) => [ours, !!flags[their]])),
  };
}

const json = JSON.stringify({
  source: 'pokemon-showdown data/moves.ts',
  generated: new Date().toISOString().slice(0, 10),
  moves: table,
}, null, 1);
if (process.argv[3]) writeFileSync(process.argv[3], json + '\n');
else process.stdout.write(json + '\n');
process.stderr.write(`showdown: ${Object.keys(table).length} moves\n`);
