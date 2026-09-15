//  SecondaryEffectTests.swift
//  The part of a move that is not the damage.
//
//      swift test --filter SecondaryEffectTests

import XCTest
@testable import ChampionsLab

final class SecondaryEffectTests: HarnessCase {
    @MainActor private func move(_ name: String) -> Move {
        store.data.moves.values.first { $0.name == name }!
    }

    /// Every legal move's secondary effects come from the reference table
    /// rather than from guessing at Serebii's English.
    ///
    /// The guessing was wrong for ninety-one of the five hundred and ten legal
    /// moves, and for the Fang moves it could not have been right at all: they
    /// carry two secondary effects each and the parser only ever produced one.
    @MainActor func testTheReferenceTableIsWhatTheModelUses() throws {
        print("\n== secondary effects come from the reference table ==")
        let expected: [(String, Int, String)] = [
            ("Heat Wave", 10, "burned"), ("Blizzard", 10, "frozen"),
            ("Lava Plume", 30, "burned"), ("Discharge", 30, "paralysed"),
            ("Sludge Wave", 10, "poisoned"),
        ]
        for (name, chance, status) in expected {
            let effects = move(name).secondaries
            guard let first = effects.first, case .status(let ailment) = first.kind else {
                check("\(name) carries a status secondary", false); continue
            }
            print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + "\(first.chance)% \(ailment.rawValue)")
            check("\(name) is \(chance)% \(status)",
                  first.chance == chance && ailment.rawValue == status)
        }

        // Two effects on one move, which the sentence parser could not express.
        for name in ["Fire Fang", "Ice Fang", "Thunder Fang"] {
            let effects = move(name).secondaries
            let hasFlinch = effects.contains { if case .flinch = $0.kind { return true }; return false }
            let hasStatus = effects.contains { if case .status = $0.kind { return true }; return false }
            print("  \(name): \(effects.count) effects, flinch \(hasFlinch), status \(hasStatus)")
            check("\(name) carries both of its effects", effects.count == 2 && hasFlinch && hasStatus)
        }

        // A secondary that pays the user rather than costing the target.
        let beam = move("Charge Beam").secondaries
        guard let boost = beam.first, case .selfBoosts(let stats) = boost.kind else {
            return check("Charge Beam boosts the user", false)
        }
        print("  Charge Beam: \(boost.chance)% \(stats)")
        check("Charge Beam is a 70% Special Attack boost for the user",
              boost.chance == 70 && stats[.spAttack] == 1)
    }

    /// A guaranteed drop lands exactly once.
    ///
    /// Icy Wind's Speed drop is in the reference table as a 100% secondary and
    /// was also in the sentence parser's target drops. Applying both took two
    /// stages of Speed for a move that takes one.
    @MainActor func testAGuaranteedDropLandsOnce() throws {
        print("\n== a guaranteed drop lands once ==")
        var board = Board(mine: fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Life Orb", ["Protect"]),
                                            ("Kingambit", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.sendOutLeads()
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Icy Wind"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let dropped = after.theirs[0].build.boosts[Stat.speed.rawValue]
        print("  Garchomp's Speed stage after one Icy Wind: \(dropped)")
        check("one stage, not two", dropped == -1)
    }

    /// The search prices a coin flip instead of pretending it never comes up.
    ///
    /// A 30% flinch used to be worth nothing to the search, because the search
    /// applies only what is certain. Now the turn is played out both ways and
    /// the two are weighed.
    @MainActor func testTheSearchPricesAChanceEffect() throws {
        print("\n== the search prices a chance effect ==")
        var board = Board(mine: fighters([("Kingambit", "Leftovers", ["Iron Head", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Life Orb", ["Protect"]),
                                            ("Whimsicott", "Focus Sash", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.sendOutLeads()
        let ways = TurnModel.outcomes(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Iron Head"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass))
        let total = ways.reduce(0) { $0 + $1.chance }
        print("  Iron Head produced \(ways.count) outcomes, weights \(ways.map { String(format: "%.2f", $0.chance) })")
        check("it comes out more than one way", ways.count > 1)
        check("the weights are a probability", abs(total - 1) < 0.001)
        let flinched = ways.contains { $0.board.theirs[0].flinched }
        check("one of those ways is a flinch", flinched)
    }

    /// Flags decide which ability answers a move, and Serebii had some wrong.
    @MainActor func testClawMovesAreNotSlicing() throws {
        print("\n== the flags the abilities read ==")
        for name in ["Dragon Claw", "Metal Claw", "Shadow Claw", "Crush Claw", "Dual Chop"] {
            let slicing = move(name).isSlicing
            print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))slicing: \(slicing)")
            check("\(name) is not a slicing move, so Sharpness does not boost it", !slicing)
        }
        check("Sacred Sword still is", move("Sacred Sword").isSlicing)
    }
}
