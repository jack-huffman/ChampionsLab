//  Builder.swift
//  Build a whole team around a Pokémon, several different ways.
//
//  The evaluation here is deliberately not the one-on-one aggregate the Versus
//  screen uses. That model scores trades, and a trade model cannot see that
//  Tailwind doubles the whole side's Speed for four turns or that Rage Powder
//  buys a partner a free turn — run on a real team it recommends cutting
//  Whimsicott, which is wrong. A team is scored here on five components, and
//  support earns its slot in three of them.
//
//  Search is a beam over slots. Scoring a partial team against the full field
//  with the damage calculator would be millions of rolls, so the search uses a
//  precomputed per-Pokémon standing and only the finished blueprints are run
//  through the real matchup engine.

import Foundation

// MARK: - Scoring

struct TeamScore {
    /// Average edge against the bundled archetypes, −100…100.
    var matchup = 0.0
    /// Essential roles filled, 0…1.
    var roles = 0.0
    /// Absence of stacked weaknesses, 0…1.
    var defence = 0.0
    /// Attacking types represented, 0…1.
    var coverage = 0.0
    /// Whether the plan hangs together — enabler with payoff, speed control.
    var synergy = 0.0
    var violations: [String] = []

    /// 0…100. Matchup is the largest single term but deliberately not a
    /// majority, so a team of six strong attackers with no speed control and no
    /// redirection cannot outscore a coherent one.
    var total: Int {
        let raw = (matchup + 100) / 200 * 38
            + roles * 24
            + defence * 14
            + coverage * 12
            + synergy * 12
        return max(0, min(100, Int(raw.rounded()) - violations.count * 3))
    }
}

// MARK: - Blueprint

struct Blueprint: Identifiable {
    let id = UUID()
    let plan: Archetype
    let title: String
    let rationale: String
    var team: Team
    var score: TeamScore
    /// Per-archetype results, filled in for the finalists only.
    var perArchetype: [(name: String, edge: Int)] = []
    var notes: [String] = []
}

// MARK: - Builder

@MainActor
struct TeamBuilder {
    let store: Store
    var format = "doubles"

    /// Candidates worth considering. The whole roster is 349 forms and most are
    /// not competitively relevant; searching over all of them wastes the beam on
    /// noise. This keeps anything with a real standing, anything that fills an
    /// essential role, and everything in the usage table.
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
        let isMega: Bool
        let speed: Int
        let physical: Bool
        /// Incoming multiplier for each of the 18 attacking types.
        let taken: [PokeType: Double]
    }

    func profiles(picks: [Forecast.Pick]) -> [Profile] {
        let standing = Dictionary(picks.map { ($0.form.id, $0.score) },
                                  uniquingKeysWith: { a, _ in a })
        let advisor = TeamAdvisor(team: Team(), store: store)
        return pool(picks: picks).map { form in
            var taken: [PokeType: Double] = [:]
            for type in PokeType.allCases {
                taken[type] = TypeChart.multiplier(type, into: form,
                                                  ability: form.abilities.first?.name)
            }
            return Profile(form: form, dex: form.dex,
                           roles: advisor.potentialRoles(of: form),
                           types: form.pokeTypes,
                           standing: standing[form.id] ?? 0,
                           isMega: form.isMega, speed: form.speed,
                           physical: form.attack >= form.spAttack,
                           taken: taken)
        }
    }

    // MARK: Cheap scoring, used inside the search

    /// A partial team's quality without running the damage calculator.
    private func quickScore(_ team: [Profile], seed: Form, plan: Archetype) -> Double {
        guard !team.isEmpty else { return 0 }
        var value = 0.0

        value += team.reduce(0.0) { $0 + $1.standing } / Double(team.count) * 22

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

        if let enabler = plan.enabler {
            let sets = team.contains { $0.form.abilities.contains { $0.name == enabler } }
            let payoff = team.filter { benefits(from: plan, $0.form) }.count
            if sets && payoff >= 2 { value += 10 }
            else if sets && payoff == 0 { value -= 6 }
        }
        if plan == .trickRoom {
            value += Double(team.filter { $0.speed <= 65 }.count) * 2.5
                - Double(team.filter { $0.speed >= 100 }.count) * 2.0
        }

        var seen = Set<Int>()
        for member in team where !seen.insert(member.dex).inserted { value -= 40 }
        let megas = team.filter(\.isMega).count
        if megas > 2 { value -= 12 } else if megas == 2 { value -= 4 }
        if !team.contains(where: { $0.form.id == seed.id }) { value -= 100 }

        // A little balance between physical and special, so the whole team is
        // not walled by one bulky wall.
        let physical = team.filter(\.physical).count
        if physical == team.count || physical == 0 { value -= 4 }
        return value
    }

    private func benefits(from plan: Archetype, _ form: Form) -> Bool {
        let ability = form.abilities.first?.name ?? ""
        switch plan {
        case .sun:   return ["Chlorophyll", "Solar Power"].contains(ability) || form.types.contains("Fire")
        case .rain:  return ["Swift Swim", "Dry Skin", "Rain Dish"].contains(ability) || form.types.contains("Water")
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

    // MARK: Plans worth trying for a seed

    /// Which plans suit the Pokémon being built around. A base 87 Speed Mega
    /// with 175 Attack is not a Tailwind sweeper and not a Trick Room abuser, so
    /// the builder should not pretend it is either.
    func plans(for seed: Form) -> [Archetype] {
        var out: [Archetype] = [.balance]
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

    // MARK: Search

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
    private func search(seed: Form, plan: Archetype, pool: [Profile],
                        beamWidth: Int = 8) -> [[Profile]] {
        guard let seedProfile = pool.first(where: { $0.form.id == seed.id })
                ?? profiles(for: [seed]).first else { return [] }
        var beam: [[Profile]] = [[seedProfile]]
        let size = store.data.rules.formats.first { $0.id == format }?.teamSize ?? 6

        while (beam.first?.count ?? size) < size {
            var next: [([Profile], Double)] = []
            for partial in beam {
                let used = Set(partial.map(\.dex))
                for candidate in pool where !used.contains(candidate.dex) {
                    let trial = partial + [candidate]
                    next.append((trial, quickScore(trial, seed: seed, plan: plan)))
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
        return beam
    }

    /// Profiles for specific forms, for a seed that the pool filtered out.
    private func profiles(for forms: [Form]) -> [Profile] {
        let advisor = TeamAdvisor(team: Team(), store: store)
        return forms.map { form in
            var taken: [PokeType: Double] = [:]
            for type in PokeType.allCases {
                taken[type] = TypeChart.multiplier(type, into: form,
                                                  ability: form.abilities.first?.name)
            }
            return Profile(form: form, dex: form.dex,
                           roles: advisor.potentialRoles(of: form),
                           types: form.pokeTypes, standing: 0,
                           isMega: form.isMega, speed: form.speed,
                           physical: form.attack >= form.spAttack, taken: taken)
        }
    }

    // MARK: Fleshing a team out

    /// Give a form the build it is actually used with, falling back to its role.
    private func flesh(_ form: Form, plan: Archetype, usedItems: inout Set<String>) -> TeamSlot {
        var slot = TeamSlot(formID: form.id)
        let advisor = TeamAdvisor(team: Team(), store: store)
        let roles = advisor.potentialRoles(of: form)
        let usage = store.data.usage.first { $0.name == form.formLabel || $0.name == form.name }

        slot.ability = preferredAbility(form, plan: plan)

        // Item: what it is usually seen with, else something that suits the role.
        let physicalAttacker = form.attack >= form.spAttack
        var wanted: [String] = usage?.commonItems ?? []
        if form.isMega { wanted = [form.megaStone.isEmpty ? "Mega Stone" : form.megaStone] }
        // A Choice item has to match the attacking stat: Specs on an Adamant
        // physical attacker is a wasted slot, which an earlier version did.
        wanted += roles.contains(.redirection) || roles.contains(.tailwind)
            ? ["Focus Sash", "Sitrus Berry", "Covert Cloak", "Mental Herb"]
            : (physicalAttacker
               ? ["Life Orb", "Choice Band", "Assault Vest", "Sitrus Berry", "Leftovers"]
               : ["Life Orb", "Choice Specs", "Assault Vest", "Sitrus Berry", "Leftovers"])
        slot.item = wanted.first { store.item(named: $0) != nil && !usedItems.contains($0) }
            ?? "Leftovers"
        usedItems.insert(slot.item)

        // Spread and alignment: bulky for support, offensive otherwise.
        let support = roles.contains(.redirection) || roles.contains(.tailwind)
            || roles.contains(.trickRoom) || roles.contains(.terrain)
        let physical = form.attack >= form.spAttack
        if support {
            slot.sp = [32, 0, 16, 0, 16, 2]
            // Never lower the stat it actually attacks with. Calm drops Attack,
            // which is wrong on a physical supporter like Grimmsnarl; Careful
            // drops Sp. Atk instead, and Timid drops Attack for a fast special one.
            slot.alignmentName = form.speed >= 90
                ? (physical ? "Jolly" : "Timid")
                : (physical ? "Careful" : "Calm")
        } else {
            slot.sp = physical ? [2, 32, 0, 0, 0, 32] : [2, 0, 0, 32, 0, 32]
            slot.alignmentName = plan == .trickRoom
                ? (physical ? "Brave" : "Quiet")
                : (physical ? "Adamant" : "Modest")
            if plan == .trickRoom { slot.sp = physical ? [32, 32, 2, 0, 0, 0] : [32, 0, 2, 32, 0, 0] }
        }

        slot.moves = chooseMoves(form, roles: roles, plan: plan, usage: usage)
        return slot
    }

    private func preferredAbility(_ form: Form, plan: Archetype) -> String {
        if let enabler = plan.enabler,
           form.abilities.contains(where: { $0.name == enabler }) { return enabler }
        // Prefer the ability the format actually uses it for.
        let priority = ["Intimidate", "Prankster", "Good as Gold", "Levitate",
                        "Adaptability", "Huge Power", "Unburden", "Armor Tail",
                        "Multiscale", "Thermal Exchange", "Tough Claws"]
        for name in priority where form.abilities.contains(where: { $0.name == name }) {
            return name
        }
        return form.abilities.first?.name ?? ""
    }

    private func chooseMoves(_ form: Form, roles: Set<TeamRole>, plan: Archetype,
                             usage: UsageEntry?) -> [String] {
        var chosen: [String] = []
        let learnset = store.moves(for: form)
        func add(_ name: String) {
            guard chosen.count < 4, let move = learnset.first(where: { $0.name == name }),
                  !chosen.contains(move.id) else { return }
            chosen.append(move.id)
        }

        // Whatever it is actually known for.
        for name in usage?.keyMoves ?? [] { add(name) }

        // The role move is the reason the slot exists, so it goes in early.
        if plan == .trickRoom { add("Trick Room") }
        if roles.contains(.tailwind) { add("Tailwind") }
        if roles.contains(.redirection) { add("Follow Me"); add("Rage Powder") }
        if roles.contains(.fakeOut) { add("Fake Out") }
        if let enabler = plan.enabler, form.abilities.contains(where: { $0.name == enabler }) == false {
            add(plan.rawValue)   // e.g. the Terrain move itself
        }

        // Then the strongest usable attack per type, for coverage.
        let physical = form.attack >= form.spAttack
        let attacks = store.attackingMoves(for: form)
            .filter { physical ? $0.category == "Physical" : $0.category == "Special" }
            .sorted { lhs, rhs in
                let l = Double(lhs.power) * (form.types.contains(lhs.type) ? 1.5 : 1)
                let r = Double(rhs.power) * (form.types.contains(rhs.type) ? 1.5 : 1)
                return l > r
            }
        // Skip Normal-type filler. A 120 BP Mega Kick on a Dark/Fairy Pokémon
        // is worse than nothing — it is resisted or blanked by most of what it
        // would ever be aimed at, and it crowds out real coverage.
        let usesNormal = form.types.contains("Normal")
            || form.abilities.contains { ["Aerilate", "Pixilate", "Refrigerate",
                                          "Galvanize", "Normalize"].contains($0.name) }
        var seenTypes = Set<String>()
        for move in attacks where move.type != "Normal" || usesNormal {
            if seenTypes.insert(move.type).inserted { add(move.name) }
        }
        add("Protect")
        return chosen
    }

    // MARK: Public entry point

    /// Build several complete teams around `seed`, one per viable plan, each
    /// fully evaluated against the bundled archetypes.
    func blueprints(seed: Form, picks: [Forecast.Pick], perPlan: Int = 1) -> [Blueprint] {
        var candidates = profiles(picks: picks)
        if !candidates.contains(where: { $0.form.id == seed.id }) {
            candidates += profiles(for: [seed])
        }
        var out: [Blueprint] = []
        // Different plans often converge on the same six; show each set once,
        // attributed to the plan that scored it highest.
        var seenTeams = Set<String>()

        for plan in plans(for: seed) {
            let results = search(seed: seed, plan: plan, pool: candidates)
            var taken = 0
            for profileSet in results {
                guard taken < perPlan else { break }
                let key = profileSet.map(\.form.id).sorted().joined(separator: "|")
                guard seenTeams.insert(key).inserted else { continue }
                taken += 1

                var usedItems = Set<String>()
                var team = Team(name: "\(seed.formLabel) · \(plan.rawValue)", format: format)
                team.slots = profileSet.map { flesh($0.form, plan: plan, usedItems: &usedItems) }
                team.locked = true
                let scored = evaluate(team, plan: plan)
                out.append(Blueprint(plan: plan,
                                     title: "\(seed.formLabel) · \(plan.rawValue)",
                                     rationale: plan.advice,
                                     team: team, score: scored.0,
                                     perArchetype: scored.1,
                                     notes: TeamAdvisor(team: team, store: store)
                                        .metaNotes.map(\.title)))
            }
        }
        return out.sorted { $0.score.total > $1.score.total }
    }

    /// The real evaluation, run on finished teams only.
    func evaluate(_ team: Team, plan: Archetype) -> (TeamScore, [(String, Int)]) {
        let advisor = TeamAdvisor(team: team, store: store)
        let analysis = TeamAnalysis(team: team, store: store)
        var score = TeamScore()

        // Matchups, with the team's own speed control switched on — this is the
        // fix for the trade model undervaluing support.
        let held = advisor.rolesPresent
        let hasTailwind = !(held[.tailwind]?.isEmpty ?? true)
        let hasTrickRoom = !(held[.trickRoom]?.isEmpty ?? true)
        var perArchetype: [(String, Int)] = []
        var total = 0.0, count = 0.0
        for meta in store.data.metaTeams where meta.format == team.format {
            let theirs = TeamPaste.team(from: meta, store: store)
            // Opponents in this format nearly all carry Tailwind of their own.
            let matchup = Matchup(mine: team, theirs: theirs, store: store,
                                  field: Field(isDoubles: team.format == "doubles"),
                                  myTailwind: hasTailwind, theirTailwind: true,
                                  myTrickRoom: hasTrickRoom)
            let edge = matchup.verdict.score
            perArchetype.append((meta.name, edge))
            total += Double(edge); count += 1
        }
        score.matchup = count > 0 ? total / count : 0

        let filled = TeamRole.essentials.filter { !(held[$0]?.isEmpty ?? true) }.count
        score.roles = Double(filled) / Double(TeamRole.essentials.count)
        score.defence = 1 - min(1, Double(analysis.softSpots.count) / 8)
        score.coverage = Double(analysis.coverage.filter { !$0.carriers.isEmpty }.count) / 18
        let detected = advisor.archetypes
        score.synergy = detected.contains { $0.archetype == plan && $0.isSupported } ? 1
            : (detected.contains { $0.isSupported } ? 0.6 : 0.25)
        score.violations = team.violations(in: store)
        return (score, perArchetype)
    }
}
