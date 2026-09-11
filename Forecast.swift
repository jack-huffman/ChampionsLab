//  Forecast.swift
//  What the format looks like, and what beats it.
//
//  Everything here is derived from the dataset rather than asserted. The usage
//  table supplies the field and its weights; the damage calculator and the type
//  chart do the rest. The point is that "Ice is the best attacking type in M-C"
//  should be a number you can check, not an opinion.
//
//  The weights themselves are the soft part: Regulation M-C has no ladder
//  history, so projected entries carry an assumed weight. Anything built on top
//  inherits that uncertainty, which is why the view says so plainly.

import Foundation

@MainActor
struct Forecast {
    let store: Store
    var format: String = "doubles"

    /// Every tracked threat that resolves to a real form, with its weight.
    /// A projected entry has no measured usage, so it is floored to keep it in
    /// the field rather than dropping out of the maths entirely.
    private var field: [(form: Form, weight: Double, entry: UsageEntry)] {
        store.data.usage.compactMap { entry in
            guard entry.formats.contains(format),
                  let form = store.form(named: entry.name) else { return nil }
            return (form, max(entry.usage, 5.0), entry)
        }
    }

    private var totalWeight: Double { field.reduce(0) { $0 + $1.weight } }

    // MARK: - Type landscape

    struct TypeScore: Identifiable {
        let type: PokeType
        let value: Double
        var id: String { type.rawValue }
    }

    /// Average effectiveness of each attacking type into the weighted field.
    /// Above 1.0 means the field is soft to it.
    var attackingTypes: [TypeScore] {
        let entries = field
        let total = totalWeight
        guard total > 0 else { return [] }
        return PokeType.allCases.map { attack in
            let sum = entries.reduce(0.0) { acc, item in
                acc + item.weight * TypeChart.multiplier(attack, into: item.form)
            }
            return TypeScore(type: attack, value: sum / total)
        }
        .sorted { $0.value > $1.value }
    }

    /// How much damage a defending type combination takes from the field's STABs.
    /// Below 1.0 means it is hard to hit.
    func defensiveScore(for form: Form) -> Double {
        let entries = field
        var total = 0.0, weight = 0.0
        for item in entries {
            for attack in item.form.pokeTypes {
                total += item.weight * TypeChart.multiplier(
                    attack, into: form, ability: form.abilities.first?.name)
                weight += item.weight
            }
        }
        return weight > 0 ? total / weight : 1
    }

    /// The type share of the projected field, for spotting what is crowded.
    var typeShare: [(type: PokeType, count: Int)] {
        var counts: [PokeType: Int] = [:]
        for item in field {
            for type in item.form.pokeTypes { counts[type, default: 0] += 1 }
        }
        return counts.map { (type: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Speed

    struct SpeedMark: Identifiable {
        let name: String
        let speed: Int
        let form: Form
        var id: String { form.id }
    }

    /// The field at full Speed investment with a boosting alignment — the
    /// numbers you actually have to beat.
    var speedLandscape: [SpeedMark] {
        field.map {
            SpeedMark(name: $0.entry.name,
                      speed: ChampionsStats.maxValue(base: $0.form.speed,
                                                     stat: .speed, boosting: true),
                      form: $0.form)
        }
        .sorted { $0.speed > $1.speed }
    }

    // MARK: - Anti-meta picks

    struct Pick: Identifiable {
        let form: Form
        /// Usage-weighted average outcome against the field, −1…1.
        let score: Double
        let beats: [String]
        let losesTo: [String]
        let outspeeds: Int
        let fieldSize: Int
        let bestMove: String

        var id: String { form.id }
        var winRate: Double { Double(beats.count) / Double(max(fieldSize, 1)) }
    }

    /// A representative competitive build: everything into the better attacking
    /// stat and into Speed, which is what most of the field actually runs.
    private func standardBuild(_ form: Form) -> Combatant {
        let physical = form.attack >= form.spAttack
        var sp = Array(repeating: 0, count: 6)
        sp[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
        sp[Stat.speed.rawValue] = 32
        sp[Stat.hp.rawValue] = 2
        return Combatant(
            form: form,
            ability: form.abilities.first?.name ?? "",
            item: "",
            sp: sp,
            alignment: Alignment(name: "std",
                                 up: physical ? .attack : .spAttack,
                                 down: physical ? .spAttack : .attack))
    }

    /// Up to four attacking moves, one per type, strongest first — an
    /// approximation of a coverage spread rather than four copies of one STAB.
    ///
    /// Filtered to moves that can actually be clicked for their damage on the
    /// turn you want it. Ranking on raw base power alone handed every Pokémon a
    /// Giga Impact or a Focus Punch and scored it as though those were free.
    private func standardMoves(_ form: Form) -> [Move] {
        let ability = form.abilities.first?.name ?? ""
        // -ate abilities convert Normal moves and give them STAB, which is the
        // whole reason Mega Salamence clicks Double-Edge rather than a Dragon
        // move. Ranking on the printed type buries it under four Dragon attacks.
        let converted: String? = {
            switch ability {
            case "Aerilate": return "Flying"
            case "Pixilate": return "Fairy"
            case "Refrigerate": return "Ice"
            case "Galvanize": return "Electric"
            default: return nil
            }
        }()
        func effectiveType(_ move: Move) -> String {
            move.type == "Normal" ? (converted ?? move.type) : move.type
        }
        func worth(_ move: Move) -> Double {
            store.moveValue(move, for: form, ability: ability)
        }
        let ranked = store.attackingMoves(for: form).sorted { worth($0) > worth($1) }

        var seen = Set<String>()
        var out: [Move] = []
        for move in ranked where !seen.contains(effectiveType(move)) {
            seen.insert(effectiveType(move))
            out.append(move)
            if out.count == 4 { break }
        }
        return out
    }

    /// Rank every legal form by how it fares against the weighted field.
    ///
    /// This is the expensive one — roughly 350 candidates against 30 threats —
    /// so it is computed once and handed to the view, never recomputed in a
    /// body.
    func picks(limit: Int = 40) -> [Pick] {
        let entries = field
        guard !entries.isEmpty else { return [] }
        let total = entries.reduce(0.0) { $0 + $1.weight }
        // Not a neutral field. Rillaboom is on a third of teams and runs Grassy
        // Surge on essentially all of them, so a third of games start with
        // Earthquake already halved. Picks are scored across the states the
        // format actually produces, weighted by how often they happen.
        let states = MetaModel(store: store, format: format).fieldStates

        // Precompute the threats once.
        let threats: [(Combatant, [Move], Double, String)] = entries.map {
            (standardBuild($0.form), standardMoves($0.form), $0.weight, $0.entry.name)
        }

        var out: [Pick] = []
        for candidate in store.data.forms {
            let me = standardBuild(candidate)
            let myMoves = standardMoves(candidate)
            guard !myMoves.isEmpty else { continue }

            var weighted = 0.0
            var beats: [String] = []
            var losesTo: [String] = []
            var outspeeds = 0
            var bestMove = "—"
            var bestSeen = 0.0

            for (them, theirMoves, weight, name) in threats {
                let faster = me.stat(.speed) > them.stat(.speed)
                if faster { outspeeds += 1 }

                // The same duel, run once per field state and averaged. A pick
                // that only wins with no terrain up is not a pick.
                var duelScore = 0.0
                for (context, stateWeight, _) in states {
                    // Best move by what it is worth once accuracy and
                    // self-inflicted costs are priced in, not by the biggest
                    // number on the roll.
                    var outgoing = 0.0
                    var outgoingReliability = 1.0
                    for move in myMoves {
                        let result = DamageCalc.calculate(attacker: me, defender: them,
                                                          move: move, field: context)
                        let quality = store.quality(of: move, ability: me.ability)
                        let worth = result.maxPercent / 100 * quality.reliability
                        if worth > outgoing * outgoingReliability {
                            outgoing = result.maxPercent / 100
                            outgoingReliability = quality.reliability
                            if worth * stateWeight > bestSeen {
                                bestSeen = worth * stateWeight
                                bestMove = move.name
                            }
                        }
                    }
                    var incoming = 0.0
                    var incomingReliability = 1.0
                    for move in theirMoves {
                        let result = DamageCalc.calculate(attacker: them, defender: me,
                                                          move: move, field: context)
                        let quality = store.quality(of: move, ability: them.ability)
                        let worth = result.maxPercent / 100 * quality.reliability
                        if worth > incoming * incomingReliability {
                            incoming = result.maxPercent / 100
                            incomingReliability = quality.reliability
                        }
                    }

                    let duel = Duel(mine: candidate, theirs: them.form,
                                    outgoing: outgoing, incoming: incoming,
                                    mySpeed: me.stat(.speed), theirSpeed: them.stat(.speed),
                                    myBestMove: bestMove, theirBestMove: "",
                                    myReliability: outgoingReliability,
                                    theirReliability: incomingReliability)
                    duelScore += stateWeight * duel.outcome.score
                }
                weighted += weight * duelScore
                // Winning in most field states, rather than in one lucky one.
                if duelScore >= 0.7 { beats.append(name) }
                else if duelScore <= -0.7 { losesTo.append(name) }
            }

            out.append(Pick(form: candidate, score: weighted / total,
                            beats: beats, losesTo: losesTo, outspeeds: outspeeds,
                            fieldSize: threats.count, bestMove: bestMove))
        }
        return out.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    // MARK: - One Pokémon against the whole field

    /// How a single form fares against every tracked threat, both directions.
    ///
    /// Same machinery as `picks`, but kept for one candidate and with the detail
    /// retained: which move does the work, what beats it back, and whether Speed
    /// decides it. Cheap enough to compute on selection — one form against
    /// twenty threats in three field states.
    struct FormProfile {
        struct Row: Identifiable {
            let form: Form
            let name: String
            let usage: Double
            let outcome: Duel.Outcome
            let score: Double
            let myBest: String
            let myPercent: Double
            let theirBest: String
            let theirPercent: Double
            let faster: Bool
            var id: String { form.id }
        }
        let beats: [Row]
        let loses: [Row]
        let even: [Row]
        /// Usage-weighted standing, −1…1.
        let score: Double
        let outspeeds: Int
        let fieldSize: Int
        let stateLabels: [String]
    }

    func profile(of candidate: Form) -> FormProfile {
        let entries = self.field
        let states = MetaModel(store: store, format: format).fieldStates
        let me = standardBuild(candidate)
        let myMoves = standardMoves(candidate)
        var rows: [FormProfile.Row] = []
        var weighted = 0.0, total = 0.0, outspeeds = 0

        for entry in entries {
            let them = standardBuild(entry.form)
            let theirMoves = standardMoves(entry.form)
            let faster = me.stat(.speed) > them.stat(.speed)
            if faster { outspeeds += 1 }

            var duelScore = 0.0
            var bestOut = 0.0, bestOutName = "—"
            var bestIn = 0.0, bestInName = "—"
            for (context, weight, _) in states {
                var outgoing = 0.0, outgoingReliability = 1.0
                for move in myMoves {
                    let result = DamageCalc.calculate(attacker: me, defender: them,
                                                      move: move, field: context)
                    let quality = store.quality(of: move, ability: me.ability)
                    let worth = result.maxPercent / 100 * quality.reliability
                    if worth > outgoing * outgoingReliability {
                        outgoing = result.maxPercent / 100
                        outgoingReliability = quality.reliability
                    }
                    if result.maxPercent / 100 * quality.reliability * weight > bestOut {
                        bestOut = result.maxPercent / 100 * quality.reliability * weight
                        bestOutName = move.name
                    }
                }
                var incoming = 0.0, incomingReliability = 1.0
                for move in theirMoves {
                    let result = DamageCalc.calculate(attacker: them, defender: me,
                                                      move: move, field: context)
                    let quality = store.quality(of: move, ability: them.ability)
                    let worth = result.maxPercent / 100 * quality.reliability
                    if worth > incoming * incomingReliability {
                        incoming = result.maxPercent / 100
                        incomingReliability = quality.reliability
                    }
                    if worth * weight > bestIn {
                        bestIn = worth * weight
                        bestInName = move.name
                    }
                }
                let duel = Duel(mine: candidate, theirs: them.form,
                                outgoing: outgoing, incoming: incoming,
                                mySpeed: me.stat(.speed), theirSpeed: them.stat(.speed),
                                myBestMove: bestOutName, theirBestMove: bestInName,
                                myReliability: outgoingReliability,
                                theirReliability: incomingReliability)
                duelScore += weight * duel.outcome.score
            }

            // Percentages from the likeliest field state, so the numbers shown
            // belong to a single coherent scenario rather than an average.
            let main = states.max { $0.weight < $1.weight }?.field
                ?? Field(isDoubles: format == "doubles")
            let myBestResult = myMoves
                .map { ($0, DamageCalc.calculate(attacker: me, defender: them,
                                                 move: $0, field: main)) }
                .max { a, b in
                    a.1.maxPercent * store.quality(of: a.0, ability: me.ability).reliability
                        < b.1.maxPercent * store.quality(of: b.0, ability: me.ability).reliability
                }
            let theirBestResult = theirMoves
                .map { ($0, DamageCalc.calculate(attacker: them, defender: me,
                                                 move: $0, field: main)) }
                .max { a, b in
                    a.1.maxPercent * store.quality(of: a.0, ability: them.ability).reliability
                        < b.1.maxPercent * store.quality(of: b.0, ability: them.ability).reliability
                }

            let outcome: Duel.Outcome = duelScore >= 0.7 ? .win
                : (duelScore >= 0.25 ? .favoured
                   : (duelScore <= -0.7 ? .loss
                      : (duelScore <= -0.25 ? .against : .neutral)))
            rows.append(FormProfile.Row(
                form: entry.form, name: entry.entry.name, usage: entry.entry.usage,
                outcome: outcome, score: duelScore,
                myBest: myBestResult?.0.name ?? "—",
                myPercent: myBestResult?.1.maxPercent ?? 0,
                theirBest: theirBestResult?.0.name ?? "—",
                theirPercent: theirBestResult?.1.maxPercent ?? 0,
                faster: faster))
            weighted += entry.weight * duelScore
            total += entry.weight
        }

        let ordered = rows.sorted { $0.score == $1.score ? $0.usage > $1.usage : $0.score > $1.score }
        return FormProfile(
            beats: ordered.filter { $0.score > 0.2 },
            loses: ordered.filter { $0.score < -0.2 }.reversed(),
            even: ordered.filter { abs($0.score) <= 0.2 },
            score: total > 0 ? weighted / total : 0,
            outspeeds: outspeeds, fieldSize: rows.count,
            stateLabels: states.map(\.label))
    }

    // MARK: - Everything, computed once

    struct Report {
        let attackingTypes: [TypeScore]
        let worstAttackingTypes: [TypeScore]
        let picks: [Pick]
        let speedLandscape: [SpeedMark]
        let typeShare: [(type: PokeType, count: Int)]
        let fieldSize: Int
        let projectedCount: Int
        let measuredCount: Int
        /// The terrain and weather the format actually puts up.
        let fieldPressures: [MetaModel.FieldPressure]
        /// The tactics a measurable share of the field runs, and what stops them.
        let tactics: [MetaModel.TacticPressure]
        let states: [(label: String, weight: Double)]
    }

    func report() -> Report {
        let attacking = attackingTypes
        let entries = field
        let meta = MetaModel(store: store, format: format)
        return Report(
            attackingTypes: Array(attacking.prefix(6)),
            worstAttackingTypes: Array(attacking.suffix(4).reversed()),
            picks: picks(),
            speedLandscape: Array(speedLandscape.prefix(16)),
            typeShare: Array(typeShare.prefix(8)),
            fieldSize: entries.count,
            projectedCount: entries.filter { $0.entry.isProjected }.count,
            measuredCount: entries.filter { !$0.entry.isProjected }.count,
            fieldPressures: meta.fieldPressures,
            tactics: meta.tactics,
            states: meta.fieldStates.map { (label: $0.label, weight: $0.weight) })
    }
}
