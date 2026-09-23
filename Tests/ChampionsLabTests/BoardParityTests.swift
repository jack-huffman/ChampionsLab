//  BoardParityTests.swift
//  The board is a mirror of the simulator, and a mirror nothing checks is
//  worth nothing.
//
//      swift test --filter BoardParityTests
//
//  Every number on the battle screen is read off `Board`, and `Board` is
//  rebuilt from the protocol lines Showdown emits. Nothing was comparing the
//  two. A Pokemon that set up, pivoted out and came back kept its stat stages
//  on the board while the sim -- correctly -- cleared them, so a card read +2
//  over a Pokemon the engine was resolving at nothing: every number on screen
//  agreeing with itself and none of them agreeing with the damage.
//
//  `PS.save()` is the sim's own state, which is the only place its view of a
//  Pokemon's stages and volatiles can be read from out here.

import XCTest
@testable import ChampionsLab

@MainActor
final class BoardParityTests: HarnessCase {
    /// The sim's actives, by side, as (species, hp, stages).
    private struct Seen {
        var species: String
        var hp: Int
        var boosts: [String: Int]
    }

    private func simActives(_ side: Int) throws -> [Seen] {
        guard let json = try ShowdownEngine.shared.save(),
              let data = json.data(using: .utf8),
              let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sides = top["sides"] as? [[String: Any]], sides.indices.contains(side)
        else { return [] }
        let pokemon = sides[side]["pokemon"] as? [[String: Any]] ?? []
        // `isActive` is the sim's own flag, and the order of `pokemon` is the
        // side's own order, which is not the board's.
        return pokemon.filter { ($0["isActive"] as? Bool) == true }.map {
            // `species` serialises as a reference -- "[Species:ceruledge]" --
            // so the name comes off `details`, which is the same string the
            // protocol puts in a |switch| line: "Ceruledge, L50, M".
            let details = ($0["details"] as? String) ?? ""
            let named = details.split(separator: ",").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? "?"
            return Seen(species: named,
                        hp: ($0["hp"] as? Int) ?? -1,
                        boosts: ($0["boosts"] as? [String: Int]) ?? [:])
        }
    }

    private static let stageOf: [String: Stat] = [
        "atk": .attack, "def": .defense, "spa": .spAttack, "spd": .spDefense, "spe": .speed,
    ]

    func testTheBoardAgreesWithTheSimulatorThroughAGameWithSwitches() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let game = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [9, 9, 9, 9])
        var checked = 0, switches = 0
        for turn in 0..<10 where !ShowdownEngine.shared.ended {
            // Switch somebody every third turn, because the divergence this
            // exists for only appears when a Pokemon leaves and comes back.
            let pivot = turn % 3 == 2
            if pivot { switches += 1 }
            let play = Play(left: pivot ? .swap(to: 2) : .attack(move: 0, target: 0),
                            right: .attack(move: 0, target: 1))
            guard (try? game.play(mine: play, theirs: play)) != nil else {
                // An illegal choice is not what this test is about.
                _ = try? game.play(mine: Play(left: .attack(move: 0, target: 0),
                                              right: .attack(move: 0, target: 1)),
                                   theirs: Play(left: .attack(move: 0, target: 0),
                                                right: .attack(move: 0, target: 1)))
                continue
            }
            for (side, mine) in [(0, true), (1, false)] {
                let sim = try simActives(side)
                let ours = (mine ? game.board.mine : game.board.theirs)
                    .prefix(game.board.activeCount)
                guard sim.count == ours.count else { continue }
                for seen in sim {
                    // Match by species: the board keeps its actives at the
                    // front and the sim keeps the side's own order.
                    guard let fighter = ours.first(where: {
                        $0.build.form.showdown == seen.species
                            || $0.build.form.formLabel == seen.species
                    }) else { continue }
                    checked += 1
                    check("turn \(game.turn): \(seen.species) HP",
                          fighter.hp == seen.hp, "board \(fighter.hp) vs sim \(seen.hp)")
                    for (key, stat) in Self.stageOf {
                        let simStage = seen.boosts[key] ?? 0
                        let ourStage = fighter.build.boosts[stat.rawValue]
                        check("turn \(game.turn): \(seen.species) \(key)",
                              ourStage == simStage, "board \(ourStage) vs sim \(simStage)")
                    }
                }
            }
        }
        check("the game ran with switches in it", switches > 0 && checked > 0,
              "\(switches) switches, \(checked) Pokemon compared")
    }
}
