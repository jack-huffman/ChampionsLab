//  FinalGambitTests.swift
//  Final Gambit: the user's health, handed over, and only if it lands.
//
//      swift test --filter FinalGambitTests

import XCTest
@testable import ChampionsLab

@MainActor
final class FinalGambitTests: HarnessCase {
    private func position(theirLead: String = "Milotic") -> Board {
        Board(mine: fighters([("Whimsicott", "", ["Final Gambit", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([(theirLead, "", ["Calm Mind", "Protect"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func gambit(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.mine[0], "Final Gambit"), target: 0),
             right: .attack(move: at(b.mine[1], "Protect"), target: 0))
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }

    /// What it deals is what the user has left, not what it started with.
    func testItDealsTheUsersRemainingHealth() {
        var start = position()
        start.mine[0].hp = 61
        let before = start.theirs[0].hp
        let after = TurnModel.resolve(start, mine: gambit(start), theirs: idle(start), rolling: true)
        let dealt = before - after.theirs[0].hp
        check("it dealt exactly what the user had left", dealt == 61, "\(dealt) against 61")
        check("which is not its maximum", start.mine[0].maxHP != 61, "\(start.mine[0].maxHP)")
        check("and the user is gone", after.mine[0].fainted, "\(after.mine[0].hp)")
    }

    func testAtFullHealthItDealsAllOfIt() {
        let start = position()
        let whole = start.mine[0].maxHP
        let before = start.theirs[0].hp
        let after = TurnModel.resolve(start, mine: gambit(start), theirs: idle(start), rolling: true)
        check("it dealt the user's whole health", before - after.theirs[0].hp == whole,
              "\(before - after.theirs[0].hp) against \(whole)")
    }

    /// Showdown marks it `selfdestruct: "ifHit"`, and that is the whole of the
    /// question: a Final Gambit turned away costs nothing but the turn.
    func testAProtectCostsTheUserNothingButTheTurn() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: gambit(start),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
            rolling: true)
        check("the target took nothing",
              after.theirs[0].hp == start.theirs[0].maxHP,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
        check("and the user is still standing", !after.mine[0].fainted,
              "\(after.mine[0].hp) of \(after.mine[0].maxHP)")
        check("at the health it had", after.mine[0].hp == start.mine[0].hp,
              "\(after.mine[0].hp)")
    }

    /// The other side of the rule, so the fix does not quietly spare an
    /// Explosion too: that one goes off whatever happens to it.
    func testAnExplosionGoesOffEvenIntoAProtect() {
        var start = position()
        start.mine[0].moves = ["explosion", "protect"].compactMap { store.move($0) }
        guard start.mine[0].moves.count == 2 else {
            return check("Explosion is in the dex", false)
        }
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: 0, target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)),
            rolling: true)
        check("the target was covered",
              after.theirs[0].hp == start.theirs[0].maxHP,
              "\(after.theirs[0].hp)")
        check("and the user went off anyway", after.mine[0].fainted,
              "\(after.mine[0].hp)")
    }

    /// It is a Fighting move, so a Ghost is not there to be hit — and the user
    /// does not throw itself away for nothing.
    func testAGhostIsNotThereToHitAndTheUserSurvives() {
        let start = position(theirLead: "Gengar")
        check("their lead is a Ghost", start.theirs[0].types.contains(.ghost),
              "\(start.theirs[0].types)")
        let after = TurnModel.resolve(start, mine: gambit(start), theirs: idle(start), rolling: true)
        check("it did nothing to the Ghost",
              after.theirs[0].hp == start.theirs[0].maxHP,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
        check("and the user did not throw itself away", !after.mine[0].fainted,
              "\(after.mine[0].hp)")
    }
}
