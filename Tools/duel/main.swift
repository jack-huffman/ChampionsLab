//  Tools/duel/main.swift
//  Two engines, one game, played to the end. Repeat until the answer is real.
//
//      ./Tools/duel.sh                       100 games, current settings both sides
//      ./Tools/duel.sh --games 400           more games, tighter answer
//      ./Tools/duel.sh --rolls 1,0           branch one coin flip against none
//      ./Tools/duel.sh --budget 0.5,0.15     half a second against a seventh
//
//  Why this exists.
//
//  Every other check in this project measures something other than playing
//  strength. `make test` says a rule fires. `make coverage` says a rule exists.
//  `make accuracy` predicts who wins from two team lists and never watches a
//  turn — it reads 5.3 points whatever the battle model does, which was found
//  the hard way while trying to decide how many dice rolls the search should
//  branch on.
//
//  So there was no way to answer the only question that matters about a change
//  to the turn model: does the engine play better now? This answers it the way
//  the question deserves — by playing.
//
//  How it is kept fair.
//
//  Teams are drawn from the real usage table, and every matchup is played
//  twice with the *engines* swapped between the chairs and everything else —
//  the teams, the dice, the seat that wins speed ties — held identical. Two
//  identical engines therefore split every pair exactly, and a lucky draw
//  cannot help one of them.
//  The dice are seeded per game and the same seed is used for the mirror, so
//  the two halves of a pair face the same draw *and* the same luck: the same
//  damage rolls, the same flinches, the same misses. What is left is the
//  engines.

import AppKit
import Foundation

// MARK: - Repeatable dice

/// A small seeded generator, so a run can be repeated exactly.
///
/// The system generator cannot be seeded, and an unrepeatable evaluation is
/// one nobody can check.
struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - What is being compared

struct Side {
    var name: String
    var engine: BattleEngine
    var branchedRolls: Int
}

func argument(_ flag: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: flag),
          at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

func pair(_ flag: String, _ fallback: (Double, Double)) -> (Double, Double) {
    guard let raw = argument(flag) else { return fallback }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { return fallback }
    return (parts[0], parts[1])
}

@MainActor func run() {
    let store = Store.shared
    if let error = store.loadError { print("dataset error: \(error)"); exit(1) }
    let rules = store.rulebook

    let games = Int(argument("--games") ?? "") ?? 100
    let budgets = pair("--nodes", (Double(BattleEngine.Nodes.duel), Double(BattleEngine.Nodes.duel)))
    let rolls = pair("--rolls", (Double(Dice.branchedRolls), Double(Dice.branchedRolls)))
    let seed = UInt64(argument("--seed") ?? "") ?? 20260915

    var a = Side(name: "A", engine: BattleEngine(rules: rules, nodes: Int(budgets.0)),
                 branchedRolls: Int(rolls.0))
    var b = Side(name: "B", engine: BattleEngine(rules: rules, nodes: Int(budgets.1)),
                 branchedRolls: Int(rolls.1))
    a.name = "A  \(Int(budgets.0)) positions a turn, rolls \(Int(rolls.0))"
    b.name = "B  \(Int(budgets.1)) positions a turn, rolls \(Int(rolls.1))"

    print("== two engines, \(games) games ==\n")
    print("  \(a.name)")
    print("  \(b.name)\n")
    if budgets.0 == budgets.1 && rolls.0 == rolls.1 {
        print("  Both sides are set the same, so this measures the noise floor")
        print("  rather than a difference. Anything far from even is a bug in")
        print("  the harness, not a finding.\n")
    }

    // The lists people actually registered, with the items, abilities and
    // movesets they chose. A team drawn at random from the usage table plays a
    // damage race, and a damage race is a bad place to measure an engine from.
    let pool = SelfPlay.teams(from: store.data, rules: rules)
    guard pool.count >= 4 else { print("  not enough registered teams to draw from"); exit(1) }
    print("  drawing from \(pool.count) registered teams\n")

    var wins = (a: 0, b: 0)
    var draws = 0
    var turnsPlayed = 0
    // The statistic that matters for a paired design: a pair where one engine
    // took both halves of the same game is evidence, and a pair that split is
    // the two of them agreeing.
    var sweeps = (a: 0, b: 0)
    var split = 0
    var dice = Seeded(seed: seed)

    for game in 0..<games {
        // One draw, played twice with the sides swapped. The same seed both
        // times, so the pair faces the same luck and only the seating differs.
        let gameSeed = dice.next()
        var picker = Seeded(seed: gameSeed)
        let left = pool.randomElement(using: &picker) ?? pool[0]
        var right = pool.randomElement(using: &picker) ?? pool[0]
        // Two different lists, or the mirror teaches nothing.
        var tries = 0
        while right.id == left.id, tries < 20 {
            right = pool.randomElement(using: &picker) ?? pool[0]
            tries += 1
        }

        // The same two teams both times, the same dice both times, and only
        // the engines change chairs.
        //
        // Swapping the *teams* instead, which is what this did first, meant
        // each engine kept the same team in both halves — so the draw never
        // cancelled and a strong team simply handed its engine both games. It
        // showed up as two identical engines going 7-1 on four pairs. This way
        // a pair of identical engines splits every pair exactly, and what is
        // left to measure is the only thing that differs.
        //
        // It cancels the seat as well as the draw: a speed tie is broken in
        // favour of whoever is sitting in the near chair, and each engine sits
        // there once.
        var tookIt = (a: 0, b: 0)
        for swapped in [false, true] {
            let near = swapped ? b : a
            let far = swapped ? a : b
            let result = SelfPlay.play(
                mine: left, theirs: right, rules: rules,
                forMine: SelfPlay.Seat(engine: near.engine, branchedRolls: near.branchedRolls),
                forTheirs: SelfPlay.Seat(engine: far.engine, branchedRolls: far.branchedRolls),
                dice: Seeded(seed: gameSeed))
            turnsPlayed += result.turns
            switch result.winner {
            case .mine:   if swapped { wins.b += 1; tookIt.b += 1 } else { wins.a += 1; tookIt.a += 1 }
            case .theirs: if swapped { wins.a += 1; tookIt.a += 1 } else { wins.b += 1; tookIt.b += 1 }
            case .none:   draws += 1
            }
        }
        if tookIt.a == 2 { sweeps.a += 1 } else if tookIt.b == 2 { sweeps.b += 1 }
        else if tookIt.a == 1 && tookIt.b == 1 { split += 1 }
        if (game + 1) % 10 == 0 {
            FileHandle.standardError.write(
                "  \(game + 1)/\(games): A \(wins.a), B \(wins.b), drawn \(draws)\n"
                    .data(using: .utf8)!)
        }
    }

    let decided = wins.a + wins.b
    print("  A won \(wins.a), B won \(wins.b), \(draws) went the distance")
    guard decided > 0 else { print("\n  Nothing was decided; every game timed out."); return }
    print(String(format: "  %.1f turns per game on average",
                 Double(turnsPlayed) / Double(games * 2)))
    print()

    // Because everything except the engines is held identical across a pair,
    // two identical engines split every pair. So the pairs that did *not*
    // split are the whole of the evidence, and the ones that did carry none.
    let telling = sweeps.a + sweeps.b
    print("  Of \(games) pairs: \(split) split, A took both in \(sweeps.a), B took both in \(sweeps.b)")
    guard telling > 0 else {
        print("\n  Every pair split. On these games the two engines are")
        print("  indistinguishable — which is the right answer when nothing differs.")
        return
    }
    let share = Double(sweeps.a) / Double(telling)
    // Two standard errors on a coin flip of the pairs that carried evidence.
    let error = 2 * (0.5 / Double(telling).squareRoot())
    print(String(format: "  Of the %d pairs that tell us anything, A took %.0f%%, give or take %.0f",
                 telling, share * 100, error * 100))
    print()
    if abs(share - 0.5) <= error {
        print("  That is inside the noise. Run more pairs before believing a")
        print("  difference either way.")
    } else {
        print("  \(share > 0.5 ? "A" : "B") is genuinely ahead at this number of pairs.")
    }
}

MainActor.assumeIsolated { run() }
