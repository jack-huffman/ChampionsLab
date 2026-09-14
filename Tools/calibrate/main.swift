//  tools/calibrate/main.swift
//  Fit the scoring weights to the only outside evidence there is.
//
//  The six component weights were numbers I picked. Nothing tested them. This
//  fits them against the records of teams that actually won games at real
//  events, which is the only signal in the dataset that did not come from the
//  engine itself.
//
//  Two things are measured, and both are reported because they answer
//  different questions:
//
//    · Agreement — across teams with real records, does a higher score go with
//      a better record? Reported as Spearman rank correlation.
//    · Separation — do teams that won events score above teams that have never
//      been tested? A scorer that cannot tell those apart is not measuring
//      anything, whatever its correlation says.
//
//  A caveat that belongs in the output, not a footnote: sets for these teams
//  are inferred, records come from events of wildly different size, and the
//  sample is small. Fitting six numbers to it will overfit. The split test
//  below is there to show how much.

import AppKit
import Foundation

@main
struct Calibrate {
@MainActor static func main() {
    let store = Store.shared
    guard store.loadError == nil else { print("dataset failed to load"); exit(1) }
    var builder = TeamBuilder(store: store)
    builder.format = "doubles"

    // -- the sample ---------------------------------------------------------
    struct Sample {
        let name: String
        let score: TeamScore
        let winRate: Double?
        let games: Int
        let proven: Bool
    }

    var samples: [Sample] = []
    for meta in store.data.metaTeams where meta.format == "doubles" {
        let team = TeamPaste.team(from: meta, store: store)
        guard team.slots.count >= 4 else { continue }
        let scored = builder.evaluate(team, plan: .balance).0
        samples.append(Sample(name: meta.name, score: scored,
                              winRate: meta.winRate, games: meta.gamesPlayed,
                              proven: meta.winRate != nil))
    }
    for team in store.teams where team.slots.count >= 4 {
        let scored = builder.evaluate(team, plan: .balance).0
        samples.append(Sample(name: team.name, score: scored, winRate: nil,
                              games: 0, proven: false))
    }

    let proven = samples.filter { $0.proven && $0.games >= 3 }
    let untested = samples.filter { !$0.proven }
    print("== sample ==")
    print("   \(proven.count) teams with a real record (3+ games)")
    print("   \(untested.count) untested teams as the control")
    guard proven.count >= 10 else { print("not enough evidence to fit"); exit(1) }

    // -- measures -----------------------------------------------------------
    func spearman(_ pairs: [(Double, Double)]) -> Double {
        guard pairs.count > 2 else { return 0 }
        func ranks(_ xs: [Double]) -> [Double] {
            let order = xs.enumerated().sorted { $0.element < $1.element }
            var out = [Double](repeating: 0, count: xs.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count, order[j + 1].element == order[i].element { j += 1 }
                let rank = Double(i + j) / 2 + 1
                for k in i...j { out[order[k].offset] = rank }
                i = j + 1
            }
            return out
        }
        let a = ranks(pairs.map(\.0)), b = ranks(pairs.map(\.1))
        let n = Double(pairs.count)
        let ma = a.reduce(0,+) / n, mb = b.reduce(0,+) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<pairs.count {
            num += (a[i] - ma) * (b[i] - mb)
            da += pow(a[i] - ma, 2); db += pow(b[i] - mb, 2)
        }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    func agreement(_ w: TeamScore.Weights, on set: [Sample]) -> Double {
        spearman(set.map { (Double($0.score.total(with: w)), $0.winRate ?? 0) })
    }
    // Separation was in here as a second objective and had to come out. It
    // compared teams that won events against teams that had not been tested,
    // and reported the winners scoring eight points lower — which looked like a
    // scoring failure and is not. The tournament teams' sets are inferred:
    // their moves and items are the ladder's most common, not what those players
    // actually ran. The one team in the sample entered from its real sets scores
    // 76, above everything else here. The metric was measuring how accurately a
    // set was recorded, not how good the team was, so fitting against it would
    // have fitted to transcription quality.
    func separation(_ w: TeamScore.Weights) -> Double { 0 }

    let current = TeamScore.Weights()
    print("\n== the weights as they stand ==")
    print(String(format: "   agreement with records  %+.3f", agreement(current, on: proven)))

    // -- fit ----------------------------------------------------------------
    // Coarse grid. Components are already computed, so this is only arithmetic.
    let steps: [Double] = [0, 5, 10, 15, 20, 25, 30, 35, 40]
    var best = current
    var bestScore = -2.0
    var evaluated = 0
    for matchup in steps where matchup >= 10 {
        for roles in steps {
            for defence in steps where defence <= 25 {
                for coverage in steps where coverage <= 25 {
                    for synergy in steps where synergy <= 25 {
                        for disruption in steps where disruption <= 30 {
                            var w = TeamScore.Weights()
                            w.matchup = matchup; w.roles = roles; w.defence = defence
                            w.coverage = coverage; w.synergy = synergy; w.disruption = disruption
                            guard w.sum >= 60, w.sum <= 140 else { continue }
                            evaluated += 1
                            // Agreement is the objective; separation must not go
                            // backwards, or the fit is chasing noise.
                            let a = agreement(w, on: proven)
                            if a > bestScore { bestScore = a; best = w }
                        }
                    }
                }
            }
        }
    }
    print("\n== fitted, \(evaluated) combinations tried ==")
    let norm = 100 / best.sum
    print(String(format: "   matchup %.0f  roles %.0f  defence %.0f  coverage %.0f  synergy %.0f  disruption %.0f",
                 best.matchup * norm, best.roles * norm, best.defence * norm,
                 best.coverage * norm, best.synergy * norm, best.disruption * norm))
    print(String(format: "   agreement  %+.3f  (was %+.3f)", bestScore, agreement(current, on: proven)))

    // -- how much of that is overfitting ------------------------------------
    //
    // One split of forty-four samples is noise. Twenty of them, each fitted on
    // half and measured on the half it never saw, answers the only question
    // that matters: does fitting beat not fitting on data it has not seen?
    func fit(on set: [Sample]) -> TeamScore.Weights {
        var bestW = current
        var bestA = -2.0
        for matchup in steps where matchup >= 10 {
            for roles in steps {
                for defence in steps where defence <= 25 {
                    for coverage in steps where coverage <= 25 {
                        for synergy in steps where synergy <= 25 {
                            for disruption in steps where disruption <= 30 {
                                var w = TeamScore.Weights()
                                w.matchup = matchup; w.roles = roles; w.defence = defence
                                w.coverage = coverage; w.synergy = synergy
                                w.disruption = disruption
                                guard w.sum >= 60, w.sum <= 140 else { continue }
                                let a = agreement(w, on: set)
                                if a > bestA { bestA = a; bestW = w }
                            }
                        }
                    }
                }
            }
        }
        return bestW
    }

    print("\n== does fitting survive contact with unseen data? ==")
    var fittedOut = 0.0, currentOut = 0.0, trainedIn = 0.0
    let rounds = 20
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<rounds {
        var shuffled = proven
        shuffled.shuffle(using: &generator)
        let half = shuffled.count / 2
        let trainSet = Array(shuffled.prefix(half))
        let testSet = Array(shuffled.suffix(shuffled.count - half))
        let w = fit(on: trainSet)
        trainedIn += agreement(w, on: trainSet)
        fittedOut += agreement(w, on: testSet)
        currentOut += agreement(current, on: testSet)
    }
    let n = Double(rounds)
    print(String(format: "   fitted weights, on data they were fitted to   %+.3f", trainedIn / n))
    print(String(format: "   fitted weights, on data they never saw        %+.3f", fittedOut / n))
    print(String(format: "   current weights, on the same unseen data      %+.3f", currentOut / n))
    print()
    if fittedOut / n > currentOut / n + 0.05 {
        print("   Fitting generalises. Adopt the fitted weights.")
    } else {
        print("   Fitting does not generalise: it buys \(String(format: "%+.3f", trainedIn / n - fittedOut / n)) of")
        print("   in-sample agreement that does not survive. The sample is too small")
        print("   and too confounded to fit six numbers to. Keep the current weights.")
    }
}

}
