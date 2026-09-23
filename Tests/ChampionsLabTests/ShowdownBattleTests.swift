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

    /// An engine that only plays forwards, put back a turn.
    ///
    /// The same seed and the same answers in the same order are the same
    /// game, so a take-back is the battle played again from the beginning and
    /// stopped early. What has to be true is that the position it stops at is
    /// the position that was there the first time.
    func testItCanBePutBackToTheStartOfATurn() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [11, 22, 33, 44])
        check("it knows how to go back", game.canRewind)
        var seen: [Int: [Int]] = [:]
        for _ in 0..<5 {
            guard !ShowdownEngine.shared.ended, !game.awaitingSendIn else { break }
            seen[game.turn] = game.board.mine.map(\.hp) + game.board.theirs.map(\.hp)
            _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        }
        check("it played a few turns", seen.count >= 3, "\(seen.count)")
        guard let target = seen.keys.sorted().dropFirst().first else { return }
        let back = try game.rewind(to: target)
        check("it came back to turn \(target)", game.turn == target, "\(game.turn)")
        check("with the health it had then",
              back.mine.map(\.hp) + back.theirs.map(\.hp) == seen[target],
              "\(back.mine.map(\.hp) + back.theirs.map(\.hp)) against \(seen[target] ?? [])")
        // And it plays on from there rather than being a museum piece.
        _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        check("and plays on from there", game.turn > target, "\(game.turn)")
        check("reading every tag on the way back", game.unread.isEmpty,
              game.unread.sorted().joined(separator: ", "))
    }

    /// A step the screen can actually play.
    ///
    /// The steps carry the text either way, but the choreography is placed
    /// from the action behind a step -- who used what, of which category and
    /// type. Without one there is nothing to throw and nothing to throw it
    /// at, so a turn arrives already over: the board jumps to its end state
    /// and no animation fires at all.
    func testEveryMoveOpensAStepTheSceneCanPlay() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [2, 7, 1, 8])
        _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        let acted = game.board.steps.filter { $0.action != nil }
        check("the turn produced steps", !game.board.steps.isEmpty, "\(game.board.steps.count)")
        check("and moves among them carry their action", !acted.isEmpty, "\(acted.count)")
        for step in acted {
            guard let action = step.action else { continue }
            check("  \(action.move) knows whose it is and what it is",
                  !action.move.isEmpty && !action.category.isEmpty && !action.type.isEmpty,
                  "\(action.category)/\(action.type)")
            check("  and the scene has choreography for \(action.move)",
                  Choreography.shared.recipe(forMove: action.move) != nil
                    || Choreography.shared.fallback(category: action.category,
                                                    targetsSelf: false) != nil)
        }
    }

    /// The opening is the engine's too.
    ///
    /// The leads walking on and the abilities that fire as they land -- an
    /// Intimidate, a Drought, whichever of two weathers is slower and so
    /// stays -- are read off the protocol onto the board the screen is about
    /// to show, rather than worked out here and handed over afterwards.
    func testTheOpeningComesOffTheProtocol() throws {
        let (mine, theirs) = try ready()
        // A board with the four chosen and nobody out yet, which is what the
        // battle screen has when the flash goes up.
        // What the battle screen has when the flash goes up: the four
        // chosen, named the way the lobby names them, and nobody out yet.
        let four = mine.slots.prefix(4).map(\.id.uuidString)
        let start = Board.opening(mine: mine, bringing: four, theirs: theirs,
                                  rules: store.rulebook, singles: false, sendOut: false)
        let game = try ShowdownBattle.start(from: start, mine: mine, theirs: theirs,
                                            store: store, seed: [9, 9, 9, 9] as [Int])
        check("the leads are standing", game.board.mine.prefix(2).allSatisfy { !$0.fainted })
        check("the opening was told", !game.board.story.isEmpty, "\(game.board.story.count) lines")
        check("and it is made of steps the screen can play",
              !game.board.steps.isEmpty, "\(game.board.steps.count)")
        check("everybody is whole at the start",
              game.board.mine.allSatisfy { $0.hp == $0.maxHP })
        check("with nothing unread", game.unread.isEmpty,
              game.unread.sorted().joined(separator: ", "))
        print("  opening said: \(game.board.story.prefix(6).joined(separator: " | "))")
        // And the game plays on from it.
        _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        check("and the first turn follows it", game.turn >= 2, "\(game.turn)")
    }

    /// Every way a turn could go, weighed -- which is the thing a search
    /// needs and playing a battle never does.
    ///
    /// Forced, not sampled. Showdown puts every coin flip through
    /// `battle.randomChance` and lets `battle.prng` be replaced, so a run can
    /// be told to answer yes to one flip and no to another. The odds are the
    /// ones the sim asked for, not a count of how often something happened.
    func testItCanSayEveryWayATurnCouldGo() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [4, 5, 6, 7])
        let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
        let flat = try game.outcomes(mine: play, theirs: play, branching: 0)
        check("with nothing split on, one way it goes", flat.count == 1, "\(flat.count)")
        check("  and it is certain", abs((flat.first?.chance ?? 0) - 1) < 0.001)

        let split = try game.outcomes(mine: play, theirs: play, branching: 2)
        check("splitting two flips gives up to four", split.count > 1 && split.count <= 4,
              "\(split.count)")
        let total = split.reduce(0) { $0 + $1.chance }
        check("and the odds are odds: they sum to one", abs(total - 1) < 0.001,
              String(format: "%.4f", total))
        check("the likeliest comes first",
              zip(split, split.dropFirst()).allSatisfy { $0.chance >= $1.chance })
        // Different branches are different turns.
        let health = split.map { $0.board.theirs.map(\.hp) }
        check("and they are not all the same turn", Set(health.map { "\($0)" }).count > 1,
              "\(health.count) branches, \(Set(health.map { "\($0)" }).count) distinct")
        // Asking what might happen does not change what has.
        check("the game did not move while it was asked",
              game.turn == 1, "\(game.turn)")
    }

    /// The Pokemon that comes in brings its own steps and not the turn
    /// before it.
    ///
    /// The interrupted turn has already been shown by the time anybody is
    /// asked who comes in. Leaving its steps on the board hands them to the
    /// screen a second time, and what plays is the whole turn again rather
    /// than the arrival.
    func testAReplacementBringsOnlyItsOwnSteps() throws {
        let (mine, theirs) = try ready()
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [3, 1, 4, 1])
        var asked = false
        for _ in 0..<25 {
            guard !ShowdownEngine.shared.ended else { break }
            if game.awaitingSendIn {
                asked = true
                let turnsMoves = Set(game.board.steps.compactMap { $0.action?.move }
                                        .filter { !$0.isEmpty })
                check("the turn that was interrupted had moves in it", !turnsMoves.isEmpty,
                      turnsMoves.sorted().joined(separator: ", "))
                guard let bench = game.board.mine.indices.first(where: {
                    $0 >= game.board.activeCount && !game.board.mine[$0].fainted
                }) else { break }
                _ = try game.sendIn(bench: bench)
                let after = Set(game.board.steps.compactMap { $0.action?.move }
                                    .filter { !$0.isEmpty })
                check("and the arrival does not play it again",
                      after.intersection(turnsMoves).isEmpty,
                      after.sorted().joined(separator: ", "))
                check("what it does carry is the coming in",
                      game.board.steps.contains { $0.action?.category == "Switch" }
                        || !game.board.story.isEmpty,
                      "\(game.board.steps.count) steps")
                break
            }
            _ = try game.play(mine: "default", theirs: "default", oursWhenForced: nil)
        }
        check("somebody fell inside twenty-five turns", asked)
    }
}
