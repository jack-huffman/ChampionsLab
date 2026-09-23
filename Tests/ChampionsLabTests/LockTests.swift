//  LockTests.swift
//  What you may click is what the simulator will take.
//
//      swift test --filter LockTests
//
//  A Choice item's lock, an Assault Vest, an Encore, a Disable. The app
//  modelled some of these and not others, and for the ones it did model the
//  bookkeeping lived in old-engine code the Showdown path never runs -- so
//  each was a button you could press that the simulator refused, and a
//  refused order takes the whole side's turn down with it. The request the
//  simulator sends already lists every one; this checks the app reads it.

import XCTest
@testable import ChampionsLab

@MainActor
final class LockTests: HarnessCase {
    private func slot(_ name: String, item: String, ability: String = "",
                      _ moves: [String]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.item = item
        s.ability = form.abilities.first { $0.name == ability }?.name ?? form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
        s.sp = [32, 32, 0, 0, 0, 32]; s.id = UUID()
        return s
    }

    private func accepted(_ text: String, side: String) throws -> Bool {
        guard let saved = try ShowdownEngine.shared.save() else { return false }
        defer { _ = try? ShowdownEngine.shared.restore(saved) }
        return try ShowdownEngine.shared.choose(side, text)
    }

    func testTheLocksAreReadAndNothingOfferedIsRefused() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let scarf = slot("Incineroar", item: "Choice Scarf",
                               ["Flare Blitz", "Darkest Lariat", "Fake Out", "Parting Shot"]),
              let vest = slot("Rillaboom", item: "Assault Vest",
                              ["Wood Hammer", "Grassy Glide", "Swords Dance", "Protect"]),
              let encore = slot("Whimsicott", item: "Focus Sash", ability: "Prankster",
                                ["Encore", "Moonblast", "Tailwind", "Protect"]),
              let bench = slot("Milotic", item: "Leftovers", ["Scald", "Protect", "Recover", "Ice Beam"]),
              scarf.moves.count == 4, vest.moves.count == 4, encore.moves.count == 4
        else { throw XCTSkip("the cast is not in this dex") }

        var mine = Team(name: "Locks"); mine.format = "doubles"; mine.slots = [scarf, vest, bench]
        var theirs = Team(name: "Encore"); theirs.format = "doubles"; theirs.slots = [encore, bench, bench]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2], theirFour: [0, 1, 2],
                                            store: store, seed: [3, 1, 4, 1])

        // The Assault Vest is a lock from the first turn: no status moves.
        let vested = game.board.mine[1]
        let swords = vested.moves.firstIndex { $0.name == "Swords Dance" } ?? -1
        check("the Assault Vest's status moves are off",
              vested.unusable.contains(swords), "\(vested.unusable)")
        check("  and the tile says why",
              CommandDeckView.shortReason(unavailable: vested.moves[swords], fighter: vested)
                .contains("Assault Vest"))

        // Turn one: the Scarf user commits to Darkest Lariat, and the
        // Whimsicott Encores it.
        let lariat = game.board.mine[0].moves.firstIndex { $0.name == "Darkest Lariat" } ?? 0
        let encoreMove = game.board.theirs[0].moves.firstIndex { $0.name == "Encore" } ?? 0
        try game.play(mine: Play(left: .attack(move: lariat, target: 1),
                                 right: .attack(move: 0, target: 1)),
                      theirs: Play(left: .attack(move: encoreMove, target: 0),
                                   right: .attack(move: 1, target: 0)))

        let locked = game.board.mine[0]
        let others = locked.moves.indices.filter { $0 != lariat }
        check("the Choice lock is read: everything but Darkest Lariat is off",
              Set(others).isSubset(of: locked.unusable), "\(locked.unusable) of \(others)")
        check("  and Darkest Lariat is not", !locked.unusable.contains(lariat))
        check("  and the tile says why",
              CommandDeckView.shortReason(unavailable: locked.moves[others[0]], fighter: locked)
                .contains("Choice Scarf"))
        check("its Power Points went down",
              locked.pp(at: lariat) < locked.moves[lariat].pp, "\(locked.pp(at: lariat))")

        // And the thing that matters: nothing either the deck or the search
        // offers is refused, across several turns of this.
        var offered = 0, refused: [String] = []
        for turn in 0..<4 where !ShowdownEngine.shared.ended {
            let solver = TurnGame(board: game.board, believingTheirs: true)
            for mine in [true, false] {
                for play in solver.plays(forMine: mine) {
                    let text = game.request(play, side: mine)
                    offered += 1
                    if try !accepted(text, side: mine ? "p1" : "p2") {
                        refused.append("turn \(turn + 1) \(mine ? "ours" : "theirs"): \(text)")
                    }
                }
            }
            // The deck's own offers, for our side: every usable move at each
            // target it would put in front of you.
            for slot in 0..<game.board.activeCount where !game.board.mine[slot].fainted {
                for index in game.board.mine[slot].moves.indices
                where MoveLegality.usable(index, byMine: true, slot: slot, board: game.board) {
                    let choice = Choice.attack(move: index, target: 0)
                    let other = Choice.attack(move: game.board.mine[slot == 0 ? 1 : 0].unusable
                        .isEmpty ? 0 : (game.board.mine[slot == 0 ? 1 : 0].moves.indices.first {
                            !game.board.mine[slot == 0 ? 1 : 0].unusable.contains($0) } ?? 0), target: 0)
                    let play = Play(left: slot == 0 ? choice : other, right: slot == 0 ? other : choice)
                    let text = game.request(play, side: true)
                    offered += 1
                    if try !accepted(text, side: "p1") { refused.append("turn \(turn + 1) deck: \(text)") }
                }
            }
            guard let a = solver.plays(forMine: true).first,
                  let b = solver.plays(forMine: false).first,
                  (try? game.play(mine: a, theirs: b)) != nil else { break }
            var guarded = 0
            while game.awaitingSendIn, guarded < 4 { try game.sendIn(bench: 0); guarded += 1 }
        }
        print("  \(offered) orders offered")
        for line in refused.prefix(12) { print("       \(line)") }
        check("not one of them refused", refused.isEmpty, "\(refused.count) of \(offered)")
    }
}
