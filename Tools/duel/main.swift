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
//  twice with the sides swapped, so a lucky draw helps both engines equally.
//  The dice are seeded per game and the seed is reused for the mirror, so the
//  two halves of a pair face the same luck. What is left is the engines.

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
    let budgets = pair("--budget", (0.3, 0.3))
    let rolls = pair("--rolls", (Double(TurnModel.branchedRolls), Double(TurnModel.branchedRolls)))
    let seed = UInt64(argument("--seed") ?? "") ?? 20260915

    var a = Side(name: "A", engine: BattleEngine(rules: rules, budget: budgets.0),
                 branchedRolls: Int(rolls.0))
    var b = Side(name: "B", engine: BattleEngine(rules: rules, budget: budgets.1),
                 branchedRolls: Int(rolls.1))
    a.name = "A  budget \(budgets.0)s, rolls \(Int(rolls.0))"
    b.name = "B  budget \(budgets.1)s, rolls \(Int(rolls.1))"

    print("== two engines, \(games) games ==\n")
    print("  \(a.name)")
    print("  \(b.name)\n")
    if budgets.0 == budgets.1 && rolls.0 == rolls.1 {
        print("  Both sides are set the same, so this measures the noise floor")
        print("  rather than a difference. Anything far from even is a bug in")
        print("  the harness, not a finding.\n")
    }

    // Teams drawn from what people actually bring, so the games look like games.
    let pool = store.data.usage.prefix(40).compactMap { entry in
        rules.forms.first { $0.formLabel == entry.name || $0.name == entry.name }
    }
    guard pool.count >= 12 else { print("  not enough forms to draw teams from"); exit(1) }

    var wins = (a: 0, b: 0)
    var draws = 0
    var turnsPlayed = 0
    var dice = Seeded(seed: seed)

    for game in 0..<games {
        // One draw, played twice with the sides swapped. The same seed both
        // times, so the pair faces the same luck and only the seating differs.
        let gameSeed = dice.next()
        var picker = Seeded(seed: gameSeed)
        let left = SelfPlay.team(from: pool, rules: rules, using: &picker)
        let right = SelfPlay.team(from: pool, rules: rules, using: &picker)

        for swapped in [false, true] {
            let mine = swapped ? right : left
            let theirs = swapped ? left : right
            let first = swapped ? b : a
            let second = swapped ? a : b
            var rolling = Seeded(seed: gameSeed)
            let result = SelfPlay.play(
                mine: mine, theirs: theirs, rules: rules,
                forMine: SelfPlay.Seat(engine: first.engine, branchedRolls: first.branchedRolls),
                forTheirs: SelfPlay.Seat(engine: second.engine, branchedRolls: second.branchedRolls),
                dice: &rolling)
            turnsPlayed += result.turns
            switch result.winner {
            case .mine:  if swapped { wins.b += 1 } else { wins.a += 1 }
            case .theirs: if swapped { wins.a += 1 } else { wins.b += 1 }
            case .none:  draws += 1
            }
        }
        if (game + 1) % 10 == 0 {
            FileHandle.standardError.write(
                "  \(game + 1)/\(games): A \(wins.a), B \(wins.b), drawn \(draws)\n"
                    .data(using: .utf8)!)
        }
    }

    let decided = wins.a + wins.b
    print("  A won \(wins.a), B won \(wins.b), \(draws) went the distance")
    guard decided > 0 else { print("\n  Nothing was decided; every game timed out."); return }
    let share = Double(wins.a) / Double(decided)
    // Two standard errors on a coin flip of this many trials, which is the
    // width inside which a difference means nothing.
    let error = 2 * (0.5 / Double(decided).squareRoot())
    print(String(format: "  A takes %.1f%% of decided games, give or take %.1f",
                 share * 100, error * 100))
    print(String(format: "  %.1f turns per game on average", Double(turnsPlayed) / Double(games * 2)))
    print()
    if abs(share - 0.5) <= error {
        print("  That is inside the noise. On this many games the two are level;")
        print("  run more before believing a difference either way.")
    } else {
        print("  \(share > 0.5 ? "A" : "B") is genuinely ahead at this number of games.")
    }
}

MainActor.assumeIsolated { run() }
