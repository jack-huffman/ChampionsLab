//  ReplacementTests.swift
//  You send in what you have, and never more than that.
//
//      swift test --filter ReplacementTests
//
//  The battle screen asks you to fill every gap and will not move on until it
//  has an answer for each. So a gap it can never fill is not a cosmetic
//  problem: both actives down with one Pokémon left asked for two, took the
//  only one you had, and then waited for a second that did not exist, with no
//  option left on screen to give it. The game has no such state.

import XCTest
@testable import ChampionsLab

final class ReplacementTests: HarnessCase {
    @MainActor func testNeverAsksForMoreThanYouHave() throws {
print("\n== gaps you can actually fill ==")
        let mine = fighters([("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])])
        let theirs = fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                               ("Kingambit", "Leftovers", ["Iron Head", "Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        // Nothing down: nothing to send.
        check("a healthy side has no gaps", board.gapsOfMine.isEmpty,
              "\(board.gapsOfMine)")

        // One active down, two on the bench: one gap.
        board.mine[0].hp = 0
        check("one gap when one falls", board.gapsOfMine == [0], "\(board.gapsOfMine)")

        // Both actives down, two on the bench: two gaps, which is the case
        // that already worked.
        board.mine[1].hp = 0
        check("two gaps when two fall and two are waiting",
              board.gapsOfMine == [0, 1], "\(board.gapsOfMine)")

        // Both actives down, only one left alive: one gap, not two.
        board.mine[3].hp = 0
        check("one gap when only one is left to send",
              board.gapsOfMine.count == 1, "\(board.gapsOfMine)")

        // Both actives down and nothing behind them: the game is over, and it
        // is not waiting for anybody.
        board.mine[2].hp = 0
        check("no gaps when there is nobody left", board.gapsOfMine.isEmpty,
              "\(board.gapsOfMine)")
        check("and the side is out", board.isOut(mine: true))

print("\n== and filling them empties the list ==")
        var again = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        again.mine[0].hp = 0
        again.mine[1].hp = 0
        again.mine[3].hp = 0
        let gaps = again.gapsOfMine
        check("one to fill", gaps.count == 1, "\(gaps)")
        // The bench Pokémon still standing.
        let bench = (again.activeCount..<again.mine.count).first { !again.mine[$0].fainted }
        check("there is somebody to send", bench != nil)
        if let bench, let slot = gaps.first {
            again.replaceFallen(mine: [(slot: slot, bench: bench)])
            check("the screen has nothing left to ask", again.gapsOfMine.isEmpty,
                  "\(again.gapsOfMine)")
            check("and somebody is standing there",
                  !again.mine[slot].fainted,
                  again.mine[slot].build.form.formLabel)
        }

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
