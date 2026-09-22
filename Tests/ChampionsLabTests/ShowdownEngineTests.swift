//  ShowdownEngineTests.swift
//  Showdown's own simulator, running inside this app.
//
//      swift test --filter ShowdownEngineTests
//
//  Not a translation of the rules and not a reading of them: the simulator
//  itself, in JavaScriptCore. What is checked here is that it loads, that it
//  knows this game's format, that its numbers are this game's numbers, and
//  that it resolves a turn the way the game does.

import XCTest
@testable import ChampionsLab

@MainActor
final class ShowdownEngineTests: HarnessCase {
    /// A team in Showdown's own paste format. Deliberately written out rather
    /// than built from the app's own model: this is the outside checking the
    /// inside, and sharing a builder between them would spoil that.
    private let paste = """
    Incineroar @ Sitrus Berry
    Ability: Intimidate
    Level: 50
    EVs: 32 HP / 16 Atk / 16 SpD
    Careful Nature
    - Fake Out
    - Knock Off
    - Parting Shot
    - Protect

    Rillaboom @ Assault Vest
    Ability: Grassy Surge
    Level: 50
    EVs: 32 HP / 32 Atk
    Adamant Nature
    - Wood Hammer
    - Grassy Glide
    - Fake Out
    - U-turn

    Garchomp @ Life Orb
    Ability: Rough Skin
    Level: 50
    EVs: 32 Atk / 32 Spe
    Jolly Nature
    - Earthquake
    - Dragon Claw
    - Rock Slide
    - Protect

    Whimsicott @ Focus Sash
    Ability: Prankster
    Level: 50
    EVs: 32 HP / 32 Spe
    Timid Nature
    - Tailwind
    - Moonblast
    - Encore
    - Protect

    Milotic @ Leftovers
    Ability: Competitive
    Level: 50
    EVs: 32 HP / 32 SpD
    Calm Nature
    - Scald
    - Icy Wind
    - Recover
    - Protect

    Kingambit @ Black Glasses
    Ability: Defiant
    Level: 50
    EVs: 32 HP / 32 Atk
    Adamant Nature
    - Kowtow Cleave
    - Sucker Punch
    - Swords Dance
    - Protect
    """

    private func engine() throws -> ShowdownEngine {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        return ShowdownEngine.shared
    }

    func testItLoadsAndKnowsThisGamesFormat() throws {
        let ps = try engine()
        let formats = try ps.formats()
        check("it carries Champions formats", !formats.isEmpty, "\(formats.count)")
        guard let mc = formats.first(where: { $0.id == ShowdownEngine.regMC }) else {
            return check("VGC 2026 Reg M-C is one of them",
                         false, formats.map(\.id).joined(separator: ", "))
        }
        check("Reg M-C is there", mc.name.contains("Reg M-C"), mc.name)
        check("  played on the champions mod", mc.mod == "champions", mc.mod)
        check("  in doubles", mc.isDoubles, mc.gameType)
    }

    /// The reason a real engine is worth the trouble: its numbers are the
    /// game's numbers, not ours. Incineroar's 95 base HP with 32 Stat Points
    /// is 95 + 32 + 75, and nothing here computed that -- the sim did.
    func testTheStatsAreChampionsStats() throws {
        let ps = try engine()
        let team = try ps.pack(paste: paste)
        check("the paste packed", team.hasPrefix("Incineroar"), String(team.prefix(24)))
        try ps.start(mine: ("Alice", team), theirs: ("Bob", team), seed: [1, 2, 3, 4])
        let request = try ps.request("p1") ?? ""
        check("a side is asked for something", !request.isEmpty)
        // 95 base + 32 points + 75.
        check("Incineroar has 202 HP, the Champions way",
              request.contains("\"condition\":\"202/202\""),
              String(request.prefix(160)))
        // 115 base + 16 points + 20, and Careful does not touch Attack.
        check("and 151 Attack", request.contains("\"atk\":151"))
    }

    func testItResolvesATurnTheWayTheGameDoes() throws {
        let ps = try engine()
        let team = try ps.pack(paste: paste)
        try ps.start(mine: ("Alice", team), theirs: ("Bob", team), seed: [1, 2, 3, 4])
        try ps.choose("p1", "team 1234")
        try ps.choose("p2", "team 1234")
        _ = try ps.since()
        try ps.choose("p1", "move fakeout 1, move woodhammer 1")
        try ps.choose("p2", "move fakeout 1, move woodhammer 1")
        let lines = try ps.since()
        check("it said what happened", !lines.isEmpty, "\(lines.count) lines")
        check("Fake Out went off", lines.contains { $0.hasPrefix("|move|") && $0.contains("Fake Out") })
        check("and it flinched somebody", lines.contains { $0.hasPrefix("|cant|") && $0.contains("flinch") },
              lines.filter { $0.hasPrefix("|cant|") }.joined(separator: " "))
        check("Wood Hammer was resisted by the Fire type",
              lines.contains { $0.hasPrefix("|-resisted|") })
        check("and took its recoil",
              lines.contains { $0.contains("[from] Recoil") })
        check("the turn ended", lines.contains { $0.hasPrefix("|turn|2") }, "\(ps.turn)")
        check("and the battle is still going", !ps.ended)
    }

    /// Repeatable, which is what makes it usable for anything but watching:
    /// the same seed and the same choices are the same game.
    func testTheSameSeedIsTheSameGame() throws {
        let ps = try engine()
        let team = try ps.pack(paste: paste)
        func play() throws -> [String] {
            try ps.start(mine: ("A", team), theirs: ("B", team), seed: [7, 7, 7, 7])
            try ps.choose("p1", "team 1234")
            try ps.choose("p2", "team 1234")
            _ = try ps.since()
            for _ in 0..<3 {
                guard !ps.ended else { break }
                try ps.choose("p1", "default")
                try ps.choose("p2", "default")
            }
            return try ps.since().filter { $0.hasPrefix("|-damage|") }
        }
        let first = try play(), again = try play()
        check("three turns happened", !first.isEmpty, "\(first.count) damage lines")
        check("and happened identically the second time", first == again,
              "\(first.count) against \(again.count)")
    }
}
