//  DamagePredictionTests.swift
//  The number the app shows you against the number the simulator deals.
//
//      swift test --filter DamagePredictionTests
//
//  The board is now audited against the sim, which settles what *state* the
//  screen is drawing. It does not settle the other half: the damage the app
//  predicts -- on the move preview, on the command deck, and in the search
//  that ranks your options -- is worked out by DamageCalc, the app's own
//  model, and nothing was comparing that to what Showdown actually does.
//
//  A prediction is a range, because the game rolls 85% to 100%. So the check
//  is the honest one: play the move in the simulator and see whether what it
//  dealt falls inside what the app said it would.
//
//  Crits are excluded rather than modelled. The app predicts the ordinary
//  roll, the sim crits one time in twenty-four, and a crit landing outside a
//  non-crit range is the two of them agreeing.

import XCTest
@testable import ChampionsLab

@MainActor
final class DamagePredictionTests: HarnessCase {
    private struct Case {
        var attacker: String
        var defender: String
        var move: String
        var predicted: ClosedRange<Int>
        var actual: Int
        var crit: Bool
        var note: String
        /// The blow took the last of it. A prediction of 282 into a Pokemon
        /// with 227 left is not a prediction of 227 -- the sim simply stops
        /// at nought -- so what is checked there is that the app saw the
        /// knockout coming, not that it named a number the game cannot deal.
        var killed: Bool
    }

    private func slot(_ name: String, item: String = "", ability: String = "",
                      moves: [String]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.item = item
        s.ability = form.abilities.first { $0.name == ability }?.name
            ?? form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { move in form.moves.first { store.move($0)?.name == move } }
        s.sp = [32, 32, 0, 32, 0, 0]
        s.id = UUID()
        return s
    }

    /// One move, thrown once, in a battle of its own.
    ///
    /// A fresh battle per case rather than one game with everything in it:
    /// the point is to compare a prediction made about a known position to
    /// what happens from exactly that position, and a position that has had
    /// five turns of other things happen to it is not known any more.
    private func fire(attacker: TeamSlot, defender: TeamSlot, filler: TeamSlot,
                      move name: String, seed: [Int],
                      setup: [(String, String)] = []) throws -> Case? {
        var mine = Team(name: "A"); mine.format = "doubles"
        var theirs = Team(name: "B"); theirs.format = "doubles"
        mine.slots = [attacker, filler]
        theirs.slots = [defender, filler]
        for index in mine.slots.indices { mine.slots[index].id = UUID() }
        for index in theirs.slots.indices { theirs.slots[index].id = UUID() }

        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: seed)
        // Whatever has to be true before the blow: a Swords Dance up, a
        // Reflect between them, a burn on the attacker.
        for (mineDoes, theyDo) in setup {
            func pick(_ move: String, _ slot: Int, _ mine: Bool) -> Choice {
                let team = mine ? game.board.mine : game.board.theirs
                guard slot < team.count,
                      let at = team[slot].moves.firstIndex(where: { $0.name == move })
                else { return .attack(move: 0, target: 1) }
                return .attack(move: at, target: move == "Will-O-Wisp" ? 0 : 1)
            }
            let a = Play(left: pick(mineDoes, 0, true), right: .attack(move: 0, target: 1))
            let b = Play(left: pick(theyDo, 0, false), right: .attack(move: 0, target: 1))
            guard (try? game.play(mine: a, theirs: b)) != nil else { return nil }
        }
        let me = game.board.mine[0], them = game.board.theirs[0]
        guard let index = me.moves.firstIndex(where: { $0.name == name }) else { return nil }
        let move = me.moves[index]
        guard move.isDamaging, move.power > 0 else { return nil }

        // What the app would tell you, off the position as it stands.
        var field = game.board.field
        field.isDoubles = true
        // The screen is a fact about the defending side, and `Field` keeps it
        // as one flag. Set the way MovePreview sets it, because the point is
        // to check the number the app would really show, not a number worked
        // out beside it.
        field.screen = game.board.theirScreens.blunt(move)
        let said = DamageCalc.calculate(attacker: me.build, defender: them.build,
                                        move: move, field: field)
        // Their side attacks my partner rather than Protecting, which is
        // what the first go at this had them do -- every single attack was
        // blocked and there was nothing to compare.
        let idle = Choice.attack(move: 0, target: 1)
        let play = Play(left: .attack(move: index, target: 0),
                        right: .attack(move: 0, target: 1))
        let theirPlay = Play(left: idle, right: idle)
        guard (try? game.play(mine: play, theirs: theirPlay)) != nil else { return nil }

        // The damage off the move's own step rather than off the turn.
        //
        // End-of-turn health is not this move's damage: a Rillaboom on the
        // field means Grassy Terrain, and Grassy Terrain heals the target a
        // sixteenth at the close of every turn, so reading the turn would
        // have quietly credited the defender back part of what it took.
        let steps = game.board.steps
        guard let at = steps.firstIndex(where: {
            $0.action?.move == name && $0.action?.byMine == true
        }), steps[at].theirHP.indices.contains(0) else { return nil }
        let after = steps[at].theirHP[0]
        let before = at > 0 && steps[at - 1].theirHP.indices.contains(0)
            ? steps[at - 1].theirHP[0] : them.hp
        let dealt = before - after
        guard dealt > 0 else { return nil }
        return Case(attacker: me.build.form.formLabel,
                    defender: them.build.form.formLabel, move: name,
                    predicted: said.minDamage...Swift.max(said.minDamage, said.maxDamage),
                    actual: dealt,
                    crit: steps[at].criticals.contains { !$0.mine && $0.slot == 0 },
                    note: said.notes.joined(separator: "; "),
                    killed: after <= 0)
    }

    func testWhatTheAppPredictsIsWhatTheSimulatorDeals() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let filler = slot("Whimsicott", moves: ["Protect"]) else {
            throw XCTSkip("no filler")
        }
        // A spread of attackers, defenders and kinds of move: physical and
        // special, resisted and super effective, contact and not, a fixed
        // damage move and a multi-hit one.
        let attackers: [(String, String, String, [String])] = [
            ("Incineroar", "", "Blaze", ["Flare Blitz", "Darkest Lariat", "Brick Break"]),
            ("Ceruledge", "", "Weak Armor", ["Shadow Sneak", "Bitter Blade", "Close Combat"]),
            ("Rillaboom", "", "Overgrow", ["Wood Hammer", "Grassy Glide", "U-turn"]),
            ("Milotic", "", "Marvel Scale", ["Scald", "Ice Beam", "Hydro Pump"]),
        ]
        // Each with something to do that does not block and does not touch
        // its own health: no Protect, no recoil, no healing.
        let defenders: [(String, String)] = [
            ("Basculegion", "Aqua Jet"), ("Incineroar", "Darkest Lariat"),
            ("Rillaboom", "Grassy Glide"), ("Kingambit", "Sucker Punch"),
        ]

        var cases: [Case] = []
        var skipped = 0
        for (name, item, ability, moves) in attackers {
            guard let attacker = slot(name, item: item, ability: ability, moves: moves) else {
                skipped += 1; continue
            }
            for (defenderName, theirMove) in defenders {
                guard let defender = slot(defenderName, moves: [theirMove]),
                      defender.moves.count == 1 else {
                    skipped += 1; continue
                }
                for move in moves {
                    if let result = try fire(attacker: attacker, defender: defender,
                                             filler: filler, move: move, seed: [3, 1, 4, 1]) {
                        cases.append(result)
                    } else { skipped += 1 }
                }
            }
        }

        let compared = cases.filter { !$0.crit }
        print("  \(compared.count) predictions compared (\(cases.count - compared.count) crits "
              + "and \(skipped) unplayable cases set aside)")
        check("there were predictions to compare", compared.count >= 20, "\(compared.count)")

        var wrong: [Case] = []
        var knockouts = 0
        for one in compared {
            if one.killed {
                // It died. The app is right if it said at least this much.
                knockouts += 1
                if one.predicted.upperBound < one.actual { wrong.append(one) }
            } else if !one.predicted.contains(one.actual) {
                wrong.append(one)
            }
        }
        print("  \(knockouts) of them were knockouts, where the check is that the "
              + "app saw it coming")
        for one in wrong.prefix(25) {
            let low = one.predicted.lowerBound, high = one.predicted.upperBound
            let off = one.actual < low
                ? Double(low - one.actual) / Double(max(1, one.actual)) * 100
                : Double(one.actual - high) / Double(max(1, one.actual)) * 100
            print(String(format: "       %@ %@ into %@: app said %d-%d, sim dealt %d (%.0f%% out)%@",
                         one.attacker, one.move, one.defender, low, high, one.actual, off,
                         one.note.isEmpty ? "" : "  [\(one.note)]"))
        }
        if wrong.count > 25 { print("       ... and \(wrong.count - 25) more") }
        check("every prediction contained what the simulator dealt",
              wrong.isEmpty, "\(wrong.count) of \(compared.count) outside their range")
    }

    /// The same question where the modifiers live.
    ///
    /// A flat hit off a clean board is the easy case. What actually decides a
    /// game is the blow through a Reflect, off a Swords Dance, out of a burned
    /// attacker -- and those are exactly the numbers a player reads before
    /// committing to a turn.
    func testThePredictionHoldsThroughTheModifiers() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let filler = slot("Whimsicott", moves: ["Protect"]),
              let attacker = slot("Ceruledge", moves: ["Shadow Sneak", "Swords Dance",
                                                       "Bitter Blade", "Close Combat"]),
              let burner = slot("Incineroar", moves: ["Will-O-Wisp", "Darkest Lariat"]),
              let screener = slot("Basculegion", moves: ["Aqua Jet"])
        else { throw XCTSkip("the cast is not in this dex") }

        var cases: [(String, Case?)] = []
        cases.append(("flat", try fire(attacker: attacker, defender: screener,
                                       filler: filler, move: "Shadow Sneak", seed: [3, 1, 4, 1])))
        cases.append(("+2 Attack", try fire(attacker: attacker, defender: screener,
                                            filler: filler, move: "Shadow Sneak", seed: [3, 1, 4, 1],
                                            setup: [("Swords Dance", "Aqua Jet")])))
        cases.append(("burned", try fire(attacker: attacker, defender: burner,
                                         filler: filler, move: "Shadow Sneak", seed: [3, 1, 4, 1],
                                         setup: [("Shadow Sneak", "Will-O-Wisp")])))
        cases.append(("+2 and burned", try fire(attacker: attacker, defender: burner,
                                                filler: filler, move: "Close Combat", seed: [5, 5, 5, 5],
                                                setup: [("Swords Dance", "Will-O-Wisp")])))

        var compared = 0, wrong: [String] = []
        for (label, one) in cases {
            guard let one, !one.crit else {
                print("  --   \(label): nothing to compare"); continue
            }
            compared += 1
            let ok = one.killed ? one.predicted.upperBound >= one.actual
                                : one.predicted.contains(one.actual)
            print("  \(ok ? "ok  " : "FAIL") \(label): \(one.move) into \(one.defender) -- "
                  + "app said \(one.predicted.lowerBound)-\(one.predicted.upperBound), "
                  + "sim dealt \(one.actual)\(one.killed ? " (a knockout)" : "")")
            if !ok { wrong.append("\(label): \(one.predicted) vs \(one.actual)") }
        }
        check("the modifier cases were playable", compared >= 3, "\(compared)")
        check("and the app's number held through each",
              wrong.isEmpty, wrong.joined(separator: " / "))
    }
}
