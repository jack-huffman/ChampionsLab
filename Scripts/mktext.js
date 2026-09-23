//  Scripts/mktext.js
//  Showdown's own battle prose, cut down to the lines a battle says.
//
//  The client does not invent sentences for the protocol; it looks them up.
//  `|-start|p2a: Salamence|move: Yawn` is rendered from the Yawn entry's
//  `start` string, "{POKEMON} grew drowsy!", and the app said "Salamence is
//  Yawn" because it was building the sentence out of the tag instead.
//
//  The tables also carry every move's long description -- three hundred
//  kilobytes of text no battle ever says -- so those keys are dropped and the
//  message keys kept. Run from Scripts/mkengine.sh, against the same checkout.
const fs = require('fs');
const path = require('path');

const src = process.argv[2] || '.cache/showdown';
const out = process.argv[3] || 'data/showdown-text.json';

// Everything that is documentation rather than something said out loud.
const PROSE = new Set(['desc', 'shortDesc']);
const isGen = k => /^gen\d+$/.test(k);

function trim(table) {
  const kept = {};
  for (const [id, entry] of Object.entries(table)) {
    const row = {};
    for (const [key, value] of Object.entries(entry)) {
      if (PROSE.has(key) || isGen(key)) continue;
      if (typeof value === 'string') row[key] = value;
    }
    // A `name` on its own says nothing a battle needs.
    if (Object.keys(row).some(k => k !== 'name')) kept[id] = row;
  }
  return kept;
}

const load = (file, exportName) => {
  const mod = require(path.resolve(src, 'dist/data/text', file));
  return mod[exportName];
};

const text = {
  default: trim(load('default.js', 'DefaultText')),
  moves: trim(load('moves.js', 'MovesText')),
  abilities: trim(load('abilities.js', 'AbilitiesText')),
  items: trim(load('items.js', 'ItemsText')),
};

fs.writeFileSync(out, JSON.stringify(text, null, 0) + '\n');
const count = Object.values(text).reduce((n, t) => n + Object.keys(t).length, 0);
console.error(`==> ${out}: ${count} entries, ${(fs.statSync(out).size / 1024).toFixed(0)} KB`);
