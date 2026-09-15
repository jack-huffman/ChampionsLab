//  tools/accuracy/main.swift
//  Does the engine's opinion match what actually happened?
//
//      ./tools/accuracy.sh
//
//  Every other harness in this project checks that the engine does what I meant
//  it to do. None of them can tell whether what I meant was right. Every bug
//  found so far was found by reading output and noticing something wrong --
//  Megas not evolving, Choice Scarf doing nothing, Protect not existing -- and
//  that only finds the mistakes somebody thinks to look for.
//
//  data/matches.json is the other kind of evidence: real games from published
//  brackets where both team lists are known and so is the winner. This runs the
//  versus engine over every one of them and asks the only question that matters
//  about a predictor -- when it says a side is ahead, does that side win?
//
//  What it cannot separate out: Stat Points are published nowhere, so both
//  sides are scored with inferred spreads, and player skill is not in the model
//  at all. A perfect engine would not reach 100% here, and nothing like it.
//  Beating a coin flip by a clear margin across a thousand games is the bar.

import AppKit

@MainActor func run() {
    let store = Store.shared
    let path = URL(fileURLWithPath: "data/matches.json")
    guard let raw = try? Data(contentsOf: path) else {
        print("data/matches.json is missing — run ./mkmatches.py first")
        exit(1)
    }

    // The file spells a member's species "name"; a MetaTeam calls it "form".
    // Mapped here rather than in the file, so what mkmatches.py writes stays a
    // faithful copy of what the event published.
    struct Entry: Decodable {
        let name: String
        let item: String
        let ability: String
        let moves: [String]
        let nature: String?
    }
    struct Side: Decodable {
        let player: String
        let placing: Int?
        let record: String?
        let members: [Entry]
    }
    struct Game: Decodable {
        let event: String
        let round: Int?
        let a: Side
        let b: Side
        let winner: Int
    }
    struct File: Decodable { let generated: String; let matches: [Game] }

    let file: File
    do {
        file = try JSONDecoder().decode(File.self, from: raw)
    } catch {
        print("data/matches.json did not decode: \(error)")
        exit(1)
    }
    print("== \(file.matches.count) real games, fetched \(file.generated) ==")

    func team(_ side: Side, name: String) -> Team {
        let members = side.members.map {
            MetaTeam.Member(form: $0.name, item: $0.item, ability: $0.ability,
                            moves: $0.moves, nature: $0.nature)
        }
        let meta = MetaTeam(id: name, name: name, archetype: "Tournament result",
                            format: "doubles", projected: false, source: "", note: "",
                            members: members, record: side.record, placement: nil)
        return TeamPaste.team(from: meta, store: store)
    }

    var scored = 0, correct = 0, drawn = 0
    var buckets: [Int: (games: Int, won: Int)] = [:]
    var worst: [(gap: Int, text: String)] = []
    var edges: [Double] = [], results: [Double] = []
    let started = Date()

    for (index, game) in file.matches.enumerated() {
        let mine = team(game.a, name: game.a.player)
        let theirs = team(game.b, name: game.b.player)
        guard mine.slots.count >= 4, theirs.slots.count >= 4 else { continue }
        let grid = Matchup(mine: mine, theirs: theirs, rules: store.rulebook,
                           field: Field(isDoubles: true))
        let edge = grid.verdict.score
        scored += 1

        let actuallyWon = game.winner == 0
        if edge == 0 { drawn += 1 }
        else if (edge > 0) == actuallyWon { correct += 1 }

        // Calibration: ten-point bands of predicted edge against what happened.
        let band = max(-4, min(4, Int((Double(edge) / 12).rounded())))
        buckets[band, default: (0, 0)].games += 1
        if actuallyWon { buckets[band]!.won += 1 }

        edges.append(Double(edge))
        results.append(actuallyWon ? 1 : 0)

        // The confident misses are the interesting ones.
        if (edge > 0) != actuallyWon, abs(edge) >= 25 {
            worst.append((abs(edge), String(format: "%+4d  %@ beat %@ (%@)",
                                            edge, game.b.player, game.a.player,
                                            game.event)))
        }
        if index % 200 == 0 && index > 0 { print("   scored \(index)…") }
    }

    let decided = scored - drawn
    let rate = decided > 0 ? Double(correct) / Double(decided) : 0
    print(String(format: "\nscored %d games in %.1f s", scored,
                 Date().timeIntervalSince(started)))
    print(String(format: "  called %d of %d decided games right: %.1f%%",
                 correct, decided, rate * 100))
    print(String(format: "  (%d were called dead level)", drawn))

    // Correlation between how far ahead it says you are and whether you won.
    let n = Double(edges.count)
    if n > 1 {
        let meanEdge = edges.reduce(0, +) / n, meanResult = results.reduce(0, +) / n
        var cov = 0.0, varEdge = 0.0, varResult = 0.0
        for (edge, result) in zip(edges, results) {
            cov += (edge - meanEdge) * (result - meanResult)
            varEdge += (edge - meanEdge) * (edge - meanEdge)
            varResult += (result - meanResult) * (result - meanResult)
        }
        let r = (varEdge > 0 && varResult > 0) ? cov / (varEdge * varResult).squareRoot() : 0
        print(String(format: "  correlation between predicted edge and winning: %+.3f", r))
    }

    print("\n  calibration — what it says, against what happened:")
    for band in buckets.keys.sorted() {
        let entry = buckets[band]!
        guard entry.games >= 15 else { continue }
        let share = Double(entry.won) / Double(entry.games)
        let bar = String(repeating: "#", count: Int(share * 40))
        print(String(format: "    edge %+3d   %4d games   won %5.1f%%  %@",
                     band * 12, entry.games, share * 100, bar))
    }

    if !worst.isEmpty {
        print("\n  most confident misses:")
        for line in worst.sorted(by: { $0.gap > $1.gap }).prefix(6) {
            print("    \(line.text)")
        }
    }

    // A predictor that beats a coin flip is doing something; one that does not
    // is decoration. Said plainly either way.
    // A floor rather than a target. The point of this harness is to notice if a
    // change quietly destroys the engine's predictive power, which no other
    // check in the project could see. It is set well below what the engine
    // currently manages so ordinary noise does not trip it.
    print("")
    let floor = 0.52
    if rate > 0.55 {
        print(String(format: "==> the engine beats a coin flip by %.1f points across %d games",
                     (rate - 0.5) * 100, decided))
    } else if rate > floor {
        print(String(format: "==> the engine is barely ahead of a coin flip (%.1f%%). Real, small.",
                     rate * 100))
    } else {
        print(String(format: "==> FAIL: the engine does not beat a coin flip (%.1f%%), floor is %.0f%%.",
                     rate * 100, floor * 100))
        exit(1)
    }
    print("    Player skill is not modelled and Stat Points are published nowhere,")
    print("    so both sides fight with inferred spreads. This is the ceiling on")
    print("    what the number can mean, not an excuse for where it sits.")
    exit(0)
}

MainActor.assumeIsolated { run() }
