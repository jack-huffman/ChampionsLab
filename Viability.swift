//  Viability.swift
//  How good a Pokémon actually is in this format, and where it is heading.
//
//  Two questions the app kept answering by feel.
//
//  The first is viability. The builder's candidate pool was a flat list of two
//  hundred forms filtered on a loose threshold, so a role could be filled by
//  something nobody has ever played as readily as by the Pokémon that wins
//  events. Top-meta picks are top-meta for a reason; the search should start
//  there and drop a tier only when nothing up there does the job.
//
//  The second is trajectory. Ladder usage says what the format is; tournament
//  results say what it is becoming, because tournament play runs ahead of the
//  ladder. The gap between the two is the only forward-looking signal in the
//  dataset, and it is a real one — but it is read carefully, because Pikalytics
//  publishes a top twenty and everything below that cutoff looks like zero
//  whether it is rare or merely twenty-first.

import Foundation

/// How established a Pokémon is, highest first.
enum ViabilityTier: Int, CaseIterable, Comparable {
    case established = 0    // the format is defined by these
    case strong = 1         // common, proven, unsurprising
    case playable = 2       // seen, works, not a staple
    case fringe = 3         // legal and reasonable, rarely played
    case unproven = 4       // nothing to go on

    static func < (a: ViabilityTier, b: ViabilityTier) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .established: return "Established"
        case .strong:      return "Strong"
        case .playable:    return "Playable"
        case .fringe:      return "Fringe"
        case .unproven:    return "Unproven"
        }
    }
}

/// Where a Pokémon appears to be heading.
enum Trend: String {
    case rising = "Rising"
    case steady = "Steady"
    case falling = "Falling"
    case emerging = "Emerging"   // turning up in results without ladder presence
}

struct Viability {
    let form: Form
    let tier: ViabilityTier
    /// Share of ladder teams carrying it, 0…1. Nil when it is below the
    /// tracking cutoff, which is not the same as zero.
    let ladder: Double?
    /// Share of the tournament teams carrying it, 0…1.
    let tournament: Double
    /// Measured winrate where the ladder has one.
    let winrate: Double?
    /// How it scores against the field, −1…1, from the anti-meta run.
    let standing: Double
    let trend: Trend
    /// The tournament-to-ladder gap, in points. An upper bound where ladder
    /// usage is unknown.
    let movement: Double
    let movementIsUpperBound: Bool

    /// One line a person can read.
    var summary: String {
        var parts: [String] = [tier.name]
        if let ladder {
            parts.append(String(format: "%.0f%% ladder", ladder * 100))
        } else if tournament > 0 {
            parts.append("below the ladder cutoff")
        }
        if tournament > 0 {
            parts.append(String(format: "%.0f%% of results", tournament * 100))
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
extension Store {
    /// The tracking cutoff: the lowest usage Pikalytics actually publishes.
    /// Anything absent is somewhere below this, not at zero.
    var ladderCutoff: Double {
        (data.usage.filter { !$0.isProjected }.map(\.usage).min() ?? 10) / 100
    }

    /// Every Pokémon that has appeared anywhere, ranked.
    func viabilityTable(picks: [Forecast.Pick] = []) -> [Viability] {
        if let cached = viabilityCache, !cached.isEmpty, !picks.isEmpty || picksWereUsed {
            return cached
        }
        let standing = Dictionary(picks.map { ($0.form.id, $0.score) },
                                  uniquingKeysWith: { a, _ in a })

        // Counted by species, not by form. A tournament list saying "Mega
        // Salamence" means Salamence is being played, and the ladder table
        // carries both entries; treating them as different Pokémon reported
        // Salamence as having fallen to zero while its Mega sat at 42%.
        let dexOf = Dictionary(data.forms.map { ($0.formLabel, $0.dex) },
                               uniquingKeysWith: { a, _ in a })
        let results = data.metaTeams.filter { $0.record != nil && $0.format == "doubles" }
        var appearances: [Int: Double] = [:]
        var weighted: [Int: Double] = [:]
        var totalWeight = 0.0
        for meta in results {
            let weight = max(0.5, (meta.winRate ?? 0.5) * Double(max(1, meta.gamesPlayed)) / 4)
            totalWeight += weight
            let species = Set(meta.members.compactMap { dexOf[$0.form] })
            for dex in species {
                appearances[dex, default: 0] += 1
                weighted[dex, default: 0] += weight
            }
        }
        let resultCount = Double(max(1, results.count))

        // Ladder usage per species as well: the highest of whatever forms the
        // table lists, since they are the same Pokémon before and after it
        // Mega Evolves.
        var ladderByDex: [Int: UsageEntry] = [:]
        for entry in data.usage where !entry.isProjected {
            guard let form = form(named: entry.name) else { continue }
            if let existing = ladderByDex[form.dex], existing.usage >= entry.usage { continue }
            ladderByDex[form.dex] = entry
        }

        var out: [Viability] = []
        for form in data.forms {
            let entry = ladderByDex[form.dex]
            let ladder = entry.map { $0.usage / 100 }
            let tournament = (appearances[form.dex] ?? 0) / resultCount
            let winWeighted = totalWeight > 0
                ? (weighted[form.dex] ?? 0) / totalWeight : 0
            guard ladder != nil || tournament > 0 || (standing[form.id] ?? 0) > 0.4 else { continue }

            // Movement: how far ahead of its ladder share the results run. Where
            // ladder usage is unknown it can only be bounded by the cutoff.
            let assumedLadder = ladder ?? ladderCutoff
            let movement = (tournament - assumedLadder) * 100
            let bounded = ladder == nil

            let trend: Trend
            if ladder == nil && tournament >= 0.08 {
                trend = .emerging
            } else if movement >= 8 {
                trend = .rising
            } else if movement <= -6 {
                trend = .falling
            } else {
                trend = .steady
            }

            // The tier is mostly evidence, with the engine's own opinion as a
            // tie-break rather than a driver.
            let proof = (ladder ?? 0) * 1.2 + tournament * 1.4 + winWeighted * 1.5
            let tier: ViabilityTier
            if proof >= 0.55 { tier = .established }
            else if proof >= 0.28 { tier = .strong }
            else if proof >= 0.10 { tier = .playable }
            else if proof > 0 || (standing[form.id] ?? 0) > 0.5 { tier = .fringe }
            else { tier = .unproven }

            out.append(Viability(form: form, tier: tier, ladder: ladder,
                                 tournament: tournament, winrate: entry?.winrate,
                                 standing: standing[form.id] ?? 0, trend: trend,
                                 movement: movement, movementIsUpperBound: bounded))
        }
        let sorted = out.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            return ($0.tournament + ($0.ladder ?? 0)) > ($1.tournament + ($1.ladder ?? 0))
        }
        if !picks.isEmpty { viabilityCache = sorted; picksWereUsed = true }
        return sorted
    }

    func viability(of form: Form, picks: [Forecast.Pick] = []) -> Viability? {
        viabilityTable(picks: picks).first { $0.form.id == form.id }
    }
}
