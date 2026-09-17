//  BuilderLines.swift
//  Two Megas, two teams hiding inside one.
//
//  Doubles brings four of six and only one Pokemon may Mega Evolve per battle,
//  so a second Mega is a second team rather than a wasted slot. This scores
//  every four a two-Mega six can bring, ranks the lines, orders each one's
//  leads, and writes the sentence a person can follow at Team Preview.

import Foundation

extension TeamBuilder {
    /// One four, scored.
    private struct Line {
        let megaIndex: Int
        let mega: Form
        let slots: [TeamSlot]
        var edge = 0
        var perArchetype: [String: Int] = [:]
    }

    /// Everything both the sync and the async path need before any scoring.
    private struct LineSetup {
        let candidates: [Line]
        let opponents: [(name: String, team: Team, weight: Double)]
        /// Names worth showing to a reader. The bundled set is mostly
        /// individual tournament lists, and "bring this four into
        /// pedrodinhani" is not advice.
        let named: Set<String>
    }

    private func lineSetup(for team: Team) -> LineSetup? {
        let bring = store.data.rules.formats.first { $0.id == format }?.bring ?? 4
        guard team.slots.count > bring, bring >= 2 else { return nil }

        let megaIndices = team.slots.indices.filter { index in
            let slot = team.slots[index]
            return slot.megaEvolution(in: store.rulebook) != nil
                || (slot.form(in: store.rulebook)?.isMega ?? false)
        }
        guard megaIndices.count == 2 else { return nil }

        var candidates: [Line] = []
        for index in megaIndices {
            guard let mega = team.slots[index].battleForm(in: store.rulebook) else { continue }
            // The other Mega stays home: bringing both wastes a slot on a
            // Pokémon that cannot use its item.
            let partners = team.slots.indices
                .filter { $0 != index && !megaIndices.contains($0) }
                .map { team.slots[$0] }
            for combination in choose(partners, bring - 1) {
                candidates.append(Line(megaIndex: index, mega: mega,
                                       slots: [team.slots[index]] + combination))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Every combination used to be run against all of the bundled teams,
        // which is 896 full matchups for one blueprint and was the single
        // largest stretch of unbroken main-thread work in the app. The weighted
        // pool is a fifth the size and says the same thing, because most of
        // what it drops are individual tournament lists that repeat each other.
        let named = Set(store.data.metaTeams
            .filter { $0.format == team.format && $0.record == nil }
            .map(\.name))
        return LineSetup(candidates: candidates,
                         opponents: opponentPool(for: team, limit: 24),
                         named: named)
    }

    /// The two ways to play a six that carries two Megas.
    ///
    /// Only one Pokémon may Mega Evolve per battle, so each Mega defines its own
    /// four. Every combination of that Mega plus three partners is scored and
    /// the best four kept — which is the Team Preview decision, made in advance.
    func battlePlans(for team: Team, seed: Form) -> [BattlePlan] {
        guard let setup = lineSetup(for: team) else { return [] }
        let scored = setup.candidates.map { line -> Line in
            var out = line
            var per: [String: Int] = [:]
            var total = 0.0, weight = 0.0
            score(four(of: line, in: team), against: setup.opponents[...],
                  into: &per, total: &total, weight: &weight)
            out.perArchetype = per
            out.edge = weight > 0 ? Int((total / weight).rounded()) : 0
            return out
        }
        return rank(scored, team: team, seed: seed, named: setup.named)
    }

    /// The same, a few opponents at a time, so the main thread is handed back
    /// often enough for the spinner to move. This was two unbroken stretches of
    /// 1.2 seconds, which is what "frozen" looked like.
    func battlePlans(for team: Team, seed: Form, yielding: Bool) async -> [BattlePlan] {
        guard yielding else { return battlePlans(for: team, seed: seed) }
        guard let setup = lineSetup(for: team) else { return [] }
        var scored: [Line] = []
        for line in setup.candidates {
            var out = line
            var per: [String: Int] = [:]
            var total = 0.0, weight = 0.0
            let four = four(of: line, in: team)
            var start = 0
            while start < setup.opponents.count {
                await breathe("battle plans")
                let end = min(start + 4, setup.opponents.count)
                score(four, against: setup.opponents[start..<end],
                      into: &per, total: &total, weight: &weight)
                start = end
            }
            out.perArchetype = per
            out.edge = weight > 0 ? Int((total / weight).rounded()) : 0
            scored.append(out)
        }
        return rank(scored, team: team, seed: seed, named: setup.named)
    }

    private func four(of line: Line, in team: Team) -> Team {
        var out = team
        out.slots = line.slots
        return out
    }

    /// Pick the best four per Mega, then order and describe the two lines.
    private func rank(_ scored: [Line], team: Team, seed: Form,
                      named: Set<String>) -> [BattlePlan] {
        var best: [Int: Line] = [:]
        for line in scored {
            if let held = best[line.megaIndex], held.edge >= line.edge { continue }
            best[line.megaIndex] = line
        }
        let lines = best.values.map {
            Line(megaIndex: $0.megaIndex, mega: $0.mega, slots: leadOrder($0.slots),
                 edge: $0.edge, perArchetype: $0.perArchetype)
        }
        guard lines.count == 2 else { return [] }

        // The Pokémon you asked to build around leads, even when the other Mega
        // scores better — "build around Golisopod" and then being handed a
        // Dragonite team is not the thing that was asked for. The edges are on
        // screen either way, and the alternate says when it is the stronger of
        // the two so the call is still yours.
        let ranked = lines.sorted { first, second in
            if first.mega.dex != second.mega.dex {
                if first.mega.dex == seed.dex { return true }
                if second.mega.dex == seed.dex { return false }
            }
            return first.edge > second.edge
        }
        return ranked.enumerated().map { position, line in
            let other = ranked[1 - position]
            // What this line is for: where it is clearly the better of the two.
            // Only names a reader recognises. Tournament lists are in the pool
            // and score the line perfectly well, but "bring this four into
            // pedrodinhani — Risen Open League" is not a sentence.
            let bestInto = line.perArchetype
                .filter { named.contains($0.key)
                          && $0.value - (other.perArchetype[$0.key] ?? 0) >= 8 }
                .sorted { $0.value > $1.value }
                .map(\.key)
            return BattlePlan(mega: line.mega, isPrimary: position == 0,
                              bring: line.slots,
                              strategy: strategy(for: line.mega, slots: line.slots,
                                                 isPrimary: position == 0,
                                                 bestInto: bestInto,
                                                 outscoresPrimary: position == 1
                                                    && line.edge > other.edge),
                              edge: line.edge, bestInto: bestInto)
        }
    }

    /// Score a four against a slice of the opponent pool, accumulating.
    ///
    /// A slice rather than the whole list so there is exactly one implementation
    /// of this: the synchronous path hands it everything at once, and the
    /// asynchronous one hands it four at a time and breathes in between.
    private func score(_ team: Team,
                       against slice: ArraySlice<(name: String, team: Team, weight: Double)>,
                       into per: inout [String: Int],
                       total: inout Double, weight: inout Double) {
        let advisor = TeamAdvisor(team: team, store: store)
        let held = advisor.rolesPresent
        let hasTailwind = !(held[.tailwind]?.isEmpty ?? true)
        let hasTrickRoom = !(held[.trickRoom]?.isEmpty ?? true)
        for opponent in slice {
            let theirs = opponent.team
            let matchup = Matchup(mine: team, theirs: theirs, rules: store.rulebook,
                                  field: field(for: team, against: theirs),
                                  myTailwind: hasTailwind, theirTailwind: true,
                                  myTrickRoom: hasTrickRoom)
            let edge = matchup.verdict.score
            per[opponent.name] = edge
            total += Double(edge) * opponent.weight
            weight += opponent.weight
        }
    }

    /// Front two first: the Mega leads beside whatever supports it turn one.
    private func leadOrder(_ slots: [TeamSlot]) -> [TeamSlot] {
        guard slots.count > 2 else { return slots }
        let advisor = TeamAdvisor(team: Team(), store: store)
        func supportRank(_ slot: TeamSlot) -> Int {
            guard let form = slot.battleForm(in: store.rulebook) else { return 9 }
            let roles = advisor.potentialRoles(of: form)
            if roles.contains(.fakeOut) || roles.contains(.redirection) { return 0 }
            if roles.contains(.intimidate) { return 1 }
            if roles.contains(.tailwind) || roles.contains(.trickRoom) { return 2 }
            return 3
        }
        let mega = slots[0]
        let rest = slots.dropFirst().sorted { supportRank($0) < supportRank($1) }
        return [mega] + rest
    }

    /// A sentence a person can actually follow at Team Preview.
    private func strategy(for mega: Form, slots: [TeamSlot], isPrimary: Bool,
                          bestInto: [String], outscoresPrimary: Bool = false) -> String {
        // What these four actually have selected, not what they could learn.
        // Reading potential roles claimed Tailwind on a four where nobody had
        // picked it, which is worse than saying nothing.
        var running: Set<String> = []
        var abilities: Set<String> = []
        for slot in slots {
            running.formUnion(slot.moves.compactMap { store.move($0)?.name })
            abilities.insert(slot.ability)
        }

        var parts: [String] = []
        let lead = slots.count > 1
            ? (slots[1].battleForm(in: store.rulebook)?.formLabel ?? "its partner") : "its partner"
        parts.append("Lead \(mega.formLabel) beside \(lead); Mega Evolve turn one.")

        if !running.isDisjoint(with: ["Follow Me", "Rage Powder"]) {
            parts.append("Redirection buys it the turn it needs to start attacking.")
        } else if running.contains("Fake Out") {
            parts.append("Fake Out buys it the turn it needs to start attacking.")
        }
        if running.contains("Tailwind") {
            parts.append("Tailwind is the speed control — win the four turns it gives you.")
        } else if running.contains("Trick Room") {
            parts.append("Trick Room is the speed control; set it before committing.")
        } else if !running.isDisjoint(with: ["Icy Wind", "Electroweb", "Thunder Wave"]) {
            parts.append("Speed control here is chip, not a boost — drop theirs rather than raising yours.")
        } else {
            parts.append("No speed control on this four, so it has to win on raw stats.")
        }
        if abilities.contains("Intimidate") {
            parts.append("Intimidate on the switch keeps their physical attackers off a clean knockout.")
        }
        if !bestInto.isEmpty {
            parts.append("Bring this four into \(bestInto.prefix(2).joined(separator: " and ")).")
        } else if !isPrimary {
            parts.append("Roughly even with the primary line — pick on what you see in Preview.")
        }
        if outscoresPrimary {
            parts.append("This line actually scores higher than the primary against the tracked archetypes — the primary leads because it is what you asked to build around, not because it is better.")
        }
        return parts.joined(separator: " ")
    }

    /// Every combination of `count` items, for the bring-four search.
    private func choose<T>(_ items: [T], _ count: Int) -> [[T]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        if items.count == count { return [items] }
        let head = items[0]
        let tail = Array(items.dropFirst())
        return choose(tail, count - 1).map { [head] + $0 } + choose(tail, count)
    }
}
