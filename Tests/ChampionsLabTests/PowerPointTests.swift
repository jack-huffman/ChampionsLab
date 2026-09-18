//  PowerPointTests.swift
//  Power Points: spent when a move actually goes off, never given back, and
//  what happens to a Pokemon that runs out of them.
//
//      swift test --filter PowerPointTests

import XCTest
@testable import ChampionsLab

@MainActor
final class PowerPointTests: HarnessCase {
    /// Nobody here carries an item that chips or heals, so the only health my
    /// side loses in these positions is what it did to itself.
    private func position(theirAbility: String = "") -> Board {
        var board = Board(mine: fighters([("Garchomp", "", ["Dragon Claw", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"]),
                                          ("Kingambit", "", ["Iron Head", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        if !theirAbility.isEmpty { board.theirs[0].build.ability = theirAbility }
        return board
    }

    /// Both of theirs setting up: nothing comes back across the field.
    private func theyThink(_ board: Board) -> Play {
        Play(left: .attack(move: at(board.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0))
    }
    private func alsoProtect(_ board: Board) -> Choice {
        .attack(move: at(board.mine[1], "Protect"), target: 0)
    }

    func testAMoveStartsOnItsPrintedCountAndOneUseCostsOne() {
        let start = position()
        let claw = at(start.mine[0], "Dragon Claw")
        let before = start.mine[0].pp(at: claw)
        check("Dragon Claw starts on its printed count",
              before == start.mine[0].moves[claw].pp, "\(before)")
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: claw, target: 0), right: alsoProtect(start)),
            theirs: theyThink(start))
        check("and one use costs one", after.mine[0].pp(at: claw) == before - 1,
              "\(after.mine[0].pp(at: claw)) left of \(before)")
    }

    func testAMoveAimedAtAPressureCostsTwo() {
        let start = position(theirAbility: "Pressure")
        let claw = at(start.mine[0], "Dragon Claw")
        let before = start.mine[0].pp(at: claw)
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: claw, target: 0), right: alsoProtect(start)),
            theirs: theyThink(start))
        check("a move thrown at a Pressure costs two",
              after.mine[0].pp(at: claw) == before - 2,
              "\(after.mine[0].pp(at: claw)) left of \(before)")
        // And the partner, who threw at nobody, paid the ordinary price.
        let guardIndex = at(start.mine[1], "Protect")
        check("while the one who aimed at nothing paid one",
              after.mine[1].pp(at: guardIndex) == start.mine[1].pp(at: guardIndex) - 1)
    }

    func testATurnItNeverGotCostsNothing() {
        var start = position()
        start.mine[0].status = .sleep
        start.mine[0].asleepFor = 3
        let claw = at(start.mine[0], "Dragon Claw")
        let before = start.mine[0].pp(at: claw)
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: claw, target: 0), right: alsoProtect(start)),
            theirs: theyThink(start))
        check("a Pokemon that never moved spent nothing",
              after.mine[0].pp(at: claw) == before, "\(after.mine[0].pp(at: claw)) of \(before)")
    }

    func testLeavingTheFieldDoesNotRefill() {
        var start = position()
        let claw = at(start.mine[0], "Dragon Claw")
        start.mine[0].ppLeft[claw] = 3
        let after = TurnModel.resolve(start,
            mine: Play(left: .swap(to: 2), right: alsoProtect(start)),
            theirs: theyThink(start))
        // It went to the bench, where it was standing; the count went with it.
        let benched = after.mine.firstIndex { $0.build.form.formLabel == "Garchomp" }
        check("the one that left is on the bench", benched != nil, "\(benched ?? -1)")
        if let benched {
            check("and its Power Points did not come back",
                  after.mine[benched].pp(at: claw) == 3, "\(after.mine[benched].pp(at: claw))")
        }
    }

    // MARK: - Struggle

    func testAPokemonWithNothingLeftStruggles() {
        var start = position()
        for index in start.mine[0].ppLeft.indices { start.mine[0].ppLeft[index] = 0 }
        let whole = start.mine[0].hp
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: 0, target: 0), right: alsoProtect(start)),
            theirs: theyThink(start))
        check("it says it has nothing left",
              after.story.contains { $0.contains("no moves left") })
        check("and Struggles", after.story.contains { $0.contains("used Struggle") })
        let lost = whole - after.mine[0].hp
        let quarter = start.mine[0].maxHP / 4
        check("paying about a quarter of its health for it",
              lost >= quarter - 1 && lost <= quarter + 1,
              "\(lost) of \(start.mine[0].maxHP), a quarter being \(quarter)")
        check("and it hurt somebody", after.theirs[0].hp < start.theirs[0].hp,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
    }

    func testStruggleGoesThroughAGhost() {
        var start = Board(mine: fighters([("Garchomp", "", ["Dragon Claw", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Gengar", "", ["Calm Mind", "Protect"]),
                                            ("Milotic", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        // A Normal move cannot touch a Ghost, and Struggle is not a Normal move
        // however it is printed.
        for index in start.mine[0].ppLeft.indices { start.mine[0].ppLeft[index] = 0 }
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: 0, target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        check("Struggle reaches a Ghost", after.theirs[0].hp < start.theirs[0].hp,
              "\(after.theirs[0].hp) of \(start.theirs[0].maxHP)")
    }

    func testStruggleMatchesWhatTheDexSays() {
        guard let dex = store.data.moves["struggle"] else {
            return check("Struggle is in the dex", false)
        }
        let ours = MoveLegality.struggle
        check("the same name", ours.name == dex.name, ours.name)
        check("the same power", ours.power == dex.power, "\(ours.power) against \(dex.power)")
        check("the same kind", ours.category == dex.category, ours.category)
        check("the same type on the page", ours.type == dex.type, ours.type)
        check("and the same priority", ours.priority == dex.priority, "\(ours.priority)")
    }

    func testAMoveWithNoneLeftIsRefusedWhileOthersWouldGo() {
        var start = position()
        let claw = at(start.mine[0], "Dragon Claw")
        start.mine[0].ppLeft[claw] = 0
        check("something else is still usable",
              MoveLegality.anyUsable(byMine: true, slot: 0, board: start))
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: claw, target: 0), right: alsoProtect(start)),
            theirs: theyThink(start))
        check("the empty move is refused rather than swapped out",
              after.story.contains { $0.contains("no Power Points left for Dragon Claw") },
              after.story.joined(separator: " | "))
        check("and it did not Struggle instead",
              !after.story.contains { $0.contains("used Struggle") })
    }
}
