//  BuilderSearch.swift
//  The beam over slots, and the cheap score that steers it.
//
//  A team is scored on six components and support earns its slot in three of
//  them; the quick score is that judgement made without the damage calculator,
//  so it can be asked thousands of times inside the search. The plans worth
//  trying for a seed are decided here too, because a base 87 Speed Mega with
//  175 Attack is not a Tailwind sweeper and not a Trick Room abuser, and the
//  search should not pretend it is either.

import Foundation

extension TeamBuilder {
    /// A partial team's quality without running the damage calculator.
    private func quickScore(_ team: [Profile], seed: Form, plan: Archetype,
                            dualMega: Bool = false) -> Double {
        guard !team.isEmpty else { return 0 }
        var value = 0.0

        value += team.reduce(0.0) { $0 + $1.standing } / Double(team.count) * 22

        // What the format has already proved. A trade model on its own reaches
        // for whatever happens to score well against the tracked field, which is
        // how a six ends up with Torterra in it. Established Pokémon get a
        // prior — deliberately a modest one, so it nudges the search rather
        // than just rebuilding the usage list, and a genuinely better fringe
        // pick can still win the slot.
        for member in team {
            value += min(3.5, member.usage * 9)
            if let winrate = member.winrate { value += (winrate - 50) * 0.25 }
            value += member.proven
        }

        // Roles. The first holder of an essential role is worth a lot; the
        // second is worth almost nothing, which stops the search stacking two
        // Tailwind setters and calling it speed control.
        var counts: [TeamRole: Int] = [:]
        for member in team { for role in member.roles { counts[role, default: 0] += 1 } }
        for role in TeamRole.essentials where (counts[role] ?? 0) > 0 {
            value += 7 + (counts[role]! > 1 ? 0.5 : 0)
        }
        for role in [TeamRole.intimidate, .pivot, .wideGuard, .terrain]
        where (counts[role] ?? 0) > 0 { value += 2 }

        for type in PokeType.allCases {
            var weak = 0, resist = 0
            for member in team {
                let m = member.taken[type] ?? 1
                if m > 1 { weak += 1 } else if m < 1 { resist += 1 }
            }
            if weak >= 3 && resist == 0 { value -= 6 }
            else if weak >= 3 { value -= 2 }
        }

        var types = Set<PokeType>()
        for member in team { types.formUnion(member.types) }
        value += Double(types.count) * 1.2

        // Pairings, not just roles. A redirector and a setup sweeper are worth
        // more together than apart: Rage Powder is what buys the Swords Dance
        // turn, and a sweeper with no cover rarely gets to use it. Likewise a
        // setup sweeper with priority behind it is a win condition; without one
        // it is a Pokémon that spends a turn doing nothing.
        let redirects = team.contains { !$0.roles.isDisjoint(with: [.redirection]) }
        let setsUp = team.contains { profile in
            profile.form.moves.contains { store.move($0)?.selfBoosts.isEmpty == false }
        }
        let hasPriority = team.contains { profile in
            profile.form.moves.contains {
                guard let move = store.move($0) else { return false }
                return move.priority > 0 && move.isDamaging && move.power >= 40
            }
        }
        let hasStatus = team.contains { profile in
            profile.form.moves.contains { id in
                guard let move = store.move(id) else { return false }
                return move.effect.hasPrefix("Burns the target")
                    || move.effect.hasPrefix("Paralyzes the target")
                    || move.effect.hasPrefix("Puts the target to sleep")
            }
        }
        if redirects && setsUp { value += 6 }
        if setsUp && hasPriority { value += 5 }
        // Status is tempo, and the format rewards it: Intimidate and priority
        // are on most teams, and a burn blunts both.
        if hasStatus { value += 4 }

        if let enabler = plan.enabler {
            let sets = team.contains { $0.form.abilities.contains { $0.name == enabler } }
            let payoff = team.filter { benefits(from: plan, $0.form) }.count
            if brief?.plan == plan {
                // It was asked for. A six that does not put the weather up has
                // not answered the question, whatever else it scores, and one
                // that does has answered it even if nothing abuses it — halving
                // an incoming type is a reason to set weather all by itself.
                value += sets ? 14 : -25
                if sets && payoff >= 2 { value += 6 }
            } else if sets && payoff >= 2 {
                value += 10
            } else if sets && payoff == 0 {
                value -= 6
            }
        }
        if plan == .trickRoom {
            value += Double(team.filter { $0.speed <= 65 }.count) * 2.5
                - Double(team.filter { $0.speed >= 100 }.count) * 2.0
        }

        var seen = Set<Int>()
        for member in team where !seen.insert(member.dex).inserted { value -= 40 }
        let megas = team.filter(\.megaBuild)
        if dualMega {
            // The second Mega is the point, not a cost — but only if it answers
            // what the first one cannot. Two Megas weak to the same thing is
            // one Mega and a dead slot.
            if megas.count == 2 {
                value += 12 + complement(megas[0], megas[1])
            } else if megas.count > 2 {
                value -= 25
            }
        } else if megas.count > 2 {
            value -= 12
        } else if megas.count == 2 {
            value -= 4
        }
        if !team.contains(where: { $0.form.id == seed.id }) { value -= 100 }

        // Speed, which the search ignored outside of a Trick Room plan. A six
        // that is slower than the format and carries no way to fix that loses
        // the first move in most games, and nothing else here noticed.
        if plan != .trickRoom {
            let control = (counts[.tailwind] ?? 0) + (counts[.trickRoom] ?? 0)
            let fast = team.filter { $0.speed >= 90 }.count
            if control == 0 && fast <= 1 {
                value -= 8
            } else {
                value += Double(min(3, fast)) * 1.5
            }
        }

        // What the interview asked for. These are preferences with real weight,
        // not filters: a six that answers the brief but falls apart is still a
        // bad six, and the rest of the scoring still has to agree.
        if let brief {
            for type in brief.mustResist {
                let resists = team.contains { ($0.taken[type] ?? 1) < 1 }
                value += resists ? 7 : -7
            }
            for threat in brief.mustAnswer {
                let answered = team.contains { profile in
                    let multiplier = threat.pokeTypes.reduce(1.0) { running, type in
                        running * TypeChart.multiplier(type, into: profile.form,
                                                       ability: profile.form.abilities.first?.name)
                    }
                    // Beats it defensively, or simply outruns and outguns it.
                    return multiplier < 1
                        || (profile.speed > threat.speed
                            && max(profile.form.attack, profile.form.spAttack) >= 110)
                }
                value += answered ? 6 : -4
            }
            let meta = MetaModel(store: store, format: format)
            for name in brief.wantRoles {
                guard let group = MetaModel.roleGroups.first(where: { $0.name == name })
                else { continue }
                let filled = !meta.fills(group, in: teamOf(team.map(\.form))).isEmpty
                value += filled ? 5 : -3
            }
        }

        // A little balance between physical and special, so the whole team is
        // not walled by one bulky wall.
        let physical = team.filter(\.physical).count
        if physical == team.count || physical == 0 { value -= 4 }
        return value
    }

    /// How well a second Mega covers the first: the types the first takes badly
    /// that the second resists, less the ones they share.
    private func complement(_ first: Profile, _ second: Profile) -> Double {
        var covered = 0.0, shared = 0.0
        for type in PokeType.allCases {
            let a = first.taken[type] ?? 1
            let b = second.taken[type] ?? 1
            if a > 1 && b < 1 { covered += 1 }
            if a > 1 && b > 1 { shared += 1 }
        }
        // One attacks physically and one specially is worth real points: it
        // means the same wall cannot hold both lines.
        let split = first.physical != second.physical ? 3.0 : 0.0
        let speedSplit = abs(first.speed - second.speed) >= 30 ? 2.0 : 0.0
        return covered * 2.0 - shared * 2.5 + split + speedSplit
    }

    private func benefits(from plan: Archetype, _ form: Form) -> Bool {
        let ability = form.abilities.first?.name ?? ""
        switch plan {
        case .sun:   return ["Chlorophyll", "Solar Power"].contains(ability)
            || form.types.contains("Fire") || WeatherShield.shields(.sun, form)
        case .rain:  return ["Swift Swim", "Dry Skin", "Rain Dish"].contains(ability)
            || form.types.contains("Water") || WeatherShield.shields(.rain, form)
        case .sand:  return ["Sand Rush", "Sand Force"].contains(ability) || form.types.contains("Rock")
        case .snow:  return ["Slush Rush", "Ice Body"].contains(ability) || form.types.contains("Ice")
        case .grassy: return form.types.contains("Grass")
        case .psychicTerrain: return form.types.contains("Psychic")
        case .electric: return form.types.contains("Electric")
        case .trickRoom: return form.speed <= 65
        case .tailwind: return form.speed >= 90
        case .balance: return false
        }
    }

    /// Which plans suit the Pokémon being built around. A base 87 Speed Mega
    /// with 175 Attack is not a Tailwind sweeper and not a Trick Room abuser, so
    /// the builder should not pretend it is either.
    func plans(for seed: Form) -> [Archetype] {
        var out: [Archetype] = [.balance]
        // A plan the interview settled on is built whatever the seed's own
        // stats suggest.
        //
        // This is the single worst thing the builder can do and it was doing
        // it: the chosen plan was used to *sort* the finished blueprints rather
        // than to generate them, so when nothing of that shape had been built
        // there was nothing for the sort to find. Asking for rain around Mega
        // Golisopod produced a sand team, because Mega Golisopod is Bug/Steel
        // and so never qualified for a rain plan on its own typing — even
        // though halving the Fire moves that hit it for four times damage is
        // exactly why someone would ask for rain.
        if let chosen = brief?.plan, chosen != .balance { out.append(chosen) }
        if seed.speed <= 70 { out.append(.trickRoom) }
        if seed.speed >= 85 { out.append(.tailwind) }
        for plan: Archetype in [.sun, .rain, .sand, .snow, .grassy, .psychicTerrain, .electric] {
            if benefits(from: plan, seed) { out.append(plan) }
            // Or the seed sets it itself.
            if let enabler = plan.enabler,
               seed.abilities.contains(where: { $0.name == enabler }) {
                out.append(plan)
            }
        }
        var seen = Set<Archetype>()
        return out.filter { seen.insert($0).inserted }
    }

    private func teamOf(_ forms: [Form]) -> Team {
        var team = Team(name: "candidate", format: format)
        team.slots = forms.map { form in
            var slot = TeamSlot(formID: form.id)
            slot.ability = form.abilities.first?.name ?? ""
            return slot
        }
        return team
    }

    /// Beam search over the remaining slots.
    /// The beam, yielding as it goes.
    ///
    /// Yielding only between plans left four-hundred-millisecond blocks, which
    /// is what a frozen spinner with occasional stutters actually is: the
    /// animation getting one frame per plan. A frame needs the main thread
    /// every sixteen milliseconds, so this hands it back inside the beam.
    func search(seed: Form, plan: Archetype, pool: [Profile],
                        dualMega: Bool = false, beamWidth: Int = 8,
                        yielding: Bool) async -> [[Profile]] {
        guard let seedProfile = pool.first(where: { $0.form.id == seed.id })
                ?? profiles(for: [seed]).first else { return [] }
        var beam: [[Profile]] = [[seedProfile]]
        if let chosen = brief?.secondMegaID, chosen != seed.id,
           let partner = pool.first(where: { $0.form.id == chosen })
            ?? profiles(for: [store.formsByID[chosen]].compactMap { $0 }).first {
            beam = [[seedProfile, partner]]
        }
        let size = store.data.rules.formats.first { $0.id == format }?.teamSize ?? 6

        while (beam.first?.count ?? size) < size {
            var next: [([Profile], Double)] = []
            for partial in beam {
                let used = Set(partial.map(\.dex))
                var since = 0
                for candidate in pool where !used.contains(candidate.dex) {
                    let trial = partial + [candidate]
                    next.append((trial, quickScore(trial, seed: seed, plan: plan,
                                                   dualMega: dualMega)))
                    since += 1
                    if yielding, since % 60 == 0 { await breathe("beam") }
                }
            }
            var seen = Set<String>()
            beam = next.sorted { $0.1 > $1.1 }.compactMap { entry -> [Profile]? in
                let key = entry.0.map(\.form.id).sorted().joined(separator: "|")
                return seen.insert(key).inserted ? entry.0 : nil
            }
            .prefix(beamWidth).map { $0 }
            if beam.isEmpty { break }
            if yielding { await breathe("beam depth") }
        }
        return dualMega ? beam.filter { $0.filter(\.megaBuild).count == 2 } : beam
    }

    func searchSync(seed: Form, plan: Archetype, pool: [Profile],
                            dualMega: Bool = false, beamWidth: Int = 8) -> [[Profile]] {
        guard let seedProfile = pool.first(where: { $0.form.id == seed.id })
                ?? profiles(for: [seed]).first else { return [] }
        var beam: [[Profile]] = [[seedProfile]]
        // A second Mega chosen in the interview is a decision, not a
        // suggestion: the search fills around it rather than reconsidering it.
        if let chosen = brief?.secondMegaID, chosen != seed.id,
           let partner = pool.first(where: { $0.form.id == chosen })
            ?? profiles(for: [store.formsByID[chosen]].compactMap { $0 }).first {
            beam = [[seedProfile, partner]]
        }
        let size = store.data.rules.formats.first { $0.id == format }?.teamSize ?? 6

        while (beam.first?.count ?? size) < size {
            var next: [([Profile], Double)] = []
            for partial in beam {
                let used = Set(partial.map(\.dex))
                for candidate in pool where !used.contains(candidate.dex) {
                    let trial = partial + [candidate]
                    next.append((trial, quickScore(trial, seed: seed, plan: plan,
                                                   dualMega: dualMega)))
                }
            }
            var seen = Set<String>()
            beam = next.sorted { $0.1 > $1.1 }.compactMap { entry -> [Profile]? in
                let key = entry.0.map(\.form.id).sorted().joined(separator: "|")
                return seen.insert(key).inserted ? entry.0 : nil
            }
            .prefix(beamWidth).map { $0 }
            if beam.isEmpty { break }
        }
        // A two-Mega build that came back with one Mega is not the thing that
        // was asked for, so it is dropped rather than quietly returned.
        return dualMega ? beam.filter { $0.filter(\.megaBuild).count == 2 } : beam
    }

    /// Profiles for specific forms, for a seed that the pool filtered out.
    func profiles(for forms: [Form]) -> [Profile] {
        let advisor = TeamAdvisor(team: Team(), store: store)
        return forms.map { form in
            var taken: [PokeType: Double] = [:]
            for type in PokeType.allCases {
                taken[type] = TypeChart.multiplier(type, into: form,
                                                  ability: form.abilities.first?.name)
            }
            return Profile(form: form, dex: form.dex,
                           roles: advisor.potentialRoles(of: form),
                           types: form.pokeTypes, standing: 0, usage: 0, winrate: nil,
                           proven: provenCredit(form),
                           megaBuild: form.isMega, speed: form.speed,
                           physical: form.attack >= form.spAttack, taken: taken)
        }
    }
}
