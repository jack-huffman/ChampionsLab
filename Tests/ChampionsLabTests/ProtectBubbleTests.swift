//  ProtectBubbleTests.swift
//  When the shield is drawn, and when it is not.
//
//      swift test --filter ProtectBubbleTests
//
//  This has been wrong in both directions. First the shield stayed up after
//  the turn, so a Pokémon that was open again looked safe. Then it was cleared
//  properly and never appeared at all, because by the time the turn is handed
//  back the flag is already down — and a Protect you cannot see is a move that
//  visibly bounces off nothing. It is drawn from what the turn left behind, but
//  only while the turn is being played out.

import XCTest
@testable import ChampionsLab

final class ProtectBubbleTests: HarnessCase {
    @MainActor func testWhenTheShieldIsDrawn() throws {
print("\n== the rule ==")
        func drawn(_ isProtected: Bool, _ protectedLast: Bool,
                   playback: Bool, fainted: Bool = false) -> Bool {
            BattleFieldView.guarding(fainted: fainted, isProtected: isProtected,
                                protectedLast: protectedLast, duringPlayback: playback)
        }
        check("while it is actually protecting", drawn(true, false, playback: false))
        check("while the turn plays out, from the step being shown",
              drawn(true, false, playback: true))
        check("the memory of it alone draws nothing: that put the shield up from the first step",
              !drawn(false, true, playback: true))
        check("and not once the turn is over",
              !drawn(false, true, playback: false))
        check("and never on something that has fainted",
              !drawn(true, true, playback: true, fainted: true))
        check("and not on something that did not protect",
              !drawn(false, false, playback: true))

print("\n== and the flags the rule reads ==")
        // The model's half of the contract: a turn in which Protect was used
        // hands back a board with the shield down and the memory of it up.
        let mine = fighters([("Incineroar", "Sitrus Berry", ["Protect", "Flare Blitz"]),
                             ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])])
        let theirs = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                               ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let after = TurnModel.resolve(board,
            mine: Play(left: .protectSelf(move: at(board.mine[0], "Protect")),
                       right: .attack(move: at(board.mine[1], "Moonblast"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Earthquake"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 0)))
        check("the shield is down on the board handed back", !after.mine[0].isProtected)
        check("and the turn remembers it was up", after.mine[0].protectedLast)
        // The steps' half: up from the step the Protect was used on, down by
        // the last step of the turn.
        let protectStep = after.steps.first { $0.action?.move == "Protect" }
        check("the step Protect was used on has the shield up", protectStep?.myProtected[0] == true,
              "\(protectStep?.myProtected ?? [])")
        let stepsBefore = after.steps.prefix { $0.action?.move != "Protect" }
        check("and the steps before it do not", stepsBefore.allSatisfy { ($0.myProtected.first ?? false) == false })
        // It stays up through the end of the turn's steps; the board handed
        // back, checked above, is where it comes down.
        check("the partner that did not protect never gets one",
              !after.mine[1].protectedLast)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
