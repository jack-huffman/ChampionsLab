//  EngineBudgetTests.swift
//  The same board, the same budget, the same answer.
//
//      swift test --filter EngineBudgetTests
//
//  The search is budgeted in positions solved rather than seconds, so what it
//  chooses depends on the board and the budget and on nothing else -- not the
//  machine, not what else it was doing. That is what makes it possible to say
//  in a test what the engine plays, and this is where that promise is held.

import XCTest
@testable import ChampionsLab

final class EngineBudgetTests: HarnessCase {
    @MainActor func testSameBoardSameBudgetSameAnswer() throws {
        let mine = fighters([("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"])])
        let theirs = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                               ("Rillaboom", "Assault Vest", ["Wood Hammer", "Grassy Glide"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

print("\n== twice, one turn ahead ==")
        let engine = BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.oneAhead)
        let first = engine.think(board)
        let again = engine.think(board)
        print("  \(first.nodes) positions, \(first.depth) deep, value \(first.value)")
        print("  \(first.principal.first ?? "no line")")
        check("the mix is identical", first.mix == again.mix)
        check("the value is identical", first.value == again.value)
        check("it solved the same number of positions", first.nodes == again.nodes,
              "\(first.nodes) then \(again.nodes)")
        check("it reached the same depth", first.depth == again.depth)
        check("it expects the same line", first.principal == again.principal)

print("\n== the budget is a budget ==")
        // Asked before every position, so the overrun is at most the children
        // of the node it was already expanding.
        let slack = engine.beam * engine.beam * 2 + engine.worlds
        check("one turn ahead stays near its budget",
              first.nodes <= BattleEngine.Nodes.oneAhead + slack,
              "\(first.nodes) for \(BattleEngine.Nodes.oneAhead)")
        check("one turn ahead looks a turn ahead", first.depth >= 2, "\(first.depth)")

        let turn = BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.turn).think(board)
        print("  this turn only: \(turn.nodes) position, \(turn.depth) deep")
        check("this turn only solves this turn", turn.nodes == 1 && turn.depth == 1,
              "\(turn.nodes) positions, \(turn.depth) deep")
        check("more budget reaches at least as deep", first.depth >= turn.depth)
        check("both budgets rate every line they return",
              turn.mix.count == turn.plays.count && first.mix.count == first.plays.count
                && !turn.plays.isEmpty && !first.plays.isEmpty)
    }
}
