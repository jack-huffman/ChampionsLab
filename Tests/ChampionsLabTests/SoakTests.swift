//  SoakTests.swift
//  Soak makes its target a pure Water type, and the battle reads the types it
//  has rather than the ones the dex printed.
//
//      swift test --filter SoakTests

import XCTest
@testable import ChampionsLab

@MainActor
final class SoakTests: HarnessCase {
    /// A Garchomp is the case worth testing: Ground, so nothing Electric can
    /// touch it until something changes what it is.
    private func position() -> Board {
        Board(mine: fighters([("Milotic", "", ["Soak", "Protect"]),
                              ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              theirs: fighters([("Garchomp", "", ["Calm Mind", "Protect"]),
                                ("Rillaboom", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func soak(_ board: Board) -> Board {
        TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Soak"), target: 0),
                       right: .attack(move: at(board.mine[1], "Calm Mind"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0)))
    }

    func testSoakMakesItsTargetPureWater() {
        let start = position()
        check("it starts as the dex has it",
              start.theirs[0].types.contains(.ground), "\(start.theirs[0].types)")
        let after = soak(start)
        check("and becomes a Water type", after.theirs[0].types == [.water],
              "\(after.theirs[0].types)")
        check("which is said out loud",
              after.story.contains { $0.contains("became a Water type") },
              after.story.joined(separator: " | "))
    }

    func testASoakedGroundTypeStopsBeingImmuneToElectric() {
        let start = position()
        let after = soak(start)
        guard let bolt = store.data.moves.values.first(where: { $0.name == "Thunderbolt" }) else {
            return check("Thunderbolt is in the dex", false)
        }
        let before = DamageCalc.calculate(attacker: start.mine[0].build,
                                          defender: start.theirs[0].build,
                                          move: bolt, field: start.field)
        let now = DamageCalc.calculate(attacker: after.mine[0].build,
                                       defender: after.theirs[0].build,
                                       move: bolt, field: after.field)
        check("a Ground type takes nothing from Thunderbolt", before.maxDamage == 0,
              "\(before.maxDamage)")
        check("and the same Pokemon takes it once it is Water", now.maxDamage > 0,
              "\(now.maxDamage)")
    }

    func testTheTypeChangeGoesWhenItLeavesTheField() {
        var after = soak(position())
        check("Water while it stands there", after.theirs[0].types == [.water])
        Switching.depart(&after.theirs, active: 0)
        check("and itself again once it has gone",
              after.theirs[0].types.contains(.ground), "\(after.theirs[0].types)")
    }
}
