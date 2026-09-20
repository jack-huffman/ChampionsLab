//  StageWriteOwnershipTests.swift
//  A stage moves through one door, and the record does not miss the rest.
//
//  `StatChanges.change` is the door: it applies every rule about a stage
//  moving and puts the move on the step's record, which is what the field
//  animates. A handful of places write a stage directly for a reason -- a
//  Belly Drum straight to six, a Haze, a switch resetting, Baton Pass
//  handing stages over -- and the step's close puts those on the record from
//  the difference. This test counts the direct writes, so a new one is a
//  decision: route it through the door, or add it here with its reason.

import XCTest
@testable import ChampionsLab

final class StageWriteOwnershipTests: HarnessCase {
    private var battle: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ChampionsLab/Battle")
    }

    /// Direct writes to a stage, by file: the door itself, and the few that
    /// bypass it on purpose.
    static let allowed: [String: (count: Int, why: String)] = [
        "StatChanges": (5, "the door, White Herb putting drops back, and giving a narrow array from an older peer the room for accuracy and evasion"),
        "Board": (3, "Speed Boost's and Moody-style end-of-turn movers on the board itself"),
        "Strikes": (2, "Anger Point straight to six on a critical hit"),
        "SupportMoves": (10, "Power and Guard Swap, Belly Drum, Stockpile and its undoing, Haze, Topsy-Turvy"),
        "Switching": (3, "a switch resetting stages, and Baton Pass handing stages over -- Mega Evolution used to copy them across by hand and no longer needs to, because it keeps the build rather than rebuilding it"),
    ]

    func testEveryDirectStageWriteIsAccountedFor() throws {
        let pattern = try NSRegularExpression(pattern: "build\\.boosts\\[[^\\]]+\\] *(=|\\+=|-=)[^=]|build\\.boosts = ")
        let files = try FileManager.default.contentsOfDirectory(at: battle, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var found: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let hits = pattern.numberOfMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length))
            if hits > 0 { found[file.deletingPathExtension().lastPathComponent] = hits }
        }
        for (name, hits) in found.sorted(by: { $0.key < $1.key }) {
            let expected = Self.allowed[name]?.count ?? 0
            check("\(name) writes a stage directly \(expected) time\(expected == 1 ? "" : "s"), not \(hits)",
                  hits == expected,
                  hits > expected ? "a new direct write: route it through StatChanges.change, or add it to the allow-list with why"
                                  : "one fewer than listed: update the allow-list")
        }
        for name in Self.allowed.keys where found[name] == nil {
            check("\(name) still has its listed writes", false, "none found; update the allow-list")
        }
    }

    @MainActor func testAStageMovedOutsideTheDoorIsStillOnTheRecord() {
        let mine = fighters([("Kingambit", "Black Glasses", ["Belly Drum", "Kowtow Cleave"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: at(board.mine[0], "Belly Drum"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        let step = out.steps.first { $0.action?.move == "Belly Drum" }
        check("Attack went to six", out.mine[0].build.boosts[Stat.attack.rawValue] == 6)
        check("and the record says by how much",
              step?.events.contains(.stat(mine: true, slot: 0, stat: Stat.attack.rawValue, delta: 6, cause: nil)) == true,
              "\(step?.events ?? [])")
        let phases = step.map { TurnPlayback().phases(of: $0) } ?? []
        check("so the field shows it rising", phases.first?.boosts[Seat(mine: true, slot: 0)]?.first?.delta == 6, "\(phases)")
    }
}
