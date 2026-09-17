//  StatusParityTests.swift
//  A status condition answers the same whoever asks for it.
//
//      swift test --filter StatusParityTests
//
//  Two ways to paralyse something: click Thunder Wave, or land a Nuzzle and
//  let its hundred per cent go off. They used to resolve through two copies of
//  the same table in two files, and the copies had drifted -- the status-move
//  one had no Misty Terrain check, so a Thunder Wave worked under the one
//  terrain that exists to stop it while a Nuzzle's paralysis was refused. This
//  holds the two to the same answer in every case that has ever differed, and
//  will fail the moment anyone writes a third copy.

import XCTest
@testable import ChampionsLab

final class StatusParityTests: HarnessCase {
    @MainActor private func pair(terrain: Terrain = .none, safeguard: Bool = false,
                                 target: String = "Milotic",
                                 targetAbility: String? = nil) -> (wave: Board, nuzzle: Board) {
        // Thunder Wave is a status move; Nuzzle is 20 power with a certain
        // paralysis. Same target, same field, same everything else.
        let mine = fighters([("Farigiraf", "Leftovers", ["Thunder Wave", "Protect"]),
                             ("Raichu", "Focus Sash", ["Nuzzle", "Protect"])])
        let theirs = fighters([(target, "Leftovers", ["Surf", "Protect"]),
                               ("Kingambit", "Leftovers", ["Iron Head", "Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.field.terrain = terrain
        if terrain != .none { board.terrainTurns = 5 }
        if safeguard { board.theirScreens.safeguard = 5 }
        if let targetAbility { board.theirs[0].build.ability = targetAbility }
        let wave = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Thunder Wave"), target: 0),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Surf"), target: 1),
                         right: .protectSelf(move: 1)))
        let nuzzle = TurnModel.resolve(board,
            mine: Play(left: .protectSelf(move: 1),
                       right: .attack(move: at(board.mine[1], "Nuzzle"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Surf"), target: 1),
                         right: .protectSelf(move: 1)))
        return (wave, nuzzle)
    }

    @MainActor func testAStatusMoveAndASecondaryAgree() throws {
print("\n== in the open ==")
        let open = pair()
        check("Thunder Wave paralyses", open.wave.theirs[0].status == .paralysis,
              "\(open.wave.theirs[0].status)")
        check("and so does Nuzzle", open.nuzzle.theirs[0].status == .paralysis,
              "\(open.nuzzle.theirs[0].status)")

print("\n== under Misty Terrain, on the ground ==")
        let misty = pair(terrain: .misty)
        check("the mist refuses Thunder Wave", misty.wave.theirs[0].status == .none,
              "\(misty.wave.theirs[0].status)")
        check("and refuses Nuzzle the same way", misty.nuzzle.theirs[0].status == .none,
              "\(misty.nuzzle.theirs[0].status)")
        for line in misty.wave.story where line.contains("mist") { print("    \(line)") }

print("\n== under Misty Terrain, off the ground ==")
        let floating = pair(terrain: .misty, targetAbility: "Levitate")
        check("a Levitating target is not under the mist, so Thunder Wave lands",
              floating.wave.theirs[0].status == .paralysis, "\(floating.wave.theirs[0].status)")
        check("and Nuzzle lands too", floating.nuzzle.theirs[0].status == .paralysis,
              "\(floating.nuzzle.theirs[0].status)")

print("\n== behind a Safeguard ==")
        let veiled = pair(safeguard: true)
        check("the veil refuses Thunder Wave", veiled.wave.theirs[0].status == .none)
        check("and Nuzzle", veiled.nuzzle.theirs[0].status == .none)

print("\n== into something that cannot be paralysed ==")
        // Thunder Wave into an Electric type is refused by the status rule;
        // Nuzzle hits for damage and its paralysis is refused by the same rule.
        let electric = pair(target: "Raichu")
        check("an Electric type is not paralysed by either",
              electric.wave.theirs[0].status == .none && electric.nuzzle.theirs[0].status == .none,
              "\(electric.wave.theirs[0].status) / \(electric.nuzzle.theirs[0].status)")
        let limber = pair(targetAbility: "Limber")
        check("nor is a Limber",
              limber.wave.theirs[0].status == .none && limber.nuzzle.theirs[0].status == .none)

print("\n== and the condition is announced once ==")
        let said = open.wave.story.filter { $0.contains("paralysed") || $0.contains("paralyzed") }
        check("Thunder Wave says so once", said.count == 1, "\(said.count): \(said)")

print("\n== sleep, which only a status move brings ==")
        let mine = fighters([("Sinistcha", "Leftovers", ["Spore", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Surf", "Protect"]),
                               ("Staraptor", "Focus Sash", ["Brave Bird", "Protect"])])
        var charged = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                            field: Field(isDoubles: true), alreadyEvolved: false)
        charged.field.terrain = .electric; charged.terrainTurns = 5
        let grounded = TurnModel.resolve(charged,
            mine: Play(left: .attack(move: at(charged.mine[0], "Spore"), target: 0),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .protectSelf(move: 1),
                         right: .attack(move: at(charged.theirs[1], "Brave Bird"), target: 1)))
        check("Electric Terrain keeps a grounded Milotic awake",
              grounded.theirs[0].status == .none, "\(grounded.theirs[0].status)")
        let airborne = TurnModel.resolve(charged,
            mine: Play(left: .attack(move: at(charged.mine[0], "Spore"), target: 1),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(charged.theirs[0], "Surf"), target: 1),
                         right: .attack(move: at(charged.theirs[1], "Brave Bird"), target: 1)))
        check("but a Staraptor in the air goes to sleep",
              airborne.theirs[1].status == .sleep, "\(airborne.theirs[1].status)")
        check("for a counted number of turns", airborne.theirs[1].asleepFor > 0,
              "\(airborne.theirs[1].asleepFor)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
