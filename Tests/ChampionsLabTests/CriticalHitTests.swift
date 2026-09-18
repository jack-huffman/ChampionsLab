//  CriticalHitTests.swift
//  What raises the critical-hit ratio, and what a critical hit ignores.
//
//      swift test --filter CriticalHitTests

import XCTest
@testable import ChampionsLab

@MainActor
final class CriticalHitTests: HarnessCase {
    private func position() -> Board {
        Board(mine: fighters([("Garchomp", "", ["Dragon Claw", "Focus Energy", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"]),
                              ("Kingambit", "", ["Iron Head", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func theyThink(_ board: Board) -> Play {
        Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
    }

    // MARK: - What raises it

    func testFocusEnergyIsTwoStagesAndTwoStagesIsHalfTheTime() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Focus Energy"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: theyThink(start))
        check("Focus Energy is two stages", after.mine[0].critStage == 2,
              "\(after.mine[0].critStage)")
        let claw = after.mine[0].moves[at(after.mine[0], "Dragon Claw")]
        check("an ordinary move crits about one time in twenty-four",
              Strikes.critRate(claw, at: 0) < 5, "\(Strikes.critRate(claw, at: 0))")
        check("one stage is an eighth", Strikes.critRate(claw, at: 1) == 12.5)
        check("two stages is half the time", Strikes.critRate(claw, at: 2) == 50)
        check("and three is every time", Strikes.critRate(claw, at: 3) == 100)
    }

    func testAScopeLensIsAStage() {
        var start = position()
        check("nothing raises it to begin with",
              Strikes.critStage(of: start.mine[0]) == 0)
        start.mine[0].build.item = "Scope Lens"
        check("a Scope Lens is a stage", Strikes.critStage(of: start.mine[0]) == 1,
              "\(Strikes.critStage(of: start.mine[0]))")
        // And it stacks with what a move gave it.
        start.mine[0].critStage = 2
        check("and it adds to a Focus Energy",
              Strikes.critStage(of: start.mine[0]) == 3,
              "\(Strikes.critStage(of: start.mine[0]))")
    }

    func testScopeLensIsAnItemThisGameHas() {
        guard let lens = store.item(named: "Scope Lens") else {
            return check("Scope Lens is in the item list", false)
        }
        check("and it has been seen in Champions", lens.seenInGame, lens.attestation ?? "")
    }

    func testTheStagesGoWhenItLeaves() {
        var start = position()
        start.mine[0].critStage = 2
        Switching.depart(&start.mine, active: 0)
        check("a Focus Energy does not follow it to the bench",
              start.mine[0].critStage == 0, "\(start.mine[0].critStage)")
    }

    // MARK: - Saying that one happened

    /// The log has always said so. The step has to as well, or the field has
    /// nothing to put beside the number.
    func testACriticalHitIsRecordedAgainstWhoTookIt() {
        var start = position()
        // Three stages is every time, so this does not depend on a roll going
        // the right way.
        start.mine[0].critStage = 3
        let claw = at(start.mine[0], "Dragon Claw")
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: claw, target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: theyThink(start), rolling: true)
        check("the log says it", after.story.contains { $0.contains("A critical hit!") },
              after.story.joined(separator: " | "))
        let marked = after.steps.flatMap(\.criticals)
        check("and the step knows who took it",
              marked.contains { !$0.mine && $0.slot == 0 }, "\(marked)")
        check("and what did it",
              marked.contains { $0.name == "Dragon Claw" }, "\(marked.map(\.name))")
        // Nobody else is marked.
        check("and nobody else is", marked.allSatisfy { !$0.mine && $0.slot == 0 })
    }

    func testNothingIsMarkedWhenNothingCrits() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: theyThink(start))
        check("a turn with no hit in it marks nobody",
              after.steps.flatMap(\.criticals).isEmpty)
    }

    // MARK: - What one ignores

    /// A crit is worked out as though the attacker had never been dropped.
    func testACritIgnoresTheAttackersOwnDrops() {
        let board = position()
        let move = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        var plain = board.field; plain.critical = false
        var crit = board.field; crit.critical = true

        var dropped = board.mine[0].build
        dropped.boosts[Stat.attack.rawValue] = -2
        let level = board.mine[0].build

        let droppedPlain = DamageCalc.calculate(attacker: dropped, defender: board.theirs[0].build,
                                                move: move, field: plain)
        let droppedCrit = DamageCalc.calculate(attacker: dropped, defender: board.theirs[0].build,
                                               move: move, field: crit)
        let levelCrit = DamageCalc.calculate(attacker: level, defender: board.theirs[0].build,
                                             move: move, field: crit)
        check("a crit from a Pokemon at -2 hits as hard as one from a Pokemon at nothing",
              droppedCrit.maxDamage == levelCrit.maxDamage,
              "\(droppedCrit.maxDamage) against \(levelCrit.maxDamage)")
        check("and much harder than the same hit without one",
              droppedCrit.maxDamage > droppedPlain.maxDamage,
              "\(droppedCrit.maxDamage) against \(droppedPlain.maxDamage)")
    }

    /// And as though the defender had never been raised.
    func testACritIgnoresTheDefendersBoosts() {
        let board = position()
        let move = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        var plain = board.field; plain.critical = false
        var crit = board.field; crit.critical = true

        var walled = board.theirs[0].build
        walled.boosts[Stat.defense.rawValue] = 2
        let level = board.theirs[0].build

        let walledPlain = DamageCalc.calculate(attacker: board.mine[0].build, defender: walled,
                                               move: move, field: plain)
        let walledCrit = DamageCalc.calculate(attacker: board.mine[0].build, defender: walled,
                                              move: move, field: crit)
        let levelCrit = DamageCalc.calculate(attacker: board.mine[0].build, defender: level,
                                             move: move, field: crit)
        check("a crit goes through a +2 Defense as though it were not there",
              walledCrit.maxDamage == levelCrit.maxDamage,
              "\(walledCrit.maxDamage) against \(levelCrit.maxDamage)")
        check("which is worth far more than the crit alone",
              walledCrit.maxDamage > walledPlain.maxDamage,
              "\(walledCrit.maxDamage) against \(walledPlain.maxDamage)")
    }

    /// The other half of the rule, which is the half that would be easy to get
    /// backwards: a crit keeps the boosts that help the attacker and the drops
    /// that help it through the defender.
    func testACritKeepsWhatFavoursTheAttacker() {
        let board = position()
        let move = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        var crit = board.field; crit.critical = true

        var raised = board.mine[0].build
        raised.boosts[Stat.attack.rawValue] = 2
        let levelCrit = DamageCalc.calculate(attacker: board.mine[0].build,
                                             defender: board.theirs[0].build, move: move, field: crit)
        let raisedCrit = DamageCalc.calculate(attacker: raised, defender: board.theirs[0].build,
                                              move: move, field: crit)
        check("a crit still counts the attacker's own +2",
              raisedCrit.maxDamage > levelCrit.maxDamage,
              "\(raisedCrit.maxDamage) against \(levelCrit.maxDamage)")

        var softened = board.theirs[0].build
        softened.boosts[Stat.defense.rawValue] = -2
        let softCrit = DamageCalc.calculate(attacker: board.mine[0].build, defender: softened,
                                            move: move, field: crit)
        check("and the defender's own -2",
              softCrit.maxDamage > levelCrit.maxDamage,
              "\(softCrit.maxDamage) against \(levelCrit.maxDamage)")
    }
}
