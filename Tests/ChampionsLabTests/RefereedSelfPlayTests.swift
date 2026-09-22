//  RefereedSelfPlayTests.swift
//  A self-played game, refereed by Showdown.
//
//      swift test --filter RefereedSelfPlayTests
//
//  The lab and the duel play thousands of games to measure how well an engine
//  chooses. What they measure is only as good as who is refereeing, and the
//  cost of a better referee barely shows: a turn resolved by the simulator is
//  a few milliseconds against a search that spends tens of them deciding what
//  to do with it.

import XCTest
@testable import ChampionsLab

@MainActor
final class RefereedSelfPlayTests: HarnessCase {
    func testAGamePlaysThroughToAResultWithShowdownRefereeing() throws {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let seat = SelfPlay.Seat(engine: BattleEngine(rules: store.rulebook,
                                                      nodes: BattleEngine.Nodes.turn),
                                 branchedRolls: 1)
        let started = Date()
        let ledger = SelfPlay.playLogged(
            mine: ladder[0].team, theirs: ladder[1].team, rules: store.rulebook,
            forMine: seat, forTheirs: seat, limit: 20,
            dice: TeamLab.SplitMix(seed: 20260922),
            refereedBy: store.data, logging: false)
        let took = Date().timeIntervalSince(started)
        print(String(format: "  %d turns in %.0f ms, winner %@",
                     ledger.turns, took * 1000, String(describing: ledger.winner)))
        check("the game got somewhere", ledger.turns > 1, "\(ledger.turns) turns")
        check("and it did not take all day", took < 30, String(format: "%.1f s", took))
    }

    /// Without a dataset it is the model refereeing, exactly as before, so
    /// nothing that already used this is changed by the option existing.
    func testWithoutADatasetItIsStillTheModel() throws {
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let seat = SelfPlay.Seat(engine: BattleEngine(rules: store.rulebook,
                                                      nodes: BattleEngine.Nodes.turn),
                                 branchedRolls: 1)
        let ledger = SelfPlay.playLogged(
            mine: ladder[0].team, theirs: ladder[1].team, rules: store.rulebook,
            forMine: seat, forTheirs: seat, limit: 12,
            dice: TeamLab.SplitMix(seed: 7), logging: false)
        check("the model played it out", ledger.turns > 1, "\(ledger.turns) turns")
    }
}
