//  TwoStageSearchTests.swift
//  The model finds where the answer lives; the engine prices it.
//
//      swift test --filter TwoStageSearchTests
//
//  Pricing the whole matrix with Showdown costs about forty times what the
//  model costs, for an answer that differs where it does not matter. Pricing
//  the three plays the equilibrium actually leans on costs a fraction of a
//  second, and it is the move you are about to make.

import XCTest
@testable import ChampionsLab

@MainActor
final class TwoStageSearchTests: HarnessCase {
    private func game() throws -> (BattleSession, Board) {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let mine = ladder[0].team, theirs = ladder[1].team
        let start = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.id.uuidString),
                                  theirs: theirs, rules: store.rulebook,
                                  singles: false, sendOut: false)
        let battle = try ShowdownBattle.start(from: start, mine: mine, theirs: theirs,
                                              store: store, seed: [1, 4, 1, 4])
        let session = BattleSession(rules: store.rulebook, playback: TurnPlayback())
        session.showdown = battle
        session.board = battle.board
        return (session, battle.board)
    }

    func testTheShortlistIsPricedByTheEngineAndStillASolution() throws {
        let (session, board) = try game()
        var solver = TurnGame(board: board, believingTheirs: true)
        solver.width = 10
        let coarse = solver.solve()
        check("the model found something to choose between",
              coarse.myPlays.count > 1, "\(coarse.myPlays.count) plays")

        let started = Date()
        let fine = session.priced(coarse, on: board)
        let took = Date().timeIntervalSince(started)
        print(String(format: "  refined %d x %d down to %d x %d in %.0f ms",
                     coarse.myPlays.count, coarse.theirPlays.count,
                     fine.myPlays.count, fine.theirPlays.count, took * 1000))

        check("it kept only the plays the answer leans on",
              fine.myPlays.count <= 3 && fine.theirPlays.count <= 3,
              "\(fine.myPlays.count) x \(fine.theirPlays.count)")
        check("and they came from the coarse answer",
              fine.myPlays.allSatisfy { coarse.myPlays.contains($0) })
        check("it is still a mix", abs(fine.myMix.reduce(0, +) - 1) < 0.01,
              String(format: "%.3f", fine.myMix.reduce(0, +)))
        check("and theirs too", abs(fine.theirMix.reduce(0, +) - 1) < 0.01,
              String(format: "%.3f", fine.theirMix.reduce(0, +)))
        check("the payoff is the shape of the plays",
              fine.payoff.count == fine.myPlays.count
                && fine.payoff.allSatisfy { $0.count == fine.theirPlays.count })
        // The whole point of doing it this way: it has to be quick enough to
        // sit in front of a player choosing a move.
        check("and it is quick enough to wait for", took < 1.2,
              String(format: "%.0f ms", took * 1000))
    }

    /// With no engine running the game, nothing is refined and the model's
    /// own answer comes back untouched.
    func testWithoutTheEngineNothingChanges() throws {
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let board = Board(mine: ladder[0].team, theirs: ladder[1].team, rules: store.rulebook)
        let session = BattleSession(rules: store.rulebook, playback: TurnPlayback())
        var solver = TurnGame(board: board, believingTheirs: true)
        solver.width = 6
        let coarse = solver.solve()
        let same = session.priced(coarse, on: board)
        check("the answer is the one the model gave",
              same.myPlays == coarse.myPlays && same.myMix == coarse.myMix)
    }
}
