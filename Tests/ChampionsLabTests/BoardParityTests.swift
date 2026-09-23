//  BoardParityTests.swift
//  The board is a mirror of the simulator, and a mirror nothing checks is
//  worth nothing.
//
//      swift test --filter BoardParityTests
//
//  Every number on the battle screen is read off `Board`, and `Board` is
//  rebuilt from the protocol lines Showdown emits -- a tag at a time, by hand,
//  in `ShowdownBattle.read`. Nothing was comparing the result to the thing it
//  is a picture of. That is how a Pokemon that set up, pivoted out and came
//  back kept its stat stages on the board while the sim -- correctly -- had
//  cleared them: every number on the screen agreed with every other number on
//  the screen, and none of them agreed with the damage.
//
//  `PS.save()` is the sim's own state, and the only place its view of a
//  Pokemon's stages, volatiles, item, ability and types can be read from out
//  here. So this plays games that actually make those things happen and
//  compares all of it, every turn.
//
//  It reports every divergence rather than stopping at the first, because the
//  question this answers is "what else is wrong", not "is anything wrong".

import XCTest
@testable import ChampionsLab

@MainActor
final class BoardParityTests: HarnessCase {
    // MARK: - The simulator's own view

    private struct SimMon {
        var species: String
        var hp: Int
        var maxHP: Int
        var status: String
        var fainted: Bool
        var item: String
        var ability: String
        var types: [String]
        var boosts: [String: Int]
        var volatiles: Set<String>
        var substitute: Int
        var moves: [String]
        /// How far along a bad poisoning is: the simulator's own count.
        var toxicStage: Int
    }

    private struct SimSide {
        var conditions: [String: Int]      // id -> turns left
        var actives: [SimMon]
        /// The rest of the party. A Pokemon on the bench is still a Pokemon
        /// the screen draws -- its health, whether it is down, what it is
        /// still carrying -- and the divergence that started all this was a
        /// Pokemon keeping something on the bench that it should have left on
        /// the field.
        var bench: [SimMon]
    }

    private struct SimState {
        var weather: String
        var weatherTurns: Int
        var terrain: String
        var terrainTurns: Int
        var pseudo: [String: Int]
        var sides: [SimSide]
    }

    private func simState() throws -> SimState? {
        guard let json = try ShowdownEngine.shared.save(),
              let data = json.data(using: .utf8),
              let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let field = top["field"] as? [String: Any] ?? [:]
        func duration(_ any: Any?) -> Int {
            ((any as? [String: Any])?["duration"] as? Int) ?? 0
        }
        var pseudo: [String: Int] = [:]
        for (id, value) in (field["pseudoWeather"] as? [String: Any] ?? [:]) {
            pseudo[id] = duration(value)
        }
        var sides: [SimSide] = []
        for side in top["sides"] as? [[String: Any]] ?? [] {
            var conditions: [String: Int] = [:]
            for (id, value) in (side["sideConditions"] as? [String: Any] ?? [:]) {
                conditions[id] = duration(value)
            }
            func read(_ mons: [[String: Any]]) -> [SimMon] {
                mons.map { mon -> SimMon in
                    // `species` serialises as a reference -- "[Species:x]" --
                    // so the name comes off `details`, the same string the
                    // protocol puts in a |switch| line: "Ceruledge, L50, M".
                    let details = (mon["details"] as? String) ?? ""
                    let volatiles = mon["volatiles"] as? [String: Any] ?? [:]
                    let sub = (volatiles["substitute"] as? [String: Any])?["hp"] as? Int ?? 0
                    return SimMon(
                        species: details.split(separator: ",").first.map(String.init)?
                            .trimmingCharacters(in: .whitespaces) ?? "?",
                        hp: (mon["hp"] as? Int) ?? -1,
                        maxHP: (mon["maxhp"] as? Int) ?? -1,
                        status: (mon["status"] as? String) ?? "",
                        fainted: (mon["fainted"] as? Bool) ?? false,
                        item: (mon["item"] as? String) ?? "",
                        ability: (mon["ability"] as? String) ?? "",
                        types: (mon["types"] as? [String]) ?? [],
                        boosts: (mon["boosts"] as? [String: Int]) ?? [:],
                        volatiles: Set(volatiles.keys),
                        substitute: sub,
                        // What the sim will accept `move N` for. The board
                        // sends its own index straight through, so if the two
                        // lists differ in length or order the app is naming a
                        // different move than the one that was clicked.
                        moves: (mon["moveSlots"] as? [[String: Any]] ?? [])
                            .compactMap { $0["id"] as? String },
                        toxicStage: ((mon["statusState"] as? [String: Any])?["stage"] as? Int) ?? 0)
                }
            }
            let party = side["pokemon"] as? [[String: Any]] ?? []
            sides.append(SimSide(
                conditions: conditions,
                actives: read(party.filter { ($0["isActive"] as? Bool) == true }),
                bench: read(party.filter { ($0["isActive"] as? Bool) != true })))
        }
        return SimState(weather: (field["weather"] as? String) ?? "",
                        weatherTurns: duration(field["weatherState"]),
                        terrain: (field["terrain"] as? String) ?? "",
                        terrainTurns: duration(field["terrainState"]),
                        pseudo: pseudo, sides: sides)
    }

    // MARK: - What the two call the same thing

    private static let statusNamed: [String: Ailment] = [
        "": .none, "brn": .burn, "par": .paralysis, "psn": .poison,
        "tox": .badPoison, "slp": .sleep, "frz": .freeze,
    ]
    private static let weatherNamed: [String: Weather] = [
        "": .none, "sunnyday": .sun, "desolateland": .sun,
        "raindance": .rain, "primordialsea": .rain,
        "sandstorm": .sand, "snowscape": .snow, "hail": .snow,
    ]
    private static let terrainNamed: [String: Terrain] = [
        "": .none, "electricterrain": .electric, "grassyterrain": .grassy,
        "mistyterrain": .misty, "psychicterrain": .psychic,
    ]
    private static let stageNamed: [String: Stat] = [
        "atk": .attack, "def": .defense, "spa": .spAttack,
        "spd": .spDefense, "spe": .speed,
    ]

    // MARK: - The comparison

    private var divergences: [String] = []
    /// What the simulator was actually seen doing, so a green audit over a
    /// game where nothing happened cannot pass for a green audit.
    private var witnessed: Set<String> = []

    private func same(_ what: String, _ ours: String, _ theirs: String) {
        guard ours != theirs else { return }
        divergences.append("\(what): board \(ours) vs sim \(theirs)")
    }

    /// Everything the board mirrors, against the thing it mirrors.
    private func compare(_ game: ShowdownBattle, turn: Int) throws {
        guard let sim = try simState(), sim.sides.count == 2 else { return }
        let board = game.board
        if !sim.weather.isEmpty { witnessed.insert("weather") }
        if !sim.terrain.isEmpty { witnessed.insert("terrain") }
        if sim.pseudo["trickroom"] != nil { witnessed.insert("trickroom") }
        for side in sim.sides {
            for id in side.conditions.keys { witnessed.insert(id) }
            for mon in side.actives {
                if !mon.status.isEmpty { witnessed.insert("a status") }
                if mon.boosts.values.contains(where: { $0 != 0 }) { witnessed.insert("a stage moved") }
                if mon.item.isEmpty { witnessed.insert("an item gone") }
                if mon.fainted { witnessed.insert("a faint") }
                for volatile in mon.volatiles where volatile != "stall" {
                    witnessed.insert(volatile)
                }
            }
        }

        // --- the field -------------------------------------------------
        let want = Self.weatherNamed[sim.weather] ?? .none
        same("turn \(turn) weather", board.field.weather.rawValue, want.rawValue)
        same("turn \(turn) weather turns", "\(board.weatherTurns)", "\(sim.weatherTurns)")
        let wantTerrain = Self.terrainNamed[sim.terrain] ?? .none
        same("turn \(turn) terrain", board.field.terrain.rawValue, wantTerrain.rawValue)
        same("turn \(turn) terrain turns", "\(board.terrainTurns)", "\(sim.terrainTurns)")
        same("turn \(turn) trick room", "\(board.trickRoom)", "\(sim.pseudo["trickroom"] ?? 0)")

        // --- each side -------------------------------------------------
        for (index, mine) in [(0, true), (1, false)] {
            let side = sim.sides[index]
            let who = mine ? "ours" : "theirs"
            let screens = mine ? board.myScreens : board.theirScreens
            same("turn \(turn) \(who) tailwind",
                 "\(mine ? board.myTailwind : board.theirTailwind)",
                 "\(side.conditions["tailwind"] ?? 0)")
            same("turn \(turn) \(who) reflect", "\(screens.reflect)",
                 "\(side.conditions["reflect"] ?? 0)")
            same("turn \(turn) \(who) light screen", "\(screens.lightScreen)",
                 "\(side.conditions["lightscreen"] ?? 0)")
            same("turn \(turn) \(who) aurora veil", "\(screens.auroraVeil)",
                 "\(side.conditions["auroraveil"] ?? 0)")
            same("turn \(turn) \(who) safeguard", "\(screens.safeguard)",
                 "\(side.conditions["safeguard"] ?? 0)")
            // The hazards are layers rather than clocks, so presence is what
            // is comparable without reading the sim's own counters.
            same("turn \(turn) \(who) stealth rock", "\(screens.stealthRock)",
                 "\(side.conditions["stealthrock"] != nil)")
            same("turn \(turn) \(who) sticky web", "\(screens.stickyWeb)",
                 "\(side.conditions["stickyweb"] != nil)")
            same("turn \(turn) \(who) spikes down", "\(screens.spikes > 0)",
                 "\(side.conditions["spikes"] != nil)")
            same("turn \(turn) \(who) toxic spikes down", "\(screens.toxicSpikes > 0)",
                 "\(side.conditions["toxicspikes"] != nil)")

            let ours = Array((mine ? board.mine : board.theirs).prefix(board.activeCount))
            for mon in side.actives {
                guard let fighter = ours.first(where: {
                    $0.build.form.showdown == mon.species
                        || $0.build.form.formLabel == mon.species
                }) else {
                    divergences.append("turn \(turn) \(who): the sim has \(mon.species) out "
                        + "and the board does not (\(ours.map(\.build.form.formLabel).joined(separator: ", ")))")
                    continue
                }
                let tag = "turn \(turn) \(who) \(mon.species)"
                same("\(tag) HP", "\(fighter.hp)", "\(mon.hp)")
                same("\(tag) max HP", "\(fighter.maxHP)", "\(mon.maxHP)")
                same("\(tag) fainted", "\(fighter.fainted)", "\(mon.fainted)")
                same("\(tag) status", fighter.status.rawValue,
                     (Self.statusNamed[mon.status] ?? .none).rawValue)
                for (key, stat) in Self.stageNamed.sorted(by: { $0.key < $1.key }) {
                    same("\(tag) \(key)", "\(fighter.build.boosts[stat.rawValue])",
                         "\(mon.boosts[key] ?? 0)")
                }
                // Item and ability are ids on one side and names on the other.
                same("\(tag) item", ShowdownText.id(fighter.build.item), mon.item)
                same("\(tag) ability", ShowdownText.id(fighter.build.ability), mon.ability)
                same("\(tag) types", fighter.types.map(\.rawValue).joined(separator: "/"),
                     mon.types.joined(separator: "/"))
                same("\(tag) move list", fighter.moves.map { ShowdownText.id($0.name) }
                        .joined(separator: ","),
                     mon.moves.joined(separator: ","))
                // Winding a two-turn move up, and out of reach while doing it.
                // The simulator keeps the first as `twoturnmove` and the second
                // as the move's own volatile, which is what carries the
                // invulnerability.
                same("\(tag) charging", "\(fighter.charging != nil)",
                     "\(mon.volatiles.contains("twoturnmove"))")
                let unreachable = ["fly", "bounce", "dig", "dive", "phantomforce",
                                   "shadowforce", "skydrop"]
                same("\(tag) out of reach", "\(fighter.hidden)",
                     "\(unreachable.contains { mon.volatiles.contains($0) })")
                if mon.status == "tox" {
                    same("\(tag) toxic count", "\(fighter.toxicTurns)", "\(mon.toxicStage)")
                }
                same("\(tag) substitute", "\(fighter.substitute > 0)",
                     "\(mon.volatiles.contains("substitute"))")
                // Every volatile the board has somewhere to put.
                let held: [(String, String, Bool)] = [
                    ("confusion", "confusion", fighter.confusedFor > 0),
                    ("taunt", "taunt", fighter.tauntedFor > 0),
                    ("encore", "encore", fighter.encoredFor > 0),
                    ("disable", "disable", fighter.disabledFor > 0),
                    ("leech seed", "leechseed", fighter.seededFrom != nil),
                    ("yawn", "yawn", fighter.drowsyFor > 0),
                    ("attract", "attract", fighter.infatuatedWith != nil),
                    ("aqua ring", "aquaring", fighter.aquaRing),
                    ("octolock", "octolock", fighter.octolocked),
                    ("torment", "torment", fighter.tormented),
                    ("destiny bond", "destinybond", fighter.destinyBound),
                    ("perish song", "perishsong", fighter.perishIn > 0),
                    // Showdown counts consecutive Protects as `stall`, and
                    // the app counts them as `protectStreak` -- which is what
                    // the move tile's "33% chance after last turn's" is read
                    // off, and what the search uses to decide whether Protect
                    // is even worth offering. Only the increment was running.
                    ("protect streak", "stall", fighter.protectStreak > 0),
                ]
                for (label, id, ourView) in held {
                    same("\(tag) \(label)", "\(ourView)", "\(mon.volatiles.contains(id))")
                }
            }

            // --- and the bench --------------------------------------------
            //
            // The screen draws these too: the four little cards along the
            // side, the health on each, which of them are down. And the
            // divergence that started all of this was a Pokemon keeping on
            // the bench something it should have left on the field, so the
            // bench is exactly where it has to be checked that it did not.
            // The whole party, not the slice after `activeCount`. Showdown
            // clears `isActive` the moment a Pokemon faints; the board keeps
            // it lying in its slot until something replaces it, so the screen
            // has something to draw going down. That is a deliberate
            // difference about where a fainted Pokemon *sits*, not about what
            // is true of it, so the party is matched by name and every
            // Pokemon is checked wherever it happens to be.
            let benched = mine ? board.mine : board.theirs
            for mon in side.bench {
                guard let fighter = benched.first(where: {
                    $0.build.form.showdown == mon.species
                        || $0.build.form.formLabel == mon.species
                }) else {
                    divergences.append("turn \(turn) \(who) bench: the sim has \(mon.species) "
                        + "and the board does not (\(benched.map(\.build.form.formLabel).joined(separator: ", ")))")
                    continue
                }
                let tag = "turn \(turn) \(who) bench \(mon.species)"
                same("\(tag) HP", "\(fighter.hp)", "\(mon.hp)")
                same("\(tag) max HP", "\(fighter.maxHP)", "\(mon.maxHP)")
                same("\(tag) fainted", "\(fighter.fainted)", "\(mon.fainted)")
                same("\(tag) status", fighter.status.rawValue,
                     (Self.statusNamed[mon.status] ?? .none).rawValue)
                same("\(tag) item", ShowdownText.id(fighter.build.item), mon.item)
                same("\(tag) move list",
                     fighter.moves.map { ShowdownText.id($0.name) }.joined(separator: ","),
                     mon.moves.joined(separator: ","))
                // Nothing the field did follows a Pokemon off it.
                for (key, stat) in Self.stageNamed.sorted(by: { $0.key < $1.key }) {
                    same("\(tag) \(key)", "\(fighter.build.boosts[stat.rawValue])",
                         "\(mon.boosts[key] ?? 0)")
                }
                for (label, id) in [("substitute", "substitute"), ("confusion", "confusion"),
                                    ("taunt", "taunt"), ("leech seed", "leechseed"),
                                    ("yawn", "yawn"), ("encore", "encore")] {
                    let ourView: Bool
                    switch id {
                    case "substitute": ourView = fighter.substitute > 0
                    case "confusion": ourView = fighter.confusedFor > 0
                    case "taunt": ourView = fighter.tauntedFor > 0
                    case "leechseed": ourView = fighter.seededFrom != nil
                    case "yawn": ourView = fighter.drowsyFor > 0
                    default: ourView = fighter.encoredFor > 0
                    }
                    same("\(tag) \(label)", "\(ourView)", "\(mon.volatiles.contains(id))")
                }
            }
        }
    }

    private func report(_ what: String) {
        if divergences.isEmpty {
            print("  ok   \(what): the board and the simulator agree throughout")
        } else {
            print("  FAIL \(what): \(divergences.count) divergences")
            for line in divergences.prefix(60) { print("       \(line)") }
            if divergences.count > 60 { print("       ... and \(divergences.count - 60) more") }
        }
        XCTAssertTrue(divergences.isEmpty, "\(what): \(divergences.count) divergences")
    }

    // MARK: - A game where all of it happens

    private func slot(_ name: String, item: String, ability: String,
                      moves: [String], sp: [Int]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.item = item
        s.ability = form.abilities.first { $0.name == ability }?.name
            ?? form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { move in form.moves.first { store.move($0)?.name == move } }
        if !sp.isEmpty { s.sp = sp }
        s.id = UUID()
        return s
    }

    /// Statuses, screens, Tailwind, Trick Room, a Substitute, Leech Seed,
    /// a Taunt, weather off an ability, an Intimidate, a Knock Off and a
    /// switch -- in one game, on purpose, because a pair of ladder teams
    /// pressing their first move does almost none of it.
    func testEverythingAGameDoesAgreesWithTheSimulator() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let a = slot("Incineroar", item: "Sitrus Berry", ability: "Intimidate",
                           moves: ["Will-O-Wisp", "Fake Out", "Flare Blitz", "Protect"],
                           sp: [32, 32, 0, 0, 0, 0]),
              let b = slot("Whimsicott", item: "Focus Sash", ability: "Prankster",
                           moves: ["Tailwind", "Leech Seed", "Taunt", "Light Screen"],
                           sp: [0, 0, 0, 0, 0, 32]),
              let c = slot("Milotic", item: "Leftovers", ability: "Competitive",
                           moves: ["Scald", "Substitute", "Protect", "Rain Dance"],
                           sp: [32, 0, 0, 0, 0, 0]),
              let d = slot("Slowbro", item: "Charcoal", ability: "Oblivious",
                           moves: ["Trick Room", "Yawn", "Body Press", "Protect"],
                           sp: [32, 0, 32, 0, 0, 0])
        else { throw XCTSkip("the cast is not in this dex") }
        // Every move has to be one the Pokemon really has, or the script runs
        // a different game than it reads as and the audit passes over nothing.
        for (who, wanted) in [(a, 4), (b, 4), (c, 4), (d, 4)] {
            check("\(store.rulebook.form(who.formID)?.formLabel ?? "?") has all its moves",
                  who.moves.count == wanted, "\(who.moves.count)")
        }

        var mine = Team(name: "Mine"); mine.format = "doubles"; mine.slots = [a, b, c, d]
        var theirs = Team(name: "Theirs"); theirs.format = "doubles"; theirs.slots = [c, d, a, b]
        for index in mine.slots.indices { mine.slots[index].id = UUID() }
        for index in theirs.slots.indices { theirs.slots[index].id = UUID() }

        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [7, 7, 7, 7])
        divergences = []
        witnessed = []
        try compare(game, turn: game.turn)

        /// A move by name, off whoever is actually standing in that slot.
        /// Scripting by index meant the script drifted the moment anything
        /// switched, and a game that quietly played something else is a green
        /// audit over nothing.
        func use(_ name: String, _ slot: Int, mine: Bool, at target: Int = 0) -> Choice {
            let team = mine ? game.board.mine : game.board.theirs
            guard slot < team.count,
                  let index = team[slot].moves.firstIndex(where: { $0.name == name })
            else { return .attack(move: 0, target: target) }
            return .attack(move: index, target: target)
        }
        func turn(_ left: String, _ right: String,
                  _ theirLeft: String, _ theirRight: String) -> (Play, Play) {
            (Play(left: use(left, 0, mine: true), right: use(right, 1, mine: true)),
             Play(left: use(theirLeft, 0, mine: false), right: use(theirRight, 1, mine: false)))
        }

        var played = 0
        let script: [() -> (Play, Play)] = [
            // Burn the Milotic; Tailwind up. They Substitute and set Trick Room.
            { turn("Will-O-Wisp", "Tailwind", "Substitute", "Trick Room") },
            // Seed it, Light Screen up. They Yawn and Protect.
            { (Play(left: use("Flare Blitz", 0, mine: true),
                     right: use("Leech Seed", 1, mine: true, at: 1)),
               Play(left: use("Protect", 0, mine: false), right: use("Yawn", 1, mine: false))) },
            // Taunt the Slowbro.
            { turn("Protect", "Taunt", "Scald", "Protect") },
            // Pivot the Incineroar out, which is where the stages went.
            { (Play(left: .swap(to: 2), right: use("Light Screen", 1, mine: true)),
               Play(left: use("Scald", 0, mine: false), right: use("Protect", 1, mine: false))) },
            // And back.
            { (Play(left: .swap(to: 2), right: use("Taunt", 1, mine: true)),
               Play(left: use("Scald", 0, mine: false), right: use("Protect", 1, mine: false))) },
            { turn("Protect", "Tailwind", "Rain Dance", "Protect") },
        ]
        for step in script where !ShowdownEngine.shared.ended {
            let (mineDoes, theyDo) = step()
            do { try game.play(mine: mineDoes, theirs: theyDo) } catch {
                print("    turn \(game.turn) REFUSED: \(ShowdownEngine.shared.lastRefusal ?? "\(error)")")
                let plain = Play(left: .attack(move: 0, target: 0),
                                 right: .attack(move: 0, target: 0))
                guard (try? game.play(mine: plain, theirs: plain)) != nil else { break }
            }
            played += 1
            try compare(game, turn: game.turn)
        }
        print("  played \(played) turns; the simulator was seen doing: "
              + witnessed.sorted().joined(separator: ", "))
        // A green audit over a game where nothing happened is not a green
        // audit. These are the mechanics this game exists to put on the board.
        for wanted in ["a status", "a stage moved", "weather", "trickroom",
                       "substitute", "leechseed", "taunt", "tailwind",
                       "lightscreen", "yawn"] {
            check("  the game actually did: \(wanted)", witnessed.contains(wanted),
                  witnessed.sorted().joined(separator: ", "))
        }
        report("a game with statuses, screens, weather, a substitute and a pivot in it")
    }

    /// And the same over teams nobody chose for the occasion.
    func testALadderGameWithSwitchesAgreesWithTheSimulator() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let game = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [9, 9, 9, 9])
        divergences = []
        for turn in 0..<12 where !ShowdownEngine.shared.ended {
            let pivot = turn % 4 == 3
            let play = Play(left: pivot ? .swap(to: 2) : .attack(move: turn % 3, target: 0),
                            right: .attack(move: 0, target: 1))
            if (try? game.play(mine: play, theirs: play)) == nil {
                let plain = Play(left: .attack(move: 0, target: 0),
                                 right: .attack(move: 0, target: 1))
                guard (try? game.play(mine: plain, theirs: plain)) != nil else { break }
            }
            try compare(game, turn: game.turn)
        }
        report("a ladder game with switches in it")
    }

    /// Fly, a Toxic, and a Solar Beam in the sun -- then every turn taken
    /// back and the rebuilt board checked against the simulator.
    ///
    /// The three are the parts of a Pokemon's state the reader had not kept.
    /// A wound-up move was recorded as move nought and never cleared, so after
    /// one Solar Beam the app ignored every order given to that Pokemon. Fly
    /// never made anything unreachable. The Toxic count never climbed. And
    /// the sun matters twice: Solar Beam fires on the turn it is begun, with
    /// no second move line to say the winding is over, and it is the weather a
    /// lead brings on the way in -- which taking a turn back was losing,
    /// because it rebuilt the game without reading the opening.
    func testWindUpsToxicAndTakingATurnBackAgreeWithTheSimulator() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let dragonite = slot("Dragonite", item: "", ability: "Inner Focus",
                                   moves: ["Fly", "Protect", "Dragon Claw", "Extreme Speed"], sp: [32, 32, 0, 0, 0, 0]),
              let gengar = slot("Gengar", item: "", ability: "Cursed Body",
                                moves: ["Toxic", "Protect", "Shadow Ball", "Sludge Bomb"], sp: [0, 0, 0, 32, 0, 32]),
              let ninetales = slot("Ninetales", item: "", ability: "Drought",
                                   moves: ["Solar Beam", "Protect", "Flamethrower", "Will-O-Wisp"], sp: [32, 0, 0, 32, 0, 0]),
              let milotic = slot("Milotic", item: "", ability: "Marvel Scale",
                                 moves: ["Scald", "Protect", "Recover", "Ice Beam"], sp: [32, 0, 32, 0, 0, 0]),
              [dragonite, gengar, ninetales, milotic].allSatisfy({ $0.moves.count == 4 })
        else { throw XCTSkip("the cast is not in this dex") }

        var mine = Team(name: "Mine"); mine.format = "doubles"; mine.slots = [dragonite, gengar]
        var theirs = Team(name: "Theirs"); theirs.format = "doubles"; theirs.slots = [ninetales, milotic]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [6, 2, 8, 3])
        divergences = []
        witnessed = []
        try compare(game, turn: game.turn)

        func use(_ name: String, _ slot: Int, mine: Bool, at target: Int = 0) -> Choice {
            let team = mine ? game.board.mine : game.board.theirs
            guard slot < team.count, !team[slot].fainted,
                  let index = team[slot].moves.firstIndex(where: { $0.name == name })
            else { return .pass }
            return .attack(move: index, target: target)
        }
        // The Pokemon's own order when it is mid-Fly: the app's, which is the
        // thing under test, rather than one the script supplies.
        func orders(_ left: String, _ right: String, mine: Bool) -> Play {
            let team = mine ? game.board.mine : game.board.theirs
            func one(_ name: String, _ slot: Int) -> Choice {
                if let charging = team[slot].charging {
                    return .attack(move: charging, target: team[slot].chargingTarget)
                }
                return use(name, slot, mine: mine)
            }
            return Play(left: one(left, 0), right: one(right, 1))
        }
        var sawCharge = false, sawHidden = false, sawToxic = 0
        let script: [(String, String, String, String)] = [
            ("Fly", "Toxic", "Solar Beam", "Protect"),        // up, poison, sun beam
            ("Fly", "Protect", "Flamethrower", "Scald"),       // Fly lands
            ("Dragon Claw", "Shadow Ball", "Solar Beam", "Recover"),
            ("Extreme Speed", "Sludge Bomb", "Flamethrower", "Ice Beam"),
        ]
        for (a, b, c, d) in script where !ShowdownEngine.shared.ended {
            try game.play(mine: orders(a, b, mine: true), theirs: orders(c, d, mine: false))
            if game.board.mine.contains(where: { $0.charging != nil }) { sawCharge = true }
            if game.board.mine.contains(where: \.hidden) { sawHidden = true }
            sawToxic = max(sawToxic, game.board.theirs.map(\.toxicTurns).max() ?? 0)
            try compare(game, turn: game.turn)
        }
        print("  wound up: \(sawCharge), out of reach: \(sawHidden), deepest Toxic: \(sawToxic)")
        check("a Fly was wound up and out of reach", sawCharge && sawHidden)
        check("and the Toxic count climbed", sawToxic >= 2, "\(sawToxic)")
        check("the sun came up with the lead", witnessed.contains("weather"))

        // And back through every turn, each rebuilt board checked whole.
        let reached = game.turn
        for back in stride(from: reached - 1, through: 1, by: -1) {
            _ = try game.rewind(to: back)
            try compare(game, turn: back)
            check("taking back to turn \(back) keeps the sun",
                  game.board.field.weather == .sun, game.board.field.weather.rawValue)
        }
        report("Fly, Toxic, sun, and every turn taken back")
    }
}
