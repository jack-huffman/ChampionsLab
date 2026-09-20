//  IntimidateAuditTests.swift
//  Every way an Intimidate can reach the field.
//
//      swift test --filter IntimidateAuditTests

import XCTest
@testable import ChampionsLab

@MainActor
final class IntimidateAuditTests: HarnessCase {
    private func sixes() -> (Team, Team) {
        (fighters([("Garchomp", "", ["Dragon Claw", "Protect"]),
                   ("Rillaboom", "", ["Wood Hammer", "Protect"]),
                   ("Incineroar", "", ["Fake Out", "Knock Off", "Protect"])]),
         fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                   ("Farigiraf", "", ["Calm Mind", "Protect"]),
                   ("Kingambit", "", ["Iron Head", "Protect"])]))
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }
    private func attack(_ b: Board) -> Int { b.theirs[0].build.boosts[Stage.attack.rawValue] }

    func testItFiresWhenItLeads() {
        let (mine, theirs) = sixes()
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          myLeads: [], theirLeads: [], field: Field(isDoubles: true),
                          alreadyEvolved: false)
        // Put the Incineroar out in front and send the leads.
        board.mine.swapAt(0, 2)
        board.mine[0].build.ability = "Intimidate"
        board.sendOutLeads()
        check("its Intimidate fired on the way in", attack(board) < 0, "\(attack(board))")
        check("and the log says so", board.story.contains { $0.contains("Intimidate") },
              board.story.joined(separator: " | "))
    }

    func testItFiresWhenItSwitchesIn() {
        let (mine, theirs) = sixes()
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[2].build.ability = "Intimidate"
        check("nothing has been lowered yet", attack(board) == 0)
        let after = TurnModel.resolve(board,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        check("the Incineroar is out", after.mine[0].build.form.formLabel == "Incineroar",
              after.mine[0].build.form.formLabel)
        check("and its Intimidate fired", after.theirs[0].build.boosts[Stage.attack.rawValue] < 0,
              "\(after.theirs[0].build.boosts[Stage.attack.rawValue])")
        check("on both of them",
              after.theirs[1].build.boosts[Stage.attack.rawValue] < 0,
              "\(after.theirs[1].build.boosts[Stage.attack.rawValue])")
        check("and it is in the log", after.story.contains { $0.contains("Intimidate") },
              after.story.joined(separator: " | "))
    }

    func testItFiresWhenItComesInForSomebodyThatFainted() {
        let (mine, theirs) = sixes()
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[2].build.ability = "Intimidate"
        board.mine[0].hp = 0
        Switching.arrive(byMine: true, slot: 0, bench: 2, board: &board, announcingLeaving: false)
        check("the replacement is out", board.mine[0].build.form.formLabel == "Incineroar",
              board.mine[0].build.form.formLabel)
        check("and its Intimidate fired", attack(board) < 0, "\(attack(board))")
    }

    /// The one the field records, which is what draws the callout over it.
    func testTheStepRecordsTheAbilityAndTheDrop() {
        let (mine, theirs) = sixes()
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[2].build.ability = "Intimidate"
        let after = TurnModel.resolve(board,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        let fired = after.steps.flatMap(\.abilities).filter { $0.name == "Intimidate" }
        check("the step knows whose ability it was", !fired.isEmpty, "\(fired)")
        check("and it is on my side, in the slot it walked into",
              fired.contains { $0.mine && $0.slot == 0 }, "\(fired)")
        let drops = after.steps.flatMap(\.events).compactMap { event -> Int? in
            if case .stat(let mine, _, let stat, let delta, _) = event,
               !mine, stat == Stage.attack.rawValue { return delta }
            return nil
        }
        check("and the drop is on the record for the field to draw",
              drops.contains { $0 < 0 }, "\(drops)")
    }

    func testAClearBodyRefusesItAndSaysSo() {
        let (mine, theirs) = sixes()
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[2].build.ability = "Intimidate"
        board.theirs[0].build.ability = "Clear Body"
        let after = TurnModel.resolve(board,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        check("the one with Clear Body kept its Attack",
              after.theirs[0].build.boosts[Stage.attack.rawValue] == 0)
        check("the other one did not",
              after.theirs[1].build.boosts[Stage.attack.rawValue] < 0,
              "\(after.theirs[1].build.boosts[Stage.attack.rawValue])")
        check("and the Intimidate is still announced",
              after.story.contains { $0.contains("Intimidate") },
              after.story.joined(separator: " | "))
    }
}
