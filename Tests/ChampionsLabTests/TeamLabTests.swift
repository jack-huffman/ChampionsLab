//  TeamLabTests.swift
//  That accumulated evidence is actually evidence.
//
//      swift test --filter TeamLabTests

import XCTest
@testable import ChampionsLab

final class TeamLabTests: HarnessCase {
    /// Two opponents, named — the shared fixture helper leaves every team
    /// called "New Team", and a report keyed by opponent name would fold them
    /// into one.
    @MainActor private func smallField() -> [Team] {
        var out = rawField()
        out[0].name = "Grass and Steel"
        out[1].name = "Sun and Sand"
        return out
    }

    @MainActor private func rawField() -> [Team] {
        [fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                   ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"]),
                   ("Gholdengo", "Leftovers", ["Make It Rain", "Protect"]),
                   ("Milotic", "Leftovers", ["Surf", "Protect"])]),
         fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                   ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                   ("Farigiraf", "Leftovers", ["Psychic", "Protect"]),
                   ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])])]
    }

    /// A second run covers new ground, and pooling adds up
    ///
    /// The opponent cycle is driven off a game's position in the sequence, so a
    /// run that always restarts at zero always faces the field in the same
    /// order — and a hundred games run four times would be four hundred games
    /// against whoever happens to come first. Carrying the count forward makes
    /// the second run continue around the field instead.
    ///
    /// Worth knowing, and found by this test rather than assumed: the same seed
    /// does *not* reproduce the same games. The engine searches for a wall-clock
    /// budget, so how deep it gets depends on what else the machine is doing,
    /// and two runs of the identical position can choose differently. These
    /// numbers are therefore never exactly repeatable — which is an argument for
    /// pooling many games rather than trusting any one run.
    @MainActor func testASecondRunIsNewGames() throws {
        print("\n== a second run is new games ==")
        let team = fighters([("Basculegion", "Choice Scarf", ["Wave Crash", "Aqua Jet"]),
                             ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Archaludon", "Leftovers", ["Flash Cannon", "Protect"]),
                             ("Sinistcha", "Leftovers", ["Matcha Gotcha", "Protect"])])
        let field = smallField()

        let first = TeamLab.run(team: team, against: field, rules: store.rulebook,
                                games: 6, budget: 0.008)
        let continued = TeamLab.run(team: team, against: field, rules: store.rulebook,
                                    games: 6, budget: 0.008, resumeFrom: first.games)
        print("  first \(first.wins)/\(first.games), carried on \(continued.wins)/\(continued.games)")

        // Two opponents and six games: a run that starts over meets them in the
        // same order, and one that carries on starts with the other.
        let fresh = TeamLab.run(team: team, against: field, rules: store.rulebook,
                                games: 2, budget: 0.008)
        let next = TeamLab.run(team: team, against: field, rules: store.rulebook,
                               games: 2, budget: 0.008, resumeFrom: 2)
        print("  a fresh run opens against \(fresh.against.keys.sorted())")
        print("  carrying on opens against \(next.against.keys.sorted())")
        check("carrying on meets a different part of the field",
              fresh.against.keys.sorted() != next.against.keys.sorted(),
              "\(fresh.against.keys.sorted()) against \(next.against.keys.sorted())")

        // And pooling adds up rather than overwriting.
        let pooled = first.merged(with: continued)
        print("  pooled: \(pooled.games) games over \(pooled.runs) runs, \(pooled.wins) won")
        check("the games add", pooled.games == first.games + continued.games,
              "\(pooled.games)")
        check("the wins add", pooled.wins == first.wins + continued.wins)
        check("and it remembers how many runs it took", pooled.runs == 2, "\(pooled.runs)")

        // Per-Pokémon records have to add too, or the trade ratios drift.
        for (form, record) in pooled.members {
            let a = first.members[form]?.knockouts ?? 0
            let b = continued.members[form]?.knockouts ?? 0
            check("\(form)'s knockouts add", record.knockouts == a + b,
                  "\(record.knockouts) against \(a) + \(b)")
        }

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// An edited team does not inherit the old team's record
    @MainActor func testEditingATeamRetiresItsRecord() throws {
        print("\n== an edited team starts again ==")
        var team = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Farigiraf", "Leftovers", ["Psychic", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Moonblast", "Protect"])])
        let before = LabStore.stamp(of: team)
        team.name = "A different name entirely"
        check("renaming the team changes nothing about how it plays",
              LabStore.stamp(of: team) == before)

        team.slots[0].item = "Choice Scarf"
        print("  item changed: stamp \(LabStore.stamp(of: team) == before ? "held" : "moved")")
        check("changing an item retires the record", LabStore.stamp(of: team) != before)

        var again = team
        again.slots[1].sp = [8, 0, 0, 24, 0, 24]
        check("and so does changing a spread",
              LabStore.stamp(of: again) != LabStore.stamp(of: team))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
