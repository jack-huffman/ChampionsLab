//  Refiner.swift
//  One change at a time, which is how teams actually get built.
//
//  The builder generates a whole six from scratch. That is not how anybody
//  competent works: they start from something, play it, find the thing that
//  keeps losing, and change one part. Coaching sessions are almost entirely
//  this loop, and the advice is always specific — swap that member, put Taunt
//  in that slot, move those Speed points.
//
//  So this takes a team you already have and asks what single change helps
//  most. It tries members, moves and items, scores each against the same
//  opponents the team score uses, and ranks what comes back by how much it
//  actually moves the number. Nothing here is a suggestion the engine cannot
//  justify with a score.

import Foundation

@MainActor
struct TeamRefiner {
    let store: Store
    let team: Team
    var format = "doubles"
    var plan: Archetype = .balance
    /// Slots the search will not touch. Defaults to anything that Mega Evolves,
    /// which is almost always what the team was built around.
    var pinned: Set<Int> = []

    struct Suggestion: Identifiable {
        enum Kind: String {
            case member = "Swap"
            case move = "Move"
            case item = "Item"
        }
        let id = UUID()
        let kind: Kind
        let delta: Int
        let headline: String
        let reason: String
        /// The team with this change already made, ready to save.
        let result: Team
    }

    /// The highest-value single changes, best first.
    ///
    /// `budget` caps how many candidate members are tried per slot; the search
    /// is a few hundred evaluations, so finalists are re-scored against the
    /// full opponent set while the search itself uses a subset.
    /// Moves this engine scores at zero because it cannot model them, not
    /// because they are bad. It must never suggest cutting one: Revival
    /// Blessing brings a fainted Pokémon back at half health in a bring-four
    /// format, and the first version of this happily recommended dropping it
    /// for a Fake Out because Fake Out ticks a role box.
    /// Helping Hand, Coaching and Revival Blessing are modelled now — the first
    /// two as the other way two Pokémon remove one target, the third as the
    /// extra body it is. What remains here is what genuinely has no
    /// representation yet, and the rule stands: do not recommend cutting
    /// something the engine cannot judge.
    static let notUnderstood: Set<String> = [
        "Decorate", "Heal Pulse", "Ally Switch", "After You", "Instruct",
        "Pollen Puff", "Aromatherapy", "Heal Bell",
    ]

    func suggestions(picks: [Forecast.Pick], budget: Int = 18,
                     limit: Int = 8) -> [Suggestion] {
        var builder = TeamBuilder(store: store)
        builder.format = format
        var pinned = self.pinned
        if pinned.isEmpty {
            for (index, slot) in team.slots.enumerated()
            where slot.battleForm(in: store)?.isMega == true {
                pinned.insert(index)
            }
        }
        let before = builder.evaluate(team, plan: plan).0
        let baseline = before.total
        let searchBaseline = builder.evaluate(team, plan: plan, opponentLimit: 10).0.total

        var found: [Suggestion] = []

        // -- swapping a member ----------------------------------------------
        var candidates: [Form] = picks.prefix(budget * 2).map(\.form)
        for entry in store.data.usage where !entry.isProjected {
            if let form = store.form(named: entry.name),
               !candidates.contains(where: { $0.id == form.id }) {
                candidates.append(form)
            }
        }
        candidates = Array(candidates.prefix(budget))

        for index in team.slots.indices {
            guard let outgoing = team.slots[index].battleForm(in: store) else { continue }
            // Never propose cutting the Pokémon the team exists to use. A team
            // called "Mega Bax" does not want to be told to drop Baxcalibur, and
            // no coach would say it.
            if pinned.contains(index) { continue }
            for candidate in candidates {
                // No duplicate species, and no swapping something for itself.
                if candidate.dex == outgoing.dex { continue }
                if team.slots.enumerated().contains(where: {
                    $0.offset != index && $0.element.form(in: store)?.dex == candidate.dex
                }) { continue }

                var trial = team
                var used = Set(trial.slots.enumerated()
                    .filter { $0.offset != index }
                    .map { $0.element.item }.filter { !$0.isEmpty })
                trial.slots[index] = builder.flesh(candidate, plan: plan, usedItems: &used)
                let quick = builder.evaluate(trial, plan: plan, opponentLimit: 10).0
                guard quick.total > searchBaseline, quick.violations.isEmpty else { continue }
                let full = builder.evaluate(trial, plan: plan).0
                guard full.total > baseline, worthIt(before: before, after: full) else { continue }
                found.append(Suggestion(
                    kind: .member, delta: full.total - baseline,
                    headline: "\(candidate.formLabel) in for \(outgoing.formLabel)",
                    reason: reason(before: before, after: full),
                    result: trial))
            }
        }

        // -- changing one move ------------------------------------------------
        // The utility moves coaching keeps reaching for, plus what the format
        // says is missing. Only ones the Pokémon can actually learn.
        let utility = ["Protect", "Wide Guard", "Taunt", "Will-O-Wisp", "Thunder Wave",
                       "Icy Wind", "Electroweb", "Helping Hand", "Fake Out", "Follow Me",
                       "Rage Powder", "Tailwind", "Trick Room", "Encore", "Snarl",
                       "Grassy Terrain", "Misty Terrain", "Electric Terrain",
                       "Swords Dance", "Nasty Plot", "Coaching"]
        for index in team.slots.indices {
            guard let form = team.slots[index].battleForm(in: store) else { continue }
            let learnable = store.moves(for: form)
            let current = Set(team.slots[index].moves)
            // The slot's best attack is the reason it is on the team. Suggesting
            // Icy Wind over Mega Golisopod's First Impression to fill a speed
            // control box is the kind of advice that loses games.
            let signature = team.slots[index].moves
                .compactMap { store.move($0) }
                .filter(\.isDamaging)
                .max { store.quality(of: $0).expectedPower < store.quality(of: $1).expectedPower }?.id
            for name in utility {
                guard let move = learnable.first(where: { $0.name == name }),
                      !current.contains(move.id) else { continue }
                // Replace the least valuable move it currently has, never Protect.
                let ranked = team.slots[index].moves.enumerated()
                    .compactMap { offset, id -> (Int, Move)? in
                        guard let m = store.move(id), m.name != "Protect",
                              id != signature,
                              !TeamRefiner.notUnderstood.contains(m.name) else { return nil }
                        return (offset, m)
                    }
                    .sorted { store.quality(of: $0.1).expectedPower
                        < store.quality(of: $1.1).expectedPower }
                guard let (slotIndex, dropped) = ranked.first else { continue }

                var trial = team
                trial.slots[index].moves[slotIndex] = move.id
                let quick = builder.evaluate(trial, plan: plan, opponentLimit: 10).0
                guard quick.total > searchBaseline else { continue }
                let full = builder.evaluate(trial, plan: plan).0
                guard full.total > baseline, full.violations.isEmpty,
                      worthIt(before: before, after: full) else { continue }
                found.append(Suggestion(
                    kind: .move, delta: full.total - baseline,
                    headline: "\(form.formLabel): \(dropped.name) → \(move.name)",
                    reason: reason(before: before, after: full),
                    result: trial))
            }
        }

        // Best first, and only one suggestion per slot so the list is a set of
        // genuine alternatives rather than eight versions of the same idea.
        var seenSlots = Set<String>()
        return found.sorted { $0.delta > $1.delta }.filter { suggestion in
            let key = suggestion.headline.components(separatedBy: ":").first
                ?? suggestion.headline
            return seenSlots.insert(key).inserted
        }
        .prefix(limit).map { $0 }
    }

    /// Rejects changes that buy a role box with real function.
    ///
    /// Filling the last essential role is worth four points of the total, so a
    /// swap that ticks one while giving up fifteen points of matchup scores as
    /// an improvement and is not one. Coaching material is consistent on this:
    /// a checklist is not a team.
    private func worthIt(before: TeamScore, after: TeamScore) -> Bool {
        let matchupLoss = before.matchup - after.matchup
        if matchupLoss <= 4 { return true }
        // Past that it has to pay for itself several times over.
        return Double(after.total - before.total) >= matchupLoss / 2.5
    }

    /// What actually improved, in the team's own terms.
    private func reason(before: TeamScore, after: TeamScore) -> String {
        var parts: [String] = []
        func note(_ label: String, _ from: Double, _ to: Double, scale: Double = 100) {
            let change = (to - from) * scale
            guard abs(change) >= 4 else { return }
            parts.append(String(format: "%@ %+.0f%@", label, change, scale == 100 ? "%" : ""))
        }
        note("matchup", before.matchup, after.matchup, scale: 1)
        note("roles", before.roles, after.roles)
        note("defence", before.defence, after.defence)
        note("coverage", before.coverage, after.coverage)
        note("disruption", before.disruption, after.disruption)
        if after.violations.count < before.violations.count {
            parts.append("fixes a rule violation")
        }
        return parts.isEmpty ? "small gains across the board" : parts.joined(separator: ", ")
    }
}
