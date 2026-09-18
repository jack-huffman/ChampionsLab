//  StaleReadingTests.swift
//  What is worked out from something that changes has to be worked out
//  again when it does.

import XCTest
@testable import ChampionsLab

final class StaleReadingTests: HarnessCase {
    @MainActor func testATeamsStampFollowsItsSlots() {
        var team = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Knock Off"]),
                             ("Garchomp", "Life Orb", ["Earthquake"])])
        let first = LabStore.stamp(of: team)
        team.slots[0].item = "Assault Vest"
        check("an item changes it", LabStore.stamp(of: team) != first)
        var swapped = team
        swapped.slots[1] = TeamSlot(formID: form("Rillaboom").id)
        check("a different Pokemon changes it", LabStore.stamp(of: swapped) != LabStore.stamp(of: team))
        check("and the same team stamps the same twice",
              LabStore.stamp(of: team) == LabStore.stamp(of: team))
    }

    @MainActor func testAFreshUsageTableRebuildsWhatItDecided() {
        let format = "doubles"
        let before = store.ladderTeams(format: format).map { $0.team.slots.map(\.formID) }
        check("the ladder has teams to offer", !before.isEmpty)
        let benchmarks = store.speedBenchmarks(format: format)

        // A table with one Pokemon on it, which cannot build the same ladder.
        let entry = store.data.usage.first!
        let thin = UsageEntry(name: entry.name, tier: "S", usage: 90, projected: false,
                              formats: ["doubles"], role: entry.role,
                              commonItems: entry.commonItems, keyMoves: entry.keyMoves,
                              why: entry.why, winrate: nil, wins: nil, losses: nil,
                              moveUsage: nil, itemUsage: nil, abilityUsage: nil, teammates: nil)
        store.apply(UsageFeed.Snapshot(format: "test", formatName: "test", source: "test",
                                       license: "test", generated: "test", fetched: Date(),
                                       entries: [thin], dropped: []))
        let after = store.ladderTeams(format: format).map { $0.team.slots.map(\.formID) }
        check("the ladder was worked out again", after != before, "\(after.count) against \(before.count)")
        check("and so were the speed benchmarks",
              store.speedBenchmarks(format: format) != benchmarks
                || store.speedBenchmarks(format: format).isEmpty)

        store.revertToBundledUsage()
        check("and putting the table back puts the ladder back",
              store.ladderTeams(format: format).map { $0.team.slots.map(\.formID) } == before)
    }
}
