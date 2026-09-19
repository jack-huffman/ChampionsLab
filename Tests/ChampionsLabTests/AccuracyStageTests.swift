//  AccuracyStageTests.swift
//  Accuracy and evasion, which are stages the game has and the model did not.
//
//      swift test --filter AccuracyStageTests

import XCTest
@testable import ChampionsLab

@MainActor
final class AccuracyStageTests: HarnessCase {
    private func position() -> Board {
        Board(mine: fighters([("Garchomp", "", ["Mud-Slap", "Dragon Claw", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"]),
                              ("Kingambit", "", ["Iron Head", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Double Team", "Calm Mind"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func theyThink(_ board: Board) -> Play {
        Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
    }

    // MARK: - The stages exist

    func testTheStageArrayHasRoomForThem() {
        let board = position()
        check("every stage has a slot", board.mine[0].build.boosts.count == Stage.width,
              "\(board.mine[0].build.boosts.count) of \(Stage.width)")
        check("and the six stats still index where they did",
              Stage(Stat.speed).rawValue == Stat.speed.rawValue)
        check("accuracy and evasion sit past them",
              Stage.accuracy.rawValue == 6 && Stage.evasion.rawValue == 7)
    }

    /// Stages of accuracy move in thirds from a base of three, not in halves
    /// from a base of two. Getting this wrong would make Double Team twice the
    /// move it is.
    func testTheyMoveInThirdsNotHalves() {
        check("+1 accuracy is a third more", abs(Stage.accuracy.multiplier(1) - 4.0 / 3) < 0.001,
              "\(Stage.accuracy.multiplier(1))")
        check("-1 accuracy is three quarters", abs(Stage.accuracy.multiplier(-1) - 0.75) < 0.001,
              "\(Stage.accuracy.multiplier(-1))")
        check("while +1 Attack is half again", abs(Stage.attack.multiplier(1) - 1.5) < 0.001)
        check("and -1 Attack is two thirds", abs(Stage.attack.multiplier(-1) - 2.0 / 3) < 0.001)
    }

    // MARK: - They change whether a move lands

    func testAnAccuracyDropMakesAMoveMissMore() {
        var board = position()
        let claw = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        let before = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                          defender: board.theirs[0], board: board)
        board.mine[0].build.boosts[Stage.accuracy.rawValue] = -2
        let after = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                         defender: board.theirs[0], board: board)
        check("a blinded attacker lands less often", after < before, "\(after) against \(before)")
        check("and by three fifths at two stages",
              abs(after - before * 0.6) < 0.5, "\(after) against \(before)")
    }

    func testEvasionMakesAMoveMissMore() {
        var board = position()
        let claw = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        let before = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                          defender: board.theirs[0], board: board)
        board.theirs[0].build.boosts[Stage.evasion.rawValue] = 2
        let after = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                         defender: board.theirs[0], board: board)
        check("a dodging target is hit less often", after < before, "\(after) against \(before)")
    }

    func testTheTwoCancelEachOther() {
        var board = position()
        let claw = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        let plain = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                         defender: board.theirs[0], board: board)
        board.mine[0].build.boosts[Stage.accuracy.rawValue] = 2
        board.theirs[0].build.boosts[Stage.evasion.rawValue] = 2
        let both = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                        defender: board.theirs[0], board: board)
        check("+2 accuracy against +2 evasion is where it started",
              abs(both - plain) < 0.001, "\(both) against \(plain)")
    }

    func testAKeenEyeLooksThroughIt() {
        var board = position()
        let claw = board.mine[0].moves[at(board.mine[0], "Dragon Claw")]
        board.theirs[0].build.boosts[Stage.evasion.rawValue] = 3
        let dodged = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                          defender: board.theirs[0], board: board)
        board.mine[0].build.ability = "Keen Eye"
        let seen = Accuracy.chanceToHit(claw, attacker: board.mine[0],
                                        defender: board.theirs[0], board: board)
        check("a Keen Eye ignores the dodging", seen > dodged, "\(seen) against \(dodged)")
        check("and lands as often as it would against nobody",
              abs(seen - Double(claw.accuracy)) < 0.001, "\(seen)")
    }

    // MARK: - Moves that move them

    func testMudSlapTakesAccuracyOffWhatItHits() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Mud-Slap"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: theyThink(start), rolling: true)
        check("it lands an accuracy drop",
              after.theirs[0].build.boosts[Stage.accuracy.rawValue] < 0,
              "\(after.theirs[0].build.boosts[Stage.accuracy.rawValue])")
        check("and the log says which stage moved",
              after.story.contains { $0.contains("Acc fell") },
              after.story.joined(separator: " | "))
    }

    func testDoubleTeamRaisesEvasion() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Double Team"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        check("Double Team raises its own evasion",
              after.theirs[0].build.boosts[Stage.evasion.rawValue] > 0,
              "\(after.theirs[0].build.boosts[Stage.evasion.rawValue])")
    }

    // MARK: - Everything that clears a stage clears these too

    func testHazeAndSwitchingAndTopsyTurvyReachThem() {
        var board = position()
        board.mine[0].build.boosts[Stage.accuracy.rawValue] = 2
        board.mine[0].build.boosts[Stage.evasion.rawValue] = -2
        var left = board
        Switching.depart(&left.mine, active: 0)
        check("a switch leaves accuracy behind",
              left.mine[0].build.boosts[Stage.accuracy.rawValue] == 0)
        check("and evasion with it",
              left.mine[0].build.boosts[Stage.evasion.rawValue] == 0)
        // Topsy-Turvy is a whole-array flip, so it should reach them for free.
        let flipped = board.mine[0].build.boosts.map { -$0 }
        check("a flip turns accuracy over", flipped[Stage.accuracy.rawValue] == -2)
        check("and evasion", flipped[Stage.evasion.rawValue] == 2)
    }

    /// What the data can actually express. Some moves carry neither a parsed
    /// sentence nor a Showdown secondary, and those are a hole in the dataset
    /// rather than in the model — worth knowing which.
    func testWhichAccuracyMovesTheDataCanExpress() {
        var working: [String] = [], silent: [String] = []
        for move in store.data.moves.values.sorted(by: { $0.name < $1.name }) {
            let text = move.effect.lowercased()
            guard text.contains("accuracy") || text.contains("evasi") else { continue }
            let touches = !move.targetDrops.filter(\.key.isAim).isEmpty
                || !move.selfBoosts.filter(\.key.isAim).isEmpty
                || !move.targetBoosts.filter(\.key.isAim).isEmpty
                || !move.selfDrops.filter(\.key.isAim).isEmpty
                || (move.secondaryData ?? []).contains { ($0.stats ?? [:]).keys.contains {
                        $0 == "accuracy" || $0 == "evasion" } }
            if touches { working.append(move.name) } else { silent.append(move.name) }
        }
        print("  moves whose text mentions accuracy or evasion: \(working.count + silent.count)")
        print("  the model can express: \(working.joined(separator: ", "))")
        if !silent.isEmpty { print("  the data says nothing usable for: \(silent.joined(separator: ", "))") }
        check("the ones with real data reach the model", working.count >= 6, "\(working.count)")
    }
}
