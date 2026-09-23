//  MultiHitTests.swift
//  A flurry lands blow by blow, and a refusal says a sentence.
//
//      swift test --filter MultiHitTests

import XCTest
@testable import ChampionsLab

@MainActor
final class MultiHitTests: HarnessCase {
    /// The field plays a multi-hit move off `action.hits` -- the move's own
    /// picture once per blow, each with its own number, the bar stepping down
    /// between them. Nothing on the Showdown path was filling it, so a Rock
    /// Blast that hit five times landed once on screen. The health was always
    /// right; it arrived in one lump.
    func testAFlurryLandsBlowByBlow() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        func slot(_ name: String, _ moves: [String]) -> TeamSlot? {
            guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
            var s = TeamSlot(formID: form.id)
            s.ability = form.abilities.first?.name ?? ""
            s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
            s.sp = [32, 32, 0, 0, 0, 0]; s.id = UUID()
            return s
        }
        // A move that strikes more than once, and something to strike.
        let flurries = ["Rock Blast", "Bullet Seed", "Icicle Spear", "Bone Rush",
                        "Dual Wingbeat", "Double Hit", "Tail Slap", "Arm Thrust"]
        var played: [(String, [Int])] = []
        for name in flurries {
            guard let move = store.data.moves.values.first(where: { $0.name == name }) else { continue }
            guard let user = store.data.forms.first(where: { $0.moves.contains(move.id) }) else { continue }
            guard let attacker = slot(user.formLabel, [name, "Protect"]),
                  attacker.moves.count == 2,
                  let filler = slot("Whimsicott", ["Protect", "Moonblast"]),
                  let target = slot("Milotic", ["Protect", "Recover"]) else { continue }
            var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [attacker, filler]
            var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [target, filler]
            for i in mine.slots.indices { mine.slots[i].id = UUID() }
            for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
            guard let game = try? ShowdownBattle.start(mine: mine, theirs: theirs,
                                                       myFour: [0, 1], theirFour: [0, 1],
                                                       store: store, seed: [2, 7, 1, 8]) else { continue }
            let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 1, target: 0))
            guard (try? game.play(mine: play,
                                  theirs: Play(left: .attack(move: 1, target: 0),
                                               right: .attack(move: 1, target: 0)))) != nil
            else { continue }
            guard let at = game.board.steps.firstIndex(where: { $0.action?.move == name })
            else { continue }
            // A flurry that missed is not a flurry that landed once: Rock
            // Blast and its like are ninety per cent moves, and a miss has no
            // blows in it to count.
            let after = game.board.steps[at].theirHP.first ?? 0
            let before = at > 0 ? (game.board.steps[at - 1].theirHP.first ?? 0)
                                : game.board.theirs[0].maxHP
            guard before > after else { continue }
            played.append((name, game.board.steps[at].action?.hits ?? []))
        }

        check("some flurries were played", !played.isEmpty, "\(played.count)")
        for (name, hits) in played {
            print("  \(name): \(hits.count) blows \(hits)")
        }
        let struckOnce = played.filter { $0.1.count < 2 }.map(\.0)
        check("and every one of them landed more than once",
              struckOnce.isEmpty, struckOnce.joined(separator: ", "))
    }

    /// A refused order used to put the simulator's whole reply in the log --
    /// the `|request|` that follows the error, which is every Pokemon on a
    /// side with its moves and stats, a couple of thousand characters of JSON.
    func testARefusalSaysASentenceAndNotTheWholeRequest() {
        let wall = "p2 |error|[Invalid choice] Can't move: Sneasler doesn't have a move matching 1101"
            + " |request|{\"active\":[{\"moves\":[{\"move\":\"Close Combat\",\"id\":\"closecombat\",\"pp\":6}]}],"
            + String(repeating: "\"padding\":\"x\",", count: 200) + "}"
        let said = ShowdownEngine.readable(wall)
        check("the error survives",
              said == "Can't move: Sneasler doesn't have a move matching 1101", said ?? "nothing")
        check("and the request does not", said?.contains("request") != true)
        check("nothing without an error in it says anything",
              ShowdownEngine.readable("p2 |request|{\"active\":[]}") == nil)
        check("and a very long error is cut short",
              (ShowdownEngine.readable("p1 |error|" + String(repeating: "x", count: 500)) ?? "").count <= 203)
    }
}
