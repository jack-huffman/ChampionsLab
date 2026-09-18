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
                                    theirs: Play(left: .pass, right: .pass), rolling: false)
        let step = out.steps.first { $0.action?.move == "Dual Wingbeat" }
        let blows = step?.action?.hits ?? []
        let lost = board.theirs[0].hp - out.theirs[0].hp
        check("two blows", blows.count == 2, "\(blows)")
        check("that add up to what landed", blows.reduce(0, +) == lost, "\(blows) vs \(lost)")
        check("and the log says so", out.story.contains { $0.contains("2 hits") })
        check("each blow is its own number", blows.allSatisfy { $0 > 0 })
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

    @MainActor func testEveryBlowRollsItsOwnDamageAndItsOwnCrit() {
        // Rolled, many times: if one roll were shared across the blows every
        // blow of every use would match its neighbours.
        var varied = 0, uses = 0, criticalLines = 0
        for _ in 0..<300 {
            let board = lineup()
            let out = TurnModel.resolve(board,
                                        mine: Play(left: .attack(move: at(board.mine[0], "Rock Blast"), target: 0), right: .pass),
                                        theirs: Play(left: .pass, right: .pass), rolling: true)
            guard let blows = out.steps.first(where: { $0.action?.move == "Rock Blast" })?.action?.hits,
                  blows.count > 1 else { continue }
            uses += 1
            if Set(blows).count > 1 { varied += 1 }
            if out.story.contains(where: { $0.contains("critical") }) { criticalLines += 1 }
        }
        check("a flurry was thrown", uses > 100, "\(uses)")
        check("its blows differ from one another most of the time",
              Double(varied) / Double(Swift.max(1, uses)) > 0.5, "\(varied) of \(uses)")
        check("and a blow crits on its own now and then, at about a twentieth",
              criticalLines > 0, "\(criticalLines) of \(uses)")
    }

    @MainActor func testTripleAxelIsThreeBlowsThatClimb() {
        let mine = fighters([("Milotic", "Mystic Water", ["Triple Axel", "Scald"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Farigiraf", "Leftovers", ["Psychic"]),
                               ("Garchomp", "Sitrus Berry", ["Earthquake"]),
                               ("Milotic", "Leftovers", ["Scald"])])
        var counts: Set<Int> = []
        var climbed = 0, uses = 0
        for _ in 0..<80 {
            let board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
            let out = TurnModel.resolve(board,
                                        mine: Play(left: .attack(move: at(board.mine[0], "Triple Axel"), target: 0), right: .pass),
                                        theirs: Play(left: .pass, right: .pass), rolling: true)
            guard let blows = out.steps.first(where: { $0.action?.move == "Triple Axel" })?.action?.hits,
                  !blows.isEmpty else { continue }
            uses += 1
            counts.insert(blows.count)
            if blows.count == 3, blows[0] < blows[1], blows[1] < blows[2] { climbed += 1 }
        }
        check("it was used", uses > 40, "\(uses)")
        check("never more than three blows", counts.allSatisfy { $0 <= 3 }, "\(counts.sorted())")
        check("three of them when none missed", counts.contains(3), "\(counts.sorted())")
        check("and each harder than the last", climbed > 0, "\(climbed) of \(uses)")
    }

    @MainActor func testAFlurryGoesThroughAFocusSash() {
        var board = lineup(theirItem: "Focus Sash")
        board.mine[0].build.boosts[Stat.attack.rawValue] = 6
        let flurry = TurnModel.resolve(board,
                                       mine: Play(left: .attack(move: at(board.mine[0], "Dual Wingbeat"), target: 0), right: .pass),
                                       theirs: Play(left: .pass, right: .pass), rolling: false)
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
                                       theirs: Play(left: .pass, right: .pass), rolling: false)
        check("one blow, and the Sash holds it at one", single.theirs[0].hp == 1, "\(single.theirs[0].hp)")
    }
}
