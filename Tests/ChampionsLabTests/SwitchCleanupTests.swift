//  SwitchCleanupTests.swift
//  Whatever the way off the field, a Pokemon leaves its stages on it and a
//  Regenerator takes its third.

import XCTest
@testable import ChampionsLab

final class SwitchCleanupTests: HarnessCase {
    @MainActor private func lineup() -> Board {
        let mine = fighters([("Incineroar", "Black Glasses", ["U-turn", "Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "Protect"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Milotic", "Leftovers", ["Scald"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook)
    }

    @MainActor func testAPivotLeavesItsStagesAndHealsARegenerator() {
        var board = lineup()
        board.mine[0].build.ability = "Regenerator"
        board.mine[0].build.boosts[Stat.attack.rawValue] = 2
        board.mine[0].build.boosts[Stat.speed.rawValue] = -1
        let maxHP = board.mine[0].maxHP
        board.mine[0].hp = maxHP / 2
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: at(board.mine[0], "U-turn"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        let incineroar = out.mine.first { $0.build.form.formLabel == "Incineroar" }
        check("it left the field", out.mine[0].build.form.formLabel != "Incineroar", out.mine[0].build.form.formLabel)
        check("its stages stayed on the field", incineroar?.build.boosts.allSatisfy { $0 == 0 } == true, "\(incineroar?.build.boosts ?? [])")
        check("Regenerator healed a third on the way out",
              incineroar?.hp == Swift.min(maxHP, maxHP / 2 + maxHP / 3), "\(incineroar?.hp ?? -1) of \(maxHP)")
    }

    @MainActor func testTheFallenLeaveTheirStagesToo() {
        var board = lineup()
        board.mine[0].build.boosts[Stat.attack.rawValue] = 3
        board.mine[0].hp = 0
        board.sendIn(2, to: 0)
        check("Rillaboom came in", board.mine[0].build.form.formLabel == "Rillaboom")
        check("the fallen one's stages went with the field",
              board.mine.first { $0.build.form.formLabel == "Incineroar" }?.build.boosts.allSatisfy { $0 == 0 } == true)
    }

    @MainActor func testAnOrdinarySwitchStillDoesTheSame() {
        var board = lineup()
        board.mine[0].build.boosts[Stat.attack.rawValue] = 2
        board.mine[0].status = .burn
        board.mine[0].build.ability = "Natural Cure"
        Switching.swapIn(mine: true, active: 0, bench: 2, board: &board)
        let incineroar = board.mine.first { $0.build.form.formLabel == "Incineroar" }
        check("stages reset", incineroar?.build.boosts.allSatisfy { $0 == 0 } == true)
        // Against the ailment's own none: an optional against `.none` is nil.
        check("Natural Cure dropped the burn", incineroar?.status == Ailment.none, "\(incineroar?.status.rawValue ?? "?")")
    }

    /// Toxic is a clock, and the clock is the ramp: a sixteenth on the first
    /// turn, two on the second, and so on. Going out and coming back keeps the
    /// poison and pays the ramp back down to the start, which is most of why a
    /// pivot answers a Toxic at all.
    @MainActor func testTheBadPoisonsClockRestartsButThePoisonItselfKeeps() {
        var board = lineup()
        board.mine[0].status = .badPoison
        board.mine[0].toxicTurns = 5
        Switching.swapIn(mine: true, active: 0, bench: 2, board: &board)
        let incineroar = board.mine.first { $0.build.form.formLabel == "Incineroar" }
        check("it is still badly poisoned", incineroar?.status == .badPoison,
              "\(incineroar?.status.rawValue ?? "?")")
        check("but the ramp restarted", incineroar?.toxicTurns == 0,
              "\(incineroar?.toxicTurns ?? -1)")
    }

    /// Sleep is the other half of that pair and goes the other way: it keeps
    /// across a switch, counter and all, so the bench is never a place to wait
    /// it off.
    @MainActor func testSleepRunsDownOnTheFieldAndNotOnTheBench() {
        var board = lineup()
        check("slot 2 really is on the bench", board.activeCount <= 2, "\(board.activeCount)")
        // The same three turns to go, one standing out there and one waiting.
        board.mine[0].status = .sleep; board.mine[0].asleepFor = 3
        board.mine[2].status = .sleep; board.mine[2].asleepFor = 3
        let out = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the one on the field slept a turn off", out.mine[0].asleepFor == 2,
              "\(out.mine[0].asleepFor)")
        check("the one on the bench kept all three", out.mine[2].asleepFor == 3,
              "\(out.mine[2].asleepFor)")
        check("and is still asleep", out.mine[2].status == .sleep,
              out.mine[2].status.rawValue)
    }
}
