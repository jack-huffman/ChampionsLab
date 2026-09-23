//  ShadowSneakAuditTests.swift
//  A reported number, chased through the app's own path rather than a paste
//  written by hand.
//
//      swift test --filter ShadowSneakAuditTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ShadowSneakAuditTests: HarnessCase {
    func testWhatAPlusTwoShadowSneakActuallyDoes() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let ceruledge = store.data.forms.first(where: { $0.formLabel == "Ceruledge" }),
              let basculegion = store.data.forms.first(where: { $0.formLabel.hasPrefix("Basculegion") })
        else { throw XCTSkip("not in the dex") }
        print("  Ceruledge types: \(ceruledge.types)  base Atk \(ceruledge.attack)")
        print("  \(basculegion.formLabel) types: \(basculegion.types)  base Def \(basculegion.defense) HP \(basculegion.hp)")

        func slot(_ form: Form, moves: [String], sp: [Int]) -> TeamSlot {
            var s = TeamSlot(formID: form.id)
            s.ability = form.abilities.first?.name ?? ""
            s.moves = moves.compactMap { name in
                form.moves.first { store.move($0)?.name == name }
            }
            if !sp.isEmpty { s.sp = sp }
            return s
        }
        var mine = Team(name: "Mine"); mine.format = "doubles"
        var theirs = Team(name: "Theirs"); theirs.format = "doubles"
        let filler = store.data.forms.first { $0.formLabel == "Incineroar" } ?? ceruledge
        mine.slots = [slot(ceruledge, moves: ["Shadow Sneak", "Swords Dance"], sp: [0, 32, 0, 0, 0, 0]),
                      slot(filler, moves: ["Protect"], sp: [0, 0, 0, 0, 0, 0])]
        theirs.slots = [slot(basculegion, moves: ["Protect"], sp: [32, 0, 0, 0, 0, 0]),
                        slot(filler, moves: ["Protect"], sp: [0, 0, 0, 0, 0, 0])]
        for index in mine.slots.indices { mine.slots[index].id = UUID() }
        for index in theirs.slots.indices { theirs.slots[index].id = UUID() }

        print("  --- the paste the app writes ---")
        print(ShowdownTeam.paste(for: mine, store: store)
            .split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))

        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [4, 4, 4, 4])
        let me = game.board.mine[0], them = game.board.theirs[0]
        print("  Ceruledge on the board: \(me.build.form.formLabel) \(me.hp)/\(me.maxHP)")
        print("  Theirs: \(them.build.form.formLabel) \(them.hp)/\(them.maxHP)")

        // Turn one: Swords Dance.
        let sd = Play(left: .attack(move: 1, target: 0), right: .attack(move: 0, target: 0))
        let idle = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))
        _ = try? game.play(mine: sd, theirs: idle)
        let boosts = game.board.mine[0].build.boosts
        print("  after Swords Dance, boosts: \(boosts)")
        check("Ceruledge is at +2 Attack", boosts[Stat.attack.rawValue] == 2, "\(boosts)")

        // Turn two: Shadow Sneak into their slot 0.
        let before = game.board.theirs[0].hp
        let sneak = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))
        _ = try? game.play(mine: sneak, theirs: idle)
        let after = game.board.theirs[0].hp
        let dealt = before - after
        print("  --- log ---")
        for line in game.board.story.suffix(12) { print("    \(line)") }
        let share = Double(dealt) / Double(game.board.theirs[0].maxHP) * 100
        print(String(format: "  Shadow Sneak took %d of %d (%.0f%%)",
                     dealt, game.board.theirs[0].maxHP, share))
        check("a +2 STAB super-effective Shadow Sneak takes most of it",
              share > 70, String(format: "%.0f%%", share))
    }

    /// The card said +2 and the sim had nothing.
    ///
    /// Showdown clears stat stages and every volatile when a Pokemon leaves
    /// the field. The reader's board did not, so a Pokemon could Swords Dance,
    /// pivot out, come back, and stand there still reading +2 -- and the
    /// damage it then did was the damage an unboosted Pokemon does, because
    /// the sim was right and the screen was not.
    func testAPokemonThatPivotsOutDoesNotComeBackStillBoosted() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let ceruledge = store.data.forms.first(where: { $0.formLabel == "Ceruledge" }),
              let basculegion = store.data.forms.first(where: { $0.formLabel.hasPrefix("Basculegion") }),
              let bench = store.data.forms.first(where: { $0.formLabel == "Incineroar" })
        else { throw XCTSkip("not in the dex") }

        func slot(_ form: Form, moves: [String], sp: [Int]) -> TeamSlot {
            var s = TeamSlot(formID: form.id)
            s.ability = form.abilities.first?.name ?? ""
            s.moves = moves.compactMap { name in form.moves.first { store.move($0)?.name == name } }
            if !sp.isEmpty { s.sp = sp }
            return s
        }
        var mine = Team(name: "Mine"); mine.format = "doubles"
        var theirs = Team(name: "Theirs"); theirs.format = "doubles"
        mine.slots = [slot(ceruledge, moves: ["Shadow Sneak", "Swords Dance"], sp: [0, 32, 0, 0, 0, 0]),
                      slot(bench, moves: ["Protect"], sp: []),
                      slot(bench, moves: ["Protect"], sp: [])]
        theirs.slots = [slot(basculegion, moves: ["Protect"], sp: [32, 0, 0, 0, 0, 0]),
                        slot(bench, moves: ["Protect"], sp: []),
                        slot(bench, moves: ["Protect"], sp: [])]
        for index in mine.slots.indices { mine.slots[index].id = UUID() }
        for index in theirs.slots.indices { theirs.slots[index].id = UUID() }

        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2], theirFour: [0, 1, 2],
                                            store: store, seed: [4, 4, 4, 4])
        let idle = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))

        _ = try? game.play(mine: Play(left: .attack(move: 1, target: 0),
                                      right: .attack(move: 0, target: 0)), theirs: idle)
        check("Swords Dance landed",
              game.board.mine[0].build.boosts[Stat.attack.rawValue] == 2,
              "\(game.board.mine[0].build.boosts)")

        // Out, and back.
        _ = try? game.play(mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                           theirs: idle)
        print("  after pivoting out, slot 0 is \(game.board.mine[0].build.form.formLabel)")
        _ = try? game.play(mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                           theirs: idle)
        guard let back = game.board.mine.prefix(2).firstIndex(where: {
            $0.build.form.formLabel == "Ceruledge"
        }) else { return check("Ceruledge came back", false,
                               game.board.mine.prefix(2).map(\.build.form.formLabel).joined(separator: ", ")) }
        let boosts = game.board.mine[back].build.boosts
        print("  Ceruledge is back at slot \(back), boosts \(boosts)")
        check("and it is not still at +2",
              boosts.allSatisfy { $0 == 0 }, "\(boosts)")
    }
}
