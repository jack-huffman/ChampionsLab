//  EngineConformanceTests.swift
//  The app's own model, checked against the engine it was copied from.
//
//      swift test --filter EngineConformanceTests
//
//  Played battles are Showdown's now, but the search still imagines with the
//  Swift model, and it has to: the search asks "what if this Protect holds"
//  *and* "what if it fails", weighing each by its own odds, and a simulator
//  cannot be asked that -- it rolls. So the model stays, and this is what
//  keeps it honest: the same position and the same orders, put through both,
//  compared on everything that is not the dice.

import XCTest
@testable import ChampionsLab

@MainActor
final class EngineConformanceTests: HarnessCase {
    private func ready() throws -> [(team: Team, weight: Double)] {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        return ladder
    }

    /// Who acted, in what order. The one thing in a turn that is decided
    /// before any dice are thrown, and the thing most worth agreeing on:
    /// Speed, priority, Tailwind, Trick Room, and every ability and item that
    /// touches any of them.
    private func order(_ board: Board) -> [String] {
        board.steps.compactMap { step in
            guard let action = step.action, !action.move.isEmpty else { return nil }
            return "\(action.byMine ? "us" : "them")\(action.slot):\(action.move)"
        }
    }

    func testTurnOrderAgreesAcrossManyPositions() throws {
        let ladder = try ready()
        var compared = 0, agreed = 0
        var differences: [String] = []
        for (index, first) in ladder.prefix(6).enumerated() {
            let second = ladder[(index + 1) % ladder.count].team
            let start = Board.opening(mine: first.team,
                                      bringing: first.team.slots.prefix(4).map(\.id.uuidString),
                                      theirs: second, rules: store.rulebook,
                                      singles: false, sendOut: false)
            guard let game = try? ShowdownBattle.start(from: start, mine: first.team,
                                                       theirs: second, store: store,
                                                       seed: [index, 2, 3, 4]) else { continue }
            var ours = game.board
            for round in 0..<6 {
                guard !ShowdownEngine.shared.ended, !game.awaitingSendIn else { break }
                // A different move each round, so the sample is not three
                // turns of the same Fake Out. The first move is usually Fake
                // Out and usually illegal after the first turn, which the sim
                // refuses and the comparison then throws away.
                let which = round == 0 ? 0 : 1 + (round % 3)
                let play = Play(left: .attack(move: which, target: 0),
                                right: .attack(move: which, target: 1))
                let mine = TurnModel.resolve(ours, mine: play, theirs: play, narrating: true)
                let subsBefore = game.substituted.count
                guard let theirs = try? game.play(mine: play, theirs: play,
                                                  oursWhenForced: nil) else { break }
                // Only where both engines were asked the same question. The
                // sim refuses a choice the board would have allowed -- a Fake
                // Out on the second turn, most often -- and plays the first
                // legal thing instead, so the two are then being asked
                // different turns and comparing them says nothing.
                guard game.substituted.count == subsBefore else { ours = theirs; continue }
                compared += 1
                // Of the moves both engines agree went off, did they go off
                // in the same order? Compared as an intersection because the
                // two record a turn differently: a Pokemon made to flinch
                // gets an action here and no move line at all from Showdown,
                // which is a difference in bookkeeping and not in who went
                // first.
                let ourList = order(mine), simList = order(theirs)
                let both = Set(ourList).intersection(simList)
                let ourOrder = ourList.filter(both.contains)
                let simOrder = simList.filter(both.contains)
                if ourOrder == simOrder { agreed += 1 }
                else {
                    differences.append("ours \(ourOrder) / showdown \(simOrder)")
                }
                ours = theirs   // both go on from the engine's truth
            }
        }
        check("it compared real turns", compared >= 10, "\(compared)")
        print("  turn order agreed on \(agreed) of \(compared)")
        for line in differences.prefix(4) { print("    \(line)") }
        // Not all of it, and it cannot be. Two Pokemon of equal Speed are
        // separated by a coin flip in both engines, so a handful of turns
        // disagree however right the model is -- and every disagreement seen
        // so far has been exactly that, two Protects or two attackers of the
        // same Speed swapping places. What the number is for is falling: a
        // model that has drifted on priority, on Tailwind, on Trick Room or
        // on an ability that touches Speed does not score in the eighties.
        let rate = Double(agreed) / Double(max(1, compared))
        check("the two engines order a turn the same way", rate >= 0.8,
              String(format: "%.0f%% of %d", rate * 100, compared))
    }

    /// What a move does to the Pokemon it lands on, within the roll.
    ///
    /// Damage is sixteen rolls from 85% to 100%, so two engines never have to
    /// agree exactly -- but they do have to land in the same band, and they
    /// have to agree about whether something fell over.
    func testDamageLandsInTheSameBand() throws {
        let ladder = try ready()
        guard let mine = ladder.first?.team, ladder.count > 1 else { return }
        let theirs = ladder[1].team
        let start = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.id.uuidString),
                                  theirs: theirs, rules: store.rulebook,
                                  singles: false, sendOut: false)
        guard let game = try? ShowdownBattle.start(from: start, mine: mine, theirs: theirs,
                                                   store: store, seed: [8, 8, 8, 8]) else {
            return check("a game stood up", false)
        }
        let before = game.board
        let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
        let ourTurn = TurnModel.resolve(before, mine: play, theirs: play, narrating: false)
        guard let theirTurn = try? game.play(mine: play, theirs: play, oursWhenForced: nil) else {
            return check("the engine played it", false)
        }
        var checked = 0
        for slot in 0..<before.activeCount {
            let was = before.theirs[slot].hp
            let ourDamage = was - ourTurn.theirs[slot].hp
            let simDamage = was - theirTurn.theirs[slot].hp
            guard ourDamage > 0 || simDamage > 0 else { continue }
            checked += 1
            check("\(before.theirs[slot].build.form.formLabel) fell over on both, or neither",
                  (ourTurn.theirs[slot].fainted) == (theirTurn.theirs[slot].fainted),
                  "ours \(ourTurn.theirs[slot].hp), showdown \(theirTurn.theirs[slot].hp) of \(was)")
            // The roll is sixteen sixteenths of a spread, so one can be up to
            // about a fifth away from the other and both still be right.
            let apart = abs(Double(ourDamage - simDamage)) / Double(max(1, max(ourDamage, simDamage)))
            check("  and took a comparable amount: \(ourDamage) against \(simDamage)",
                  apart <= 0.35 || ourTurn.theirs[slot].fainted,
                  String(format: "%.0f%% apart", apart * 100))
        }
        check("something actually happened", checked > 0, "\(checked)")
    }
}
