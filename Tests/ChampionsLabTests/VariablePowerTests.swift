//  VariablePowerTests.swift
//  Moves whose power is read off the board rather than the page: the
//  calculation says what it was, so the move tile can say it too.

import XCTest
@testable import ChampionsLab

final class VariablePowerTests: HarnessCase {
    @MainActor func testLastRespectsCountsTheFallen() {
        let mine = fighters([("Basculegion", "Choice Scarf", ["Last Respects", "Wave Crash"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        // Milotic in front: a Normal type is immune to Ghost, and nothing
        // is worked out against something a move cannot touch.
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Farigiraf", "Leftovers", ["Psychic"]),
                               ("Garchomp", "Sitrus Berry", ["Earthquake"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        let move = board.mine[0].moves[at(board.mine[0], "Last Respects")]

        func power(_ b: Board) -> Int {
            var attacker = b.mine[0].build
            attacker.fallenAllies = b.mine.filter(\.fainted).count
            let r = DamageCalc.calculate(attacker: attacker, defender: b.theirs[0].build,
                                         move: move, field: b.calcField)
            return Int(r.power.rounded())
        }
        check("fifty with nobody down", power(board) == 50, "\(power(board))")
        board.mine[2].hp = 0
        check("a hundred with one down", power(board) == 100, "\(power(board))")
        board.mine[3].hp = 0
        check("a hundred and fifty with two", power(board) == 150, "\(power(board))")

        // And the damage follows the power, in a played turn.
        var down = board
        down.mine[1].hp = 0
        let out = TurnModel.resolve(down,
                                    mine: Play(left: .attack(move: at(down.mine[0], "Last Respects"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass), rolling: false)
        let hit = down.theirs[0].hp - out.theirs[0].hp
        let plain = TurnModel.resolve(board.withNobodyDown(),
                                      mine: Play(left: .attack(move: at(board.mine[0], "Last Respects"), target: 0), right: .pass),
                                      theirs: Play(left: .pass, right: .pass), rolling: false)
        let base = board.theirs[0].hp - plain.theirs[0].hp
        check("three fallen hit far harder than none", hit > base * 2, "\(hit) against \(base)")
        check("and the log says what it counted",
              out.story.contains { $0.contains("Last Respects") && $0.contains("fallen") },
              "\(out.story.filter { $0.contains("Respects") })")
    }

    @MainActor func testTheWeightMovesReadTheTargetNotThePage() {
        let mine = fighters([("Rillaboom", "Assault Vest", ["Grass Knot", "Wood Hammer"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind"]),
                               ("Garchomp", "Sitrus Berry", ["Earthquake"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        let knot = board.mine[0].moves[at(board.mine[0], "Grass Knot")]
        check("the page says next to nothing", knot.power <= 1, "\(knot.power)")
        let heavy = DamageCalc.calculate(attacker: board.mine[0].build, defender: board.theirs[0].build,
                                         move: knot, field: board.calcField)
        let light = DamageCalc.calculate(attacker: board.mine[0].build, defender: board.theirs[1].build,
                                         move: knot, field: board.calcField)
        check("but the board says more against something heavy", heavy.power > 1, "\(heavy.power)")
        check("and less against something light", light.power < heavy.power,
              "\(light.power) against \(heavy.power)")
    }
}

private extension Board {
    /// The same board with everybody of mine standing, for a fair comparison.
    func withNobodyDown() -> Board {
        var out = self
        for index in out.mine.indices where out.mine[index].fainted {
            out.mine[index].hp = out.mine[index].maxHP
        }
        return out
    }
}
