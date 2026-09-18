//  TurnStartTests.swift
//  A turn starts where the turn before it ended, and plays forward.
//
//  The field draws whichever step of the turn the playback is resting on.
//  Step nought is the board *after* the first action, so resting there
//  before the turn has played showed that action's damage, and anything it
//  knocked out, from the moment the turn was handed over -- the faint
//  landing before its own animation. Minus one is the board the turn began
//  on, and that is where a turn now waits.

import XCTest
@testable import ChampionsLab

@MainActor
final class TurnStartTests: HarnessCase {
    private func lineup() -> Board {
        let mine = fighters([("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "Protect"]),
                               ("Milotic", "Leftovers", ["Scald"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook)
    }

    func testATurnWaitsOnTheBoardItBeganOn() {
        let before = lineup()
        let out = TurnModel.resolve(before,
                                    mine: Play(left: .attack(move: at(before.mine[0], "Moonblast"), target: 0), right: .pass),
                                    theirs: Play(left: .attack(move: at(before.theirs[0], "Kowtow Cleave"), target: 0), right: .pass),
                                    rolling: false)
        let playback = TurnPlayback()
        playback.show(out, steps: out.steps, before: before)
        check("nothing of the turn is shown yet", playback.at == -1, "\(playback.at)")
        check("and no step counts as seen", playback.seen == 0, "\(playback.seen)")
        check("the board it waits on is the one the turn began on",
              playback.startBoard?.mine.map(\.hp) == before.mine.map(\.hp),
              "\(playback.startBoard?.mine.map(\.hp) ?? [])")
        check("which is not where the turn ended",
              out.mine.map(\.hp) != before.mine.map(\.hp))
    }

    func testPickingUpPartwayWaitsOnTheStepBeforeIt() {
        let before = lineup()
        let out = TurnModel.resolve(before,
                                    mine: Play(left: .attack(move: at(before.mine[0], "Moonblast"), target: 0), right: .pass),
                                    theirs: Play(left: .attack(move: at(before.theirs[0], "Kowtow Cleave"), target: 0), right: .pass),
                                    rolling: false)
        guard out.steps.count > 1 else { return check("the turn has steps to pick up from", false) }
        let playback = TurnPlayback()
        playback.show(out, steps: out.steps, before: before)
        playback.play(out.steps, hitMine: [], hitTheirs: [], singles: false, from: 1, leadIn: 0)
        check("it waits on the step before the one it resumes at", playback.at == 0, "\(playback.at)")
        playback.finish()
    }

    func testAShownTurnRestsOnItsLastStep() {
        let before = lineup()
        let out = TurnModel.resolve(before,
                                    mine: Play(left: .attack(move: at(before.mine[0], "Moonblast"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass), rolling: false)
        let playback = TurnPlayback()
        // What a screen does when it wants the whole turn on show at once.
        playback.show(out, steps: out.steps, before: before, revealed: out.steps.count)
        check("it rests on the last step", playback.at == out.steps.count - 1, "\(playback.at)")
        check("with every step counted as seen", playback.seen == out.steps.count)
    }
}
