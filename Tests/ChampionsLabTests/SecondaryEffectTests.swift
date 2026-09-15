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

extension SecondaryEffectTests {
    /// A move that hits more than once has to hit more than once.
    ///
    /// Double Hit was being played as a single thirty-five power attack when
    /// it is two of them, and the parity audit could not see it: a damaging
    /// move registers as implemented the moment it does any damage at all, not
    /// when it does the right amount.
    @MainActor func testAMultiHitMoveLandsEveryBlow() throws {
        print("\n== every blow lands ==")
        for (name, expected) in [("Double Hit", 2.0), ("Dual Wingbeat", 2.0),
                                 ("Triple Axel", 3.0), ("Bullet Seed", 3.0)] {
            var dice: RandomNumberGenerator = SystemRandomNumberGenerator()
            let blows = move(name).blows(for: "", rolling: false, using: &dice)
            print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))\(blows) blows")
            check("\(name) lands \(expected) blows to the search", blows == expected)
        }
        var dice: RandomNumberGenerator = SystemRandomNumberGenerator()
        let linked = move("Bullet Seed").blows(for: "Skill Link", rolling: false, using: &dice)
        check("Skill Link always lands five", linked == 5)

        // And the damage actually doubles on the board.
        var board = Board(mine: fighters([("Kingambit", "Leftovers", ["Double Hit", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Leftovers", ["Protect"]),
                                            ("Whimsicott", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.narrating = false
        board.sendOutLeads()
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Double Hit"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let taken = board.theirs[0].hp - after.theirs[0].hp
        let single = DamageCalc.calculate(attacker: board.mine[0].build,
                                          defender: board.theirs[0].build,
                                          move: move("Double Hit"),
                                          field: Field(isDoubles: true))
        let once = (single.minDamage + single.maxDamage) / 2
        print("  Double Hit took \(taken); one blow would be about \(once)")
        check("it took roughly two blows, not one", taken > once * 3 / 2)
    }

    /// Defog clears the other side's screens, both sides' hazards, and the
    /// terrain. Rapid Spin clears only its own side's hazards.
    @MainActor func testDefogAndRapidSpinClearTheRightThings() throws {
        print("\n== what Defog and Rapid Spin clear ==")
        func cluttered(_ user: String, _ moveName: String) -> Board {
            var b = Board(mine: fighters([(user, "Leftovers", [moveName, "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Leftovers", ["Protect"]),
                                            ("Whimsicott", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
            b.narrating = false
            b.myScreens.spikes = 2; b.myScreens.stealthRock = true; b.myScreens.reflect = 5
            b.theirScreens.spikes = 3; b.theirScreens.stickyWeb = true
            b.theirScreens.lightScreen = 5
            b.field.terrain = .grassy; b.terrainTurns = 5
            b.sendOutLeads()
            return b
        }

        let before = cluttered("Whimsicott", "Defog")
        let defogged = TurnModel.resolve(before,
            mine: Play(left: .attack(move: at(before.mine[0], "Defog"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        print("  after Defog: my spikes \(defogged.myScreens.spikes),"
              + " my reflect \(defogged.myScreens.reflect),"
              + " their spikes \(defogged.theirScreens.spikes),"
              + " their screen \(defogged.theirScreens.lightScreen),"
              + " terrain \(defogged.field.terrain)")
        check("my own hazards go", defogged.myScreens.spikes == 0 && !defogged.myScreens.stealthRock)
        check("my own screens stay", defogged.myScreens.reflect > 0)
        check("their hazards go", defogged.theirScreens.spikes == 0 && !defogged.theirScreens.stickyWeb)
        check("their screens go", defogged.theirScreens.lightScreen == 0)
        check("and the terrain goes", defogged.field.terrain == .none)

        let spinBoard = cluttered("Kingambit", "Rapid Spin")
        let spun = TurnModel.resolve(spinBoard,
            mine: Play(left: .attack(move: at(spinBoard.mine[0], "Rapid Spin"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        print("  after Rapid Spin: my spikes \(spun.myScreens.spikes),"
              + " their spikes \(spun.theirScreens.spikes),"
              + " terrain \(spun.field.terrain)")
        check("Rapid Spin clears its own hazards",
              spun.myScreens.spikes == 0 && !spun.myScreens.stealthRock)
        check("and leaves the other side alone", spun.theirScreens.spikes == 3)
        check("and leaves the terrain alone", spun.field.terrain == .grassy)
    }
}
