//  BattleModelShapeTests.swift
//  The battle model stays in the shape it was put in.
//
//      swift test --filter BattleModelShapeTests
//
//  TurnModel was one file of 5,371 lines. It is fourteen now, each owning one
//  aspect of a turn, and the only thing that keeps it that way is something
//  that notices when it stops. This does. It is a ratchet, not a style guide:
//  the budgets are set a little above where things stand, so ordinary work
//  passes and the file that quietly doubles does not.
//
//  Two functions are allowed to be long and are named here with the reason.
//  Adding a third means adding a line, which is the point -- it forces the
//  question to be asked once, out loud. The damage calculator is held to the
//  same limit: it was one function of 451 lines, and is twelve phases now.

import XCTest
@testable import ChampionsLab

final class BattleModelShapeTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChampionsLab")
    }
    private var battle: URL { sources.appendingPathComponent("Battle") }
    /// The calculator is not an aspect of a turn, but its one function was the
    /// longest in the project, and the same ratchet keeps it in phases.
    private var damage: URL { sources.appendingPathComponent("Damage") }
    /// The builder was one file of 1,630 lines; it is six now, and the same
    /// ratchet keeps every function in Analysis under the ordinary limit.
    private var analysis: URL { sources.appendingPathComponent("Analysis") }

    /// Every aspect, and the most lines it may run to.
    static let aspects: [String: Int] = [
        "Board": 1400,          // the state; large because Fighter carries a lot
        "TurnModel": 400,       // the orchestrator, and nothing else
        "TurnOrder": 400,
        "Strikes": 1560,        // the action pipeline, in its phases; a flurry is rolled blow by blow
        "SupportMoves": 1500,   // eighty-odd rules in fifteen sections, one each
        "Ailments": 300,
        "StatChanges": 300,
        "Switching": 560,        // owns the Board's arrival methods as well, and every way off the field
        "Residuals": 650,
        "Evaluation": 300,
        "Accuracy": 150,
        "Protection": 150,
        "MoveHistory": 150,
        "Dice": 60,
        "ChampionsRules": 80,           // the numbers Champions changed, the mod's line beside each
    ]

    /// Functions allowed past the ordinary limit, with why.
    static let longFunctions: [String: String] = [
        "Board.flipped": "every field of the state, mirrored -- long because the state is",
        "SelfPlay.playLogged": "the game loop with its ledger readers nested inside it, "
                             + "so they can write to the ledger they are reading for",
    ]
    static let ordinaryLimit = 260

    func testEveryAspectIsPresentAndWithinBudget() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: battle.path)
            .filter { $0.hasSuffix(".swift") }
        for (name, budget) in Self.aspects {
            guard files.contains("\(name).swift") else {
                XCTFail("\(name).swift is missing from the battle model"); continue
            }
            let text = try String(contentsOf: battle.appendingPathComponent("\(name).swift"),
                                  encoding: .utf8)
            let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
            XCTAssertLessThanOrEqual(count, budget,
                "\(name).swift is \(count) lines against a budget of \(budget)")
        }
    }

    /// Who may depend on whom. Board and Dice are the floor and depend on
    /// nothing; TurnModel is the roof and nothing depends on it; and the graph
    /// between has no cycles, so every aspect can be read on its own.
    func testTheAspectsFormADirectedAcyclicGraph() throws {
        let names = Array(Self.aspects.keys) + ["Dice"]
        var uses: [String: Set<String>] = [:]
        for name in names {
            let text = try String(contentsOf: battle.appendingPathComponent("\(name).swift"),
                                  encoding: .utf8)
            // Prose in comments mentions everything; only code counts.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            uses[name] = Set(names.filter { other in
                other != name && code.range(of: "\\b\(other)\\.", options: .regularExpression) != nil
            })
        }
        for (name, deps) in uses.sorted(by: { $0.key < $1.key }) {
            print("  \(name) -> \(deps.sorted().joined(separator: ", "))")
        }
        XCTAssertTrue(uses["Board"]?.isEmpty ?? false,
                      "Board is state and depends on nothing; it names \(uses["Board"] ?? [])")
        XCTAssertTrue(uses["Dice"]?.isEmpty ?? false, "Dice depends on nothing")
        let dependOnTurnModel = uses.filter { $0.value.contains("TurnModel") }.map(\.key).sorted()
        XCTAssertTrue(dependOnTurnModel.isEmpty,
                      "TurnModel is the orchestrator; nothing may depend on it: \(dependOnTurnModel)")
        func reaches(_ from: String, _ target: String, _ seen: inout Set<String>) -> Bool {
            for next in uses[from] ?? [] where !seen.contains(next) {
                seen.insert(next)
                if next == target || reaches(next, target, &seen) { return true }
            }
            return false
        }
        var cycles: [String] = []
        for name in names {
            var seen: Set<String> = []
            if reaches(name, name, &seen) { cycles.append(name) }
        }
        XCTAssertTrue(cycles.isEmpty, "these aspects can reach themselves: \(cycles.sorted())")
    }

    func testNoFunctionGrowsPastTheLimitUnannounced() throws {
        var offenders: [String] = []
        for folder in [battle, damage, analysis] {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }
        for file in files {
            let type = String(file.dropLast(6))
            let lines = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: #"func ([a-zA-Z]+)\("#, options: .regularExpression)
                else { continue }
                let name = line[range].dropFirst(5).dropLast(1)
                var depth = 0, seen = false, end = index
                for j in index..<lines.count {
                    depth += lines[j].filter { $0 == "{" }.count - lines[j].filter { $0 == "}" }.count
                    if lines[j].contains("{") { seen = true }
                    if seen && depth == 0 { end = j; break }
                }
                let length = end - index + 1
                let key = "\(type).\(name)"
                if length > Self.ordinaryLimit, Self.longFunctions[key] == nil {
                    offenders.append("\(key) is \(length) lines")
                }
            }
        }
        }
        XCTAssertTrue(offenders.isEmpty,
            "over \(Self.ordinaryLimit) lines and not declared: " + offenders.joined(separator: "; "))
    }
}
