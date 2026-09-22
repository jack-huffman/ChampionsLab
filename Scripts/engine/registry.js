// The data the dex loads by path at runtime, gathered here so it can be
// bundled. Showdown reads `require(dataDir + '/' + name)` with a path it
// computes, which nothing can resolve ahead of time -- so the paths are
// resolved here instead, once, and the lookup below matches on the tail.
//
// Only the base data and the champions mod: the other forty mods are other
// people's formats and would triple the bundle for nothing.
const base = {
  abilities: require('./dist/data/abilities.js'),
  aliases: require('./dist/data/aliases.js'),
  conditions: require('./dist/data/conditions.js'),
  'formats-data': require('./dist/data/formats-data.js'),
  items: require('./dist/data/items.js'),
  learnsets: require('./dist/data/learnsets.js'),
  moves: require('./dist/data/moves.js'),
  natures: require('./dist/data/natures.js'),
  pokedex: require('./dist/data/pokedex.js'),
  pokemongo: require('./dist/data/pokemongo.js'),
  rulesets: require('./dist/data/rulesets.js'),
  scripts: require('./dist/data/scripts.js'),
  tags: require('./dist/data/tags.js'),
  typechart: require('./dist/data/typechart.js'),
};
const champions = {
  abilities: require('./dist/data/mods/champions/abilities.js'),
  conditions: require('./dist/data/mods/champions/conditions.js'),
  'formats-data': require('./dist/data/mods/champions/formats-data.js'),
  items: require('./dist/data/mods/champions/items.js'),
  learnsets: require('./dist/data/mods/champions/learnsets.js'),
  moves: require('./dist/data/mods/champions/moves.js'),
  rulesets: require('./dist/data/mods/champions/rulesets.js'),
  scripts: require('./dist/data/mods/champions/scripts.js'),
};
// Only the formats this mod can actually play. The config lists every format
// Showdown runs -- nine hundred of them, across forty mods -- and the dex
// validates the whole list on load, so one naming a mod we did not bundle
// stops everything before a battle ever starts. The Champions ones are the
// point; the rest are other people's ladders.
const allFormats = require('./dist/config/formats.js').Formats;
const formats = {
  Formats: [{ section: 'Champions' }].concat(
    allFormats.filter((f) => f && f.mod === 'champions' && f.name)
  ),
};

globalThis.__psData = { base, mods: { champions }, formats };
