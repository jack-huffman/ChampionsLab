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
            BattleView.guarding(fainted: fainted, isProtected: isProtected,
                                protectedLast: protectedLast, duringPlayback: playback)
        }
        check("while it is actually protecting", drawn(true, false, playback: false))
        check("while the turn plays out, from what the turn left behind",
              drawn(false, true, playback: true))
        check("but not once the turn is over",
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
        check("so it is drawn during playback and not after",
              drawn(after.mine[0].isProtected, after.mine[0].protectedLast, playback: true)
                  && !drawn(after.mine[0].isProtected, after.mine[0].protectedLast,
                            playback: false))
        check("the partner that did not protect never gets one",
              !after.mine[1].protectedLast)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
