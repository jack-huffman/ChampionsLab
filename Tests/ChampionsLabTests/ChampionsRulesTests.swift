//  ChampionsRulesTests.swift
//  The numbers Champions changed are the numbers the sim plays.
//
//      swift test --filter ChampionsRulesTests
//
//  ChampionsChampionsRules.swift carries them with the line of Showdown's champions mod beside
//  each. This reads that mod when the checkout is present and fails if the two
//  have parted, then plays the turns and counts: a paralysed Pokemon losing
//  one turn in eight, a freeze thawing by its third turn, a sleep that is two
//  or three turns and never one.

import XCTest
@testable import ChampionsLab

final class ChampionsRulesTests: HarnessCase {
    private static let mod = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/VSCode/Personal Projects/pokemon-showdown-master/data/mods/champions")

    @MainActor private func board() -> Board {
        let mine = fighters([("Garchomp", "Life Orb", ["Dragon Claw", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"])])
        let theirs = fighters([("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"]),
                               ("Milotic", "Leftovers", ["Surf", "Protect"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    }

    func testTheNumbersAreTheModsNumbers() throws {
        let conditions = Self.mod.appendingPathComponent("conditions.ts")
        let abilities = Self.mod.appendingPathComponent("abilities.ts")
        guard let cond = try? String(contentsOf: conditions, encoding: .utf8),
              let abil = try? String(contentsOf: abilities, encoding: .utf8) else {
            throw XCTSkip("no pokemon-showdown checkout beside the project; the mod cannot be read")
        }
        func block(_ text: String, _ key: String) -> String {
            guard let start = text.range(of: "\n\t\(key): {") else { return "" }
            let rest = text[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n\t},")?.lowerBound ?? rest.endIndex)])
        }
        func chance(_ text: String) -> Double? {
            guard let m = text.range(of: #"randomChance\((\d+), (\d+)\)"#, options: .regularExpression) else { return nil }
            let parts = text[m].split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
            return parts.count == 2 ? parts[0] / parts[1] : nil
        }
print("\n== against the mod ==")
        check("paralysis: the mod says what Rules says", chance(block(cond, "par")) == ChampionsRules.fullParalysis,
              "\(chance(block(cond, "par")) ?? -1) against \(ChampionsRules.fullParalysis)")
        let slp = block(cond, "slp")
        let sample = slp.range(of: #"sample\(\[[\d, ]+\]\)"#, options: .regularExpression)
            .map { slp[$0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } } ?? []
        check("sleep: the mod draws from what Rules draws from", sample == ChampionsRules.sleepTurns, "\(sample)")
        let frz = block(cond, "frz")
        check("freeze: the mod thaws at the rate Rules says", chance(frz) == ChampionsRules.thaw, "\(chance(frz) ?? -1)")
        check("freeze: and after the turns Rules says", frz.contains("startTime = \(ChampionsRules.frozenFor);"))
        check("healer: the mod clears at the rate Rules says", chance(block(abil, "healer")) == ChampionsRules.healer,
              "\(chance(block(abil, "healer")) ?? -1)")
    }

    @MainActor func testTheSimPlaysThem() throws {
        defer { Dice.source = TeamLab.SplitMix(seed: 0x5EED_1CE5) }
        let start = board()
        let claw = at(start.mine[0], "Dragon Claw")
        let swing = Play(left: .attack(move: claw, target: 0), right: .pass)
        let idle = Play(left: .pass, right: .pass)

print("\n== one turn in eight ==")
        var numb = start
        numb.mine[0].status = .paralysis
        var lost = 0
        let trials = 600
        for seed in 0..<trials {
            Dice.source = TeamLab.SplitMix(seed: UInt64(seed))
            let after = TurnModel.resolve(numb, mine: swing, theirs: idle, rolling: true)
            if after.story.contains(where: { $0.contains("paralysed and cannot move") }) { lost += 1 }
        }
        let rate = Double(lost) / Double(trials)
        print(String(format: "  lost %d of %d turns: %.1f%%", lost, trials, rate * 100))
        check("a paralysed Pokemon loses about one turn in eight", rate > 0.07 && rate < 0.19,
              String(format: "%.1f%%", rate * 100))

print("\n== frozen, and thawed by the third turn ==")
        var iced = start
        check("the freeze takes", Ailments.inflict(.freeze, onMine: true, slot: 0, byMine: false, bySlot: 0,
                                                    board: &iced, rolling: false))
        check("and carries its clock", iced.mine[0].frozenFor == ChampionsRules.frozenFor, "\(iced.mine[0].frozenFor)")
        var frozenTurns = 0
        for turn in 1...3 {
            iced = TurnModel.resolve(iced, mine: swing, theirs: idle, rolling: false)
            let stillFrozen = iced.story.contains { $0.contains("frozen solid") }
            if stillFrozen { frozenTurns += 1 }
            print("  turn \(turn): \(stillFrozen ? "frozen solid" : "thawed out"), clock \(iced.mine[0].frozenFor)")
        }
        check("it stays frozen for two turns without a roll", frozenTurns == 2, "\(frozenTurns)")
        check("and thaws on the third regardless", iced.mine[0].status == .none,
              iced.mine[0].status.rawValue)

print("\n== two or three turns of sleep, never one ==")
        var naps: [Int: Int] = [:]
        for seed in 0..<300 {
            var dozing = start
            Dice.source = TeamLab.SplitMix(seed: UInt64(seed))
            _ = Ailments.inflict(.sleep, onMine: true, slot: 0, byMine: false, bySlot: 0,
                                 board: &dozing, rolling: true)
            naps[dozing.mine[0].asleepFor, default: 0] += 1
        }
        print("  \(naps.sorted { $0.key < $1.key })")
        check("every sleep is two or three turns", Set(naps.keys) == [2, 3], "\(naps.keys.sorted())")
        check("and three more often than two", (naps[3] ?? 0) > (naps[2] ?? 0))
        check("the search takes two", Ailments.sleepTurns(rolling: false) == 2)
    }
}
