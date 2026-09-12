//  Trajectory.swift
//  Where the format is going, and what will be waiting for it.
//
//  The forecast screen described the format as it stands. This is the part that
//  tries to be ahead of it, and it rests on one observation: tournament results
//  run in front of ladder usage. What people bring to events on a Saturday is
//  what the ladder looks like a fortnight later, so the gap between the two is
//  a leading indicator rather than noise.
//
//  Then the useful question, which is not "what is strong" but "what is strong
//  and nobody is playing". A Pokémon that beats the top of the format and sits
//  at two percent usage is worth more to you than one that beats it at forty,
//  because the forty-percent answer is already in everyone's team preview.
//
//  Finally the cascade. Answering the meta creates a new meta; the things that
//  beat the answers are where the format goes next. Two steps is as far as this
//  is worth taking — past that it is astrology.

import Foundation

@MainActor
struct Trajectory {
    let store: Store
    var format = "doubles"
    /// The anti-meta run, which everything here is weighed against.
    let picks: [Forecast.Pick]

    // MARK: - Where things are heading

    struct Movement: Identifiable {
        let viability: Viability
        var form: Form { viability.form }
        var id: String { form.id }
        /// Why it is moving, in plain terms.
        let reading: String
    }

    /// What is climbing and what is sliding, biggest movers first.
    func movements(limit: Int = 10) -> (rising: [Movement], falling: [Movement]) {
        let table = store.viabilityTable(picks: picks)
        func reading(_ v: Viability) -> String {
            let results = String(format: "%.0f%% of tournament teams", v.tournament * 100)
            switch v.trend {
            case .emerging:
                return "\(results), and not yet on the tracked ladder at all"
            case .rising:
                let ladder = v.ladder.map { String(format: "%.0f%%", $0 * 100) } ?? "under the cutoff"
                return "\(results) against \(ladder) on ladder"
            case .falling:
                let ladder = v.ladder.map { String(format: "%.0f%%", $0 * 100) } ?? "under the cutoff"
                return "\(ladder) on ladder but only \(results)"
            case .steady:
                return results
            }
        }
        // One row per species. Both forms carry the same numbers now that they
        // are counted together, and printing "Floette" above "Mega Floette"
        // with identical figures says nothing twice.
        var bySpecies: [Int: Viability] = [:]
        for v in table where v.tournament > 0 || v.ladder != nil {
            if let held = bySpecies[v.form.dex] {
                // Prefer whichever form the results actually name.
                let heldIsMega = held.form.isMega
                let better = v.form.isMega && !heldIsMega && v.tournament > 0
                if !better { continue }
            }
            bySpecies[v.form.dex] = v
        }
        let moving = Array(bySpecies.values)
        let rising = moving.filter { $0.trend == .rising || $0.trend == .emerging }
            .sorted { $0.movement > $1.movement }
            .prefix(limit).map { Movement(viability: $0, reading: reading($0)) }
        let falling = moving.filter { $0.trend == .falling }
            .sorted { $0.movement < $1.movement }
            .prefix(limit).map { Movement(viability: $0, reading: reading($0)) }
        return (Array(rising), Array(falling))
    }

    // MARK: - What is strong and unplayed

    struct Undervalued: Identifiable {
        let form: Form
        let tier: ViabilityTier
        /// Its score against the projected field, −1…1.
        let standing: Double
        /// How much of the field is currently playing it, 0…1.
        let exposure: Double
        /// Standing relative to how known it is. Higher is more overlooked.
        let edge: Double
        let beats: [String]
        var id: String { form.id }
    }

    /// Strong against the field, and not yet in it.
    ///
    /// Weighted against the projected field rather than the current one, so an
    /// answer to something that is rising counts for more than an answer to
    /// something on the way out.
    func undervalued(limit: Int = 12, includeMegas: Bool = true) -> [Undervalued] {
        let table = store.viabilityTable(picks: picks)
        let known = Dictionary(table.map { ($0.form.id, $0) }, uniquingKeysWith: { a, _ in a })

        return picks.compactMap { pick -> Undervalued? in
            guard includeMegas || !pick.form.isMega else { return nil }
            let v = known[pick.form.id]
            let exposure = max(v?.ladder ?? 0, v?.tournament ?? 0)
            // Being unplayed is only interesting if it is also good.
            guard pick.score > 0.25 else { return nil }
            // Diminishing credit for obscurity: something at 0% and something
            // at 3% are both unplayed, and neither is a secret at 25%.
            let obscurity = 1 - min(1, exposure / 0.25)
            let edge = pick.score * (0.45 + 0.55 * obscurity)
            return Undervalued(form: pick.form, tier: v?.tier ?? .unproven,
                               standing: pick.score, exposure: exposure,
                               edge: edge, beats: Array(pick.beats.prefix(4)))
        }
        .sorted { $0.edge > $1.edge }
        .prefix(limit).map { $0 }
    }

    // MARK: - The cascade

    struct Wave: Identifiable {
        let name: String
        let explanation: String
        let members: [(form: Form, note: String)]
        var id: String { name }
    }

    /// The format, its answers, and what beats the answers.
    ///
    /// Each step is computed the same way — run every legal form against the
    /// previous step and keep what wins — so the second wave is what the format
    /// turns into if the first wave is adopted.
    func cascade() -> [Wave] {
        let forecast = Forecast(store: store, format: format)
        let table = store.viabilityTable(picks: picks)

        // Step one: what the format is now, by evidence rather than opinion.
        let now = table.filter { $0.tier <= .strong }.prefix(8)
        guard !now.isEmpty else { return [] }

        // Step two: what answers it. Already computed by the anti-meta run.
        let answers = picks.filter { $0.score > 0.35 }.prefix(6)

        // Step three: what beats those answers. Same machinery, new field.
        let answerForms = Set(answers.map(\.form.id))
        var counters: [(Form, Double, String)] = []
        for candidate in picks where !answerForms.contains(candidate.form.id) {
            let beatsAnswers = candidate.beats.filter { name in
                answers.contains { $0.form.formLabel == name || $0.form.name == name }
            }
            guard beatsAnswers.count >= 2 else { continue }
            counters.append((candidate.form, candidate.score,
                             "beats " + beatsAnswers.prefix(3).joined(separator: ", ")))
        }
        counters.sort { $0.1 > $1.1 }

        return [
            Wave(name: "What the format is",
                 explanation: "Ranked by what people bring and win with, not by what the engine likes.",
                 members: now.map { v in
                     (v.form, v.summary)
                 }),
            Wave(name: "What answers it",
                 explanation: "Every legal form run against that field with a standard build, best first.",
                 members: answers.map { pick in
                     (pick.form, "beats \(pick.beats.count) of \(pick.fieldSize) · "
                        + (store.viability(of: pick.form, picks: picks)?.tier.name ?? "Unproven").lowercased())
                 }),
            Wave(name: "What beats the answers",
                 explanation: "If those answers are adopted, this is the field they create. Two steps out is as far as this is worth taking.",
                 members: counters.prefix(6).map { ($0.0, $0.2) }),
        ]
        _ = forecast
    }

    // MARK: - Role shopping, from the top down

    struct RoleCandidate: Identifiable {
        let form: Form
        let tier: ViabilityTier
        let standing: Double
        let how: String
        var id: String { form.id }
    }

    /// Who fills a job, best-established first.
    ///
    /// This is the "start from the top of the meta and work down" rule made
    /// literal: candidates are grouped by tier, and a lower tier is only worth
    /// reading if the one above it is empty.
    func candidates(for group: MetaModel.RoleGroup,
                    limit: Int = 8) -> [RoleCandidate] {
        let meta = MetaModel(store: store, format: format)
        let table = store.viabilityTable(picks: picks)
        _ = meta
        // Suggestions come from what defines the job, not from anything that
        // brushes against it: on a bare learnset test Kingambit is a weather
        // setter because it learns Rain Dance.
        var out: [RoleCandidate] = []
        var seenSpecies = Set<Int>()
        for v in table {
            let ability = v.form.abilities.map(\.name).first { group.abilities.contains($0) }
            let learned = store.moves(for: v.form)
                .filter { group.core.contains($0.name) }
                .map(\.name)
            let qualifies = ability != nil || !learned.isEmpty
                || (group.anySetup && store.moves(for: v.form)
                        .contains { !$0.selfBoosts.isEmpty })
            guard qualifies, seenSpecies.insert(v.form.dex).inserted else { continue }

            // What the ladder actually runs on it comes first.
            let measured = store.data.usage.first {
                $0.name == v.form.formLabel || $0.name == v.form.name
            }?.keyMoves ?? []
            let played = learned.filter { measured.contains($0) }
            let how = !played.isEmpty ? played.prefix(2).joined(separator: ", ")
                : (ability ?? learned.prefix(2).joined(separator: ", "))
            out.append(RoleCandidate(form: v.form, tier: v.tier, standing: v.standing,
                                     how: how.isEmpty ? "its stats" : how))
            if out.count >= limit { break }
        }
        return out
    }
}
