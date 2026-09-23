//  ChoiceEchoTests.swift
//  Everything the screen lets you click is something the simulator will play.
//
//      swift test --filter ChoiceEchoTests
//
//  Reported as: Mega Evolve the Staraptor and Close Combat, Charm the
//  Staraptor with your own Whimsicott -- and the Staraptor does not Mega
//  Evolve, and the Whimsicott uses Moonblast.
//
//  All one fault. `Choice.attackingAlly` is how the deck says "aim this at my
//  own partner", and it is a target of a hundred; every reader of a choice in
//  this app tests for it except the one that writes the simulator's orders,
//  which sent "move 3 101". Showdown refuses a target that does not exist,
//  and a refused order is refused for the *whole side* -- so the Mega went
//  with it, and `answer` fell back to "default", which is the first legal
//  move and no Mega Evolution.
//
//  A single wrong turn is worth a fix. A whole family of orders that the
//  screen offers and the simulator will not take is worth a test, so this
//  offers every one of them and checks it comes back accepted.

import XCTest
@testable import ChampionsLab

@MainActor
final class ChoiceEchoTests: HarnessCase {
    /// Whether the simulator would take this order, without letting it change
    /// the game: the position is saved and put back around the asking.
    private func accepted(_ text: String, side: String) throws -> (ok: Bool, why: String) {
        guard let saved = try ShowdownEngine.shared.save() else { return (false, "no position") }
        defer { _ = try? ShowdownEngine.shared.restore(saved) }
        let ok = try ShowdownEngine.shared.choose(side, text)
        return (ok, ok ? "" : (ShowdownEngine.shared.lastRefusal ?? "refused"))
    }

    func testEveryOrderTheDeckCanBuildIsOneTheSimulatorWillPlay() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let game = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [5, 5, 5, 5])
        let board = game.board
        // Something legal for the other slot, so what is being tested is the
        // one order under test rather than the pair.
        let filler = Choice.attack(move: 0, target: 0)

        var offered = 0, allyOrders = 0, megaOrders = 0
        var refused: [String] = []
        for slot in 0..<board.activeCount {
            let fighter = board.mine[slot]
            guard !fighter.fainted else { continue }
            for index in fighter.moves.indices {
                guard MoveLegality.usable(index, byMine: true, slot: slot, board: board) else { continue }
                // Every target the aiming screen puts in front of you: each
                // Pokemon on their side, and your own partner.
                var choices: [(String, Choice)] = []
                for foe in 0..<board.activeCount where !board.theirs[foe].fainted {
                    choices.append(("at their \(foe)", .attack(move: index, target: foe)))
                }
                if board.activeCount > 1, !board.mine[slot == 0 ? 1 : 0].fainted {
                    choices.append(("at your own", Choice.attackingAlly(move: index)))
                }
                for (where_, choice) in choices {
                    // And with the stone toggled as well as without, because
                    // Mega Evolution rides on the order rather than beside it.
                    for mega in [false, true] where !mega || fighter.pendingMega != nil {
                        var play = Play(left: slot == 0 ? choice : filler,
                                        right: slot == 0 ? filler : choice)
                        if mega { play.megaSlot = slot }
                        let text = game.request(play, side: true)
                        let verdict = try accepted(text, side: "p1")
                        offered += 1
                        if where_ == "at your own" { allyOrders += 1 }
                        if mega { megaOrders += 1 }
                        if !verdict.ok {
                            refused.append("\(fighter.build.form.formLabel) "
                                + "\(fighter.moves[index].name) \(where_)"
                                + (mega ? " with the stone" : "")
                                + " -> \"\(text)\"  \(verdict.why)")
                        }
                    }
                }
            }
        }

        print("  \(offered) orders offered, \(allyOrders) of them at your own partner, "
              + "\(megaOrders) with a Mega Evolution")
        for line in refused.prefix(20) { print("       \(line)") }
        if refused.count > 20 { print("       ... and \(refused.count - 20) more") }
        // The matrix has to actually contain the shapes that broke, or a
        // green run means nothing.
        check("orders were offered", offered >= 12, "\(offered)")
        check("including some at your own partner", allyOrders > 0, "\(allyOrders)")
        check("the simulator would play every one of them",
              refused.isEmpty, "\(refused.count) of \(offered) refused")
    }

    /// The reported turn, exactly: a Mega on one and a Charm from the other
    /// onto it.
    func testTheReportedTurnPlaysAsAsked() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        func slot(_ name: String, item: String, _ moves: [String]) -> TeamSlot? {
            guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
            var s = TeamSlot(formID: form.id)
            s.item = item
            s.ability = form.abilities.first?.name ?? ""
            s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
            s.sp = [32, 32, 0, 0, 0, 0]; s.id = UUID()
            return s
        }
        guard let mega = store.data.forms.first(where: { $0.formLabel.contains("Staraptor") && $0.isMega }),
              let staraptor = slot("Staraptor", item: mega.megaTrigger,
                                   ["Close Combat", "Brave Bird", "Protect", "U-turn"]),
              let whimsicott = slot("Whimsicott", item: "Focus Sash",
                                    ["Charm", "Moonblast", "Tailwind", "Protect"]),
              staraptor.moves.count == 4, whimsicott.moves.count == 4,
              let theirs = slot("Milotic", item: "Leftovers", ["Scald", "Protect", "Recover", "Ice Beam"])
        else { throw XCTSkip("the cast is not in this dex") }

        var mine = Team(name: "Mine"); mine.format = "doubles"
        mine.slots = [staraptor, whimsicott]
        var them = Team(name: "Theirs"); them.format = "doubles"; them.slots = [theirs, theirs]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in them.slots.indices { them.slots[i].id = UUID() }

        let game = try ShowdownBattle.start(mine: mine, theirs: them,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [6, 6, 6, 6])
        let closeCombat = game.board.mine[0].moves.firstIndex { $0.name == "Close Combat" } ?? 0
        let charm = game.board.mine[1].moves.firstIndex { $0.name == "Charm" } ?? 0
        var play = Play(left: .attack(move: closeCombat, target: 0),
                        right: Choice.attackingAlly(move: charm))
        play.megaSlot = 0
        print("  orders: \(game.request(play, side: true))")
        try game.play(mine: play,
                      theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
        let said = game.board.story.joined(separator: " ")
        for line in game.board.story.prefix(10) { print("    | \(line)") }
        check("nothing was substituted", !said.contains("could not be played"), said.prefix(120).description)
        check("the Staraptor Mega Evolved",
              game.board.mine[0].build.form.isMega || said.contains("Mega"),
              game.board.mine[0].build.form.formLabel)
        check("it used Close Combat", said.contains("Close Combat"))
        check("and the Whimsicott used Charm, not Moonblast",
              said.contains("Charm") && !said.contains("Moonblast"))
    }
}
