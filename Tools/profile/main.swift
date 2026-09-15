//  Tools/profile/main.swift
//  Where the search actually spends its time.
//
//  Optimising by guesswork is how a project ends up with a fast function
//  nobody calls. This times the pieces a search is made of, against a real
//  board, and prints them in order of cost.
//
//      ./Tools/profile.sh

import AppKit
import SwiftUI

@MainActor func run() {
    let store = Store.shared
    let rules = store.rulebook
    guard let mine = store.teams.first(where: { $0.slots.count >= 4 }),
          let meta = store.data.metaTeams.first(where: { $0.name == "Big Six" }) else {
        print("no teams to profile against"); exit(1)
    }
    let theirs = store.opponentTeam(meta)
    let board = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                              theirs: theirs, rules: rules, singles: false)

    func time(_ label: String, _ runs: Int, _ body: () -> Void) -> (String, Double, Int) {
        // One warm pass, so a lazy cache is not charged to the first timing.
        body()
        let start = Date()
        for _ in 0..<runs { body() }
        let each = Date().timeIntervalSince(start) / Double(runs) * 1000
        return (label, each, runs)
    }

    var game = TurnGame(board: board, believingTheirs: true)
    game.width = 8
    let mySide = game.plays(forMine: true)
    let theirSide = game.plays(forMine: false)
    let solved = game.solve(iterations: 900)

    var rows: [(String, Double, Int)] = []
    rows.append(time("plays(forMine:) x2", 200) {
        _ = game.plays(forMine: true); _ = game.plays(forMine: false)
    })
    rows.append(time("TurnModel.resolve, one cell", 500) {
        _ = TurnModel.resolve(board, mine: mySide[0], theirs: theirSide[0], narrating: false)
    })
    rows.append(time("TurnModel.outcomes, one cell", 500) {
        _ = TurnModel.outcomes(board, mine: mySide[0], theirs: theirSide[0])
    })
    rows.append(time("TurnModel.value", 5000) { _ = TurnModel.value(board) })
    rows.append(time("equilibrium 900, \(mySide.count)x\(theirSide.count)", 20) {
        _ = TurnGame.equilibrium(solved.payoff, iterations: 900)
    })
    rows.append(time("one full solve (both boards)", 10) { _ = game.solve(iterations: 900) })
    var flat = TurnGame(board: board)
    flat.width = 8
    rows.append(time("one full solve (one board)", 10) { _ = flat.solve(iterations: 900) })
    let attacker = board.mine[0].build, defender = board.theirs[0].build
    let move = board.mine[0].moves.first { $0.isDamaging } ?? board.mine[0].moves[0]
    rows.append(time("DamageCalc.calculate", 20000) {
        _ = DamageCalc.calculate(attacker: attacker, defender: defender,
                                 move: move, field: board.field)
    })
    rows.append(time("Board.asTheySeeIt", 2000) { _ = board.asTheySeeIt })
    rows.append(time("Matchup (36 duels)", 20) {
        _ = Matchup(mine: mine, theirs: theirs, rules: rules, field: Field(isDoubles: true))
    })

    // What a move costs to ask a question of. Every one of these is a
    // computed property that parses the move's text.
    var textRows: [(String, Double, Int)] = []
    textRows.append(time("move.aim", 20000) { _ = move.aim })
    textRows.append(time("move.charge", 20000) { _ = move.charge })
    textRows.append(time("move.secondary", 20000) { _ = move.secondary })
    textRows.append(time("move.healing", 20000) { _ = move.healing })
    textRows.append(time("move.targetDrops", 20000) { _ = move.targetDrops })
    textRows.append(time("move.selfBoosts", 20000) { _ = move.selfBoosts })
    textRows.append(time("move.drainShare", 20000) { _ = move.drainShare })
    textRows.append(time("move.drawbacks (memoised)", 20000) { _ = move.drawbacks })
    textRows.append(time("move.isProtectable", 20000) { _ = move.isProtectable })
    print("== what one question about a move costs ==")
    for (label, each, _) in textRows.sorted(by: { $0.1 > $1.1 }) {
        print(String(format: "  %9.4f ms  %@", each, label))
    }
    print(String(format: "  %9.4f ms  all of them once", textRows.reduce(0) { $0 + $1.1 }))

    print("\n== where a turn's time goes ==")
    print("  board: \(mySide.count) of my plays x \(theirSide.count) of theirs")
    for (label, each, runs) in rows.sorted(by: { $0.1 > $1.1 }) {
        print(String(format: "  %9.4f ms  %@  (x%d)", each, label, runs))
    }

    let engine = BattleEngine(rules: rules, budget: 0.5)
    let start = Date()
    let result = engine.think(board)
    print(String(format: "\n  search: %.2fs -> depth %d, %d positions",
                 Date().timeIntervalSince(start), result.depth, result.nodes))
    print(String(format: "  that is %.2f ms per position",
                 Date().timeIntervalSince(start) * 1000 / Double(max(1, result.nodes))))
}
MainActor.assumeIsolated { run() }
