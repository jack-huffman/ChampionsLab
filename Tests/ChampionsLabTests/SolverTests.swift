//  SolverTests.swift
//  The turn as a matrix game: the equilibrium, the reads, and the lines it names.
//
//      swift test --filter SolverTests

import XCTest
@testable import ChampionsLab

final class SolverTests: HarnessCase {
    /// the solver, a turn played out, the reads, and switching in
    @MainActor func testSolverAndReads() throws {
print("\n== the solver ==")
    func mix(_ m: [[Double]]) -> (row: [Double], column: [Double], value: Double) {
        TurnGame.equilibrium(m, iterations: 20000)
    }
    let pennies = mix([[1, -1], [-1, 1]])
    print("  matching pennies: \(pennies.row.map { String(format: "%.2f", $0) }.joined(separator: "/"))")
    check("matching pennies is a coin flip",
          pennies.row.allSatisfy { abs($0 - 0.5) < 0.02 } && abs(pennies.value) < 0.02)
    let rps = mix([[0, -1, 1], [1, 0, -1], [-1, 1, 0]])
    print("  rock paper scissors: \(rps.row.map { String(format: "%.2f", $0) }.joined(separator: "/"))")
    check("rock paper scissors is even thirds",
          rps.row.allSatisfy { abs($0 - 1.0 / 3) < 0.02 } && abs(rps.value) < 0.02)
    let dominant = mix([[2, 3], [0, 1]])
    check("a dominant option is taken every time",
          dominant.row[0] > 0.98 && abs(dominant.value - 2) < 0.05,
          "\(dominant.row[0])")
    let saddle = mix([[4, 2], [3, 1]])
    check("a saddle point is a pure strategy both ways",
          saddle.row[0] > 0.98 && saddle.column[1] > 0.98 && abs(saddle.value - 2) < 0.05)
    check("an empty matrix does not crash", TurnGame.equilibrium([]).value == 0)

print("\n== a turn played out ==")
    if let opponent = store.data.metaTeams.first(where: { $0.name == "Big Six" }),
       let mineTeam = store.teams.first(where: { $0.slots.count >= 4 }) {
        let start = Board(mine: mineTeam, theirs: store.opponentTeam(opponent), rules: store.rulebook)
        check("both sides have two out and the rest behind",
              start.mine.count >= 2 && start.theirs.count >= 2)
        check("everyone starts at full health",
              start.mine.allSatisfy { $0.hp == $0.maxHP })

        // Protect has to actually refuse the damage.
        let attackers = start.theirs.prefix(2)
        if let hitIndex = start.mine[0].moves.firstIndex(where: \.isDamaging),
           let guardIndex = start.theirs[0].moves.firstIndex(where: {
               DuelEngine.protectMoves.contains($0.name) }) {
            let openTurn = TurnModel.resolve(
                start, mine: Play(left: .attack(move: hitIndex, target: 0),
                                  right: .attack(move: hitIndex, target: 0)),
                theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)))
            let guardedTurn = TurnModel.resolve(
                start, mine: Play(left: .attack(move: hitIndex, target: 0),
                                  right: .attack(move: hitIndex, target: 0)),
                theirs: Play(left: .protectSelf(move: guardIndex),
                             right: .attack(move: 0, target: 0)))
            print("  their lead takes \(start.theirs[0].maxHP - openTurn.theirs[0].hp) open, "
                  + "\(start.theirs[0].maxHP - guardedTurn.theirs[0].hp) behind Protect")
            check("Protect refuses the damage",
                  guardedTurn.theirs[0].hp > openTurn.theirs[0].hp
                    || openTurn.theirs[0].hp == start.theirs[0].maxHP,
                  "\(guardedTurn.theirs[0].hp) vs \(openTurn.theirs[0].hp)")
        }
        _ = attackers

        let game = TurnGame(board: start)
        // The first solve pays for warming the damage calculator's caches, and
        // measuring that measures the caches rather than the search. What the
        // interface actually costs is the second one — and it takes the
        // yielding path anyway, which is checked for stalls in tools/hitch.sh.
        _ = game.solve()
        let started = Date()
        let solution = game.solve()
        let took = Date().timeIntervalSince(started) * 1000
        print(String(format: "  %d x %d matrix in %.0f ms, turn worth %+.3f",
                     solution.myPlays.count, solution.theirPlays.count, took, solution.value))
        check("the matrix is the size the play lists say",
              solution.payoff.count == solution.myPlays.count
                && solution.payoff.allSatisfy { $0.count == solution.theirPlays.count })
        check("every payoff is a real number",
              solution.payoff.allSatisfy { $0.allSatisfy { $0.isFinite } })
        check("both mixes are probabilities",
              abs(solution.myMix.reduce(0, +) - 1) < 0.01
                && abs(solution.theirMix.reduce(0, +) - 1) < 0.01)
        // Not a speed assertion: this harness is built without optimisation, so
        // a millisecond budget here measures the compiler rather than the
        // search. tools/hitch.sh owns that, and builds with -O. This only
        // catches a blow-up in the size of the problem.
        check("the search has not blown up in size", took < 5000,
              String(format: "%.0f ms unoptimised", took))

        // A one-turn model left alone tells both sides to double-protect for
        // ever, because declining to attack costs nothing inside one turn.
        var doubleProtect = 0.0
        for (index, play) in solution.theirPlays.enumerated()
        where play.left.isProtect && play.right.isProtect {
            doubleProtect += solution.theirMix[index]
        }
        print(String(format: "  they double-protect %.0f%% of the time", doubleProtect * 100))
        check("giving up the turn is priced, so double Protect is not a free win",
              doubleProtect < 0.6, String(format: "%.0f%%", doubleProtect * 100))

        for line in game.read(solution).prefix(4) { print("  · \(line)") }

        // -- reading them ---------------------------------------------------
        //
        // Equilibrium is the mix nobody can exploit, which is the right answer
        // when you know nothing. Reading someone means leaving it on purpose,
        // and the question is what that is worth against what it risks.

print("\n== reading them ==")
        let information = game.tells(solution)
        print(String(format: "  knowing their choice in advance is worth %+.3f", information.value))
        check("perfect information is never a loss", information.value >= -0.001,
              String(format: "%.3f", information.value))
        check("every tell is at least as good as playing blind",
              information.top.allSatisfy { $0.worthKnowing >= -0.001 })
        check("tells are ordered by what they are worth",
              zip(information.top, information.top.dropFirst())
                .allSatisfy { $0.worthKnowing >= $1.worthKnowing })
        for tell in information.top.prefix(2) {
            print(String(format: "    %-44s %3.0f%%, worth %+.2f",
                         (tell.label as NSString).utf8String!,
                         tell.likelihood * 100, tell.worthKnowing))
        }

        // A read at no strength is the equilibrium, and at full strength it is
        // a different distribution that still adds to one.
        let none = game.mix(solution, assuming: .protectsOften, strength: 0)
        check("believing nothing leaves the mix alone",
              zip(none, solution.theirMix).allSatisfy { abs($0 - $1) < 0.001 })
        for read in TurnGame.Read.allCases {
            let tilted = game.mix(solution, assuming: read, strength: 0.8)
            check("\(read.shorthand) still adds up to a distribution",
                  abs(tilted.reduce(0, +) - 1) < 0.01, "\(tilted.reduce(0, +))")
        }
        // Punishing a tendency has to beat playing the mix against it, or it is
        // not a punishment.
        let found = game.exploits(solution)
        print("  exploits found: \(found.count)")
        check("every exploit beats the mix against the tendency it answers",
              found.allSatisfy { $0.against >= $0.equilibrium - 0.001 })
        check("and each names a line you could actually pick",
              found.allSatisfy { !$0.label.isEmpty && $0.label != "—" })
        check("they are ordered by what they gain",
              zip(found, found.dropFirst()).allSatisfy { $0.gain >= $1.gain })
        for exploit in found.prefix(3) {
            print(String(format: "    %-32s gain %+.2f risk %.2f  %@",
                         (exploit.read.shorthand as NSString).utf8String!,
                         exploit.gain, exploit.cost,
                         (exploit.worthIt ? "take it" : "not yet") as NSString))
        }
        for line in game.readingNotes(solution) { print("  · \(line)") }

        // -- switching in ---------------------------------------------------
        //
        // A Pokemon that switches in takes a free hit, because it does not act
        // that turn, and arriving is itself an action: Intimidate, and the
        // weather or terrain a setter brings back with it.

print("\n== switching in ==")
        if start.mine.count > 2, let hit = start.theirs[0].moves.firstIndex(where: \.isDamaging) {
            let stayed = TurnModel.resolve(
                start, mine: Play(left: .attack(move: 0, target: 0),
                                  right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: hit, target: 0),
                             right: .attack(move: 0, target: 1)))
            let swapped = TurnModel.resolve(
                start, mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: hit, target: 0),
                             right: .attack(move: 0, target: 1)))
            print("  the one that came in is \(swapped.mine[0].build.form.formLabel), "
                  + "on \(swapped.mine[0].hp) of \(swapped.mine[0].maxHP)")
            check("the Pokemon that switched in is the one that took the hit",
                  swapped.mine[0].build.form.id != stayed.mine[0].build.form.id)
            check("and it took a real one, because it does not act on the way in",
                  swapped.mine[0].hp < swapped.mine[0].maxHP,
                  "\(swapped.mine[0].hp)/\(swapped.mine[0].maxHP)")
        }
        // A weather setter coming in takes the field back.
        if let pelipper = store.form(named: "Pelipper") {
            var rainTeam = Team(); rainTeam.format = "doubles"
            var lead = TeamSlot(formID: form("Garchomp").id)
            lead.ability = "Rough Skin"
            var second = TeamSlot(formID: form("Incineroar").id)
            second.ability = "Intimidate"
            var bench = TeamSlot(formID: pelipper.id)
            bench.ability = "Drizzle"
            rainTeam.slots = [lead, second, bench]
            let dry = Board(mine: rainTeam, theirs: store.opponentTeam(opponent), rules: store.rulebook)
            check("the field starts clear", dry.field.weather == .none)
            let wet = TurnModel.resolve(dry,
                mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: 0, target: 0),
                             right: .attack(move: 0, target: 1)))
            print("  after pivoting Pelipper in, the weather is \(wet.field.weather.rawValue)")
            check("a Drizzle switch-in takes the field back", wet.field.weather == .rain,
                  wet.field.weather.rawValue)
        }
    }

    // -- Mega Evolution, and the order of it --------------------------------
    //
    // It happens after the switches and before any move, fastest first, and the
    // order is not decoration: an ability that fires on evolving fires in that
    // order, so when two Megas both bring weather the slower one evolves second
    // and its weather is the one left on the field.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
