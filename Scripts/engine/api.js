// What Swift calls. Deliberately the Battle object rather than BattleStream:
// the stream is an async iterator over promises, and a battle driven from
// Swift wants to hand over a choice and read what happened, in that order,
// with nothing in between. Battle already works exactly that way -- every
// protocol line it produces lands in `battle.log`, and `choose` returns once
// the turn is resolved.
// The three modules by name, never `sim/index`: that re-exports the whole of
// `lib`, which is the server's half of the project -- an HTTP client, a MySQL
// driver, a process manager -- and none of it has anything to do with playing
// a battle. Reaching for it pulled in seven hundred unresolvable imports.
const { Battle } = require('./dist/sim/battle.js');
const { Teams } = require('./dist/sim/teams.js');
const { Dex } = require('./dist/sim/dex.js');

let battle = null;
let read = 0;

globalThis.PS = {
  version: () => Dex.version || 'unknown',

  formats: () => Dex.formats.all().filter(f => f.id.includes('champions')).map(f => ({
    id: f.id, name: f.name, mod: f.mod, gameType: f.gameType,
  })),

  /** A team written the way a Showdown paste is, packed the way the sim wants. */
  pack: (paste) => Teams.pack(Teams.import(paste)),

  start: (formatid, p1, p2, seed) => {
    battle = new Battle({
      formatid,
      seed: seed ? seed.split(',').map(Number) : undefined,
      strictChoices: false,
    });
    read = 0;
    battle.setPlayer('p1', { name: p1.name, team: p1.team });
    battle.setPlayer('p2', { name: p2.name, team: p2.team });
    return true;
  },

  choose: (side, choice) => battle.choose(side, choice),

  /** Everything said since the last time anyone asked. */
  since: () => {
    const out = battle.log.slice(read);
    read = battle.log.length;
    return out;
  },

  all: () => battle.log,

  /** What a side is being asked for right now, as the client would see it. */
  request: (side) => {
    const s = battle.sides.find(x => x.id === side);
    return s && s.activeRequest ? JSON.stringify(s.activeRequest) : null;
  },

  /// A position, kept so it can be gone back to.
  ///
  /// The search needs a great many of these -- it plays a turn, looks at
  /// what happened, and puts the board back to try a different one -- and
  /// replaying the game from its first turn each time would cost the whole
  /// game per position. Showdown serialises a battle whole, which makes a
  /// position something that can be saved once and returned to at will.
  save: () => JSON.stringify(battle.toJSON()),

  restore: (state) => {
    battle = Battle.fromJSON(JSON.parse(state));
    battle.restart();
    read = battle.log.length;
    return true;
  },

  ended: () => battle.ended,
  winner: () => battle.winner || null,
  turn: () => battle.turn,
};
