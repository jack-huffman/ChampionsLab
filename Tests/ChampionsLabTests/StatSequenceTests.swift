//  StatSequenceTests.swift
//  A drop and the ability that answers it are two things, recorded in order
//  and shown one after the other.

import XCTest
@testable import ChampionsLab

final class StatSequenceTests: HarnessCase {
    @MainActor func testIntimidateThenDefiantAreTwoPhases() {
        var mine = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"])])
        mine.slots[0].ability = "Intimidate"
        var theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave"]),
                               ("Milotic", "Leftovers", ["Scald"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"])])
        theirs.slots[0].ability = "Defiant"
        theirs.slots[1].ability = "Competitive"
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.beginStep()
        board.landed(mine: true, slot: 0)
        board.closeStep()
        guard let step = board.steps.last else { return check("a step was recorded", false) }

        let stats = step.events.compactMap { event -> (Bool, Int, Int, String?)? in
            if case .stat(let m, let s, let stat, let delta, let cause) = event { return (m, s, delta, cause) }
            return nil
        }
        // Each target: its drop, then its answer, in that order.
        for slot in 0..<2 {
            let own = stats.filter { !$0.0 && $0.1 == slot }
            check("slot \(slot) fell first", own.first?.2 ?? 0 < 0, "\(own)")
            check("slot \(slot) then answered, for a named cause",
                  own.dropFirst().first.map { $0.2 > 0 && ["Defiant", "Competitive"].contains($0.3 ?? "") } == true, "\(own)")
        }

        let phases = TurnPlayback().phases(of: step)
        check("several causes, not one", phases.count >= 3, "\(phases.count)")
        check("the first is the Intimidate and a drop",
              phases[0].cause == "Intimidate"
                && phases[0].boosts.values.allSatisfy { $0.allSatisfy { $0.delta < 0 } }
                && phases[0].abilities[Seat(mine: true, slot: 0)] == ["Intimidate"],
              "\(phases[0])")
        check("no phase mixes a rise with a fall",
              phases.allSatisfy { phase in
                  let deltas = phase.boosts.values.flatMap { $0.map(\.delta) }
                  return deltas.allSatisfy { $0 > 0 } || deltas.allSatisfy { $0 < 0 }
              })
        check("every rise is an answer with its name",
              phases.filter { $0.boosts.values.contains { $0.contains { $0.delta > 0 } } }
                .allSatisfy { ["Defiant", "Competitive"].contains($0.cause ?? "") },
              "\(phases.map(\.cause))")
        check("every fall is the Intimidate's",
              phases.filter { $0.boosts.values.contains { $0.contains { $0.delta < 0 } } }
                .allSatisfy { $0.cause == "Intimidate" && $0.abilities[Seat(mine: true, slot: 0)] == ["Intimidate"] },
              "\(phases.map(\.cause))")
    }

    @MainActor func testACloseCombatsDropsAndAScaldsBurnAreTheirOwnBeats() {
        let mine = fighters([("Sneasler", "Grassy Seed", ["Close Combat", "Protect"]),
                             ("Milotic", "Leftovers", ["Will-O-Wisp", "Scald"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave"]),
                               ("Garchomp", "Life Orb", ["Earthquake"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.theirs[0].build.ability = "Supreme Overlord"
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attack(move: at(board.mine[0], "Close Combat"), target: 0),
                                               right: .attack(move: at(board.mine[1], "Will-O-Wisp"), target: 1)),
                                    theirs: Play(left: .pass, right: .pass))
        let combat = out.steps.first { $0.action?.move == "Close Combat" }
        let phases = combat.map { TurnPlayback().phases(of: $0) } ?? []
        check("Close Combat's drops are a phase of their own",
              phases.contains { $0.boosts[Seat(mine: true, slot: 0)]?.allSatisfy { $0.delta < 0 } == true }, "\(phases)")
        let wisp = out.steps.first { $0.action?.move == "Will-O-Wisp" }
        let burn = wisp.map { TurnPlayback().phases(of: $0) } ?? []
        check("the burn is a beat of its own",
              burn.contains { $0.statuses[Seat(mine: false, slot: 1)] == .burn }, "\(burn)")
        check("and is on the step's record",
              wisp?.events.contains(.status(mine: false, slot: 1, ailment: .burn)) == true)
    }

    @MainActor func testASwordsDanceIsOnePhase() {
        let mine = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: at(board.mine[0], "Swords Dance"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        let step = out.steps.first { $0.action?.move == "Swords Dance" }
        let phases = step.map { TurnPlayback().phases(of: $0) } ?? []
        check("one phase", phases.count == 1, "\(phases.count)")
        check("Attack up two", phases.first?.boosts[Seat(mine: true, slot: 0)] == [TurnPlayback.StatChange(stat: Stat.attack.rawValue, delta: 2)],
              "\(phases.first?.boosts ?? [:])")
    }
}
