//  ItemCalloutTests.swift
//  An item that did something says so over the Pokémon that held it.
//
//      swift test --filter ItemCalloutTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ItemCalloutTests: HarnessCase {
    private func fired(_ board: Board) -> [Board.Step.Firing] {
        board.steps.flatMap(\.items)
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }

    /// The one this was asked for: a Sash decides a game and the field said
    /// nothing about it.
    func testAFocusSashSaysSo() {
        var board = Board(mine: fighters([("Garchomp", "", ["Earthquake", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "Focus Sash", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.theirs[0].build.boosts[Stage.defense.rawValue] = -6
        board.mine[0].build.boosts[Stage.attack.rawValue] = 6
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Earthquake"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board), rolling: true)
        check("it hung on", after.theirs[0].hp == 1, "\(after.theirs[0].hp)")
        check("the log says why",
              after.story.contains { $0.contains("Focus Sash") },
              after.story.joined(separator: " | "))
        let items = fired(after)
        check("and the step records the item, over the one that held it",
              items.contains { !$0.mine && $0.slot == 0 && $0.name == "Focus Sash" },
              "\(items)")
    }

    func testLeftoversAndASitrusAreCalledOutToo() {
        var board = Board(mine: fighters([("Garchomp", "Sitrus Berry", ["Earthquake", "Protect"]),
                                          ("Rillaboom", "Leftovers", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[0].hp = board.mine[0].maxHP / 3
        board.mine[1].hp = board.mine[1].maxHP / 2
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        let items = fired(after)
        check("the berry is called out",
              items.contains { $0.mine && $0.slot == 0 && $0.name == "Sitrus Berry" }, "\(items)")
        check("and the Leftovers",
              items.contains { $0.mine && $0.slot == 1 && $0.name == "Leftovers" }, "\(items)")
    }

    /// The important half: an item is only named when it did something. A
    /// Pokémon merely holding one, on a turn it attacked, is not news.
    func testHoldingAnItemIsNotDoingSomethingWithIt() {
        let board = Board(mine: fighters([("Garchomp", "Choice Scarf", ["Dragon Claw", "Protect"]),
                                          ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Dragon Claw"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        let items = fired(after)
        check("nothing is claimed for an item that only sat there",
              items.isEmpty, "\(items)")
    }

    /// Both sides may hold the same item, and then the sentence has to decide.
    func testTwoOfTheSameItemGoToTheOneNamed() {
        var board = Board(mine: fighters([("Garchomp", "Life Orb", ["Dragon Claw", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "Life Orb", ["Scald", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[0].build.ability = "Rough Skin"
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Dragon Claw"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Scald"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Calm Mind"), target: 0)))
        let items = fired(after)
        let mineOrb = items.filter { $0.name == "Life Orb" && $0.mine }
        let theirOrb = items.filter { $0.name == "Life Orb" && !$0.mine }
        print("  Life Orbs called out: mine \(mineOrb.count), theirs \(theirOrb.count)")
        check("each is claimed by exactly one Pokémon",
              mineOrb.allSatisfy { $0.slot == 0 } && theirOrb.allSatisfy { $0.slot == 0 },
              "\(items)")
        check("and neither side's orb is put on the other side",
              !items.contains { $0.name == "Life Orb" && $0.mine && $0.slot == 1 })
    }

    /// The step travels across the network, so what it carries has to survive
    /// being written down and read back from the other chair.
    func testAnItemSurvivesTheWireAndTheOtherChair() throws {
        var board = Board(mine: fighters([("Garchomp", "Sitrus Berry", ["Earthquake", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[0].hp = board.mine[0].maxHP / 3
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: idle(board))
        guard let step = after.steps.first(where: { !$0.items.isEmpty }) else {
            return check("an item went off", false)
        }
        let wire = try JSONDecoder().decode(Board.Step.self,
                                            from: try JSONEncoder().encode(step))
        check("the item came back off the wire", wire.items == step.items, "\(wire.items)")
        let seen = step.events.compactMap { event -> Board.Step.Firing? in
            if case .item(let firing) = event.flipped { return firing }
            return nil
        }
        check("and from the other chair it is on the other side",
              seen.allSatisfy { !$0.mine }, "\(seen)")
    }
}
