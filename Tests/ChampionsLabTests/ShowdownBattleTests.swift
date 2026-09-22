//  ShowdownBattleTests.swift
//  A game played by Showdown, shown on this app's board.
//
//      swift test --filter ShowdownBattleTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ShowdownBattleTests: HarnessCase {
    private func ready() throws -> (Team, Team) {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        
    /// When one of ours falls, the turn stops and the engine waits to be told
    /// who comes in -- because that is the player's decision, not the
    /// engine's. Theirs it answers for itself.
    func testItStopsAndAsksWhoComesInForOurs() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [3, 1, 4, 1])
        var asked = false
        for _ in 0..<25 {
            guard !ShowdownEngine.shared.ended else { break }
            if game.awaitingSendIn {
                asked = true
                // Somebody of ours is down and the board says so.
                check("one of ours is down when it asks",
                      game.board.mine.prefix(game.board.activeCount).contains { $0.fainted })
                let bench = game.board.mine.indices.first { $0 >= game.board.activeCount
                    && !game.board.mine[$0].fainted }
                guard let bench else { break }
                _ = try game.sendIn(bench: bench)
                check("and it plays on once told", !game.awaitingSendIn)
                break
            }
            _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        }
        check("it asked at some point in twenty-five turns", asked)
        check("and still read every tag", game.unread.isEmpty,
              game.unread.sorted().joined(separator: ", "))
    }
}
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        return (ladder[0].team, ladder[1].team)
    }

    func testABattleStandsUpAndTheBoardMatches() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [1, 2, 3, 4])
        check("four a side came to the board", game.board.mine.count == 4 && game.board.theirs.count == 4,
              "\(game.board.mine.count) and \(game.board.theirs.count)")
        for f in game.board.mine + game.board.theirs where f.hp != f.maxHP {
            print("  NOT WHOLE: \(f.build.form.formLabel) \(f.hp)/\(f.maxHP)")
        }
        check("everybody starts whole",
              game.board.mine.allSatisfy { $0.hp == $0.maxHP } && game.board.theirs.allSatisfy { $0.hp == $0.maxHP })
        check("and nobody has fainted", game.board.mine.allSatisfy { !$0.fainted })
    }

    /// The real test of a reader: play a game out and see whether the board
    /// still agrees with the engine at the end of it.
    func testAGameRunsAndTheBoardKeepsUp() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [5, 6, 7, 8])
        let startHP = game.board.theirs.map(\.hp).reduce(0, +)
        var turns = 0, told = 0
        for _ in 0..<12 {
            guard !ShowdownEngine.shared.ended else { break }
            // The sim picks the first legal thing for each side, which is
            // what a game played for the reader's sake wants: the point is
            // the protocol coming back, not the choices going out.
            _ = try game.play(mine: "default", theirs: "default")
            told += game.board.story.count
            turns += 1
        }
        check("the game got somewhere", turns >= 3, "\(turns) turns")
        let endHP = game.board.theirs.map(\.hp).reduce(0, +)
        check("and somebody took damage", endHP < startHP, "\(startHP) -> \(endHP)")
        check("the board was told what happened, turn after turn", told >= turns, "\(told) lines over \(turns) turns")
        // Every tag the reader did not know. Printed either way, because the
        // list is the honest measure of how finished this is.
        print("  protocol tags not read: \(game.unread.sorted().joined(separator: ", "))")
        check("nothing important went unread",
              game.unread.isEmpty, game.unread.sorted().joined(separator: ", "))
    }

    /// When one of ours falls, the turn stops and the engine waits to be told
    /// who comes in -- because that is the player's decision, not the
    /// engine's. Theirs it answers for itself.
    func testItStopsAndAsksWhoComesInForOurs() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [3, 1, 4, 1])
        var asked = false
        for _ in 0..<25 {
            guard !ShowdownEngine.shared.ended else { break }
            if game.awaitingSendIn {
                asked = true
                check("one of ours is down when it asks",
                      game.board.mine.prefix(game.board.activeCount).contains { $0.fainted })
                guard let bench = game.board.mine.indices.first(where: {
                    $0 >= game.board.activeCount && !game.board.mine[$0].fainted
                }) else { break }
                _ = try game.sendIn(bench: bench)
                check("and it plays on once it is told", !game.awaitingSendIn)
                break
            }
            _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        }
        check("it asked at some point in twenty-five turns", asked)
        check("and still read every tag", game.unread.isEmpty,
              game.unread.sorted().joined(separator: ", "))
    }
}
