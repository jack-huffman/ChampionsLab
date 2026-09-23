//  ShowdownTextTests.swift
//  The log says what Showdown says.
//
//      swift test --filter ShowdownTextTests

import XCTest
@testable import ChampionsLab

final class ShowdownTextTests: XCTestCase {
    private func check(_ what: String, _ passed: Bool, _ detail: String = "") {
        print("  \(passed ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  -- \(detail)")")
        XCTAssertTrue(passed, "\(what) \(detail)")
    }

    func testTheTableIsThere() {
        check("data/showdown-text.json loaded", ShowdownText.isLoaded)
    }

    /// The line that was reported: "Empoleon used Yawn. Salamence is Yawn."
    /// The sentence the client prints is in the Yawn entry, and it is not
    /// anything the tag could have been rearranged into.
    func testYawnReadsAsASentence() {
        let said = ShowdownText.say("start", of: "move: Yawn", values: ["POKEMON": "Salamence"])
        check("Yawn has Showdown's own line", said == "Salamence grew drowsy!", said ?? "nothing")
        check("and not the tag glued to the name", said?.contains("is Yawn") != true)
    }

    func testTheFamilyAroundItReadsToo() {
        let cases: [(String, String, String, [String: String], String)] = [
            ("start", "move: Leech Seed", "seeded", ["POKEMON": "Rillaboom"], "Rillaboom was seeded!"),
            ("end", "move: Leech Seed", "freed", ["POKEMON": "Rillaboom"],
             "Rillaboom was freed from Leech Seed!"),
            ("start", "confusion", "confused", ["POKEMON": "Incineroar"],
             "Incineroar became confused!"),
            ("start", "brn", "burned", ["POKEMON": "Incineroar"], "Incineroar was burned!"),
            ("start", "tox", "badly poisoned", ["POKEMON": "Milotic"],
             "Milotic was badly poisoned!"),
            ("cant", "flinch", "flinched", ["POKEMON": "Ceruledge"],
             "Ceruledge flinched and couldn't move!"),
            ("start", "move: Taunt", "taunted", ["POKEMON": "Whimsicott"],
             "Whimsicott fell for the taunt!"),
            ("start", "RainDance", "rain", [:], "It started to rain!"),
            ("start", "Grassy Terrain", "grass", [:],
             "Grass grew to cover the battlefield!"),
        ]
        for (key, effect, what, values, want) in cases {
            let said = ShowdownText.say(key, of: effect, values: values)
            check("\(effect) \(key) is the \(what) line", said == want, said ?? "nothing")
        }
    }

    /// A cure follows a cross-reference: Toxic's `end` is `#psn`, which means
    /// "the way poison ends".
    func testACrossReferenceIsFollowed() {
        let said = ShowdownText.say("end", of: "tox", values: ["POKEMON": "Milotic"])
        check("Toxic ends the way poison does",
              said == "Milotic was cured of its poisoning!", said ?? "nothing")
    }

    /// Nothing half-rendered ever reaches the log: a sentence with a
    /// placeholder still in it is worse than the plain fallback, so it comes
    /// back as nothing and the caller writes its own.
    func testAnUnfilledPlaceholderIsNotASentence() {
        let said = ShowdownText.say("cant", of: "move: Taunt", values: ["POKEMON": "Whimsicott"])
        check("no {MOVE} left showing", said?.contains("{") != true, said ?? "nothing")
    }

    func testSomethingShowdownHasNoLineForComesBackEmpty() {
        check("an invented effect has no line",
              ShowdownText.say("start", of: "move: Not A Real Move") == nil)
        check("and neither does a key it does not use",
              ShowdownText.say("nosuchkey", of: "move: Yawn") == nil)
    }
}
