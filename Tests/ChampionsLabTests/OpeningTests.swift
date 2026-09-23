//  OpeningTests.swift
//  How a game starts: who is announced, and one ability going off per beat.
//
//      swift test --filter OpeningTests

import XCTest
@testable import ChampionsLab

@MainActor
final class OpeningTests: HarnessCase {
    private func slot(_ name: String, want ability: String, _ moves: [String]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.ability = form.abilities.first { $0.name == ability }?.name
            ?? form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
        s.sp = [32, 32, 0, 0, 0, 0]; s.id = UUID()
        return s
    }

    /// Two Intimidates arriving together are two things happening, and the
    /// field draws a step at a time: one pair of arrows, then the other.
    ///
    /// They used to share a step. The simulator sends
    /// `|-ability|p2b: Salamence|Intimidate|boost` and its unboosts, then the
    /// same for the second Pokemon, and nothing here opened a beat between
    /// them -- so one step carried both names, the log read them off in a
    /// heap, and the field showed a single drop for two separate ones.
    func testEachIntimidateIsItsOwnBeat() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let inc = slot("Incineroar", want: "Intimidate", ["Protect", "Flare Blitz"]),
              let sala = slot("Salamence", want: "Intimidate", ["Protect", "Dragon Claw"]),
              let a = slot("Whimsicott", want: "Prankster", ["Protect", "Moonblast"]),
              let b = slot("Milotic", want: "Marvel Scale", ["Protect", "Scald"]),
              inc.ability == "Intimidate", sala.ability == "Intimidate"
        else { throw XCTSkip("the cast is not in this dex") }

        var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [a, b]
        var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [inc, sala]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [8, 8, 8, 8])

        for (i, step) in game.board.steps.enumerated() {
            print("  [\(i)] \(step.abilities.map(\.name)) -- "
                  + step.text.replacingOccurrences(of: "\n", with: " / "))
        }
        let firing = game.board.steps.filter { $0.abilities.contains { $0.name == "Intimidate" } }
        check("both Intimidates went off", firing.count == 2, "\(firing.count) steps")
        for step in firing {
            check("  and each has one on it", step.abilities.count == 1,
                  "\(step.abilities.map(\.name))")
        }
        // And the drop landed twice, which is what the two steps are about.
        check("the Attack came down twice",
              game.board.mine[0].build.boosts[Stat.attack.rawValue] == -2,
              "\(game.board.mine[0].build.boosts[Stat.attack.rawValue])")
    }

    /// The two sides are told apart on the way in. Four Pokemon walking on is
    /// four lines whatever they say, but "Staraptor went in" four times over
    /// reads as one thing happening four times rather than two teams arriving.
    func testTheOpeningTellsTheSidesApart() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let a = slot("Whimsicott", want: "Prankster", ["Protect", "Moonblast"]),
              let b = slot("Milotic", want: "Marvel Scale", ["Protect", "Scald"])
        else { throw XCTSkip("the cast is not in this dex") }
        var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [a, b]
        var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [b, a]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [8, 8, 8, 8])
        let said = game.board.story
        check("yours are called out", said.contains { $0.hasPrefix("Go! ") }, said.joined(separator: " | "))
        check("and theirs are sent out against you",
              said.contains { $0.hasSuffix("was sent out!") }, said.joined(separator: " | "))
        check("nothing merely went in", !said.contains { $0.contains("came in") })
    }

    /// Fake Out works on the turn a Pokemon walks on and no other, and the
    /// app has to stop offering it after that.
    ///
    /// `justArrived` is set when a Pokemon arrives and unset in `Residuals`,
    /// which is the old engine's end of turn -- never reached when Showdown
    /// resolves the game. So every Pokemon stayed permanently fresh: the move
    /// tile offered Fake Out on turn nine, and the search built orders out of
    /// it that the simulator refused, which takes the whole side's turn down
    /// and substitutes the first legal move for everything you asked for.
    func testFakeOutStopsBeingOfferedAfterTheTurnItArrivesOn() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let inc = slot("Incineroar", want: "Blaze",
                             ["Fake Out", "Flare Blitz", "Protect", "Darkest Lariat"]),
              let other = slot("Milotic", want: "Marvel Scale", ["Protect", "Scald"]),
              inc.moves.count == 4 else { throw XCTSkip("the cast is not in this dex") }
        var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [inc, other, other]
        var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [other, other, other]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2], theirFour: [0, 1, 2],
                                            store: store, seed: [3, 3, 3, 3])
        let fakeOut = game.board.mine[0].moves.firstIndex { $0.name == "Fake Out" } ?? 0

        check("on the turn it walks on, it is fresh", game.board.mine[0].justArrived)
        check("  so the deck offers Fake Out",
              MoveLegality.usable(fakeOut, byMine: true, slot: 0, board: game.board)
                || game.board.mine[0].justArrived)

        let idle = Play(left: .attack(move: 1, target: 0), right: .attack(move: 0, target: 0))
        try game.play(mine: idle, theirs: Play(left: .attack(move: 0, target: 0),
                                               right: .attack(move: 0, target: 0)))
        check("a turn later it is not", !game.board.mine[0].justArrived)
        // Which is the whole point: the search stops building orders out of it.
        let solver = TurnGame(board: game.board, believingTheirs: true)
        let offersIt = solver.choices(forMine: true, slot: 0).contains {
            if case .attack(let m, _) = $0 { return m == fakeOut }
            return false
        }
        check("and the search stops offering it", !offersIt)
    }
}
