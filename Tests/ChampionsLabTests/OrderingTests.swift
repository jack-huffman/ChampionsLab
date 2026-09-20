//  OrderingTests.swift
//  The order two things happen in, when the order is the whole outcome.
//
//      swift test --filter OrderingTests

import XCTest
@testable import ChampionsLab

@MainActor
final class OrderingTests: HarnessCase {

    // MARK: - Two Megas, and whose weather is left

    /// Mega Evolution runs fastest first, so the *slower* one evolves second
    /// and its weather overwrites the first. Charizard Y is 100 base Speed and
    /// Tyranitar 71, so the sand lands last and the sand is what stays.
    func testTheSlowerMegaSetsTheWeatherThatStays() {
        var board = Board(mine: fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Tyranitar", "Tyranitarite", ["Crunch", "Protect"]),
                                            ("Milotic", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.field.weather = .none
        var mine = Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0),
                        right: .attack(move: at(board.mine[1], "Protect"), target: 0))
        mine.megaSlot = 0
        var theirs = Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                          right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
        theirs.megaSlot = 0

        let after = TurnModel.resolve(board, mine: mine, theirs: theirs)
        check("both Mega Evolved",
              after.mine[0].build.form.isMega && after.theirs[0].build.form.isMega,
              "\(after.mine[0].build.form.formLabel) / \(after.theirs[0].build.form.formLabel)")
        check("the slower one's weather is the one left on the field",
              after.field.weather == .sand, "\(after.field.weather)")
        // And the order is visible in the log, fastest first.
        let sun = after.story.firstIndex { $0.contains("Charizard Mega Evolved") } ?? 99
        let sand = after.story.firstIndex { $0.contains("Tyranitar Mega Evolved") } ?? -1
        check("the faster one evolved first", sun < sand, "\(sun) then \(sand)")
    }

    /// And each is a step of its own, so the field can show them a beat apart
    /// rather than as one moment in which the sun somehow lost to the rain.
    func testEachMegaEvolutionIsItsOwnStep() {
        var board = Board(mine: fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Tyranitar", "Tyranitarite", ["Crunch", "Protect"]),
                                            ("Milotic", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.field.weather = .none
        var mine = Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0),
                        right: .attack(move: at(board.mine[1], "Protect"), target: 0))
        mine.megaSlot = 0
        var theirs = Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                          right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
        theirs.megaSlot = 0
        let after = TurnModel.resolve(board, mine: mine, theirs: theirs)
        let megaSteps = after.steps.filter { $0.action?.category == "Mega" }
        check("two of them, one each", megaSteps.count == 2, "\(megaSteps.count)")
        check("and they are on opposite sides",
              Set(megaSteps.compactMap { $0.action?.byMine }).count == 2)
        check("no move animation is attached to either",
              megaSteps.allSatisfy { ($0.action?.move ?? "").isEmpty })
    }

    // MARK: - The White Herb, and what follows it

    /// Three things happen and the field has to be able to show three: the
    /// drop, the herb putting it back, and the Unburden that follows from the
    /// herb being gone.
    func testTheDropTheHerbAndTheUnburdenAreThreeBeats() {
        var board = Board(mine: fighters([("Sneasler", "White Herb", ["Close Combat", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.mine[0].build.ability = "Unburden"
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Close Combat"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0)),
            rolling: true)

        check("Close Combat took its defences",
              after.story.contains { $0.contains("Def and SpD fell") || $0.contains("Def") },
              after.story.joined(separator: " | "))
        check("the herb put them back",
              after.story.contains { $0.contains("White Herb restored") },
              after.story.joined(separator: " | "))
        check("and the Unburden is said on its own",
              after.story.contains { $0.contains("Unburden") },
              after.story.joined(separator: " | "))
        check("the stages really are back where they started",
              after.mine[0].build.boosts[Stage.defense.rawValue] == 0
                && after.mine[0].build.boosts[Stage.spDefense.rawValue] == 0,
              "\(after.mine[0].build.boosts)")
        check("and the herb is spent", after.mine[0].build.itemSpent)

        // The part the field reads: the drop and the restore are recorded
        // separately, with different causes, so they are cut into two beats
        // rather than netting to nothing.
        let moved = after.steps.flatMap(\.events).compactMap { event -> String? in
            if case .stat(_, _, _, _, let cause) = event { return cause ?? "the move" }
            return nil
        }
        check("the drop and the restore are both on the record",
              moved.contains("the move") && moved.contains("White Herb"),
              moved.joined(separator: ", "))
    }

    /// The same for a drop from outside: an Intimidate, then the herb.
    func testAnIntimidateIsPutBackByTheHerbToo() {
        var board = Board(mine: fighters([("Sneasler", "White Herb", ["Close Combat", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Incineroar", "", ["Fake Out", "Protect"]),
                                            ("Milotic", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.mine[0].build.ability = "Unburden"
        board.theirs[0].build.ability = "Intimidate"
        Switching.intimidate(from: false, slot: 0, board: &board)
        check("the Intimidate landed and the herb answered it",
              board.mine[0].build.boosts[Stage.attack.rawValue] == 0,
              "\(board.mine[0].build.boosts[Stage.attack.rawValue])")
        check("the herb is spent", board.mine[0].build.itemSpent)
        check("and it said so", board.story.contains { $0.contains("White Herb restored") },
              board.story.joined(separator: " | "))
        check("with the Unburden after it",
              board.story.contains { $0.contains("Unburden") },
              board.story.joined(separator: " | "))
    }
}
