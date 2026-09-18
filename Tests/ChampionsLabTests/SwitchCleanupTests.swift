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
}
