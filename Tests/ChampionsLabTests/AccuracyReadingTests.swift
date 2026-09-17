//  AccuracyReadingTests.swift
//  The search has to price a move the way the board will resolve it.
//
//      swift test --filter AccuracyReadingTests
//
//  Three places in the search read a move's printed accuracy instead of asking
//  the board what it would actually be. The printed number is wrong in every
//  case the format is built around: a No Guard Mega Raichu exists to throw Zap
//  Cannon and Focus Blast, a rain team exists to throw Hurricane and Thunder,
//  and a Sand Veil exists to make the printed number a lie. An engine that
//  prices Zap Cannon at 50 on the one Pokémon that never misses with it will
//  not click the move, which is to say it will not play the Pokémon.

import XCTest
@testable import ChampionsLab

final class AccuracyReadingTests: HarnessCase {
    @MainActor func testAccuracyAsTheBoardResolvesIt() throws {
print("\n== No Guard ==")
        let mine = fighters([
            ("Mega Raichu Y", "Life Orb", ["Zap Cannon", "Focus Blast", "Protect"]),
            ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])])
        let theirs = fighters([
            ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
            ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        check("the No Guard ability is actually on the field",
              board.mine[0].build.ability == "No Guard", board.mine[0].build.ability)

        let zap = board.mine[0].moves[at(board.mine[0], "Zap Cannon")]
        check("Zap Cannon is printed at 50", zap.accuracy == 50, "\(zap.accuracy)")
        let real = Accuracy.chanceToHit(zap, attacker: board.mine[0],
                                         defender: board.theirs[0], board: board)
        check("No Guard resolves Zap Cannon at 100", real == 100, "\(real)")

        // The search's own reading of the same play. This is the number that
        // decides whether the move is ever clicked.
        let game = TurnGame(board: board)
        let play = Play(left: .attack(move: at(board.mine[0], "Zap Cannon"), target: 0),
                        right: .pass)
        let seen = game.reliability(of: play, forMine: true)
        check("the search prices it at 100 too", seen > 0.99, String(format: "%.2f", seen))

print("\n== the sky ==")
        // Hurricane at 70 under the rain a team built its whole turn around.
        var wet = Board(mine: fighters([
            ("Pelipper", "Focus Sash", ["Hurricane", "Protect"]),
            ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])]),
                        theirs: theirs, rules: store.rulebook)
        let gale = wet.mine[0].moves[at(wet.mine[0], "Hurricane")]
        wet.field.weather = .none
        let dry = Accuracy.chanceToHit(gale, attacker: wet.mine[0],
                                        defender: wet.theirs[0], board: wet)
        wet.field.weather = .rain
        let rained = Accuracy.chanceToHit(gale, attacker: wet.mine[0],
                                           defender: wet.theirs[0], board: wet)
        check("Hurricane is 70 in the open and 100 in rain",
              dry == 70 && rained == 100, "\(dry) then \(rained)")

        let wetGame = TurnGame(board: wet)
        let gust = Play(left: .attack(move: at(wet.mine[0], "Hurricane"), target: 0),
                        right: .pass)
        let wetSeen = wetGame.reliability(of: gust, forMine: true)
        check("the search sees the rain too", wetSeen > 0.99, String(format: "%.2f", wetSeen))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
