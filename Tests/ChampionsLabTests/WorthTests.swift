//  WorthTests.swift
//  What a Pokémon is worth, and when it stops being worth it.
//
//      swift test --filter WorthTests

import XCTest
@testable import ChampionsLab

final class WorthTests: HarnessCase {
    @MainActor private func form(named name: String) -> Form {
        store.data.forms.first { $0.formLabel == name }!
    }

    /// A counter is worth keeping only while the thing it counters is alive
    ///
    /// The reasoning here is the one people say out loud while they play: "I'd
    /// like to preserve this for later, into their Swampert." It is a statement
    /// about a particular opposing Pokémon and stops being true the moment that
    /// Pokémon faints.
    ///
    /// The engine does *not* currently re-derive its weights as the game goes,
    /// because doing so measured worse — 55.0% against 57.3%, both give or take
    /// 2.2 — and the reasoning is written up on `Board.refreshWorth`. What this
    /// checks is that the machinery still does what it claims, so that turning
    /// it back on is a one-line change and not a rebuild.
    @MainActor func testACounterIsWorthLessOnceItsTargetIsGone() throws {
        print("\n== worth follows who is left ==")
        let mine = fighters([("Rillaboom", "Leftovers", ["Wood Hammer", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Farigiraf", "Leftovers", ["Psychic", "Protect"]),
                             ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"])])
        let theirs = fighters([("Swampert", "Leftovers", ["Earthquake", "Protect"]),
                               ("Incineroar", "Leftovers", ["Flare Blitz", "Protect"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind", "Protect"]),
                               ("Garchomp", "Leftovers", ["Earthquake", "Protect"])])
        let field = Field(isDoubles: true)
        let table = Worth.table(for: mine, against: theirs, rules: store.rulebook, field: field)
        check("the table covers the team", table.count >= 4, "\(table.count)")

        let boom = form(named: "Rillaboom").id
        let swampert = form(named: "Swampert").id
        let incineroar = form(named: "Incineroar").id
        let whimsicott = form(named: "Whimsicott").id
        let chomp = form(named: "Garchomp").id

        // Rillaboom is Grass into a Water/Ground: four times damage, and the
        // clearest counter on the board.
        print("  Rillaboom against Swampert alone: \(table[boom]?[swampert] ?? -1)")
        check("Rillaboom beats Swampert in the grid", (table[boom]?[swampert] ?? 0) >= 0.75,
              "\(table[boom]?[swampert] ?? -1)")

        let whileAlive = Worth.weights(from: table,
                                       against: [swampert, incineroar, whimsicott, chomp])
        let afterItFalls = Worth.weights(from: table, against: [incineroar, whimsicott, chomp])
        let before = whileAlive[boom] ?? 0
        let after = afterItFalls[boom] ?? 0
        print(String(format: "  Rillaboom is worth %.3f while the Swampert lives, %.3f once it is gone",
                     before, after))
        check("and is worth less once the Swampert has gone", after < before,
              String(format: "%.3f then %.3f", before, after))

        // The scale has to hold still while the distribution moves, or the
        // engine would read the whole position as better or worse simply
        // because somebody fainted.
        for (name, set) in [("all four alive", whileAlive), ("Swampert gone", afterItFalls)] {
            let mean = set.values.reduce(0, +) / Double(max(1, set.count))
            print(String(format: "  mean worth with %@: %.3f", name, mean))
            check("worth still averages one with \(name)", abs(mean - 1) < 0.02,
                  String(format: "%.3f", mean))
        }

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// The board can re-derive its weights, whether or not play does
    @MainActor func testTheBoardRefreshesWhatItsPokemonAreWorth() throws {
        print("\n== the board keeps up ==")
        let mine = fighters([("Rillaboom", "Leftovers", ["Wood Hammer", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Farigiraf", "Leftovers", ["Psychic", "Protect"]),
                             ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"])])
        let theirs = fighters([("Swampert", "Leftovers", ["Earthquake", "Protect"]),
                               ("Incineroar", "Leftovers", ["Flare Blitz", "Protect"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind", "Protect"]),
                               ("Garchomp", "Leftovers", ["Earthquake", "Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.myBeats = Worth.table(for: mine, against: theirs,
                                    rules: store.rulebook, field: Field(isDoubles: true))
        board.theirRoster = theirs.slots.compactMap { $0.battleForm(in: store.rulebook)?.id }
        board.sendOutLeads()
        board.refreshWorth()
        let boom = form(named: "Rillaboom").id
        let standing = board.myWorth[boom] ?? 0
        check("it has a weight while the Swampert is up", standing > 0, "\(standing)")

        // Their lead falls. Nothing else changes.
        board.theirs[0].hp = 0
        board.refreshWorth()
        let fallen = board.myWorth[boom] ?? 0
        print(String(format: "  Rillaboom: %.3f with their Swampert up, %.3f once it falls",
                     standing, fallen))
        check("and less once it has fallen", fallen < standing,
              String(format: "%.3f then %.3f", standing, fallen))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
