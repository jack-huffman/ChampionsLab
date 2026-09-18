//  SpiteTests.swift
//  Spite takes four Power Points off whatever the target used last.
//
//      swift test --filter SpiteTests

import XCTest
@testable import ChampionsLab

@MainActor
final class SpiteTests: HarnessCase {
    /// Gengar outruns Milotic, so on a turn where both pick an ordinary move
    /// the Spite lands first. Several of these depend on that order.
    private func position() -> Board {
        Board(mine: fighters([("Gengar", "", ["Spite", "Shadow Ball", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Scald", "Calm Mind"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func spite(_ board: Board, at target: Int = 0) -> Play {
        Play(left: .attack(move: at(board.mine[0], "Spite"), target: target),
             right: .attack(move: at(board.mine[1], "Protect"), target: 0))
    }
    /// Both of theirs on an ordinary move, so nothing jumps the queue.
    private func theyThink(_ board: Board) -> Play {
        Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
    }

    func testTheSpiteLandsFirst() {
        let board = position()
        check("Gengar outruns Milotic",
              board.mine[0].build.speed(in: board.field)
                > board.theirs[0].build.speed(in: board.field),
              "\(board.mine[0].build.speed(in: board.field)) against "
                + "\(board.theirs[0].build.speed(in: board.field))")
    }

    func testSpiteTakesFour() {
        var start = position()
        let scald = at(start.theirs[0], "Scald")
        start.theirs[0].lastMove = scald
        let before = start.theirs[0].pp(at: scald)
        let after = TurnModel.resolve(start, mine: spite(start), theirs: theyThink(start))
        check("four Power Points off the move it used last",
              after.theirs[0].pp(at: scald) == before - 4,
              "\(after.theirs[0].pp(at: scald)) of \(before)")
        check("and the log says how many",
              after.story.contains { $0.contains("Scald lost 4 Power Points") },
              after.story.joined(separator: " | "))
    }

    func testSpiteTakesOnlyWhatIsThere() {
        var start = position()
        let scald = at(start.theirs[0], "Scald")
        start.theirs[0].lastMove = scald
        start.theirs[0].ppLeft[scald] = 2
        let after = TurnModel.resolve(start, mine: spite(start), theirs: theyThink(start))
        check("it cannot take more than is left",
              after.theirs[0].pp(at: scald) == 0, "\(after.theirs[0].pp(at: scald))")
        check("and says the true number, not the four it wanted",
              after.story.contains { $0.contains("Scald lost 2 Power Points") },
              after.story.joined(separator: " | "))
    }

    func testSpiteFailsBeforeTheTargetHasMoved() {
        let start = position()
        check("nobody has moved yet", start.theirs[0].lastMove == nil)
        let after = TurnModel.resolve(start, mine: spite(start), theirs: theyThink(start))
        check("there is nothing to take",
              after.story.contains { $0.contains("But it failed") },
              after.story.joined(separator: " | "))
    }

    func testSpiteFailsOnAMoveAlreadyDry() {
        var start = position()
        let scald = at(start.theirs[0], "Scald")
        start.theirs[0].lastMove = scald
        start.theirs[0].ppLeft[scald] = 0
        let after = TurnModel.resolve(start, mine: spite(start), theirs: theyThink(start))
        check("nothing left to take",
              after.story.contains { $0.contains("But it failed") },
              after.story.joined(separator: " | "))
    }

    func testAProtectTurnsItAway() {
        var start = position()
        let scald = at(start.theirs[1], "Protect")
        start.theirs[1].lastMove = scald
        let before = start.theirs[1].pp(at: scald)
        let after = TurnModel.resolve(start, mine: spite(start, at: 1),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Protect"), target: 0)))
        check("a Protect turns it away",
              after.story.contains { $0.contains("Farigiraf protected itself") },
              after.story.joined(separator: " | "))
        // Only the Protect it just used was spent, and nothing was drained.
        check("and nothing was taken beyond the use itself",
              after.theirs[1].pp(at: scald) == before - 1,
              "\(after.theirs[1].pp(at: scald)) of \(before)")
    }

    /// The point of the move: run something out of everything and it has to
    /// Struggle, which is a clock on a Pokemon nothing else can break.
    func testSpiteCanRunSomethingOutEntirely() {
        var start = position()
        let scald = at(start.theirs[0], "Scald")
        let mind = at(start.theirs[0], "Calm Mind")
        start.theirs[0].lastMove = scald
        start.theirs[0].ppLeft[scald] = 4
        start.theirs[0].ppLeft[mind] = 0
        let drained = TurnModel.resolve(start, mine: spite(start), theirs: theyThink(start))
        check("the last of it goes", drained.theirs[0].pp(at: scald) == 0,
              "\(drained.theirs[0].pp(at: scald))")
        check("and it has nothing left anywhere",
              !MoveLegality.anyUsable(byMine: false, slot: 0, board: drained))
        let cornered = TurnModel.resolve(drained,
            mine: Play(left: .attack(move: at(drained.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(drained.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: scald, target: 0),
                         right: .attack(move: at(drained.theirs[1], "Calm Mind"), target: 0)))
        check("so the next turn it Struggles",
              cornered.story.contains { $0.contains("used Struggle") },
              cornered.story.joined(separator: " | "))
    }
}
