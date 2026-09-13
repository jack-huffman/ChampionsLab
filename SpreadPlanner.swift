//  SpreadPlanner.swift
//  Stat Points spent against the numbers the format actually presents.
//
//  This is where most of the skill in team building lives and it is the part
//  the app had least of. The builder spread points the way a beginner does:
//  32 into the attacking stat, enough Speed to clear some mark, the rest into
//  health. Nobody good builds that way. They build to numbers:
//
//      "survive Glaive Rush from a Life Orb Mega Baxcalibur"
//      "outspeed Choice Scarf Garchomp"
//      "live two Grassy Glides so the Sitrus Berry matters"
//
//  Those sentences are what a spread is *for*, and each is a threshold: below
//  it the points bought nothing, above it every extra point is wasted. Finding
//  the cheapest allocation that clears the thresholds worth clearing, and
//  spending what is left on offence, is a search rather than a habit.
//
//  Everything needed was already here — the Champions stat formula, the damage
//  calculator, measured usage saying which threats are real and what they hold.
//
//  What it does not do, said plainly. It assumes the threatening version of
//  each attacker, because that is what you build to survive; a Pokemon that
//  usually runs bulk will sometimes run offence and this plans for the second.
//  It works from the high damage roll, so "survives" means survives the worst
//  case rather than usually. It plans one Pokemon at a time and knows nothing
//  about the other five. And it searches canonical allocations rather than
//  every one of the tens of thousands that fit in 66 points.

import Foundation

@MainActor
struct SpreadPlanner {
    let store: Store
    var format = "doubles"
    /// The field the numbers are judged in. Speed abilities and Weather Ball
    /// both depend on it, so a rain team's benchmarks are not a sun team's.
    var field = Field(isDoubles: true)
    /// How many measured threats to build against.
    var depth = 12

    // MARK: - What is worth hitting

    struct Benchmark: Identifiable {
        enum Kind: String { case outspeed = "Outspeed", survive = "Survive" }
        let kind: Kind
        let threat: Form
        /// The attack to live through. Nil for a Speed benchmark.
        let move: Move?
        /// Speed to beat, or damage to stay above.
        let number: Int
        /// Share of the field this threat is, from measured usage.
        let share: Double
        let label: String
        let detail: String

        var id: String { "\(kind.rawValue)-\(threat.id)-\(move?.id ?? "")" }
    }

    /// The threats worth planning against: what people actually bring, in the
    /// order they bring it.
    private var threats: [(form: Form, entry: UsageEntry)] {
        store.data.usage
            .filter { $0.formats.contains(format) && !$0.isProjected && $0.usage > 0 }
            .sorted { $0.usage > $1.usage }
            .prefix(depth)
            .compactMap { entry in
                store.form(named: entry.name).map { (form: $0, entry: entry) }
            }
    }

    /// The build a threat is dangerous in.
    ///
    /// Deliberately the offensive version, with the item it most often holds.
    /// You build to survive the scary one: a Rillaboom that usually runs bulk
    /// will sometimes run Life Orb, and a spread that only lives through the
    /// bulky one is a spread that loses to the other.
    private func threatening(_ form: Form, entry: UsageEntry) -> Combatant {
        let physical = form.attack >= form.spAttack
        var sp = Array(repeating: 0, count: 6)
        sp[(physical ? Stat.attack : .spAttack).rawValue] = ChampionsStats.spPerStat
        // The rest into Speed, but no stat may hold more than 32 whatever the
        // budget says. Spending 34 here quietly made every threat two points
        // faster than the game allows.
        sp[Stat.speed.rawValue] = min(ChampionsStats.spPerStat,
                                      ChampionsStats.spTotal - ChampionsStats.spPerStat)
        let item = (entry.itemUsage?.first?.name ?? entry.commonItems.first ?? "")
        let ability = entry.abilityUsage?.first?.name ?? form.abilities.first?.name ?? ""
        return Combatant(form: form, ability: ability, item: item, sp: sp,
                         alignment: Alignment.named(physical ? "Adamant" : "Modest"))
    }

    /// Speed numbers worth clearing, fastest first.
    ///
    /// A threat that commonly holds a Choice Scarf appears twice, because its
    /// Scarf number is a different and much harder benchmark — and it is the
    /// one that catches people out.
    func speedBenchmarks() -> [Benchmark] {
        var out: [Benchmark] = []
        for (form, entry) in threats {
            let fast = threatening(form, entry: entry)
            var maxed = fast
            maxed.sp[Stat.speed.rawValue] = ChampionsStats.spPerStat
            maxed.alignment = Alignment.named(form.attack >= form.spAttack ? "Jolly" : "Timid")
            let plain = maxed.speed(in: field)
            out.append(Benchmark(kind: .outspeed, threat: form, move: nil, number: plain,
                                 share: entry.usage / 100,
                                 label: "Outspeed \(form.formLabel)",
                                 detail: "\(plain) Speed, fully invested"))
            // The Scarf version, when the ladder says people run one.
            let holdsScarf = (entry.itemUsage ?? []).contains {
                $0.name == "Choice Scarf" && $0.percent >= 8
            }
            if holdsScarf {
                var scarfed = maxed
                scarfed.item = "Choice Scarf"
                let quick = scarfed.speed(in: field)
                out.append(Benchmark(kind: .outspeed, threat: form, move: nil, number: quick,
                                     share: entry.usage / 100 * 0.5,
                                     label: "Outspeed Choice Scarf \(form.formLabel)",
                                     detail: "\(quick) Speed"))
            }
        }
        return out.sorted { $0.number > $1.number }
    }

    /// Attacks worth living through, hardest first.
    func survivalBenchmarks(for form: Form) -> [Benchmark] {
        // A reference defender, so the benchmark is about the attack rather
        // than about whatever spread is currently on the slot.
        let reference = Combatant(form: form, ability: form.abilities.first?.name ?? "",
                                  item: "", sp: Array(repeating: 0, count: 6),
                                  alignment: .neutral)
        var out: [Benchmark] = []
        for (threat, entry) in threats where threat.dex != form.dex {
            let attacker = threatening(threat, entry: entry)
            // What it would actually click at this target.
            let moves = (entry.moveUsage?.compactMap { row in
                store.data.moves.values.first { $0.name == row.name }
            } ?? []).filter(\.isDamaging)
            let pool = moves.isEmpty ? store.moves(for: threat).filter(\.isDamaging) : moves
            var worst: (move: Move, damage: Int)?
            for move in pool {
                let result = DamageCalc.calculate(attacker: attacker, defender: reference,
                                                  move: move, field: field)
                if worst == nil || result.maxDamage > worst!.damage {
                    worst = (move, result.maxDamage)
                }
            }
            guard let worst, worst.damage > 0 else { continue }
            out.append(Benchmark(kind: .survive, threat: threat, move: worst.move,
                                 number: worst.damage, share: entry.usage / 100,
                                 label: "Survive \(worst.move.name) from \(threat.formLabel)",
                                 detail: entry.itemUsage?.first.map { "\($0.name) set" } ?? ""))
        }
        return out.sorted { $0.number > $1.number }
    }

    // MARK: - Spending the points

    struct Plan {
        let sp: [Int]
        let alignment: Alignment
        let met: [Benchmark]
        let missed: [Benchmark]
        /// What the result is, in the sentences people actually use.
        let lines: [String]
        /// Weighted share of the benchmarks it clears.
        let cover: Double

        var spent: Int { sp.reduce(0, +) }
    }

    /// The cheapest Speed investment that clears a number, or nil if 32 cannot.
    private func speedCost(_ form: Form, over target: Int,
                           alignment: Alignment, item: String, ability: String) -> Int? {
        for candidate in 0...ChampionsStats.spPerStat {
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.speed.rawValue] = candidate
            let probe = Combatant(form: form, ability: ability, item: item,
                                  sp: sp, alignment: alignment)
            if probe.speed(in: field) > target { return candidate }
        }
        return nil
    }

    /// Build a spread for one Pokémon against the format's numbers.
    func plan(for form: Form, ability: String = "", item: String = "",
              role: StatRole? = nil, attacker: Bool = true) -> Plan {
        let resolved = ability.isEmpty ? (form.abilities.first?.name ?? "") : ability
        let statRole = role ?? store.statRole(of: form)
        let physical = statRole.offence != .special
        let offence: Stat = physical ? .attack : .spAttack

        let speedMarks = speedBenchmarks()
        let survivalMarks = survivalBenchmarks(for: form)
        // Which side of the defence the field actually threatens, so the points
        // go where the damage is coming from rather than where the stat is high.
        let physicalPressure = survivalMarks
            .filter { $0.move?.category == "Physical" }.reduce(0) { $0 + $1.share }
        let specialPressure = survivalMarks
            .filter { $0.move?.category != "Physical" }.reduce(0) { $0 + $1.share }
        let firstWall: Stat = physicalPressure >= specialPressure ? .defense : .spDefense
        let secondWall: Stat = firstWall == .defense ? .spDefense : .defense

        // Alignments that do not throw away the thing this Pokémon is for.
        //
        // An attacker must not drop the stat it attacks with, and must not
        // raise the one it never uses. A support has no points in either
        // attacking stat, so raising one is ten percent of nothing and dropping
        // one is free.
        let unused: Stat = physical ? .spAttack : .attack
        let usable = Alignment.all.filter { alignment in
            guard alignment.up != unused else { return false }
            if attacker { return alignment.down != offence }
            return alignment.up != offence
        }

        var best: Plan?
        // Speed goals: clear nothing, or clear one of the marks it can reach.
        let goals: [Int?] = [nil] + speedMarks.prefix(6).map { Optional($0.number) }

        for alignment in usable {
            for goal in goals {
                var speedSP = 0
                if let goal {
                    guard let cost = speedCost(form, over: goal, alignment: alignment,
                                               item: item, ability: resolved)
                    else { continue }
                    speedSP = cost
                }
                let offenceSP = attacker ? ChampionsStats.spPerStat : 0
                var budget = ChampionsStats.spTotal - speedSP - offenceSP
                guard budget >= 0 else { continue }
                budget = min(budget, ChampionsStats.spPerStat * 3)

                // Health multiplies whatever defence sits behind it, so the
                // split is worth searching rather than guessing. One point at a
                // time across health, with the rest falling into the side the
                // format actually attacks from.
                for hp in stride(from: 0, through: min(ChampionsStats.spPerStat, budget), by: 1) {
                    var sp = Array(repeating: 0, count: 6)
                    sp[Stat.speed.rawValue] = speedSP
                    sp[offence.rawValue] = offenceSP
                    sp[Stat.hp.rawValue] = hp
                    let afterHP = budget - hp
                    sp[firstWall.rawValue] = min(ChampionsStats.spPerStat, afterHP)
                    sp[secondWall.rawValue] = min(ChampionsStats.spPerStat,
                                                  afterHP - sp[firstWall.rawValue])
                    guard sp.reduce(0, +) <= ChampionsStats.spTotal else { continue }

                    let candidate = assess(form: form, sp: sp, alignment: alignment,
                                           ability: resolved, item: item,
                                           speedMarks: speedMarks, survivalMarks: survivalMarks)
                    if best == nil
                        || rank(candidate, offence: offence, wall: firstWall, attacker: attacker)
                            > rank(best!, offence: offence, wall: firstWall, attacker: attacker) {
                        best = candidate
                    }
                }
            }
        }
        return best ?? assess(form: form, sp: Array(repeating: 0, count: 6),
                              alignment: .neutral, ability: resolved, item: item,
                              speedMarks: speedMarks, survivalMarks: survivalMarks)
    }

    /// How to choose between allocations that clear the same benchmarks.
    ///
    /// Clearing more of the field always wins. After that: spend all 66, because
    /// leaving points unspent is free stat thrown away; prefer health, which
    /// multiplies whatever defence sits behind it; and prefer the alignment that
    /// raises what the Pokémon is actually for. Without this the search returned
    /// a wall with 64 points spent and none of them in health, which clears the
    /// same benchmarks and is plainly worse.
    private func rank(_ plan: Plan, offence: Stat, wall: Stat,
                      attacker: Bool) -> (Double, Int, Int, Int) {
        (plan.cover,
         plan.spent,
         alignmentFit(plan.alignment, offence: offence, wall: wall, attacker: attacker),
         plan.sp[Stat.hp.rawValue])
    }

    /// Whether the alignment suits the job, once the benchmarks are tied.
    ///
    /// The search would otherwise hand a physically bulky Pokémon a −Defense
    /// alignment, and hand a support +Attack it has no points in, because
    /// neither changed which benchmarks were cleared. Both are plainly wrong to
    /// anyone who plays, and this is where that judgment goes.
    private func alignmentFit(_ alignment: Alignment, offence: Stat, wall: Stat,
                              attacker: Bool) -> Int {
        var score = 0
        if attacker {
            if alignment.up == offence { score += 3 }
            if alignment.up == .speed { score += 2 }
        } else {
            if alignment.up == wall { score += 3 }
            if alignment.up == .speed { score += 1 }
            // Dropping an attacking stat it has no points in costs nothing.
            if alignment.down == .attack || alignment.down == .spAttack { score += 2 }
        }
        // Never pay for a benchmark with the defence the field is attacking.
        if alignment.down == wall { score -= 4 }
        if alignment.down == .hp { score -= 4 }
        return score
    }

    /// What one allocation actually clears.
    private func assess(form: Form, sp: [Int], alignment: Alignment,
                        ability: String, item: String,
                        speedMarks: [Benchmark], survivalMarks: [Benchmark]) -> Plan {
        let me = Combatant(form: form, ability: ability, item: item,
                           sp: sp, alignment: alignment)
        let mySpeed = me.speed(in: field)
        var met: [Benchmark] = [], missed: [Benchmark] = []

        for mark in speedMarks {
            if mySpeed > mark.number { met.append(mark) } else { missed.append(mark) }
        }
        for mark in survivalMarks {
            guard let move = mark.move,
                  let entry = store.data.usage.first(where: { $0.name == mark.threat.formLabel
                                                            || $0.name == mark.threat.name })
            else { continue }
            let attacker = threatening(mark.threat, entry: entry)
            let result = DamageCalc.calculate(attacker: attacker, defender: me,
                                              move: move, field: field)
            if result.maxDamage < me.maxHP { met.append(mark) } else { missed.append(mark) }
        }
        let total = (met + missed).reduce(0) { $0 + $1.share }
        let cover = total > 0 ? met.reduce(0) { $0 + $1.share } / total : 0

        var lines: [String] = []
        for mark in met.filter({ $0.kind == .outspeed }).sorted(by: { $0.number > $1.number })
            .prefix(1) {
            lines.append("Outspeeds \(mark.threat.formLabel) at \(mark.number), and everything below it.")
        }
        for mark in met.filter({ $0.kind == .survive }).sorted(by: { $0.number > $1.number })
            .prefix(2) {
            lines.append("Lives \(mark.move?.name ?? "its best attack") from \(mark.threat.formLabel).")
        }
        for mark in missed.filter({ $0.kind == .survive }).sorted(by: { $0.share > $1.share })
            .prefix(1) {
            lines.append("Still loses to \(mark.move?.name ?? "its best attack") from \(mark.threat.formLabel) — nothing in 66 points fixes that.")
        }
        return Plan(sp: sp, alignment: alignment, met: met, missed: missed,
                    lines: lines, cover: cover)
    }

}
