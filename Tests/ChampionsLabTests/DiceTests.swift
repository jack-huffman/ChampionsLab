//  DiceTests.swift
//  What a played turn rolls, and what the search averages instead.
//
//      swift test --filter DiceTests

import XCTest
@testable import ChampionsLab

final class DiceTests: HarnessCase {
    /// per-target accuracy, draining, and the move that doubles after a failure
    @MainActor func testEachTargetRollsItsOwn() throws {
print("\n== each target rolls its own ==")
    let muddy = fighters([("Politoed", "Leftovers", ["Muddy Water", "Protect"]),
                          ("Whimsicott", "Focus Sash", ["Protect"])])
    let soaked = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])])
    let muddyBoard = Board(mine: muddy, theirs: soaked, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    var oneOfTwo = 0, bothHit = 0
    for _ in 0..<400 {
        let rolled = TurnModel.resolve(muddyBoard,
            mine: Play(left: .attack(move: at(muddyBoard.mine[0], "Muddy Water"), target: 0),
                       right: .attack(move: at(muddyBoard.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(muddyBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(muddyBoard.theirs[1], "Swords Dance"), target: 0)), rolling: true)
        let hits = [rolled.theirs[0], rolled.theirs[1]].filter { $0.hp < $0.maxHP }.count
        if hits == 1 { oneOfTwo += 1 }
        if hits == 2 { bothHit += 1 }
    }
    print("  400 Muddy Waters at 85%: both hit \(bothHit), exactly one hit \(oneOfTwo) (about 102 expected)")
    check("a spread move can hit one and miss the other", oneOfTwo > 55 && oneOfTwo < 160, "\(oneOfTwo)")

    let leech = store.data.moves.values.first { $0.name == "Leech Life" }!
    print("  Leech Life gives back: \(leech.drainShare ?? 0)")
    check("draining moves are read from the text", leech.drainShare == 0.5
          && store.data.moves.values.first { $0.name == "Draining Kiss" }?.drainShare == 0.75)
    var drainBoard = Board(mine: soaked, theirs: muddy, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    drainBoard.mine[0].moves = [leech] + drainBoard.mine[0].moves
    drainBoard.mine[0].hp = drainBoard.mine[0].maxHP / 2
    let drained = TurnModel.resolve(drainBoard,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(drainBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(drainBoard.theirs[0], "Muddy Water"), target: 0),
                     right: .attack(move: 0, target: 0)))
    for line in drained.story where line.contains("drained") { print("    \(line)") }
    let drainLine = drained.story.first { $0.contains("Garchomp drained") }
    let gained = drainLine.flatMap { line in Int(line.split(separator: " ").first { Int($0) != nil } ?? "") } ?? 0
    let taken = drained.theirs[0].maxHP - drained.theirs[0].hp
    print("  Leech Life took \(taken) from Politoed and gave \(gained) back")
    // Politoed's Leftovers give some back at the end of the turn, so what it
    // shows as lost is a little under what was dealt.
    check("Leech Life restores half of what it took",
          gained > 0 && gained >= taken / 2 - 1 && gained <= taken / 2 + 10, "\(gained) back from \(taken)")

    let tantrum = store.data.moves.values.first { $0.name == "Stomping Tantrum" }!
    check("Stomping Tantrum is read as doubling after a failed move", tantrum.doublesAfterFailure)
    var tantrumBoard = Board(mine: soaked, theirs: muddy, store: store,
                             field: Field(isDoubles: true), alreadyEvolved: false)
    tantrumBoard.mine[0].moves = [tantrum] + tantrumBoard.mine[0].moves
    // Turn one: the move goes into a Protect and fails.
    let walled = TurnModel.resolve(tantrumBoard,
        mine: Play(left: .attack(move: 0, target: 1),
                   right: .attack(move: at(tantrumBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tantrumBoard.theirs[0], "Protect"), target: 0),
                     right: .protectSelf(move: at(tantrumBoard.theirs[1], "Protect"))))
    check("a move that reached nobody is remembered as failed", walled.mine[0].lastMoveFailed)
    let calm = DamageCalc.calculate(attacker: tantrumBoard.mine[0].build, defender: tantrumBoard.theirs[1].build,
                                    move: tantrum, field: tantrumBoard.field).maxDamage
    var angry = walled.mine[0].build
    angry.lastMoveFailed = true
    let doubled = DamageCalc.calculate(attacker: angry, defender: walled.theirs[1].build,
                                       move: tantrum, field: walled.field).maxDamage
    print("  Stomping Tantrum: \(calm) normally, \(doubled) after a failed move")
    check("and it hits twice as hard the turn after", doubled >= calm * 2 - 2 && doubled <= calm * 2 + 2, "\(calm) vs \(doubled)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// weather and terrain on a five-turn clock
    @MainActor func testTheFieldRunsOut() throws {
print("\n== the field runs out ==")
    var clock = Board(mine: muddy, theirs: soaked, store: store,
                      field: Field(isDoubles: true), alreadyEvolved: false)
    clock.mine[0].build.ability = "Drizzle"
    clock.sendOutLeads()
    check("weather set at the start has five turns on the clock", clock.field.weather == .rain && clock.weatherTurns == 5,
          "\(clock.field.weather) \(clock.weatherTurns)")
    var running = clock
    var endedAt = 0
    for turn in 1...6 where running.field.weather == .rain {
        running = TurnModel.resolve(running,
            mine: Play(left: .attack(move: at(running.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(running.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(running.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(running.theirs[1], "Protect"), target: 0)))
        if running.field.weather == .none { endedAt = turn }
    }
    print("  the rain stopped at the end of turn \(endedAt)")
    check("and it stops at the end of the fifth turn", endedAt == 5 && running.story.contains { $0.contains("rain stopped") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
