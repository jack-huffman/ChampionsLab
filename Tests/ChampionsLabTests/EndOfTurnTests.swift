//  EndOfTurnTests.swift
//  What happens after everybody has moved, and where it is drawn.
//
//      swift test --filter EndOfTurnTests
//
//  Showdown runs the residuals -- a burn, a Leftovers, the sandstorm, a Speed
//  Boost -- after the last Pokemon has acted, and marks the start of them
//  with an empty line and the end with `upkeep`. Reading straight past that
//  mark leaves all of it inside whatever Pokemon happened to move last, drawn
//  as part of its attack instead of as the end of the turn.

import XCTest
@testable import ChampionsLab

@MainActor
final class EndOfTurnTests: HarnessCase {
    /// A reader with a board and nothing played on it. The protocol is fed
    /// in by hand here: the question is what the reader makes of a turn's
    /// shape, which does not need a simulator to answer.
    private func battle() throws -> ShowdownBattle {
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let board = Board(mine: ladder[0].team, theirs: ladder[1].team, rules: store.rulebook)
        return ShowdownBattle(board: board, data: store.data)
    }

    func testResidualsAreTheirOwnBeatAndNotPartOfTheLastAttack() throws {
        let game = try battle()
        // A turn written the way the simulator writes one: somebody acts,
        // then the empty line, then what the turn itself did to people.
        game.read([
            "|move|p1a: X|Tackle|p2a: Y",
            "|-damage|p2a: Y|150/200",
            "|",
            "|-damage|p1a: X|180/200|[from] psn",
            "|-heal|p2a: Y|165/200|[from] item: Leftovers",
            "|upkeep",
            "|turn|2",
        ])
        let steps = game.board.steps
        check("the turn produced steps", !steps.isEmpty, "\(steps.count)")
        let acting = steps.filter { $0.action != nil }
        let after = steps.filter { $0.action == nil }
        check("the attack is a step with a move behind it", acting.count == 1, "\(acting.count)")
        check("and the end of the turn is its own, with none",
              !after.isEmpty, "\(after.count)")
        // The thing that was wrong: the poison and the Leftovers inside the
        // Tackle's step, drawn as part of throwing it.
        let attack = acting.first?.text ?? ""
        check("the attack does not carry the poison", !attack.contains("psn"), attack)
        check("nor the Leftovers", !attack.lowercased().contains("leftovers"), attack)
    }

    /// The clocks come down a turn at a time. The engine says when a screen
    /// goes up and when it ends and nothing in between, so without this a
    /// Reflect read five for its whole life and then vanished.
    func testTheClocksComeDown() throws {
        let game = try battle()
        game.read(["|-sidestart|p1: Us|move: Reflect",
                   "|-sidestart|p1: Us|move: Tailwind"])
        let up = (reflect: game.board.myScreens.reflect, wind: game.board.myTailwind)
        check("Reflect went up for five", up.reflect == 5, "\(up.reflect)")
        check("and Tailwind for four", up.wind == 4, "\(up.wind)")
        game.read(["|turn|2"])
        check("a turn later the Reflect has four left",
              game.board.myScreens.reflect == 4, "\(game.board.myScreens.reflect)")
        check("and the Tailwind three", game.board.myTailwind == 3, "\(game.board.myTailwind)")
        // And the engine is still the one that ends it.
        game.read(["|-sideend|p1: Us|move: Reflect"])
        check("the engine's word ends it, whatever the count said",
              game.board.myScreens.reflect == 0, "\(game.board.myScreens.reflect)")
    }

    /// Protect lasts the turn it was used on. Left standing it would draw a
    /// shield over a Pokemon that has not protected since.
    func testProtectDoesNotOutlastItsTurn() throws {
        let game = try battle()
        game.read(["|-singleturn|p1a: Us|Protect"])
        check("it is protected", game.board.mine[0].isProtected)
        game.read(["|turn|2"])
        check("and not the turn after", !game.board.mine[0].isProtected)
    }
}
