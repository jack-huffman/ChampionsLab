//  Advisor.swift
//  The assisted builder: what a team is trying to do, what it is missing, and
//  what to add next.
//
//  Type coverage alone does not build a doubles team. A team can resist
//  everything and still lose because it has no way to move first, nothing to
//  absorb a turn, and no answer to the Pokémon that sets terrain against it. So
//  this works in three passes: read the roles the team already fills, infer the
//  archetype it is reaching for, then rank additions on role, defence, offence
//  and how well they suit that archetype.

import Foundation

// MARK: - Roles

/// A job a slot does. Detected from moves and abilities, never assumed.
enum TeamRole: String, CaseIterable, Identifiable {
    case tailwind = "Tailwind"
    case trickRoom = "Trick Room"
    case redirection = "Redirection"
    case intimidate = "Intimidate"
    case fakeOut = "Fake Out"
    case pivot = "Pivot"
    case terrain = "Terrain"
    case weather = "Weather"
    case spread = "Spread damage"
    case priority = "Priority"
    case screens = "Screens"
    case wideGuard = "Wide Guard"
    case breaker = "Wallbreaker"
    case cleaner = "Cleaner"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .tailwind:    return "Doubling your side's Speed for four turns is the format's default answer to being outrun."
        case .trickRoom:   return "The other way to move first: invert the order and bring Pokémon that are slow on purpose."
        case .redirection: return "Follow Me and Rage Powder buy a turn by absorbing what was aimed at your partner."
        case .intimidate:  return "A free Attack drop on entry, and the cheapest way to blunt a physical Mega."
        case .fakeOut:     return "A free turn of flinch on the lead, which is often the turn you need to set up."
        case .pivot:       return "U-turn, Volt Switch, Flip Turn and Parting Shot let you leave a bad matchup without losing tempo."
        case .terrain:     return "Terrain changes what the whole field is allowed to do — halving Earthquake or switching off priority."
        case .weather:     return "Sun, rain, sand and snow each power a whole archetype and shut another one down."
        case .spread:      return "Moves that hit both opponents are how doubles games are actually won."
        case .priority:    return "Moving first regardless of Speed, which is how you close a game against something faster."
        case .screens:     return "Reflect and Light Screen buy your setup two turns of survival."
        case .wideGuard:   return "Blanks the spread moves that punish slow teams — Rock Slide, Earthquake, Heat Wave."
        case .breaker:     return "Something that removes a wall so the rest of the team can operate."
        case .cleaner:     return "Fast and strong enough to take the last two Pokémon once the board is even."
        }
    }

    /// Roles a doubles team should nearly always have one of.
    static var essentials: [TeamRole] {
        [.tailwind, .redirection, .fakeOut, .spread, .priority]
    }
}

// MARK: - Archetypes

enum Archetype: String, CaseIterable, Identifiable {
    case sun = "Sun", rain = "Rain", sand = "Sand", snow = "Snow"
    case grassy = "Grassy Terrain", psychicTerrain = "Psychic Terrain"
    case electric = "Electric Terrain"
    case trickRoom = "Trick Room", tailwind = "Tailwind offence"
    case balance = "Balance"

    var id: String { rawValue }

    /// The ability that defines the archetype, where one does.
    var enabler: String? {
        switch self {
        case .sun:            return "Drought"
        case .rain:           return "Drizzle"
        case .sand:           return "Sand Stream"
        case .snow:           return "Snow Warning"
        case .grassy:         return "Grassy Surge"
        case .psychicTerrain: return "Psychic Surge"
        case .electric:       return "Electric Surge"
        default:              return nil
        }
    }

    var advice: String {
        switch self {
        case .sun:   return "Sun wants Chlorophyll or Solar Power partners and a Fire attacker; it loses to rain, so a second win condition matters."
        case .rain:  return "Rain wants Swift Swim and a Water attacker. Politoed and Pelipper are the only two Drizzle users in the roster."
        case .sand:  return "Sand chips everything that is not Rock, Ground or Steel, which pairs with bulky Steels rather than fast attackers."
        case .snow:  return "Snow raises Ice-type Defense by 50%, so it is a defensive shell rather than an offensive one."
        case .grassy: return "Grassy Terrain halves Earthquake and heals your grounded side each turn. It is the structural answer to the Garchomp cores."
        case .psychicTerrain: return "Psychic Terrain blocks all priority against your grounded side — it turns off Sucker Punch, Fake Out, Aqua Jet and Grassy Glide at once."
        case .electric: return "Electric Terrain blocks sleep and doubles Rising Voltage. The narrowest of the four, but the sleep immunity is real."
        case .trickRoom: return "Trick Room wants Pokémon under about base 60 Speed and something to protect the setup turn — Armor Tail or redirection."
        case .tailwind: return "Tailwind offence wants attackers that are already fast, so four turns of doubled Speed converts into knockouts rather than just parity."
        case .balance: return "No single plan detected. That is fine, but check that the team can still move first and force damage without setup."
        }
    }
}

// MARK: - Advisor

@MainActor
struct TeamAdvisor {
    let team: Team
    let store: Store

    private var members: [(slot: TeamSlot, form: Form)] {
        team.slots.compactMap { slot in
            // Read the Mega, since that is what actually fights.
            guard let form = slot.battleForm(in: store.rulebook) else { return nil }
            return (slot, form)
        }
    }

    /// Moves a slot has selected, or its whole learnset if it has none.
    ///
    /// The learnset, not the attacking subset: Follow Me, Tailwind, Trick Room
    /// and Wide Guard are all status moves, so probing with attacks only made
    /// every support role undetectable — the advisor would report "no
    /// redirection" and then never suggest a redirector.
    private func moves(_ slot: TeamSlot, _ form: Form) -> [Move] {
        let chosen = slot.moves.compactMap { store.move($0) }
        return chosen.isEmpty ? store.moves(for: form) : chosen
    }

    /// Roles a form could fill if built for it — used to judge candidates,
    /// which have no chosen moveset yet.
    func potentialRoles(of form: Form) -> Set<TeamRole> {
        roles(of: TeamSlot(formID: form.id), form: form)
    }

    private func ability(_ slot: TeamSlot, _ form: Form) -> String {
        slot.ability.isEmpty ? (form.abilities.first?.name ?? "") : slot.ability
    }

    // MARK: Role detection

    /// Which roles a single Pokémon fills, given its moves and ability.
    func roles(of slot: TeamSlot, form: Form) -> Set<TeamRole> {
        var found: Set<TeamRole> = []
        let names = Set(moves(slot, form).map(\.name))
        let ability = ability(slot, form)
        let all = moves(slot, form)

        if names.contains("Tailwind") { found.insert(.tailwind) }
        if names.contains("Trick Room") { found.insert(.trickRoom) }
        if names.contains("Follow Me") || names.contains("Rage Powder") { found.insert(.redirection) }
        if ability == "Intimidate" { found.insert(.intimidate) }
        if names.contains("Fake Out") { found.insert(.fakeOut) }
        if !names.isDisjoint(with: ["U-turn", "Volt Switch", "Flip Turn", "Parting Shot"]) {
            found.insert(.pivot)
        }
        if ability.hasSuffix("Surge") || names.contains(where: { $0.hasSuffix("Terrain") }) {
            found.insert(.terrain)
        }
        if ["Drought", "Drizzle", "Sand Stream", "Snow Warning"].contains(ability) {
            found.insert(.weather)
        }
        if all.contains(where: { $0.isSpread && $0.isDamaging }) { found.insert(.spread) }
        if all.contains(where: { $0.priority > 0 && $0.isDamaging }) { found.insert(.priority) }
        if !names.isDisjoint(with: ["Reflect", "Light Screen", "Aurora Veil"]) { found.insert(.screens) }
        if names.contains("Wide Guard") { found.insert(.wideGuard) }

        // Stat-shaped roles.
        let offence = max(form.attack, form.spAttack)
        if offence >= 130 { found.insert(.breaker) }
        if offence >= 110 && form.speed >= 100 { found.insert(.cleaner) }
        return found
    }

    var rolesPresent: [TeamRole: [Form]] {
        var out: [TeamRole: [Form]] = [:]
        for member in members {
            for role in roles(of: member.slot, form: member.form) {
                out[role, default: []].append(member.form)
            }
        }
        return out
    }

    var missingEssentials: [TeamRole] {
        let have = rolesPresent
        return TeamRole.essentials.filter { have[$0]?.isEmpty ?? true }
    }

    // MARK: Archetype

    struct Detected: Identifiable {
        let archetype: Archetype
        let enabledBy: [Form]
        let payoff: [Form]
        var id: String { archetype.rawValue }
        /// An enabler with nothing that benefits is a wasted slot.
        var isSupported: Bool { !payoff.isEmpty }
    }

    var archetypes: [Detected] {
        var out: [Detected] = []
        let present = members

        for archetype in Archetype.allCases where archetype != .balance {
            var enablers: [Form] = []
            for member in present {
                let ability = ability(member.slot, member.form)
                if let enabler = archetype.enabler, ability == enabler {
                    enablers.append(member.form)
                }
                if archetype == .trickRoom,
                   moves(member.slot, member.form).contains(where: { $0.name == "Trick Room" }) {
                    enablers.append(member.form)
                }
                if archetype == .tailwind,
                   moves(member.slot, member.form).contains(where: { $0.name == "Tailwind" }) {
                    enablers.append(member.form)
                }
            }
            guard !enablers.isEmpty else { continue }
            out.append(Detected(archetype: archetype, enabledBy: enablers,
                                payoff: beneficiaries(of: archetype)))
        }
        if out.isEmpty {
            out.append(Detected(archetype: .balance, enabledBy: [], payoff: []))
        }
        return out
    }

    /// Team members that actually gain from the archetype being up.
    private func beneficiaries(of archetype: Archetype) -> [Form] {
        members.compactMap { member in
            let ability = ability(member.slot, member.form)
            let types = member.form.types
            switch archetype {
            case .sun:
                if ["Chlorophyll", "Solar Power", "Flower Gift"].contains(ability) { return member.form }
                return types.contains("Fire") ? member.form : nil
            case .rain:
                if ["Swift Swim", "Rain Dish", "Hydration", "Dry Skin"].contains(ability) { return member.form }
                return types.contains("Water") ? member.form : nil
            case .sand:
                if ["Sand Rush", "Sand Force", "Sand Veil"].contains(ability) { return member.form }
                return types.contains(where: { ["Rock", "Ground", "Steel"].contains($0) }) ? member.form : nil
            case .snow:
                if ["Slush Rush", "Snow Cloak", "Ice Body"].contains(ability) { return member.form }
                return types.contains("Ice") ? member.form : nil
            case .grassy:
                return types.contains("Grass") ? member.form : nil
            case .psychicTerrain:
                return types.contains("Psychic") ? member.form : nil
            case .electric:
                return types.contains("Electric") ? member.form : nil
            case .trickRoom:
                // Anything genuinely slow benefits; a fast attacker is hurt by it.
                return member.form.speed <= 65 ? member.form : nil
            case .tailwind:
                return member.form.speed >= 90 ? member.form : nil
            case .balance:
                return nil
            }
        }
    }

    // MARK: Mega and item checks

    struct Note: Identifiable {
        let severity: Severity
        let title: String
        let detail: String
        var id: String { title }
        enum Severity { case problem, caution, good }
    }

    /// Checks specific to what Regulation M-C changed.
    var metaNotes: [Note] {
        var out: [Note] = []
        let present = members

        // Megas: registered vs usable, and whether the stone is actually held.
        let megaSlots = team.slots.filter { $0.megaEvolution(in: store.rulebook) != nil }
        let megaForms = team.slots.compactMap { $0.form(in: store.rulebook) }.filter(\.isMega)
        if megaSlots.isEmpty && megaForms.isEmpty {
            out.append(Note(severity: .caution, title: "No Mega Evolution",
                            detail: "M-C added six Megas and the format is built around them. A team without one is giving up its once-per-battle gimmick — there is no Terastallization here to fall back on."))
        } else if megaSlots.count > 1 {
            out.append(Note(severity: .caution,
                            title: "\(megaSlots.count) Megas registered",
                            detail: "Legal, and common on tournament lists as a matchup choice, but only one can Mega Evolve per battle. The others are paying an item slot for nothing on the turns they are out."))
        }
        for slot in team.slots {
            guard let form = slot.form(in: store.rulebook), !form.isMega else { continue }
            let hasMega = store.data.forms.contains { $0.dex == form.dex && $0.isMega }
            if hasMega && slot.megaEvolution(in: store.rulebook) == nil && !slot.item.isEmpty {
                out.append(Note(severity: .caution,
                                title: "\(form.formLabel) is not holding its stone",
                                detail: "It has a Mega form, but with \(slot.item) it will fight in its base form all game."))
            }
        }

        // Terrain, the M-C story.
        let setters = present.filter { ability($0.slot, $0.form).hasSuffix("Surge") }
        let grounded = present.filter { !$0.form.types.contains("Flying")
            && ability($0.slot, $0.form) != "Levitate" }
        if setters.isEmpty {
            out.append(Note(severity: .caution, title: "No terrain, and no protection from it",
                            detail: "M-C shipped Rillaboom, Indeedee and Pincurchin alongside Terrain Extender and all four Seeds. \(grounded.count) of your \(present.count) are grounded, so an opposing Psychic Terrain switches off your priority and an opposing Grassy Terrain halves your Earthquake — while you get nothing back."))
        } else if let setter = setters.first {
            let extender = present.contains { $0.slot.item == "Terrain Extender" }
            out.append(Note(severity: extender ? .good : .caution,
                            title: "Terrain set by \(setter.form.formLabel)",
                            detail: extender
                            ? "Terrain Extender takes it from five turns to eight, which is most of a game."
                            : "Without Terrain Extender this only lasts five turns. The item exists in M-C specifically to fix that."))
        }

        // Contact tax, the other M-C story.
        let contactMegas = present.filter { member in
            member.form.isMega && moves(member.slot, member.form)
                .contains { $0.makesContact && $0.isDamaging }
        }
        if !contactMegas.isEmpty {
            let helmet = present.contains { $0.slot.item == "Rocky Helmet" }
            out.append(Note(severity: .caution,
                            title: "\(contactMegas.map(\.form.formLabel).joined(separator: ", ")) attacks by contact",
                            detail: "Rocky Helmet is new in M-C and taxes contact 1/6 per hit, and Mega Lucario Z's Aura Guard halves it. \(helmet ? "You carry a Helmet yourself, which is the same tax in the other direction." : "Expect to meet one.")"))
        }
        return out
    }

    // MARK: Recommendations

    struct Recommendation: Identifiable {
        let form: Form
        let score: Double
        let fillsRoles: [TeamRole]
        let resists: [PokeType]
        let answers: [String]
        let archetypeFit: String?
        var id: String { form.id }

        var headline: String {
            var parts: [String] = []
            if !fillsRoles.isEmpty {
                parts.append(fillsRoles.map(\.rawValue).joined(separator: ", "))
            }
            if let archetypeFit { parts.append(archetypeFit) }
            if !resists.isEmpty {
                parts.append("resists " + resists.prefix(3).map(\.rawValue).joined(separator: "/"))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Rank additions on the four things that actually matter for a next pick:
    /// the roles the team lacks, the types it is weak to, the threats it cannot
    /// answer, and whether the candidate suits the plan already on the board.
    func recommendations(limit: Int = 12,
                         picks: [Forecast.Pick]) -> [Recommendation] {
        let analysis = TeamAnalysis(team: team, store: store)
        let soft = analysis.softSpots.prefix(4).map(\.type)
        let missing = missingEssentials
        let onTeam = Set(team.slots.compactMap { $0.form(in: store.rulebook)?.dex })
        let plans = archetypes.filter { $0.archetype != .balance }
        let hasMega = !team.slots.compactMap { $0.form(in: store.rulebook) }.filter(\.isMega).isEmpty
            || team.slots.contains { $0.megaEvolution(in: store.rulebook) != nil }

        // Anti-meta standing, from the Forecast engine, as a baseline of quality.
        let standing = Dictionary(picks.map { ($0.form.id, $0) },
                                  uniquingKeysWith: { a, _ in a })

        var out: [Recommendation] = []
        for candidate in store.data.forms where !onTeam.contains(candidate.dex) {
            var score = 0.0
            var fills: [TeamRole] = []
            var resists: [PokeType] = []

            // A candidate is judged with its own likely moveset.
            let candidateRoles = potentialRoles(of: candidate)
            for role in missing where candidateRoles.contains(role) {
                // The dominant term. A team missing redirection needs a
                // redirector more than it needs another good Pokémon.
                score += 4.0
                fills.append(role)
            }

            for type in soft {
                let taken = TypeChart.multiplier(type, into: candidate,
                                                 ability: candidate.abilities.first?.name)
                if taken == 0 { score += 2.0; resists.append(type) }
                else if taken < 1 { score += 1.2; resists.append(type) }
            }

            var fit: String? = nil
            for plan in plans {
                if let enabler = plan.archetype.enabler,
                   candidate.abilities.contains(where: { $0.name == enabler }) {
                    // A second weather or terrain setter is redundancy, not value.
                    score += plan.enabledBy.isEmpty ? 3.0 : 0.5
                    fit = "sets \(plan.archetype.rawValue)"
                } else if beneficiaryOf(plan.archetype, candidate) {
                    score += 1.8
                    fit = fit ?? "suits \(plan.archetype.rawValue)"
                }
            }

            // Quality baseline: how it fares against the field on its own.
            // Weighted enough to separate Sinistcha from Ariados, both of which
            // technically have Rage Powder, without letting raw quality outrank
            // an unfilled essential role.
            let pick = standing[candidate.id]
            score += (pick?.score ?? -0.4) * 2.5

            // One Mega is the gimmick; a second is usually not what a team needs.
            // One Mega is the gimmick and only one can be used per battle, so a
            // third is rarely the answer to anything.
            if candidate.isMega && hasMega { score -= 2.5 }

            if score > 2.0 {
                out.append(Recommendation(
                    form: candidate, score: score,
                    fillsRoles: fills, resists: Array(Set(resists)).sorted { $0.rawValue < $1.rawValue },
                    answers: Array((pick?.beats ?? []).prefix(4)),
                    archetypeFit: fit))
            }
        }
        return out.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func beneficiaryOf(_ archetype: Archetype, _ form: Form) -> Bool {
        let ability = form.abilities.first?.name ?? ""
        switch archetype {
        case .sun:   return ["Chlorophyll", "Solar Power"].contains(ability)
            || form.types.contains("Fire") || WeatherShield.shields(.sun, form)
        case .rain:  return ["Swift Swim", "Dry Skin"].contains(ability)
            || form.types.contains("Water") || WeatherShield.shields(.rain, form)
        case .sand:  return ["Sand Rush", "Sand Force"].contains(ability)
        case .snow:  return ["Slush Rush", "Ice Body"].contains(ability)
        case .grassy: return form.types.contains("Grass")
        case .psychicTerrain: return form.types.contains("Psychic")
        case .electric: return form.types.contains("Electric")
        case .trickRoom: return form.speed <= 65 && max(form.attack, form.spAttack) >= 110
        case .tailwind: return form.speed >= 100 && max(form.attack, form.spAttack) >= 110
        case .balance: return false
        }
    }

    // MARK: Prescriptions

    struct Prescription: Identifiable {
        let problem: String
        let fix: String
        let options: [Form]
        var id: String { problem }
    }

    /// Concrete fixes, each naming Pokémon from the roster rather than
    /// describing a shape and leaving you to find one.
    func prescriptions(picks: [Forecast.Pick]) -> [Prescription] {
        let analysis = TeamAnalysis(team: team, store: store)
        var out: [Prescription] = []
        let onTeam = Set(team.slots.compactMap { $0.form(in: store.rulebook)?.dex })

        for role in missingEssentials {
            let options = store.data.forms
                .filter { !onTeam.contains($0.dex) }
                .filter { potentialRoles(of: $0).contains(role) }
                .sorted { $0.bst > $1.bst }
                .prefix(4)
            out.append(Prescription(
                problem: "No \(role.rawValue)",
                fix: role.blurb,
                options: Array(options)))
        }

        for spot in analysis.softSpots.prefix(3) {
            let options = store.data.forms
                .filter { !onTeam.contains($0.dex) }
                .filter { TypeChart.multiplier(spot.type, into: $0,
                                               ability: $0.abilities.first?.name) < 1 }
                .sorted { lhs, rhs in
                    let l = picks.first { $0.form.id == lhs.id }?.score ?? 0
                    let r = picks.first { $0.form.id == rhs.id }?.score ?? 0
                    return l > r
                }
                .prefix(4)
            out.append(Prescription(
                problem: "\(spot.weakCount) members weak to \(spot.type.rawValue)",
                fix: "Add something that resists it, or the whole team folds to one attacker.",
                options: Array(options)))
        }

        let uncovered = analysis.coverage.filter { $0.carriers.isEmpty }.map(\.type)
        if uncovered.count > 8 {
            out.append(Prescription(
                problem: "Only \(18 - uncovered.count) of 18 attacking types covered",
                fix: "Thin coverage is survivable if what you do have hits the field hard. Check the Forecast page — Ice and Fire are the two best attacking types in M-C.",
                options: []))
        }
        return out
    }
}

/// Weather that halves a whole attacking type, and the type it halves.
///
/// Rain halves Fire and sun halves Water, which is a reason to set weather that
/// has nothing to do with Swift Swim or Chlorophyll. Mega Golisopod is the case
/// that makes it obvious: Bug/Steel takes four times from Fire, and putting up
/// rain turns that into double for the whole game. Judging a rain plan purely
/// on who abuses the rain missed it entirely.
enum WeatherShield {
    static let halves: [Archetype: PokeType] = [.rain: .fire, .sun: .water]

    /// Whether this weather blunts the type that hits this Pokémon hardest.
    static func shields(_ plan: Archetype, _ form: Form) -> Bool {
        guard let softened = halves[plan] else { return false }
        return TypeChart.multiplier(softened, into: form) >= 2
    }
}
