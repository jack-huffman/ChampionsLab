//  FlippedBoardTests.swift
//  The same position seen from the other chair has to be the same position.
//
//      swift test --filter FlippedBoardTests
//
//  `Board.flipped` is what lets two engines sit in one game: the far side is
//  asked for its move on a board turned round, so it can think as "mine". If
//  the turn round is wrong in any way, the duel harness is comparing two
//  engines through a distorting mirror and every number it prints is noise.
//  These are the invariants that say it is not.

import XCTest
@testable import ChampionsLab

final class FlippedBoardTests: HarnessCase {
    @MainActor private func opening() -> Board {
        var board = Board(
            mine: fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect", "Tailwind"]),
                            ("Milotic", "Leftovers", ["Scald", "Protect", "Recover"]),
                            ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"])]),
            theirs: fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect", "Swords Dance"]),
                              ("Incineroar", "Sitrus Berry", ["Knock Off", "Protect", "Fake Out"]),
                              ("Rillaboom", "Leftovers", ["Wood Hammer", "Protect"])]),
            rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.narrating = false
        board.sendOutLeads()
        return board
    }

    /// Turning it round twice gets back where it started.
    @MainActor func testFlippingTwiceIsTheSameBoard() throws {
        print("\n== the same position from the other chair ==")
        let board = opening()
        let there = board.flipped
        let back = there.flipped
        check("the Pokémon come back to their own side",
              back.mine.map(\.build.form.id) == board.mine.map(\.build.form.id)
              && back.theirs.map(\.build.form.id) == board.theirs.map(\.build.form.id))
        check("and so does everything on the field",
              back.myTailwind == board.myTailwind
              && back.theirTailwind == board.theirTailwind
              && back.myScreens.reflect == board.myScreens.reflect
              && back.theirScreens.reflect == board.theirScreens.reflect)
        print("  mine \(board.mine.prefix(2).map(\.build.form.formLabel))"
              + " becomes theirs \(there.theirs.prefix(2).map(\.build.form.formLabel))")
        check("the far side really did change chairs",
              there.theirs.map(\.build.form.id) == board.mine.map(\.build.form.id))
    }

    /// A position worth something to one side is worth the opposite to the
    /// other. If this drifts, the duel scores the wrong winner.
    @MainActor func testTheValueChangesSign() throws {
        print("\n== a lead for one side is a deficit for the other ==")
        var board = opening()
        // Give one side a real advantage so the number is not zero.
        board.theirs[0].hp = board.theirs[0].maxHP / 5
        board.mine[0].build.boosts[Stat.attack.rawValue] = 2
        let mine = TurnModel.value(board)
        let theirs = TurnModel.value(board.flipped)
        print(String(format: "  worth %+.3f to me, %+.3f to them", mine, theirs))
        check("the two are opposite", abs(mine + theirs) < 0.001)
        check("and it is not simply zero", abs(mine) > 0.01)
    }

    /// The turn plays out the same whichever chair it is played from.
    ///
    /// This is the one that matters. If a turn resolved differently depending
    /// on which side was called "mine", the duel would be handing one engine
    /// an advantage that has nothing to do with how well it plays.
    @MainActor func testATurnResolvesTheSameFromEitherSide() throws {
        print("\n== a turn plays out the same from either chair ==")
        let board = opening()
        let ours = Play(left: .attack(move: at(board.mine[0], "Icy Wind"), target: 0),
                        right: .attack(move: at(board.mine[1], "Scald"), target: 0))
        let theirs = Play(left: .attack(move: at(board.theirs[0], "Earthquake"), target: 0),
                          right: .protectSelf(move: at(board.theirs[1], "Protect")))

        let straight = TurnModel.resolve(board, mine: ours, theirs: theirs, rolling: false)
        let mirrored = TurnModel.resolve(board.flipped, mine: theirs, theirs: ours, rolling: false)

        func health(_ b: Board) -> ([Int], [Int]) {
            (b.mine.map(\.hp), b.theirs.map(\.hp))
        }
        let (a1, a2) = health(straight)
        let (b1, b2) = health(mirrored.flipped)
        print("  played as me:   mine \(a1.prefix(2)) theirs \(a2.prefix(2))")
        print("  played as them: mine \(b1.prefix(2)) theirs \(b2.prefix(2))")
        check("everybody ends on the same health", a1 == b1 && a2 == b2)

        let straightBoosts = straight.theirs.map(\.build.boosts)
        let mirroredBoosts = mirrored.flipped.theirs.map(\.build.boosts)
        check("and with the same stat changes", straightBoosts == mirroredBoosts)
    }
}
