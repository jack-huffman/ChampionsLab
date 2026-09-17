//  AbilityFiringTests.swift
//  A step remembers which abilities went off and whose, off its own notes,
//  so the field can name them over the Pokemon.

import XCTest
@testable import ChampionsLab

final class AbilityFiringTests: HarnessCase {
    @MainActor func testAnArrivalNamesTheAbilitiesThatFired() {
        var mine = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        mine.slots[0].ability = "Intimidate"
        var theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Milotic", "Leftovers", ["Scald"])])
        theirs.slots[0].ability = "Defiant"
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.narrating = true
        board.beginStep()
        board.landed(mine: true, slot: 0)
        board.closeStep()
        let fired = board.steps.last?.abilities ?? []
        check("the step says something", !(board.steps.last?.text.isEmpty ?? true))
        check("Incineroar's Intimidate went off",
              fired.contains(Board.Step.Firing(mine: true, slot: 0, name: "Intimidate")), "\(fired)")
        check("and Kingambit's Defiant answered",
              fired.contains(Board.Step.Firing(mine: false, slot: 0, name: "Defiant")), "\(fired)")
        check("Sneasler's own ability did not fire",
              !fired.contains { !$0.mine && $0.slot == 1 }, "\(fired)")
        check("the stages moved to match",
              board.theirs[1].build.boosts[Stat.attack.rawValue] == -1
                && board.theirs[0].build.boosts[Stat.attack.rawValue] == 1,
              "\(board.theirs.map { $0.build.boosts[Stat.attack.rawValue] })")
    }

    @MainActor func testABareNameGoesToTheOneActing() {
        let mine = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.narrating = true
        board.beginStep(Board.Action(byMine: true, slot: 0, move: "Kowtow Cleave", category: "Physical", type: "Dark"))
        board.note("  Defiant x1.5")
        board.note("Nothing here names anyone.")
        board.closeStep()
        let fired = board.steps.last?.abilities ?? []
        check("the bare name went to the one acting",
              fired == [Board.Step.Firing(mine: true, slot: 0, name: "Defiant")], "\(fired)")
    }
}
