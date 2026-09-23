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
}
