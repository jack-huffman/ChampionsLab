//  EngineOwnershipTests.swift
//  One simulator, more than one battle wanting it.
//
//      swift test --filter EngineOwnershipTests
//
//  The engine keeps a single `battle`, so starting a second ShowdownBattle
//  takes the first one's position away. Worse than a wrong position: `restore`
//  resets the engine's read pointer to the end of the log, so the dispossessed
//  battle loses the protocol lines it had not read yet -- and the turn that
//  follows fails for no reason visible anywhere on the board.
//
//  This is not a hypothetical about tests. The search runs in the background
//  off the same engine the live game is played on. It was *found* in the
//  tests, as a turn that would not play once in a while and played perfectly
//  when run on its own.

import XCTest
@testable import ChampionsLab

@MainActor
final class EngineOwnershipTests: HarnessCase {
    private func slot(_ name: String, _ moves: [String]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.ability = form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
        s.sp = [32, 32, 0, 0, 0, 0]; s.id = UUID()
        return s
    }

    /// Two games at once, played turn about. Each has to go on being its own.
    func testTwoBattlesDoNotTakeEachOthersPosition() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let first = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                             myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                             store: store, seed: [1, 2, 3, 4])
        // A second battle, which takes the engine.
        let second = try ShowdownBattle.start(mine: ladder[1].team, theirs: ladder[0].team,
                                              myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                              store: store, seed: [9, 8, 7, 6])
        let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))

        // And now the first one is asked to carry on, which is exactly what a
        // background search finishing inside the next game looks like.
        var firstTurns = 0, secondTurns = 0
        for _ in 0..<3 {
            if (try? first.play(mine: play, theirs: play)) != nil { firstTurns += 1 }
            if (try? second.play(mine: play, theirs: play)) != nil { secondTurns += 1 }
        }
        print("  first played \(firstTurns) turns, second played \(secondTurns)")
        check("the first battle kept playing", firstTurns == 3, "\(firstTurns)")
        check("and so did the second", secondTurns == 3, "\(secondTurns)")
        // Each keeps its own clock, which is the plainest sign they did not
        // end up sharing one game.
        check("they are two games, not one",
              first.turn == 4 && second.turn == 4, "\(first.turn) and \(second.turn)")
        // And two different games: the same orders from different seeds and
        // opposite sides do not produce the same story.
        check("with stories of their own",
              first.board.story != second.board.story)
    }

    /// A whole game, played with the orders the app itself would give, and
    /// nothing substituted anywhere in it.
    ///
    /// This is the shape of the reported log: a request showing a Kingambit
    /// at "0 fnt" still marked active, next to an order the simulator would
    /// not take. A side reduced to one living Pokemon in doubles leaves a
    /// corpse standing in a slot, and the simulator will not be given orders
    /// for it -- `TurnGame.choices` returns nothing for a fainted slot and
    /// the play becomes a `pass`, which is right, but nothing was checking
    /// that the whole chain holds together to the end of a game.
    func testAWholeGamePlaysWithoutASingleOrderBeingSubstituted() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let game = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [4, 4, 4, 4])
        var turns = 0, sawACorpseInASlot = false, substitutions: [String] = []
        while turns < 40, !ShowdownEngine.shared.ended {
            let board = game.board
            // A slot holding somebody who is down, with nobody left to send.
            for side in [board.mine, board.theirs] {
                let downed = side.prefix(board.activeCount).filter(\.fainted).count
                let bench = side.dropFirst(board.activeCount).filter { !$0.fainted }.count
                if downed > 0, bench == 0 { sawACorpseInASlot = true }
            }
            // The app's own orders, for both sides.
            let mineGame = TurnGame(board: board, believingTheirs: true)
            guard let mine = mineGame.plays(forMine: true).first,
                  let theirs = mineGame.plays(forMine: false).first else { break }
            do { try game.play(mine: mine, theirs: theirs) } catch {
                return check("turn \(turns + 1) played", false,
                             ShowdownEngine.shared.lastRefusal ?? "\(error)")
            }
            substitutions += game.board.story.filter { $0.contains("could not be played") }
            var guarded = 0
            while game.awaitingSendIn, guarded < 4 {
                try game.sendIn(bench: 0)
                guarded += 1
            }
            turns += 1
        }
        print("  played \(turns) turns; a fainted Pokemon stood in a slot: \(sawACorpseInASlot)")
        for line in substitutions.prefix(5) { print("       \(line)") }
        check("the game actually ran", turns >= 5, "\(turns)")
        check("a side did run out, which is the position reported",
              sawACorpseInASlot || ShowdownEngine.shared.ended,
              "never got that far in \(turns) turns")
        check("and not one order was substituted",
              substitutions.isEmpty, "\(substitutions.count)")
    }
}
