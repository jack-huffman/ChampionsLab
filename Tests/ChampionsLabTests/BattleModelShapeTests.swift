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
//  question to be asked once, out loud.

import XCTest
@testable import ChampionsLab

final class BattleModelShapeTests: XCTestCase {
    private var battle: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChampionsLab/Battle")
    }

    /// Every aspect, and the most lines it may run to.
    static let aspects: [String: Int] = [
        "Board": 1400,          // the state; large because Fighter carries a lot
        "TurnModel": 400,       // the orchestrator, and nothing else
        "TurnOrder": 400,
        "Strikes": 1400,        // the action pipeline
        "SupportMoves": 1400,   // eighty-odd rules, one each
        "Ailments": 300,
        "StatChanges": 300,
        "Switching": 400,
        "Residuals": 650,
        "Evaluation": 300,
        "Accuracy": 150,
        "Protection": 150,
        "MoveHistory": 150,
    ]

    /// Functions allowed past the ordinary limit, with why.
    static let longFunctions: [String: String] = [
        "Strikes.apply": "the whole pipeline for one action, in the order it happens",
        "SupportMoves.support": "eighty-odd status moves, each its own rule; a switch, not logic",
        "Residuals.endOfTurn": "every end-of-turn effect, in the order the game applies them",
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

    func testNoFunctionGrowsPastTheLimitUnannounced() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: battle.path)
            .filter { $0.hasSuffix(".swift") }
        var offenders: [String] = []
        for file in files {
            let type = String(file.dropLast(6))
            let lines = try String(contentsOf: battle.appendingPathComponent(file), encoding: .utf8)
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
        XCTAssertTrue(offenders.isEmpty,
            "over \(Self.ordinaryLimit) lines and not declared: " + offenders.joined(separator: "; "))
    }
}
