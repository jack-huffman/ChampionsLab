//  Analysis.swift
//  Turning a team into the things you actually want to know: what it cannot
//  hurt, what it folds to, what outruns it, and how it fares against the meta.

import Foundation

// MARK: - Defensive profile

struct TypeExposure: Identifiable {
    let type: PokeType
    /// One entry per team slot.
    let multipliers: [Double]

    var id: String { type.rawValue }
    var weakCount: Int { multipliers.filter { $0 > 1 }.count }
    var resistCount: Int { multipliers.filter { $0 < 1 }.count }
    var immuneCount: Int { multipliers.filter { $0 == 0 }.count }

    /// Weak on three or more members with nothing resisting it is the shape of
    /// a team that loses to one well-chosen attacker.
    var isCritical: Bool { weakCount >= 3 && resistCount == 0 }
    var isSoft: Bool { weakCount >= 3 || (weakCount >= 2 && resistCount == 0) }
}

// MARK: - Offensive coverage

struct CoverageEntry: Identifiable {
    let type: PokeType
    /// Team members that carry a damaging move of this type.
    let carriers: [String]
    var id: String { type.rawValue }
}

// MARK: - Threat assessment

struct ThreatAssessment: Identifiable {
    let threat: UsageEntry
    let form: Form?
    /// Best damage any team member does to it, as a fraction of its HP.
    let bestOutgoing: Double
    /// Worst damage it does to any team member.
    let worstIncoming: Double
    let outspeedsCount: Int
    let checkedBy: [String]
    let losesTo: [String]
    /// Average one-on-one outcome across the team, −1…1, raced on Speed.
    ///
    /// This screen used to work out who outspeeds what and then never use it:
    /// a member was called a check because it knocked the threat out, whether
    /// or not the threat moved first and knocked it out instead. It now runs
    /// the same `Duel` the Versus grid does, so the two cannot disagree.
    let duelScore: Double

    var id: String { threat.name }

    /// Positive is good for you. Weighted so a threat you cannot damage but
    /// that flattens you scores worst.
    var score: Double { duelScore }

    var verdict: Verdict {
        if checkedBy.isEmpty && worstIncoming >= 0.7 { return .losing }
        if checkedBy.isEmpty { return .shaky }
        if duelScore > 0.2 && !checkedBy.isEmpty { return .favourable }
        return .even
    }

    enum Verdict: String {
        case favourable = "Favourable"
        case even = "Even"
        case shaky = "Shaky"
        case losing = "Losing"
    }
}

// MARK: - Engine

@MainActor
struct TeamAnalysis {
    let team: Team
    let store: Store

    private var slots: [(slot: TeamSlot, form: Form)] {
        team.slots.compactMap { slot in
            guard let form = slot.form(in: store) else { return nil }
            return (slot, form)
        }
    }

    // -- defence ------------------------------------------------------------

    var exposures: [TypeExposure] {
        let members = slots
        return PokeType.allCases.map { type in
            let multipliers = members.map { member in
                TypeChart.multiplier(type, into: member.form, ability: member.slot.ability)
            }
            return TypeExposure(type: type, multipliers: multipliers)
        }
    }

    /// The types this team is genuinely afraid of, worst first.
    var softSpots: [TypeExposure] {
        exposures.filter(\.isSoft).sorted {
            ($0.weakCount - $0.resistCount) > ($1.weakCount - $1.resistCount)
        }
    }

    // -- offence ------------------------------------------------------------

    var coverage: [CoverageEntry] {
        var carriers: [PokeType: [String]] = [:]
        for member in slots {
            let moves = member.slot.moves.compactMap { store.move($0) }
            for move in moves where move.isDamaging {
                guard let type = PokeType(loose: move.type) else { continue }
                carriers[type, default: []].append(member.form.formLabel)
            }
        }
        return PokeType.allCases.map {
            CoverageEntry(type: $0, carriers: carriers[$0].map(Array.init) ?? [])
        }
    }

    /// Legal Pokémon that nothing on this team can hit for neutral damage.
    /// A short list is fine; a long one means a real hole.
    var uncoveredThreats: [Form] {
        let attackTypes: [PokeType] = coverage.filter { !$0.carriers.isEmpty }.map(\.type)
        guard !attackTypes.isEmpty else { return [] }
        let relevant = store.data.usage.compactMap { store.form(named: $0.name) }
        return relevant.filter { target in
            let best = attackTypes.map { TypeChart.multiplier($0, into: target) }.max() ?? 0
            return best < 1
        }
    }

    // -- speed --------------------------------------------------------------

    struct SpeedRow: Identifiable {
        let name: String
        let speed: Int
        let isTeam: Bool
        var id: String { "\(name)-\(isTeam)" }
    }

    /// Your team's speeds against the format's benchmarks, so you can see which
    /// side of base 151 you are on.
    var speedTiers: [SpeedRow] {
        var rows: [SpeedRow] = slots.map { member in
            SpeedRow(name: member.form.formLabel,
                     speed: ChampionsStats.value(base: member.form.speed,
                                                 sp: member.slot.sp[Stat.speed.rawValue],
                                                 stat: .speed,
                                                 alignment: member.slot.alignment),
                     isTeam: true)
        }
        for entry in store.data.usage.prefix(24) {
            guard let form = store.form(named: entry.name) else { continue }
            rows.append(SpeedRow(name: form.formLabel,
                                 speed: ChampionsStats.maxValue(base: form.speed,
                                                                stat: .speed, boosting: true),
                                 isTeam: false))
        }
        return rows.sorted { $0.speed > $1.speed }
    }

    // -- threats ------------------------------------------------------------

    /// How the team fares against every entry in the usage table.
    func threats(field: Field = Field()) -> [ThreatAssessment] {
        let members = slots
        var out: [ThreatAssessment] = []

        for entry in store.data.usage {
            guard entry.formats.contains(team.format) else { continue }
            guard let threatForm = store.form(named: entry.name) else {
                out.append(ThreatAssessment(threat: entry, form: nil, bestOutgoing: 0,
                                            worstIncoming: 0, outspeedsCount: 0,
                                            checkedBy: [], losesTo: [], duelScore: 0))
                continue
            }

            // Give the threat a representative build: max Attack or Sp. Attack
            // depending on which of its stats is higher, and its most common item.
            let physical = threatForm.attack >= threatForm.spAttack
            var threatSP = Array(repeating: 0, count: 6)
            threatSP[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
            threatSP[Stat.speed.rawValue] = 32
            let threatCombatant = Combatant(
                form: threatForm,
                ability: threatForm.abilities.first?.name ?? "",
                item: entry.commonItems.first ?? "",
                sp: threatSP,
                alignment: Alignment(name: "x",
                                     up: physical ? .attack : .spAttack, down: .hp))

            let threatSpeed = threatCombatant.speed(in: field)
            // Their whole measured set, status included: a threat that carries
            // Will-O-Wisp is a different problem from one that does not.
            let threatMoves = entry.keyMoves.compactMap { name in
                store.data.moves.values.first { $0.name == name }
            }

            var bestOutgoing = 0.0
            var worstIncoming = 0.0
            var checkedBy: [String] = []
            var losesTo: [String] = []
            var outspeeds = 0
            var duelTotal = 0.0
            var duelCount = 0.0

            for member in members {
                guard var attacker = member.slot.combatant(in: store) else { continue }
                attacker.ability = member.slot.ability.isEmpty
                    ? (member.form.abilities.first?.name ?? "") : member.slot.ability

                if attacker.speed(in: field) > threatSpeed { outspeeds += 1 }

                let ourMoves = member.slot.moves.compactMap { store.move($0) }
                let duel = DuelEngine.duel(
                    mine: DuelEngine.Side(combatant: attacker, moves: ourMoves, speed: nil),
                    theirs: DuelEngine.Side(combatant: threatCombatant,
                                            moves: threatMoves, speed: threatSpeed),
                    field: field, store: store)
                let memberBest = duel.outgoing
                let memberWorst = duel.incoming
                bestOutgoing = max(bestOutgoing, memberBest)
                worstIncoming = max(worstIncoming, memberWorst)
                duelTotal += duel.outcome.score
                duelCount += 1
                switch duel.outcome {
                case .win:  checkedBy.append(member.form.formLabel)
                case .loss: losesTo.append(member.form.formLabel)
                default:    break
                }
            }

            out.append(ThreatAssessment(threat: entry, form: threatForm,
                                        bestOutgoing: bestOutgoing,
                                        worstIncoming: worstIncoming,
                                        outspeedsCount: outspeeds,
                                        checkedBy: checkedBy, losesTo: losesTo,
                                        duelScore: duelCount > 0 ? duelTotal / duelCount : 0))
        }
        return out.sorted { $0.score < $1.score }
    }

    // -- summary ------------------------------------------------------------

    struct Grade {
        let score: Int          // 0...100
        let headline: String
        let strengths: [String]
        let problems: [String]
    }

    func grade(field: Field = Field()) -> Grade {
        let assessments = threats(field: field)
        guard !assessments.isEmpty, !slots.isEmpty else {
            return Grade(score: 0, headline: "Add Pokémon to see an assessment.",
                         strengths: [], problems: [])
        }

        let losing = assessments.filter { $0.verdict == .losing }
        let shaky = assessments.filter { $0.verdict == .shaky }
        let favourable = assessments.filter { $0.verdict == .favourable }

        // Weighted by usage: losing to Garchomp costs more than losing to Pincurchin.
        let totalWeight = assessments.reduce(0.0) { $0 + max($1.threat.usage, 5) }
        let lostWeight = (losing + shaky).reduce(0.0) { $0 + max($1.threat.usage, 5) }
        let coverageScore = Double(coverage.filter { !$0.carriers.isEmpty }.count) / 18.0
        let defenceScore = 1.0 - Double(softSpots.count) / 18.0

        let raw = (1 - lostWeight / max(totalWeight, 1)) * 55
            + coverageScore * 25
            + defenceScore * 20
        let score = max(0, min(100, Int(raw.rounded())))

        var strengths: [String] = []
        if !favourable.isEmpty {
            strengths.append("Beats \(favourable.prefix(3).map(\.threat.name).joined(separator: ", "))")
        }
        let covered = coverage.filter { !$0.carriers.isEmpty }.count
        strengths.append("\(covered) of 18 attacking types covered")
        if softSpots.isEmpty { strengths.append("No stacked type weakness") }

        var problems: [String] = []
        for assessment in losing.prefix(3) {
            problems.append("No answer to \(assessment.threat.name) — \(assessment.threat.role.lowercased())")
        }
        for spot in softSpots.prefix(2) {
            problems.append("\(spot.weakCount) members weak to \(spot.type.rawValue) with \(spot.resistCount) resisting")
        }
        let uncovered = uncoveredThreats
        if !uncovered.isEmpty {
            problems.append("Cannot hit \(uncovered.prefix(2).map(\.formLabel).joined(separator: ", ")) neutrally")
        }

        let headline: String
        switch score {
        case 80...:  headline = "Strong against the projected M-C field."
        case 60..<80: headline = "Solid, with a couple of exploitable holes."
        case 40..<60: headline = "Workable but the meta has clear angles on it."
        default:     headline = "This loses to too much of the format as built."
        }

        return Grade(score: score, headline: headline,
                     strengths: strengths, problems: problems)
    }

    // -- suggestions --------------------------------------------------------

    struct Suggestion: Identifiable {
        let form: Form
        let reason: String
        var id: String { form.id }
    }

    /// Legal Pokémon that would patch this team's worst problems: they resist
    /// what the team is weak to and handle the threats nothing currently checks.
    func suggestions(limit: Int = 8, field: Field = Field()) -> [Suggestion] {
        let problemTypes = softSpots.prefix(4).map(\.type)
        let unanswered = threats(field: field)
            .filter { $0.verdict == .losing || $0.verdict == .shaky }
            .prefix(5)
            .compactMap(\.form)
        let onTeam = Set(slots.map { $0.form.dex })

        var scored: [(Form, Double, [String])] = []
        for candidate in store.data.forms where !onTeam.contains(candidate.dex) {
            var score = 0.0
            var reasons: [String] = []

            for type in problemTypes {
                let taken = TypeChart.multiplier(type, into: candidate,
                                                 ability: candidate.abilities.first?.name)
                if taken == 0 {
                    score += 3
                    reasons.append("immune to \(type.rawValue)")
                } else if taken < 1 {
                    score += 1.5
                    reasons.append("resists \(type.rawValue)")
                }
            }

            for threat in unanswered {
                // Can it threaten what we cannot?
                let offensive = candidate.pokeTypes.map {
                    TypeChart.multiplier($0, into: threat)
                }.max() ?? 1
                let defensive = threat.pokeTypes.map {
                    TypeChart.multiplier($0, into: candidate,
                                         ability: candidate.abilities.first?.name)
                }.max() ?? 1
                if offensive > 1 && defensive <= 1 {
                    score += 2.5
                    reasons.append("beats \(threat.formLabel)")
                }
            }

            // Prefer things that are actually good.
            score += Double(candidate.bst) / 600.0
            if candidate.isMega { score += 0.4 }

            if score > 3, !reasons.isEmpty {
                scored.append((candidate, score, reasons))
            }
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { Suggestion(form: $0.0, reason: uniqueReasons($0.2)) }
    }

    private func uniqueReasons(_ reasons: [String]) -> String {
        var seen = Set<String>()
        let unique = reasons.filter { seen.insert($0).inserted }
        return unique.prefix(3).joined(separator: ", ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
