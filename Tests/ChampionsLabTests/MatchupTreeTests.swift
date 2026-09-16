//  MatchupTreeTests.swift
//  That the tree is a tree, and that it finishes.
//
//      swift test --filter MatchupTreeTests

import XCTest
@testable import ChampionsLab

final class MatchupTreeTests: HarnessCase {
    @MainActor private var attackers: Team {
        var out = fighters([
            ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Knock Off", "Protect"]),
            ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Encore", "Protect"]),
            ("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Rock Slide", "Protect"]),
            ("Rillaboom", "Assault Vest", ["Wood Hammer", "Grassy Glide", "U-turn", "Fake Out"])])
        out.name = "Fake Out and Tailwind"
        return out
    }

    @MainActor private var sunTeam: Team {
        var out = fighters([
            ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Air Slash", "Protect"]),
            ("Farigiraf", "Leftovers", ["Psychic", "Trick Room", "Helping Hand", "Protect"]),
            ("Kingambit", "Leftovers", ["Iron Head", "Sucker Punch", "Swords Dance", "Protect"]),
            ("Milotic", "Leftovers", ["Surf", "Ice Beam", "Recover", "Protect"])])
        out.name = "Sun and Room"
        return out
    }

    /// the shape of it, cheaply
    @MainActor func testTheTreeIsATree() throws {
print("\n== the tree ==")
        let started = Date()
        let report = MatchupTree.explore(mine: attackers, theirs: sunTeam,
                                         rules: store.rulebook, depth: 2)
        print(String(format: "  depth 2: %d nodes, %d leaves, %.1fs",
                     report.nodes, report.leaves, Date().timeIntervalSince(started)))

        check("the lead is the first two slots",
              report.myLead == ["Incineroar", "Whimsicott"], "\(report.myLead)")
        check("turn one is enumerated both ways",
              report.matrix.mine.count > 8 && report.matrix.theirs.count > 8,
              "\(report.matrix.mine.count) x \(report.matrix.theirs.count)")
        check("the matrix is the right shape",
              report.matrix.winChance.count == report.matrix.mine.count
                  && report.matrix.winChance.allSatisfy { $0.count == report.matrix.theirs.count })
        check("every cell is a chance", report.matrix.winChance.allSatisfy {
            $0.allSatisfy { $0 >= 0 && $0 <= 1 } })
        check("the mixes are distributions",
              abs(report.matrix.myMix.reduce(0, +) - 1) < 0.01
                  && abs(report.matrix.theirMix.reduce(0, +) - 1) < 0.01,
              "\(report.matrix.myMix.reduce(0, +))")

        check("it reached leaves", report.leaves > 0, "\(report.leaves)")
        check("every line is as deep as asked, or decided early",
              report.paths.allSatisfy { $0.steps.count == 2 || $0.decided || $0.steps.count < 2 },
              "\(Set(report.paths.map(\.steps.count)).sorted())")
        check("the best line beats the worst",
              (report.paths.first?.estimate ?? 0) > (report.paths.last?.estimate ?? 1),
              String(format: "%.3f vs %.3f",
                     report.paths.first?.estimate ?? 0, report.paths.last?.estimate ?? 0))
        check("lines are ranked best first",
              zip(report.paths, report.paths.dropFirst()).allSatisfy { $0.estimate >= $1.estimate })

        check("there is a decision recorded for every internal node",
              report.decisions.count == report.nodes,
              "\(report.decisions.count) against \(report.nodes)")
        check("each decision ranks its options",
              report.decisions.allSatisfy { decision in
                  zip(decision.options, decision.options.dropFirst())
                      .allSatisfy { $0.winChance >= $1.winChance } })
        check("the widest turn has real distance in it",
              (report.pivotal.first?.swing ?? 0) > 0.02,
              String(format: "%.3f", report.pivotal.first?.swing ?? 0))
        check("swing is the full drop, not the gap at the top",
              report.decisions.allSatisfy { $0.swing >= $0.margin })

print("\n  what it found")
        for path in report.best.prefix(3) {
            print(String(format: "    %.0f%%  ", path.estimate * 100)
                  + path.steps.map(\.mine).joined(separator: "  then  "))
        }
        print("    ...")
        for path in report.worst.prefix(2) {
            print(String(format: "    %.0f%%  ", path.estimate * 100)
                  + path.steps.map(\.mine).joined(separator: "  then  "))
        }
        if let pivot = report.pivotal.first {
            print("\n  the turn most worth getting right (turn \(pivot.turn)):")
            for option in pivot.options.prefix(3) {
                print(String(format: "    %.0f%%  %@", option.winChance * 100, option.play))
            }
            print(String(format: "    worst option %.0f%%  (swing %.0f points)",
                         (pivot.options.last?.winChance ?? 0) * 100, pivot.swing * 100))
        }

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }

    /// stopping works, because a search nobody can stop is a search nobody runs
    @MainActor func testItCanBeStopped() throws {
print("\n== stopping ==")
        var seen = 0
        let report = MatchupTree.explore(mine: attackers, theirs: sunTeam,
                                         rules: store.rulebook, depth: 3,
                                         progress: { _ in seen += 1 },
                                         shouldStop: { seen > 2 })
        check("it gave up early", report.nodes < 100, "\(report.nodes)")
        check("and still returned something readable", report.matrix.mine.count > 0)
        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
