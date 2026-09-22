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

// A deserialised battle has nobody to talk to. Showdown reports a refused
// choice by sending it back to the player who made it, so without this the
// first illegal move in a search is not an error but a crash -- and the error
// it was trying to report never gets read.
const hush = function (type, data) {
  globalThis.__psLastError = String(data);
};

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
    battle.restart(hush);
    read = battle.log.length;
    return true;
  },

  /// Every way a turn could go, each with the odds of going that way.
  ///
  /// This is the one thing a search needs that playing a battle does not.
  /// It is not sampling: the rolls are *forced*. Showdown puts every coin
  /// flip through `battle.randomChance`, and `battle.prng` is a plain
  /// property the sim itself documents as an override -- so a run can be
  /// made to answer "yes" to the third flip and "no" to the fourth, and the
  /// turn that comes out is exactly the turn where the Protect held and the
  /// secondary missed. The odds come from the question it was asked.
  ///
  /// One probe run to find out what gets flipped, then one forced run per
  /// combination of the `limit` likeliest. Everything else rolls normally,
  /// which keeps a turn with twenty small chances in it from becoming a
  /// million turns.
  outcomes: (p1, p2, limit) => {
    // Written out once and parsed back per branch. A hand-rolled deep clone
    // was tried and is slower -- 0.060ms against 0.043ms -- because
    // JavaScriptCore's JSON is native and a loop in JavaScript is not. Both
    // are noise anyway: a branch costs about four milliseconds and almost all
    // of it is `Battle.fromJSON` rebuilding the object graph, which is the
    // thing that cannot be made cheaper from out here.
    const saved = JSON.stringify(battle.toJSON());
    const cap = Math.max(0, Math.min(limit === undefined ? 1 : limit, 4));

    function run(answers) {
      battle = Battle.fromJSON(JSON.parse(saved));
      battle.restart(hush);
      const base = battle.prng;
      const asked = [];
      let index = 0;
      const scripted = Object.create(base);
      scripted.randomChance = function (numerator, denominator) {
        const forced = answers[index];
        let held;
        if (forced === true || forced === false) held = forced;
        else held = base.randomChance.call(this, numerator, denominator);
        // What it was asked *and* what it answered, so a run with nothing
        // forced is also a run whose answers are known -- which is what lets
        // the probe stand in for the branch it happens to be.
        asked.push({ numerator, denominator, held });
        index++;
        return held;
      };
      battle.prng = scripted;
      const from = battle.log.length;
      battle.choose('p1', p1);
      battle.choose('p2', p2);
      battle.prng = base;
      return { asked, log: battle.log.slice(from) };
    }

    function putBack() {
      battle = Battle.fromJSON(JSON.parse(saved));
      battle.restart(hush);
      read = battle.log.length;
    }

    // One run to find out what this turn turns on.
    const probe = run([]);
    globalThis.__psLastFlips = probe.asked;
    const flips = probe.asked
      .map((a, at) => ({ at, chance: a.numerator / a.denominator, was: a.held }))
      .filter((f) => f.chance > 0 && f.chance < 1)
      .sort((a, b) => Math.abs(0.5 - a.chance) - Math.abs(0.5 - b.chance))
      .slice(0, cap);

    if (!flips.length) {
      putBack();
      return [{ chance: 1, log: probe.log }];
    }

    const out = [];
    for (let mask = 0; mask < (1 << flips.length); mask++) {
      const answers = [];
      let chance = 1;
      let asProbed = true;
      flips.forEach((flip, bit) => {
        const holds = !!(mask & (1 << bit));
        answers[flip.at] = holds;
        chance *= holds ? flip.chance : 1 - flip.chance;
        if (holds !== flip.was) asProbed = false;
      });
      if (chance <= 0) continue;
      // The probe already played exactly this one: its rolls came out this
      // way on their own. Running it again would give the same turn for the
      // price of another position.
      const got = asProbed ? probe : run(answers);
      out.push({ chance, log: got.log });
    }
    // Put the battle back where it was, so asking what might happen does not
    // change what has.
    putBack();
    return out.sort((a, b) => b.chance - a.chance);
  },

  ended: () => battle.ended,
  winner: () => battle.winner || null,
  turn: () => battle.turn,
};
