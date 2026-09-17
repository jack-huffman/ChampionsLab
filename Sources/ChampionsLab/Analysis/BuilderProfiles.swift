//  BuilderProfiles.swift
//  What the search knows about each Pokemon before it starts.
//
//  Scoring a partial team against the full field with the damage calculator
//  would be millions of rolls, so the beam works from a precomputed standing
//  per Pokemon -- its worth against the format, the roles it can fill, the
//  archetypes it benefits from, and how established it is -- and only the
//  finished blueprints are run through the real matchup engine. This is the
//  pool the search draws from, and the profile it draws each candidate as.

import Foundation

extension TeamBuilder {
    /// Candidates worth considering. The whole roster is 349 forms and most are
    /// not competitively relevant; searching over all of them wastes the beam on
    /// noise. This keeps anything with a real standing, anything that fills an
    /// essential role, and everything in the usage table.
    func publicPool(picks: [Forecast.Pick]) -> [Form] { pool(picks: picks) }

    /// Candidates ordered by how established they are, not merely filtered.
    ///
    /// The pool used to be a flat list on a loose threshold, so a role could be
    /// filled by something nobody has played as readily as by what wins events.
    /// Top-meta picks are top-meta for a reason: this hands the search the
    /// established ones first and drops a tier only as far as it has to, which
    /// is how a person shops for a partner.
    func tieredPool(picks: [Forecast.Pick]) -> [Form] {
        let table = store.viabilityTable(picks: picks)
        let ranked = Dictionary(table.map { ($0.form.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pool(picks: picks).sorted { first, second in
            let a = ranked[first.id], b = ranked[second.id]
            let tierA = a?.tier ?? .unproven, tierB = b?.tier ?? .unproven
            if tierA != tierB { return tierA < tierB }
            // Within a tier, what is played more and doing better goes first.
            let playA = max(a?.ladder ?? 0, a?.tournament ?? 0)
            let playB = max(b?.ladder ?? 0, b?.tournament ?? 0)
            if abs(playA - playB) > 0.01 { return playA > playB }
            return (a?.standing ?? 0) > (b?.standing ?? 0)
        }
    }

    private func pool(picks: [Forecast.Pick]) -> [Form] {
        let standing = Dictionary(picks.map { ($0.form.id, $0.score) },
                                  uniquingKeysWith: { a, _ in a })
        let tracked = Set(store.data.usage.compactMap { store.form(named: $0.name)?.id })
        let advisor = TeamAdvisor(team: Team(), store: store)
        return store.data.forms.filter { form in
            if tracked.contains(form.id) { return true }
            if (standing[form.id] ?? -1) > 0.15 { return true }
            let roles = advisor.potentialRoles(of: form)
            return !roles.isDisjoint(with: [.tailwind, .trickRoom, .redirection,
                                            .terrain, .weather, .fakeOut])
                && form.bst >= 460
        }
    }

    /// Whether the build will hand this form a Mega Stone.
    ///
    /// `flesh` follows measured item usage, and the ladder's top item for
    /// Salamence is Salamencite on 99% of sets — so a "base" Salamence in a
    /// generated six is a Mega in every way that counts. Counting only forms
    /// named "Mega" let three Megas into a two-Mega team.
    func buildsAsMega(_ form: Form, usage: UsageEntry?) -> Bool {
        if form.isMega { return true }
        let stones = Set(store.data.forms
            .filter { $0.dex == form.dex && $0.isMega }
            .map(\.megaStone).filter { !$0.isEmpty })
        guard !stones.isEmpty else { return false }
        let items = usage?.itemUsage?.map(\.name) ?? usage?.commonItems ?? []
        return items.first.map { stones.contains($0) } ?? false
    }

    /// Everything the search needs about a candidate, worked out once.
    ///
    /// The beam evaluates thousands of partial teams; building a TeamAdvisor and
    /// re-deriving a learnset inside that loop is what made generation take
    /// seconds rather than a moment.
    struct Profile {
        let form: Form
        let dex: Int
        let roles: Set<TeamRole>
        let types: [PokeType]
        let standing: Double
        /// Share of teams running it on the measured ladder, 0…1.
        let usage: Double
        /// Measured winrate, where the ladder has one.
        let winrate: Double?
        /// Credit for being established in the format, 0…4.
        let proven: Double
        /// Fights as a Mega. Champions registers the base Pokémon holding its
        /// stone, so Salamence carrying a Salamencite is a Mega for every
        /// purpose that matters here even though the form is not named one.
        let megaBuild: Bool
        let speed: Int
        let physical: Bool
        /// Incoming multiplier for each of the 18 attacking types.
        let taken: [PokeType: Double]
    }

    /// The same work, letting go of the main thread as it goes.
    func profiles(picks: [Forecast.Pick], yielding: Bool) async -> [Profile] {
        let standing = Dictionary(picks.map { ($0.form.id, $0.score) },
                                  uniquingKeysWith: { a, _ in a })
        let advisor = TeamAdvisor(team: Team(), store: store)
        var out: [Profile] = []
        for (index, form) in tieredPool(picks: picks).enumerated() {
            if yielding, index % 8 == 0 { await breathe("profiles") }
            out.append(profile(of: form, standing: standing, advisor: advisor))
        }
        return out
    }

    private func profile(of form: Form, standing: [String: Double],
                         advisor: TeamAdvisor) -> Profile {
        var taken: [PokeType: Double] = [:]
        for type in PokeType.allCases {
            taken[type] = TypeChart.multiplier(type, into: form,
                                               ability: form.abilities.first?.name)
        }
        let measured = store.data.usage.first {
            $0.name == form.formLabel || $0.name == form.name
        }
        return Profile(form: form, dex: form.dex,
                       roles: advisor.potentialRoles(of: form),
                       types: form.pokeTypes,
                       standing: standing[form.id] ?? 0,
                       usage: (measured?.isProjected == false ? measured?.usage : nil)
                            .map { $0 / 100 } ?? 0,
                       winrate: measured?.winrate,
                       proven: provenCredit(form),
                       megaBuild: buildsAsMega(form, usage: measured), speed: form.speed,
                       physical: form.attack >= form.spAttack,
                       taken: taken)
    }

    /// Being established is worth something, and not very much.
    func provenCredit(_ form: Form) -> Double {
        switch store.viability(of: form)?.tier ?? .unproven {
        case .established: return 4
        case .strong:      return 2.5
        case .playable:    return 1.2
        case .fringe:      return 0
        case .unproven:    return -1
        }
    }

    func profiles(picks: [Forecast.Pick]) -> [Profile] {
        let standing = Dictionary(picks.map { ($0.form.id, $0.score) },
                                  uniquingKeysWith: { a, _ in a })
        let advisor = TeamAdvisor(team: Team(), store: store)
        return tieredPool(picks: picks).map { form in
            var taken: [PokeType: Double] = [:]
            for type in PokeType.allCases {
                taken[type] = TypeChart.multiplier(type, into: form,
                                                  ability: form.abilities.first?.name)
            }
            let measured = store.data.usage.first {
                $0.name == form.formLabel || $0.name == form.name
            }
            return Profile(form: form, dex: form.dex,
                           roles: advisor.potentialRoles(of: form),
                           types: form.pokeTypes,
                           standing: standing[form.id] ?? 0,
                           usage: (measured?.isProjected == false ? measured?.usage : nil).map { $0 / 100 } ?? 0,
                           winrate: measured?.winrate,
                           proven: provenCredit(form),
                           megaBuild: buildsAsMega(form, usage: measured), speed: form.speed,
                           physical: form.attack >= form.spAttack,
                           taken: taken)
        }
    }
}
