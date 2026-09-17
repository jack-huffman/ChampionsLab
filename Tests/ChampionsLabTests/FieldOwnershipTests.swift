//  FieldOwnershipTests.swift
//  Who sets the weather and the terrain is written down once.
//
//      swift test --filter FieldOwnershipTests
//
//  FieldSetters is the one table of which abilities and moves put a field up.
//  Eleven files used to carry their own, and two of them disagreed. This walks
//  the sources and fails when a setter is named by string anywhere else, so
//  the twelfth copy cannot be written without this line being changed first.

import XCTest
@testable import ChampionsLab

final class FieldOwnershipTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChampionsLab")
    }
    static let owner = "Damage/FieldSetters.swift"

    /// A setting move's name is allowed in a few places for a reason that is
    /// not "who sets it", and each reason is written here. Nothing else may
    /// name a setting ability at all.
    static let mayNameAMove: [String: String] = [
        "Damage/Damage.swift": "Weather's raw value is what a sandstorm is called on screen",
        "Analysis/Advisor.swift": "Archetype raw values are what an archetype is called on screen",
        "Analysis/Refiner.swift": "the coaching list names them as moves worth a slot",
    ]

    func testOnlyTheOwnerNamesASetter() throws {
        let abilities = Array(FieldSetters.arrivalAbilities) + Array(FieldSetters.weatherLater.keys)
            + ["Orichalcum Pulse"]
        let moves = Array(FieldSetters.weatherMoves.keys) + Array(FieldSetters.terrainMoves.keys)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            guard relative != Self.owner else { continue }
            // Prose in comments mentions everything; only code counts.
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for name in abilities where code.contains("\"\(name)\"") {
                offenders.append("\(relative) names \(name)")
            }
            for name in moves where code.contains("\"\(name)\"") && Self.mayNameAMove[relative] == nil {
                offenders.append("\(relative) names \(name)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a setter is named outside FieldSetters: " + offenders.joined(separator: "; "))
    }

    func testTheTableIsWhole() {
        for weather in Weather.allCases where weather != .none {
            XCTAssertNotNil(FieldSetters.ability(setting: weather), "\(weather) has no arrival ability")
            XCTAssertNotNil(FieldSetters.move(setting: weather), "\(weather) has no move")
        }
        for terrain in Terrain.allCases where terrain != .none {
            XCTAssertNotNil(FieldSetters.ability(setting: terrain), "\(terrain) has no arrival ability")
            XCTAssertNotNil(FieldSetters.move(setting: terrain), "\(terrain) has no move")
        }
        XCTAssertEqual(FieldSetters.terrains.count, 4)
        XCTAssertEqual(FieldSetters.weatherArrivals.count, 4)
        let put = FieldSetters.set(by: ["Intimidate", "Drizzle", "Grassy Surge"])
        XCTAssertEqual(put.weather, .rain)
        XCTAssertEqual(put.terrain, .grassy)
        XCTAssertEqual(FieldSetters.set(by: ["Drizzle", "Drought"]).weather, .sun, "the last setter wins")
        XCTAssertNil(FieldSetters.weather(onArrivalWith: "Sand Spit"), "Sand Spit is not an arrival")
        XCTAssertTrue(FieldSetters.abilities(bringing: .sand).contains("Sand Spit"),
                      "but it is counted where sand is being forecast")
        XCTAssertEqual(FieldSetters.arrivalAbilities(setting: [.sun], or: [.electric]),
                       ["Drought", "Electric Surge"])
    }
}
