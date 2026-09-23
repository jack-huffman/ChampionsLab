//  VanishingTests.swift
//  Fly, Bounce, Dig, Dive, Phantom Force, Shadow Force, Sky Drop.
//
//      swift test --filter VanishingTests
//
//  The simulator's own list of what makes a Pokemon unreachable for a turn is
//  `Pokemon.isSemiInvulnerable`: those seven. The client draws three ways of
//  going -- up into the sky, down into the ground or the water, and simply
//  gone -- and the field has to follow both: the Pokemon out of reach while
//  it winds up, and back when it lands.

import XCTest
@testable import ChampionsLab

@MainActor
final class VanishingTests: HarnessCase {
    private static let expected: [String: Move.Vanish] = [
        "fly": .up, "bounce": .up, "skydrop": .up,
        "dig": .down, "dive": .down,
        "phantomforce": .gone, "shadowforce": .gone,
    ]

    /// All seven, whatever the dataset's text for them says -- Shadow Force's
    /// is blank -- and nothing else in the dex mistaken for one.
    func testEveryVanishingMoveIsKnownAndNothingElseIs() {
        for (id, way) in Self.expected {
            check("\(id) goes \(way.rawValue)", Move.vanish(named: id, effect: "") == way)
        }
        for move in store.data.moves.values {
            let way = move.charge?.vanish
            if let want = Self.expected[move.id] {
                check("\(move.name) in the dex goes \(want.rawValue)", way == want,
                      way?.rawValue ?? "nowhere")
            } else if let way {
                check("\(move.name) is not one of the seven", false, way.rawValue)
            }
        }
        // And the two-turn moves that do not vanish stay put.
        for id in ["solarbeam", "skyattack", "electroshot", "meteorbeam"] {
            guard let move = store.data.moves[id] else { continue }
            check("\(move.name) winds up in plain sight", move.charge?.vanish == nil)
        }
    }

    private func slot(_ form: Form, _ moves: [String]) -> TeamSlot {
        var s = TeamSlot(formID: form.id)
        s.ability = form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
        s.sp = [32, 32, 0, 0, 0, 32]; s.id = UUID()
        return s
    }

    /// Every one of them this game actually teaches, played through the
    /// simulator: out of reach the right way on the beat it winds up, missed
    /// by what is thrown at it meanwhile, and back on the beat it lands.
    func testEachOneTheGameTeachesVanishAndReturnsOnTheRightBeat() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let foe = store.data.forms.first(where: { $0.formLabel == "Milotic" }),
              let filler = store.data.forms.first(where: { $0.formLabel == "Whimsicott" })
        else { throw XCTSkip("the cast is not in this dex") }

        var played: [String] = []
        for (id, way) in Self.expected.sorted(by: { $0.key < $1.key }) {
            guard let move = store.data.moves[id],
                  let user = store.data.forms.first(where: {
                      $0.moves.contains(id) && $0.formLabel != "Milotic" && $0.formLabel != "Whimsicott"
                  }) else { continue }
            var mine = Team(name: "A"); mine.format = "doubles"
            mine.slots = [slot(user, [move.name, "Protect"]), slot(filler, ["Protect", "Moonblast"])]
            var theirs = Team(name: "B"); theirs.format = "doubles"
            // Something to throw at it while it is gone, with no priority and
            // nothing that hits a Pokemon underground or in the air.
            theirs.slots = [slot(foe, ["Ice Beam", "Protect"]), slot(filler, ["Moonblast", "Protect"])]
            guard mine.slots[0].moves.count == 2 else { continue }
            let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                                myFour: [0, 1], theirFour: [0, 1],
                                                store: store, seed: [2, 4, 6, 8])
            // Turn one: it winds up, and they aim at it.
            try game.play(mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
                          theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 1, target: 0)))
            let up = game.board.mine[0]
            check("\(move.name): out of reach after the wind-up", up.hidden)
            check("  and gone \(way.rawValue)", up.vanished == way, up.vanished?.rawValue ?? "nowhere")
            // On the right beat: the wind-up's own step, not the turn's first.
            let windUp = game.board.steps.firstIndex { $0.action?.move == move.name }
            if let windUp {
                check("  on the step it wound up in",
                      (game.board.steps[windUp].myVanished.first ?? nil) == way)
                if windUp > 0 {
                    check("  and not before it",
                          (game.board.steps[windUp - 1].myVanished.first ?? nil) == nil)
                }
                // Whatever was thrown at it after it went, missed. Whatever
                // went first -- a faster Pokemon's Ice Beam -- hit it on the
                // ground, which is right.
                let after = game.board.steps.indices.filter { $0 > windUp }
                    .filter { game.board.steps[$0].action?.move == "Ice Beam" }
                for index in after {
                    check("  and the Ice Beam thrown after it went missed",
                          game.board.steps[index].missed.contains { $0.mine && $0.slot == 0 },
                          "\(game.board.steps[index].missed)")
                }
            }

            // Turn two: it lands.
            let charging = game.board.mine[0].charging ?? 0
            try game.play(mine: Play(left: .attack(move: charging, target: game.board.mine[0].chargingTarget),
                                     right: .attack(move: 0, target: 0)),
                          theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
            check("  and back when it lands", !game.board.mine[0].hidden && game.board.mine[0].vanished == nil)
            played.append(move.name)
        }
        print("  played: \(played.joined(separator: ", "))")
        check("every one the game teaches was played", played.count >= 5, "\(played.count)")
    }
}
