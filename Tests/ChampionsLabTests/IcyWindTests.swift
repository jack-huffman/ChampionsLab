//  IcyWindTests.swift
//  The format's most-clicked speed control, pinned down.
//
//      swift test --filter IcyWindTests

import XCTest
@testable import ChampionsLab

/// Icy Wind is the format's most-clicked speed control, so what it does is
/// worth pinning: it hits both of them, and takes a stage of Speed off both.
///
///     swift test --filter IcyWindTests
@MainActor
final class IcyWindTests: HarnessCase {
    private func position() -> Board {
        Board(mine: fighters([("Milotic", "", ["Icy Wind", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([("Garchomp", "", ["Calm Mind", "Protect"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }

    func testItIsReadAsASpreadMove() {
        let board = position()
        let wind = board.mine[0].moves[at(board.mine[0], "Icy Wind")]
        check("it reaches everything it can", wind.isSpread, "\(wind.aim)")
        check("and is aimed at the far side", wind.aim == .spread, "\(wind.aim)")
        check("it does damage as well", wind.isDamaging && wind.power > 0, "\(wind.power)")
    }

    func testItHitsBothAndSlowsBoth() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Icy Wind"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
            rolling: true)
        check("the first one took damage", after.theirs[0].hp < start.theirs[0].maxHP,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
        check("and so did the second", after.theirs[1].hp < start.theirs[1].maxHP,
              "\(after.theirs[1].hp) of \(start.theirs[1].maxHP)")
        check("the first one is a stage slower",
              after.theirs[0].build.boosts[Stage.speed.rawValue] == -1,
              "\(after.theirs[0].build.boosts[Stage.speed.rawValue])")
        check("and so is the second",
              after.theirs[1].build.boosts[Stage.speed.rawValue] == -1,
              "\(after.theirs[1].build.boosts[Stage.speed.rawValue])")
        check("my own side is untouched",
              after.mine.allSatisfy { $0.build.boosts[Stage.speed.rawValue] == 0 })
    }

    /// One of them behind a Protect still leaves the other slowed.
    func testAProtectCoversOnlyTheOneBehindIt() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Icy Wind"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
            rolling: true)
        check("the one that protected kept its Speed",
              after.theirs[0].build.boosts[Stage.speed.rawValue] == 0,
              "\(after.theirs[0].build.boosts[Stage.speed.rawValue])")
        check("the one that did not is slower",
              after.theirs[1].build.boosts[Stage.speed.rawValue] == -1,
              "\(after.theirs[1].build.boosts[Stage.speed.rawValue])")
    }

    /// And it really changes who goes first, which is the entire point of it.
    func testItChangesWhoMovesFirst() {
        var board = position()
        let chomp = board.theirs[0]
        let fast = chomp.build.speed(in: board.field)
        board.theirs[0].build.boosts[Stage.speed.rawValue] = -1
        let slowed = board.theirs[0].build.speed(in: board.field)
        check("a stage of Speed is a third off", slowed < fast, "\(slowed) against \(fast)")
        check("and it is two thirds of what it was",
              abs(Double(slowed) - Double(fast) * 2 / 3) <= 1,
              "\(slowed) against \(fast)")
    }
}
