//  CursedBodyTests.swift
//  Cursed Body shuts off whatever just hit it.
//
//      swift test --filter CursedBodyTests

import XCTest
@testable import ChampionsLab

@MainActor
final class CursedBodyTests: HarnessCase {
    private func position(theirAbility: String = "Cursed Body") -> Board {
        var board = Board(mine: fighters([("Garchomp", "", ["Dragon Claw", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.theirs[0].build.ability = theirAbility
        board.theirs[0].hp = board.theirs[0].maxHP
        return board
    }

    /// Three times in ten, over enough turns to be sure it is not never and
    /// not always.
    private func disabledShare(_ start: Board, runs: Int = 200) -> Double {
        var shut = 0
        for _ in 0..<runs {
            let after = TurnModel.resolve(start,
                mine: Play(left: .attack(move: at(start.mine[0], "Dragon Claw"), target: 0),
                           right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
                theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                             right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
                rolling: true)
            if after.mine[0].disabled != nil { shut += 1 }
        }
        return Double(shut) / Double(runs)
    }

    func testItShutsOffAboutThreeHitsInTen() {
        let share = disabledShare(position())
        print("  Cursed Body shut the move off \(Int(share * 100))% of the time")
        check("it happens", share > 0.12, "\(share)")
        check("and not every time", share < 0.55, "\(share)")
    }

    func testSomethingElseDoesNotDoIt() {
        let share = disabledShare(position(theirAbility: "Marvel Scale"), runs: 60)
        check("an ordinary ability shuts nothing off", share == 0, "\(share)")
    }

    func testAMoldBreakerIsNotCursed() {
        var start = position()
        start.mine[0].build.ability = "Mold Breaker"
        let share = disabledShare(start, runs: 80)
        check("a Mold Breaker goes through it", share == 0, "\(share)")
    }

    func testTheMoveItShutsOffIsTheOneThatWasUsed() {
        var start = position()
        // Make it certain by leaving nothing to chance but the roll, and run
        // until it fires.
        var found: Board?
        for _ in 0..<300 where found == nil {
            let after = TurnModel.resolve(start,
                mine: Play(left: .attack(move: at(start.mine[0], "Dragon Claw"), target: 0),
                           right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
                theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                             right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
                rolling: true)
            if after.mine[0].disabled != nil { found = after }
        }
        guard let found else { return check("it fired at least once in three hundred turns", false) }
        let shut = found.mine[0].disabled!
        check("what it shut off is the move that hit it",
              found.mine[0].moves[shut].name == "Dragon Claw", found.mine[0].moves[shut].name)
        // Four turns, less the tick the end of this one already took, which
        // is how Disable counts down too.
        check("and it is shut for three more turns", found.mine[0].disabledFor == 3,
              "\(found.mine[0].disabledFor)")
        check("and the log says so",
              found.story.contains { $0.contains("Cursed Body disabled") },
              found.story.joined(separator: " | "))
        _ = start
    }
}
