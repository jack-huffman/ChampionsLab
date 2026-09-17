//  MultiHitTests.swift
//  A flurry strikes several times, each blow on the record; a Focus Sash
//  holds the first blow and the next one lands.

import XCTest
@testable import ChampionsLab

final class MultiHitTests: HarnessCase {
    @MainActor private func lineup(theirItem: String = "Leftovers") -> Board {
        let mine = fighters([("Garchomp", "Life Orb", ["Dual Wingbeat", "Rock Blast", "Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Whimsicott", theirItem, ["Tailwind", "Protect"]),
                               ("Milotic", "Leftovers", ["Scald"]),
                               ("Kingambit", "Black Glasses", ["Kowtow Cleave"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook)
    }

    @MainActor func testDualWingbeatIsTwoBlowsOnTheRecord() {
        let board = lineup()
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attack(move: at(board.mine[0], "Dual Wingbeat"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass), rolling: true)
        let step = out.steps.first { $0.action?.move == "Dual Wingbeat" }
        let blows = step?.action?.hits ?? []
        let lost = board.theirs[0].hp - out.theirs[0].hp
        check("two blows", blows.count == 2, "\(blows)")
        check("that add up to what landed", blows.reduce(0, +) == lost, "\(blows) vs \(lost)")
        check("and the log says so", out.story.contains { $0.contains("2 hits") })
    }

    @MainActor func testRockBlastRollsTwoToFive() {
        var counts: Set<Int> = []
        for _ in 0..<12 {
            let board = lineup()
            let out = TurnModel.resolve(board,
                                        mine: Play(left: .attack(move: at(board.mine[0], "Rock Blast"), target: 0), right: .pass),
                                        theirs: Play(left: .pass, right: .pass), rolling: true)
            if let blows = out.steps.first(where: { $0.action?.move == "Rock Blast" })?.action?.hits, !blows.isEmpty {
                counts.insert(blows.count)
            }
        }
        check("every count is two to five", counts.allSatisfy { (2...5).contains($0) }, "\(counts.sorted())")
        check("and the dice were rolled", !counts.isEmpty)
    }

    @MainActor func testASingleBlowKeepsNoList() {
        let board = lineup()
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attack(move: at(board.mine[0], "Earthquake"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass), rolling: true)
        let blows = out.steps.first { $0.action?.move == "Earthquake" }?.action?.hits ?? [1]
        check("one blow, nothing to list", blows.isEmpty, "\(blows)")
    }

    @MainActor func testAFlurryGoesThroughAFocusSash() {
        var board = lineup(theirItem: "Focus Sash")
        board.mine[0].build.boosts[Stat.attack.rawValue] = 6
        let flurry = TurnModel.resolve(board,
                                       mine: Play(left: .attack(move: at(board.mine[0], "Dual Wingbeat"), target: 0), right: .pass),
                                       theirs: Play(left: .pass, right: .pass), rolling: true)
        check("the Sash held the first blow and the second finished it",
              flurry.theirs[0].fainted, "\(flurry.theirs[0].hp)")
        check("the Sash was spent doing it", flurry.theirs[0].build.itemSpent)
        check("the blows on record are what landed",
              (flurry.steps.first { $0.action?.move == "Dual Wingbeat" }?.action?.hits.reduce(0, +) ?? -1)
                == board.theirs[0].hp)
        check("and it was told", flurry.story.contains { $0.contains("the next blow landed") })

        var again = lineup(theirItem: "Focus Sash")
        again.mine[0].build.boosts[Stat.attack.rawValue] = 6
        let single = TurnModel.resolve(again,
                                       mine: Play(left: .attack(move: at(again.mine[0], "Earthquake"), target: 0), right: .pass),
                                       theirs: Play(left: .pass, right: .pass), rolling: true)
        check("one blow, and the Sash holds it at one", single.theirs[0].hp == 1, "\(single.theirs[0].hp)")
    }
}
