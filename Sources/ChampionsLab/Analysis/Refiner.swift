//  Refiner.swift
//  What to change, which is how teams actually get built.
//
//  The builder generates a whole six from scratch. That is not how anybody
//  competent works: they start from something, play it, find the thing that
//  keeps losing, and change one part. Coaching sessions are almost entirely
//  this loop, and the advice is always specific — swap that member, put Taunt
//  in that slot, move those Speed points.
//
//  So this takes a team you already have and asks what change helps most. It
//  tries members and moves, scores each against the same opponents the team
//  score uses, and ranks what comes back by how much it actually moves the
//  number. Nothing here is a suggestion the engine cannot justify with a score.
//
//  One change at a time is not enough on its own, though. Plenty of good ideas
//  score badly alone and well together — a weather setter is a wasted slot
//  until something abuses the weather, and a Trick Room setter makes the team
//  worse until the slow attacker arrives to use it. A search that only ever
//  looks one step ahead cannot find either, and will report that nothing helps
//  while sitting in a hole two changes deep.
//
//  Trying every pair is not an option: one change is a few hundred evaluations,
//  and every pair of those is tens of thousands. So the pair search is a beam.
//  Each single change is scored once against a small opponent set; the most
//  promising handful are kept, and — crucially — so are the near misses, the
//  changes that come out level or slightly down, because those are exactly the
//  ones that are waiting for a partner. Each of those is then combined with the
//  best changes elsewhere on the team.
//
//  A pair is only reported when it beats both of its own halves by a clear
//  margin. Otherwise it is not a pair, it is one good change with something
//  harmless bolted on, and saying "change these two things" when one of them
//  does nothing is how advice stops being trusted.

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

    /// How wide the pair search looks: the best changes it starts from, how
    /// many near misses it also starts from, and how many partners it tries
    /// against each. Every one of these multiplies the work, so they are
    /// settings rather than constants — the numbers were chosen by widening
    /// them until nothing new came back.
    var pairLeaders = 4
    var pairNearMisses = 3
    var pairPartners = 8

    struct Suggestion: Identifiable {
        enum Kind: String {
            case member = "Swap"
            case move = "Move"
            case item = "Item"
            case pair = "Two changes"
        }
        let id = UUID()
        let kind: Kind
        let delta: Int
        let headline: String
        let reason: String
        /// The team with this change already made, ready to save.
        let result: Team
    }

    /// Moves this engine scores at zero because it cannot model them, not
    /// because they are bad. It must never suggest cutting one: Revival
    /// Blessing brings a fainted Pokémon back at half health in a bring-four
    /// format, and the first version of this happily recommended dropping it
    /// for a Fake Out because Fake Out ticks a role box.
    ///
    /// Helping Hand, Coaching and Revival Blessing are modelled now — the first
    /// two as the other way two Pokémon remove one target, the third as the
    /// extra body it is. What remains here is what genuinely has no
    /// representation yet, and the rule stands: do not recommend cutting
    /// something the engine cannot judge.
    static let notUnderstood: Set<String> = [
        "Decorate", "Heal Pulse", "Ally Switch", "After You", "Instruct",
        "Pollen Puff", "Aromatherapy", "Heal Bell",
    ]

    /// Jobs a six must not lose its last copy of.
    ///
    /// The engine scores roles as a checklist, and a checklist will happily
    /// trade a rain team's only Tailwind for an Icy Wind because both land in
    /// the "speed control" box. They are not the same thing, and "drop your
    /// only speed control" is advice no coach would give. This is the same
    /// guard as the one on a slot's signature attack, applied to the team
    /// rather than the slot.
    private static let soleJobs: [Set<String>] = [
        ["Tailwind"], ["Trick Room"], ["Follow Me", "Rage Powder"],
        ["Fake Out"], ["Revival Blessing"],
    ]

    /// Whether this slot holds the team's only copy of one of those jobs.
    private func lastOfItsJob(_ move: Move) -> Bool {
        guard let job = TeamRefiner.soleJobs.first(where: { $0.contains(move.name) })
        else { return false }
        let holders = team.slots.filter { slot in
            slot.moves.contains { job.contains(store.move($0)?.name ?? "") }
        }
        return holders.count <= 1
    }

    /// Moves that are the whole point of a slot, but only under a field the
    /// team itself puts up.
    ///
    /// The move ranker prices a move in a vacuum, and in a vacuum Grassy Glide
    /// is 70 base power and Weather Ball is 50 and Normal. Under the terrain
    /// Rillaboom always sets, Grassy Glide is 70 with priority; under the sun
    /// Charizard Y always brings, Weather Ball is 100 and Fire. So the ranker
    /// puts them at the bottom of the slot and this would offer to trade them
    /// for a Snarl, which is advice that gives away the game.
    ///
    /// Each move names the field it wants; who sets that field is
    /// FieldSetters' business.
    private static let fieldMoves: [String: (weathers: [Weather], terrains: [Terrain])] = [
        "Grassy Glide": ([], [.grassy]),
        "Expanding Force": ([], [.psychic]),
        "Rising Voltage": ([], [.electric]),
        "Psyblade": ([], [.electric]),
        "Misty Explosion": ([], [.misty]),
        "Terrain Pulse": ([], [.grassy, .psychic, .electric, .misty]),
        "Weather Ball": ([.sun, .rain, .sand, .snow], []),
        "Solar Beam": ([.sun], []), "Solar Blade": ([.sun], []),
        "Thunder": ([.rain], []), "Hurricane": ([.rain], []),
        "Aurora Veil": ([.snow], []),
    ]

    /// Every ability on the six, resolved through Mega Evolution.
    private var teamAbilities: Set<String> {
        Set(team.slots.compactMap { slot -> String? in
            if let mega = slot.megaEvolution(in: store.rulebook) {
                return mega.abilities.first?.name
            }
            return slot.ability.isEmpty
                ? slot.battleForm(in: store.rulebook)?.abilities.first?.name : slot.ability
        })
    }

    private func poweredByOwnField(_ move: Move, abilities: Set<String>) -> Bool {
        guard let needs = TeamRefiner.fieldMoves[move.name] else { return false }
        return !FieldSetters.arrivalAbilities(setting: needs.weathers, or: needs.terrains)
            .isDisjoint(with: abilities)
    }

    /// The utility moves coaching keeps reaching for.
    private static let utility = [
        "Protect", "Wide Guard", "Taunt", "Will-O-Wisp", "Thunder Wave",
        "Icy Wind", "Electroweb", "Helping Hand", "Fake Out", "Follow Me",
        "Rage Powder", "Tailwind", "Trick Room", "Encore", "Snarl",
        "Grassy Terrain", "Misty Terrain", "Electric Terrain",
        "Swords Dance", "Nasty Plot", "Coaching",
    ]

    // MARK: - One change, described so it can be replayed

    /// The pair search has to apply a change it already scored on top of a
    /// different base, so what matters is remembering what the change *was*
    /// rather than only the team it produced.
    private struct Edit {
        let kind: Suggestion.Kind
        let slot: Int
        let headline: String
        /// A member swap brings this in.
        var form: Form?
        /// A move change drops this id for that move.
        var dropping: String?
        var adding: Move?
    }

    private func apply(_ edit: Edit, to team: Team,
                       builder: TeamBuilder) -> Team? {
        guard team.slots.indices.contains(edit.slot) else { return nil }
        var out = team
        switch edit.kind {
        case .member:
            guard let form = edit.form else { return nil }
            // Species clause against whatever is on the team *now*, which is
            // not what it was when the edit was first scored.
            if out.slots.enumerated().contains(where: {
                $0.offset != edit.slot && $0.element.form(in: store.rulebook)?.dex == form.dex
            }) { return nil }
            var used = Set(out.slots.enumerated()
                .filter { $0.offset != edit.slot }
                .map { $0.element.item }.filter { !$0.isEmpty })
            out.slots[edit.slot] = builder.flesh(form, plan: plan, usedItems: &used)
        case .move:
            guard let adding = edit.adding, let dropping = edit.dropping,
                  let at = out.slots[edit.slot].moves.firstIndex(of: dropping),
                  !out.slots[edit.slot].moves.contains(adding.id) else { return nil }
            out.slots[edit.slot].moves[at] = adding.id
        case .item, .pair:
            return nil
        }
        return out
    }

    /// Every change worth trying, unscored.
    private func edits(picks: [Forecast.Pick], budget: Int,
                       pinned: Set<Int>) -> [Edit] {
        var out: [Edit] = []

        var candidates: [Form] = picks.prefix(budget * 2).map(\.form)
        for entry in store.data.usage where !entry.isProjected {
            if let form = store.form(named: entry.name),
               !candidates.contains(where: { $0.id == form.id }) {
                candidates.append(form)
            }
        }
        candidates = Array(candidates.prefix(budget))

        for index in team.slots.indices {
            guard let outgoing = team.slots[index].battleForm(in: store.rulebook) else { continue }
            // Never propose cutting the Pokémon the team exists to use. A team
            // called "Mega Bax" does not want to be told to drop Baxcalibur,
            // and no coach would say it.
            guard !pinned.contains(index) else { continue }
            for candidate in candidates where candidate.dex != outgoing.dex {
                out.append(Edit(kind: .member, slot: index,
                                headline: "\(candidate.formLabel) in for \(outgoing.formLabel)",
                                form: candidate))
            }
        }

        let abilities = teamAbilities
        for index in team.slots.indices {
            guard let form = team.slots[index].battleForm(in: store.rulebook) else { continue }
            let learnable = store.moves(for: form)
            let current = Set(team.slots[index].moves)
            let ability = team.slots[index].ability
            // The slot's best attack is the reason it is on the team.
            // Suggesting Icy Wind over Mega Golisopod's First Impression to
            // fill a speed control box is the kind of advice that loses games.
            let signature = team.slots[index].moves
                .compactMap { store.move($0) }
                .filter(\.isDamaging)
                .max { store.moveValue($0, for: form, ability: ability)
                     < store.moveValue($1, for: form, ability: ability) }?.id
            // Replace the least valuable move it has, never Protect, never its
            // signature attack, never something the engine cannot judge.
            let droppable = team.slots[index].moves
                .compactMap { id -> Move? in
                    guard let move = store.move(id), move.name != "Protect",
                          id != signature,
                          !lastOfItsJob(move),
                          !poweredByOwnField(move, abilities: abilities),
                          !TeamRefiner.notUnderstood.contains(move.name) else { return nil }
                    return move
                }
                .min { store.moveValue($0, for: form, ability: ability)
                     < store.moveValue($1, for: form, ability: ability) }
            guard let dropped = droppable else { continue }
            for name in TeamRefiner.utility {
                guard let move = learnable.first(where: { $0.name == name }),
                      !current.contains(move.id) else { continue }
                out.append(Edit(kind: .move, slot: index,
                                headline: "\(form.formLabel): \(dropped.name) → \(move.name)",
                                dropping: dropped.id, adding: move))
            }
        }
        return out
    }

    // MARK: - The search

    /// How many opponents the exploratory pass scores against. Small on
    /// purpose: it only has to rank candidates, and anything that survives is
    /// re-scored against the full set before it is shown to anybody.
    private static let quickOpponents = 10

    private struct Scored {
        let edit: Edit
        let team: Team
        let quick: Int
    }

    /// The highest-value changes, best first.
    ///
    /// `budget` caps how many candidate members are tried per slot.
    func suggestions(picks: [Forecast.Pick], budget: Int = 18, limit: Int = 8,
                     pairs findPairs: Bool = true,
                     progress: @escaping @MainActor (String, Double) -> Void) async
        -> [Suggestion] {
        var builder = TeamBuilder(store: store)
        builder.format = format

        var pinned = self.pinned
        if pinned.isEmpty {
            for (index, slot) in team.slots.enumerated()
            where slot.battleForm(in: store.rulebook)?.isMega == true {
                pinned.insert(index)
            }
        }

        progress("Scoring the team as it stands", 0)
        await breathe("refine baseline")
        let before = await builder.evaluate(team, plan: plan, yielding: true).0
        let baseline = before.total
        let searchBaseline = await builder
            .evaluate(team, plan: plan, yielding: true,
                      opponentLimit: TeamRefiner.quickOpponents).0.total

        // -- every single change, scored once -------------------------------
        let all = edits(picks: picks, budget: budget, pinned: pinned)
        var scored: [Scored] = []
        for (index, edit) in all.enumerated() {
            if index % 4 == 0 {
                progress("Trying \(edit.headline)",
                         0.05 + 0.55 * Double(index) / Double(max(1, all.count)))
            }
            guard let trial = apply(edit, to: team, builder: builder) else { continue }
            let quick = await builder.evaluate(trial, plan: plan, yielding: true,
                                               opponentLimit: TeamRefiner.quickOpponents).0
            guard noNewFaults(quick.violations, versus: before.violations) else { continue }
            scored.append(Scored(edit: edit, team: trial, quick: quick.total))
        }
        scored.sort { $0.quick > $1.quick }

        var found: [Suggestion] = []

        // -- the ones that stand up on their own ----------------------------
        for candidate in scored where candidate.quick > searchBaseline {
            await breathe("refine single")
            let full = await builder.evaluate(candidate.team, plan: plan, yielding: true).0
            guard full.total > baseline,
                  noNewFaults(full.violations, versus: before.violations),
                  worthIt(before: before, after: full) else { continue }
            found.append(Suggestion(kind: candidate.edit.kind,
                                    delta: full.total - baseline,
                                    headline: candidate.edit.headline,
                                    reason: reason(before: before, after: full),
                                    result: candidate.team))
        }

        // Only when nothing single helps.
        //
        // This was built for the case where a team sits in a hole two changes
        // deep, and that is the only case where it has ever been worth the
        // time. Measured across six of my teams and fourteen registered
        // tournament lists, widening the beam three times over moved it from
        // finding a pair on none of them to finding one on one of them, and on
        // no team did a pair beat the best single change. So it runs where it
        // was meant to run and nowhere else: it costs nothing when there is
        // already something to say, and the honest reading is that the score is
        // too coarse for two-step synergy to show up as a clear win.
        if findPairs && found.isEmpty {
            progress("Nothing single helps — trying changes that only work together", 0.65)
            found += await pairSearch(scored: scored, builder: &builder,
                                      before: before, baseline: baseline,
                                      searchBaseline: searchBaseline,
                                      singles: found, progress: progress)
        }

        progress("Ranking what helped", 1)
        return rank(found, limit: limit)
    }

    /// Combine the most promising changes with the best changes elsewhere.
    ///
    /// The starting points are the top few by score *and* the top few near
    /// misses — changes that come out level or a little down. Those are the
    /// whole reason this exists: a change that is waiting for a partner looks
    /// like a bad change until the partner arrives.
    private func pairSearch(scored: [Scored], builder: inout TeamBuilder,
                            before: TeamScore, baseline: Int, searchBaseline: Int,
                            singles: [Suggestion],
                            progress: @escaping @MainActor (String, Double) -> Void) async
        -> [Suggestion] {
        guard scored.count > 1 else { return [] }

        let leaders = Array(scored.prefix(pairLeaders))
        // Level or slightly down. Far enough down and no partner saves it.
        let nearMisses = scored
            .filter { $0.quick <= searchBaseline && $0.quick >= searchBaseline - 6 }
            .prefix(pairNearMisses)
        var starts: [Scored] = leaders
        for miss in nearMisses where !starts.contains(where: {
            $0.edit.slot == miss.edit.slot && $0.edit.headline == miss.edit.headline
        }) { starts.append(miss) }

        var out: [Suggestion] = []
        for (index, start) in starts.enumerated() {
            progress("Pairing \(start.edit.headline)",
                     0.65 + 0.3 * Double(index) / Double(max(1, starts.count)))
            // Only changes elsewhere: two edits to one slot are one edit.
            let partners = scored
                .filter { $0.edit.slot != start.edit.slot }
                .prefix(pairPartners)
            for partner in partners {
                await breathe("refine pair")
                guard let combined = apply(partner.edit, to: start.team,
                                           builder: builder) else { continue }
                let quick = await builder.evaluate(combined, plan: plan, yielding: true,
                                                   opponentLimit: TeamRefiner.quickOpponents).0
                // Has to beat both halves on the cheap pass before it earns a
                // full one, or this turns back into the search it is avoiding.
                guard noNewFaults(quick.violations, versus: before.violations),
                      quick.total > max(start.quick, partner.quick),
                      quick.total > searchBaseline + 1 else { continue }

                let full = await builder.evaluate(combined, plan: plan, yielding: true).0
                guard full.total > baseline,
                      noNewFaults(full.violations, versus: before.violations),
                      worthIt(before: before, after: full) else { continue }

                // A pair is only a pair when the two together are worth more
                // than either alone. Otherwise it is one good change with
                // something harmless attached, and saying "change both" when
                // one of them does nothing is how advice stops being trusted.
                let halves = [start, partner].map { half -> Int in
                    singles.first { $0.headline == half.edit.headline }?.delta ?? 0
                }
                guard full.total - baseline >= (halves.max() ?? 0) + 2 else { continue }

                out.append(Suggestion(
                    kind: .pair, delta: full.total - baseline,
                    headline: "\(start.edit.headline), and \(partner.edit.headline)",
                    reason: reason(before: before, after: full)
                        + " — neither change is worth this on its own",
                    result: combined))
            }
        }
        return out
    }

    /// Best first, and one suggestion per slot so the list is a set of genuine
    /// alternatives rather than eight versions of the same idea.
    private func rank(_ found: [Suggestion], limit: Int) -> [Suggestion] {
        var seen = Set<String>()
        return found.sorted { $0.delta > $1.delta }.filter { suggestion in
            let key = suggestion.headline.components(separatedBy: ":").first
                ?? suggestion.headline
            return seen.insert(key).inserted
        }
        .prefix(limit).map { $0 }
    }

    /// Whether a trial introduces a problem the team did not already have.
    ///
    /// Not "has no violations". A two-Mega team is deliberate — only one can
    /// evolve, so the second is a spare, and the team screen says so rather
    /// than calling it illegal. Treating any violation as disqualifying threw
    /// away every candidate on those teams and reported that nothing helps,
    /// which is a different and much worse claim than "this is a spare Mega".
    private func noNewFaults(_ trial: [String], versus base: [String]) -> Bool {
        Set(trial).subtracting(base).isEmpty
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
