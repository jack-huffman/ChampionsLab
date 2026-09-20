//  ImmuneTests.swift
//  A move that does nothing says so where it would have done something.
//
//      swift test --filter ImmuneTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ImmuneTests: HarnessCase {
    private func position() -> Board {
        Board(mine: fighters([("Garchomp", "", ["Earthquake", "Dragon Claw", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([("Charizard", "", ["Calm Mind", "Protect"]),
                                ("Milotic", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }

    func testAGroundMoveRecordsThatItMissedAFlyingType() {
        let start = position()
        check("their lead is a Flying type",
              start.theirs[0].types.contains(.flying), "\(start.theirs[0].types)")
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Earthquake"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        check("the log says it did nothing",
              after.story.contains { $0.contains("does not affect Charizard") },
              after.story.joined(separator: " | "))
        let marked = after.steps.flatMap(\.untouched)
        check("and the step records who it did not touch",
              marked.contains { !$0.mine && $0.slot == 0 }, "\(marked)")
        check("and what it was that did nothing",
              marked.contains { $0.name == "Earthquake" }, "\(marked.map(\.name))")
        check("their Charizard took nothing", after.theirs[0].hp == start.theirs[0].maxHP,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
    }

    /// The same Earthquake into something standing on the ground is not
    /// immune, and must not be marked.
    func testSomethingItDoesAffectIsNotMarked() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Earthquake"), target: 1),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        check("the Milotic took it", after.theirs[1].hp < start.theirs[1].maxHP,
              "\(after.theirs[1].hp) of \(start.theirs[1].maxHP)")
        let marked = after.steps.flatMap(\.untouched)
        check("and is not marked immune",
              !marked.contains { !$0.mine && $0.slot == 1 }, "\(marked)")
    }

    func testAQuietTurnMarksNobody() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        check("nothing was called immune", after.steps.flatMap(\.untouched).isEmpty)
    }
}
