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
    /// How much of what the format is actually doing this team can turn off,
    /// weighted by how much of the field does it. A team that beats nothing it
    /// will meet is not a good team, however good its stats are.
    var disruption = 0.0
    var violations: [String] = []

    /// How much each component counts.
    ///
    /// These were six numbers I chose. They are now fitted against the only
    /// outside evidence available — the records of teams that actually won
    /// games — by tools/calibrate.sh, and the fitted values live here with the
    /// date and sample size they came from. Change them by re-running that,
    /// not by taste.
    struct Weights: Equatable {
        var matchup = 34.0
        var roles = 20.0
        var defence = 12.0
        var coverage = 10.0
        var synergy = 10.0
        var disruption = 14.0

        var sum: Double { matchup + roles + defence + coverage + synergy + disruption }
        /// The weights the scorer actually uses. `Tools/calibrate` fits them
        /// against tournament results and writes them here once, before
        /// anything reads them; the app never changes them at all. Marked
        /// unsafe rather than locked because every read is on a hot path and
        /// the only write happens before there is a second thread.
        nonisolated(unsafe) static var current = Weights()
    }

    /// 0…100. Matchup is the largest single term but deliberately not a
    /// majority, so a team of six strong attackers with no speed control and no
    /// redirection cannot outscore a coherent one.
    var total: Int { total(with: Weights.current) }

    func total(with w: Weights) -> Int {
        let raw = (matchup + 100) / 200 * w.matchup
            + roles * w.roles
            + defence * w.defence
            + coverage * w.coverage
            + synergy * w.synergy
            + disruption * w.disruption
        let scaled = w.sum > 0 ? raw * 100 / w.sum : raw
        return max(0, min(100, Int(scaled.rounded()) - violations.count * 3))
    }
}

// MARK: - Battle plans

/// One of the two ways to play a two-Mega team.
///
/// Doubles brings four of six, and only one Pokémon may Mega Evolve per battle,
/// so a second Mega is not a wasted slot — it is a second team hiding inside the
/// first. Team Preview tells you which one the matchup wants, and the four you
/// bring changes completely depending on the answer.
struct BattlePlan: Identifiable {
    let mega: Form
    let isPrimary: Bool
    /// The four to bring, in lead order: the front two first.
    let bring: [TeamSlot]
    let strategy: String
    /// Average edge across the bundled meta archetypes with this four.
    let edge: Int
    /// The archetypes this line is the right answer to.
    let bestInto: [String]

    var id: String { mega.id }
    var title: String { (isPrimary ? "Primary — " : "Alternate — ") + mega.formLabel }
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
    /// The two ways to play it, when the six carries two Megas.
    var lines: [BattlePlan] = []
    /// How this six handles faster teams, Trick Room, and the field.
    var answers: [GamePlanner.Answer] = []
    var isDualMega: Bool { lines.count == 2 }
}

// MARK: - Builder

/// Hand the main thread back for long enough that the run loop can draw.
///
/// `Task.yield()` does not do this. It offers the cooperative pool a chance to
/// run another task, and on the main actor that means the search simply
/// resumes — the run loop never gets in, so nothing repaints. A watchdog timer
/// set to fire every 4ms during a build recorded exactly one tick. A real
/// suspension is what lets AppKit draw a frame.
@MainActor
func breathe(_ label: String = "") async {
    BreathLog.mark(label)
    try? await Task.sleep(nanoseconds: 1_200_000)
}

/// How long the main thread runs between suspensions. This is what decides
/// whether an animation can draw, and unlike a run-loop probe it means the same
/// thing in a test harness as it does in the app.
@MainActor
enum BreathLog {
    static var enabled = false
    /// Each suspension, labelled with the stretch of work that preceded it.
    /// Without the label a measurement says a frame was missed but not by what,
    /// which is the only part worth knowing.
    static var gaps: [(label: String, seconds: Double)] = []
    private static var last = Date()

    static func begin() { enabled = true; gaps = []; last = Date() }
    static func mark(_ label: String = "") {
        guard enabled else { return }
        gaps.append((label, Date().timeIntervalSince(last)))
        last = Date()
    }

    /// The stretches that ran longer than a frame, worst first.
    static var stalls: [(label: String, seconds: Double)] {
        gaps.filter { $0.seconds > 1.0 / 60 }.sorted { $0.seconds > $1.seconds }
    }
    static func end() -> (count: Int, worst: Double) {
        enabled = false
        return (gaps.count, gaps.map(\.seconds).max() ?? 0)
    }
}

@MainActor
struct TeamBuilder {
    let store: Store
    var format = "doubles"
    /// What the interview established, where one was run. The search reads it
    /// rather than being told a plan and left to guess the rest.
    var brief: BuildBrief?

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
    private func provenCredit(_ form: Form) -> Double {
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

    // MARK: Cheap scoring, used inside the search

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

    // MARK: Plans worth trying for a seed

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
    /// The beam, yielding as it goes.
    ///
    /// Yielding only between plans left four-hundred-millisecond blocks, which
    /// is what a frozen spinner with occasional stutters actually is: the
    /// animation getting one frame per plan. A frame needs the main thread
    /// every sixteen milliseconds, so this hands it back inside the beam.
    private func search(seed: Form, plan: Archetype, pool: [Profile],
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

    private func searchSync(seed: Form, plan: Archetype, pool: [Profile],
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
                           types: form.pokeTypes, standing: 0, usage: 0, winrate: nil,
                           proven: provenCredit(form),
                           megaBuild: form.isMega, speed: form.speed,
                           physical: form.attack >= form.spAttack, taken: taken)
        }
    }

    // MARK: Fleshing a team out

    /// Give a form the build it is actually used with, falling back to its role.
    func flesh(_ form: Form, plan: Archetype, usedItems: inout Set<String>,
               allyGrounded: Int = 0) -> TeamSlot {
        var slot = TeamSlot(formID: form.id)
        let advisor = TeamAdvisor(team: Team(), store: store)
        let roles = advisor.potentialRoles(of: form)
        let usage = store.data.usage.first { $0.name == form.formLabel || $0.name == form.name }

        // The ladder's own answer beats anything derived, where there is one.
        let live = store.data.usage.first {
            ($0.name == form.formLabel || $0.name == form.name) && $0.hasLiveData
        }
        if let measured = live?.abilityUsage?.first,
           form.abilities.contains(where: { $0.name == measured.name }) {
            slot.ability = measured.name
        } else {
            slot.ability = preferredAbility(form, plan: plan)
        }

        // Item: what it is usually seen with, else something that suits the role.
        let physicalAttacker = form.attack >= form.spAttack
        // Measured item share first, then the role-appropriate fallbacks.
        var wanted: [String] = (live?.itemUsage?.map(\.name) ?? usage?.commonItems ?? [])
        if form.isMega { wanted = [form.megaTrigger] }
        // A Choice item has to match the attacking stat: Specs on an Adamant
        // physical attacker is a wasted slot, which an earlier version did.
        wanted += roles.contains(.redirection) || roles.contains(.tailwind)
            ? ["Focus Sash", "Sitrus Berry", "Covert Cloak", "Mental Herb"]
            : (physicalAttacker
               ? ["Life Orb", "Choice Band", "Assault Vest", "Sitrus Berry", "Leftovers"]
               : ["Life Orb", "Choice Specs", "Assault Vest", "Sitrus Berry", "Leftovers"])
        // Only things people have actually been seen holding in Champions. The
        // item list comes from the main-series itemdex, and half of it is not in
        // this game — Assault Vest, Choice Band, Choice Specs and Covert Cloak
        // are all on that list and all appear on none of the registered teams.
        // Building a six around an item that does not exist is worse than any
        // scoring error, because none of it can be played.
        slot.item = wanted.first {
            guard let item = store.item(named: $0) else { return false }
            return item.seenInGame && !usedItems.contains($0)
        } ?? "Leftovers"
        usedItems.insert(slot.item)

        // Spread and alignment, built to a benchmark rather than to a habit.
        let support = roles.contains(.redirection) || roles.contains(.tailwind)
            || roles.contains(.trickRoom) || roles.contains(.terrain)
        let physical = form.attack >= form.spAttack
        let built = spread(for: form, physical: physical, support: support, plan: plan,
                           tailwind: roles.contains(.tailwind) || plan == .tailwind)
        slot.sp = built.sp
        slot.alignmentName = built.alignment

        slot.moves = chooseMoves(form, roles: roles, plan: plan, usage: usage,
                                 ability: slot.ability, item: slot.item,
                                 allyGrounded: allyGrounded)
        return slot
    }

    /// Something whose whole case is hitting hard should be hitting hard.
    private func physicalAttackerIsTheWholePoint(_ form: Form) -> Bool {
        max(form.attack, form.spAttack) >= 130
    }

    /// Speed numbers worth investing to beat, from the tracked field.
    private var benchmarks: [Int] { store.speedBenchmarks(format: format) }

    /// The same numbers seen from under your own Tailwind.
    ///
    /// Coaching advice that keeps coming up is "invest enough to outspeed X
    /// under Tailwind", and that is a different number: doubling your own Speed
    /// halves what you need to reach. A team that carries Tailwind was still
    /// paying full price for Speed it did not need.
    private func benchmarks(underTailwind: Bool) -> [Int] {
        let marks = benchmarks
        // Opponents in this format nearly all carry Tailwind of their own, so
        // yours buys parity rather than a free halving. Half the gap, not all.
        return underTailwind ? marks.map { Int(Double($0) * 0.72) } : marks
    }

    /// A spread aimed at a Speed benchmark the Pokémon can actually reach.
    ///
    /// The previous version gave every attacker 32 Speed and every supporter 2,
    /// which produced teams sitting at 108-139 against a field whose benchmarks
    /// are 178 to 223 — investment that bought nothing. Here, Speed is only paid
    /// for when it clears something real, and the points go into bulk otherwise.
    func spread(for form: Form, physical: Bool, support: Bool,
                plan: Archetype, tailwind: Bool = false) -> (sp: [Int], alignment: String) {
        var sp = Array(repeating: 0, count: 6)
        let attacking: Stat = physical ? .attack : .spAttack

        // Trick Room wants to be slow, so none of this applies.
        if plan == .trickRoom {
            sp[attacking.rawValue] = 32
            sp[Stat.hp.rawValue] = 32
            sp[Stat.defense.rawValue] = 2
            return (sp, physical ? "Brave" : "Quiet")
        }

        let marks = benchmarks(underTailwind: tailwind)
        // Try the attack-boosting alignment first: Speed that clears a benchmark
        // is worth having, but not at the cost of the attacking stat if the
        // benchmark is reachable either way.
        for alignmentName in [physical ? "Adamant" : "Modest", physical ? "Jolly" : "Timid"] {
            let alignment = Alignment.named(alignmentName)
            let ceiling = ChampionsStats.value(base: form.speed, sp: 32,
                                               stat: .speed, alignment: alignment)
            // The highest mark this Pokémon can actually get above.
            guard let target = marks.first(where: { $0 < ceiling }) else { continue }
            // Cheapest investment that clears it.
            var needed = 32
            for candidate in 0...32 {
                let value = ChampionsStats.value(base: form.speed, sp: candidate,
                                                 stat: .speed, alignment: alignment)
                if value > target { needed = candidate; break }
            }
            sp[Stat.speed.rawValue] = needed
            sp[attacking.rawValue] = support ? 0 : 32
            let spent = sp.reduce(0, +)
            // Everything left goes into bulk rather than being wasted, and into
            // the side it is already good at: health multiplies whichever
            // defence it has, so points spent there are worth more.
            let spare = ChampionsStats.spTotal - spent
            sp[Stat.hp.rawValue] = min(32, spare)
            let after = ChampionsStats.spTotal - sp.reduce(0, +)
            if after > 0 {
                let role = store.statRole(of: form)
                let strong: Stat = role.defence == .specialWall ? .spDefense : .defense
                let other: Stat = strong == .defense ? .spDefense : .defense
                sp[strong.rawValue] = min(32, after)
                let last = ChampionsStats.spTotal - sp.reduce(0, +)
                if last > 0 { sp[other.rawValue] = min(32, last) }
            }
            return (sp, alignmentName)
        }

        // Nothing reachable: do not pay for Speed at all.
        sp[attacking.rawValue] = support ? 0 : 32
        sp[Stat.hp.rawValue] = 32
        let spare = ChampionsStats.spTotal - sp.reduce(0, +)
        let role = store.statRole(of: form)
        let strong: Stat = role.defence == .specialWall ? .spDefense : .defense
        let other: Stat = strong == .defense ? .spDefense : .defense
        sp[strong.rawValue] = min(32, spare)
        let last = ChampionsStats.spTotal - sp.reduce(0, +)
        if last > 0 { sp[other.rawValue] = min(32, last) }
        return (sp, support
                ? (physical ? "Careful" : "Calm")
                : (physical ? "Adamant" : "Modest"))
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

    /// Four moves, built to a doubles shape rather than to raw power.
    ///
    /// Reserving the last slot for Protect matters: the previous version added
    /// it after coverage, so it was crowded out of 58 of 78 slots. Two damaging
    /// moves of the same type are a wasted slot, and a team with no spread move
    /// at all has no way to win a doubles game, so both are handled explicitly.
    ///
    /// `allyGrounded` is the count of partners an Earthquake would also hit.
    private func chooseMoves(_ form: Form, roles: Set<TeamRole>, plan: Archetype,
                             usage: UsageEntry?, ability: String, item: String,
                             allyGrounded: Int) -> [String] {
        var chosen: [String] = []
        var usedTypes = Set<String>()
        let learnset = store.moves(for: form)

        // Assault Vest forbids status moves, and a Choice item locks you into
        // one — neither wants Protect.
        let wantsProtect = item != "Assault Vest"
            && !item.hasPrefix("Choice")
        let budget = wantsProtect ? 3 : 4

        @discardableResult
        func add(_ name: String) -> Bool {
            guard chosen.count < budget,
                  let move = learnset.first(where: { $0.name == name }),
                  !chosen.contains(move.id) else { return false }
            if move.isDamaging {
                guard usedTypes.insert(move.type).inserted else { return false }
            }
            chosen.append(move.id)
            return true
        }

        // Status before damage on something built to survive. Coaching material
        // is emphatic about this and the engine now agrees: a burn halves a
        // physical attacker for the whole game, which beats one more attack from
        // a Pokémon that was never going to out-damage it anyway.
        let bulky = form.hp + form.defense + form.spDefense >= 300
        if bulky && !physicalAttackerIsTheWholePoint(form) {
            for name in ["Will-O-Wisp", "Thunder Wave", "Hypnosis", "Spore"] {
                if add(name) { break }
            }
        }

        // The role move is the reason the slot exists.
        if plan == .trickRoom { add("Trick Room") }
        if roles.contains(.tailwind) { add("Tailwind") }
        if roles.contains(.redirection) { if !add("Follow Me") { add("Rage Powder") } }
        if roles.contains(.fakeOut) { add("Fake Out") }
        // Moves people actually run, in the order they run them.
        for name in usage?.keyMoves ?? [] where !name.hasPrefix("Protect") { add(name) }

        let physical = form.attack >= form.spAttack
        let usesNormal = form.types.contains("Normal")
            || form.abilities.contains { ["Aerilate", "Pixilate", "Refrigerate",
                                          "Galvanize", "Normalize"].contains($0.name) }
        // Worth, not base power. Steel Beam's 140 is not 140 when it costs half
        // your HP, and Focus Blast's 120 is not 120 at 70% accuracy.
        func ranked(_ pool: [Move]) -> [Move] {
            pool.sorted {
                store.moveValue($0, for: form, ability: ability, item: item)
                    > store.moveValue($1, for: form, ability: ability, item: item)
            }
        }
        let attacks = ranked(store.attackingMoves(for: form)
            .filter { physical ? $0.category == "Physical" : $0.category == "Special" }
            .filter { $0.type != "Normal" || usesNormal }
            // An Earthquake beside three grounded partners costs more than it wins.
            .filter { !($0.hitsAlly && allyGrounded >= 2) })

        // A spread move first — doubles games are decided by hitting both.
        if let spreadMove = attacks.first(where: { $0.isSpread }) { add(spreadMove.name) }
        // Then the strongest STAB, then coverage, one per type.
        for move in attacks where form.types.contains(move.type) { add(move.name) }
        for move in attacks { add(move.name) }

        if wantsProtect, chosen.count < 4 {
            if learnset.contains(where: { $0.name == "Protect" }) {
                chosen.append(learnset.first { $0.name == "Protect" }!.id)
            } else if let detect = learnset.first(where: { $0.name == "Detect" }) {
                chosen.append(detect.id)
            }
        }
        // If anything is still short, top up with the best remaining attack.
        for move in attacks where chosen.count < 4 {
            if !chosen.contains(move.id) { chosen.append(move.id) }
        }
        return chosen
    }

    // MARK: Two-Mega lines

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

    // MARK: Public entry point

    /// Build several complete teams around `seed`, one per viable plan.
    ///
    /// This is the path the interface uses, and it exists to let go of the main
    /// thread: not between plans, which left three-quarters of a second in one
    /// piece, but inside the beam, between finalists, and between the opponents
    /// each finalist is scored against. Nothing here is faster for it; it is
    /// interruptible, which is what a spinner needs to move.
    func blueprints(seed: Form, picks: [Forecast.Pick], perPlan: Int = 1,
                    dualMega: Bool = false,
                    progress: @escaping @MainActor (String, Double) -> Void) async -> [Blueprint] {
        progress("Reading the field", 0)
        // What winning teams carry is worked out once and then cached for the
        // life of the process. Paying for it in the middle of the search meant
        // one stall of a third of a second with the spinner already turning; it
        // is cheap now, and taken here it lands before anything is animating.
        await breathe("start")
        // Build the opponent lists first, breathing through them, so that
        // working out what winning teams carry is only the arithmetic and not
        // a hundred team constructions in one piece.
        await warmOpponentTeams(format: format)
        _ = store.winningStructure(format: format)
        await breathe("warm the structure")
        var candidates = await profiles(picks: picks, yielding: true)
        if !candidates.contains(where: { $0.form.id == seed.id }) {
            candidates += profiles(for: [seed])
        }

        let plans = self.plans(for: seed)
        var out: [Blueprint] = []
        var seenTeams = Set<String>()

        for (index, plan) in plans.enumerated() {
            let base = Double(index) / Double(max(1, plans.count))
            progress("Searching the \(plan.rawValue) plan", base)
            await breathe("plan start")
            let results = await search(seed: seed, plan: plan, pool: candidates,
                                       dualMega: dualMega, yielding: true)
            var taken = 0
            for profileSet in results {
                guard taken < perPlan else { break }
                let key = profileSet.map(\.form.id).sorted().joined(separator: "|")
                guard seenTeams.insert(key).inserted else { continue }
                taken += 1
                progress("Scoring a \(plan.rawValue) six",
                         base + 0.6 / Double(max(1, plans.count)))
                out.append(await finish(profileSet, seed: seed, plan: plan,
                                        dualMega: dualMega, yielding: true))
            }
        }
        progress("Ranking them", 1)
        return out.sorted { $0.score.total > $1.score.total }
    }

    func blueprints(seed: Form, picks: [Forecast.Pick], perPlan: Int = 1,
                    dualMega: Bool = false, only: Archetype? = nil) -> [Blueprint] {
        var candidates = profiles(picks: picks)
        if !candidates.contains(where: { $0.form.id == seed.id }) {
            candidates += profiles(for: [seed])
        }
        var out: [Blueprint] = []
        // Different plans often converge on the same six; show each set once,
        // attributed to the plan that scored it highest.
        var seenTeams = Set<String>()

        for plan in plans(for: seed) where only == nil || plan == only {
            let results = searchSync(seed: seed, plan: plan, pool: candidates,
                                     dualMega: dualMega)
            var taken = 0
            for profileSet in results {
                guard taken < perPlan else { break }
                let key = profileSet.map(\.form.id).sorted().joined(separator: "|")
                guard seenTeams.insert(key).inserted else { continue }
                taken += 1

                out.append(finishSync(profileSet, seed: seed, plan: plan, dualMega: dualMega))
            }
        }
        return out.sorted { $0.score.total > $1.score.total }
    }

    private func finishSync(_ profileSet: [Profile], seed: Form, plan: Archetype,
                            dualMega: Bool) -> Blueprint {
        var usedItems = Set<String>()
        var team = Team(name: "\(seed.formLabel) · \(plan.rawValue)", format: format)
        let grounded = profileSet.filter { profile in
            !profile.types.contains(.flying)
                && profile.form.abilities.first?.name != "Levitate"
        }.count
        team.slots = profileSet.map {
            let others = grounded - ((!$0.types.contains(.flying)
                && $0.form.abilities.first?.name != "Levitate") ? 1 : 0)
            return flesh($0.form, plan: plan, usedItems: &usedItems, allyGrounded: others)
        }
        team.locked = true
        let scored = evaluate(team, plan: plan)
        let lines = dualMega ? battlePlans(for: team, seed: seed) : []
        return Blueprint(plan: plan, title: "\(seed.formLabel) · \(plan.rawValue)",
                         rationale: lines.count == 2
                            ? "Two Megas, two ways to play it. \(plan.advice)" : plan.advice,
                         team: team, score: scored.0, perArchetype: scored.1,
                         notes: TeamAdvisor(team: team, store: store).metaNotes.map(\.title),
                         lines: lines,
                         answers: GamePlanner(store: store, team: team, format: format).answers)
    }

    /// Turn a chosen six into a scored blueprint.
    private func finish(_ profileSet: [Profile], seed: Form, plan: Archetype,
                        dualMega: Bool, yielding: Bool = false) async -> Blueprint {
                var usedItems = Set<String>()
                var team = Team(name: "\(seed.formLabel) · \(plan.rawValue)", format: format)
                // How many partners an ally-hitting spread move would catch.
                let grounded = profileSet.filter { profile in
                    !profile.types.contains(.flying)
                        && profile.form.abilities.first?.name != "Levitate"
                }.count
                team.slots = profileSet.map {
                    let others = grounded - ((!$0.types.contains(.flying)
                        && $0.form.abilities.first?.name != "Levitate") ? 1 : 0)
                    return flesh($0.form, plan: plan, usedItems: &usedItems,
                                 allyGrounded: others)
                }
                team.locked = true
                if yielding { await breathe("flesh out") }
                let scored = await evaluate(team, plan: plan, yielding: yielding)
                if yielding { await breathe("evaluate") }
                let lines = dualMega
                    ? await battlePlans(for: team, seed: seed, yielding: yielding) : []
                if yielding { await breathe("battle plans tail") }
                // Worked out before the blueprint rather than inside it, so
                // there is somewhere to breathe first.
                let answers = GamePlanner(store: store, team: team, format: format).answers
                let notes = TeamAdvisor(team: team, store: store).metaNotes.map(\.title)
                if yielding { await breathe("game plan") }
                return Blueprint(plan: plan,
                                 title: "\(seed.formLabel) · \(plan.rawValue)",
                                 rationale: lines.count == 2
                                    ? "Two Megas, two ways to play it. \(plan.advice)"
                                    : plan.advice,
                                 team: team, score: scored.0,
                                 perArchetype: scored.1,
                                 notes: notes,
                                 lines: lines,
                                 answers: answers)
    }

    /// The field a matchup between these two teams actually starts on.
    ///
    /// Every matchup was scored on an empty field, which quietly deleted the
    /// point of a weather team: a Golisopod side whose whole answer to its 4x
    /// Fire weakness is Pelipper's Drizzle was being graded as though the rain
    /// were never up. When both sides set something it is genuinely contested,
    /// so that case stays neutral rather than guessing who wins the lead.
    func field(for team: Team, against opponent: Team? = nil) -> Field {
        func conditions(_ t: Team) -> (Weather, Terrain) {
            var weather = Weather.none
            var terrain = Terrain.none
            for slot in t.slots {
                guard let combatant = slot.combatant(in: store.rulebook) else { continue }
                switch combatant.ability {
                case "Drizzle":       weather = .rain
                case "Drought":       weather = .sun
                case "Sand Stream":   weather = .sand
                case "Snow Warning":  weather = .snow
                case "Grassy Surge":  terrain = .grassy
                case "Psychic Surge": terrain = .psychic
                case "Electric Surge": terrain = .electric
                case "Misty Surge":   terrain = .misty
                default: break
                }
            }
            return (weather, terrain)
        }
        let (myWeather, myTerrain) = conditions(team)
        let (theirWeather, theirTerrain) = opponent.map(conditions) ?? (.none, .none)
        return Field(
            weather: theirWeather != .none && theirWeather != myWeather ? .none : myWeather,
            terrain: theirTerrain != .none && theirTerrain != myTerrain ? .none : myTerrain,
            isDoubles: team.format == "doubles")
    }

    /// Whether this team can remove something behind a Focus Sash.
    ///
    /// Sash is on 87% of measured Whimsicott sets and 37% of Pelipper, and the
    /// hardest single hit in the game does not get through one. What does: a
    /// multi-hit move, a chip attack followed by priority, or simply two
    /// attackers on the same target. A team with none of those loses tempo to
    /// every Sash lead it meets.
    func breaksSashes(_ team: Team) -> (can: Bool, how: [String]) {
        var how: [String] = []
        for slot in team.slots {
            guard let form = slot.battleForm(in: store.rulebook) else { continue }
            for id in slot.moves {
                guard let move = store.move(id), move.isDamaging else { continue }
                if move.effect.contains("attacks 2 to") || move.effect.contains("times in a row") {
                    how.append("\(form.formLabel)'s \(move.name) hits more than once")
                } else if move.priority > 0 && move.power >= 40 {
                    how.append("\(form.formLabel)'s \(move.name) finishes through it")
                } else if move.isSpread {
                    how.append("\(form.formLabel)'s \(move.name) chips both")
                }
            }
        }
        // Two attackers on one target does it too, which the matchup engine
        // already works out; here it is enough that the team has two.
        let attackers = team.slots.filter { slot in
            slot.moves.contains { store.move($0)?.isDamaging == true }
        }.count
        if attackers >= 3 { how.append("three or more attackers can focus one target") }
        return (!how.isEmpty, Array(Set(how)).sorted())
    }

    /// How much of the format's game plan this team can turn off.
    ///
    /// Weighted by how much of the field actually runs each tactic, so an answer
    /// to Fake Out — which 41% of teams carry — counts for far more than an
    /// answer to something nobody is playing. Changing the terrain the format
    /// puts up is scored separately, because it is the one answer that affects
    /// every turn rather than one of them.
    func disruption(of team: Team) -> Double {
        let meta = MetaModel(store: store, format: format)
        let coverage = meta.coverage(of: team)
        let weight = coverage.reduce(0.0) { $0 + $1.share }
        let answered = coverage.reduce(0.0) { $0 + ($1.isAnswered ? $1.share : 0) }
        let tacticScore = weight > 0 ? answered / weight : 0.5

        let control = meta.fieldControl(of: team)
        let fieldWeight = control.reduce(0.0) { $0 + $1.pressure.probability }
        // An override nobody has selected is worth half: it is real, but it is
        // a move slot they have not spent.
        let controlled = control.reduce(0.0) { running, entry in
            guard entry.answer != nil else { return running }
            return running + entry.pressure.probability * (entry.isSelected ? 1 : 0.5)
        }
        let fieldScore = fieldWeight > 0 ? controlled / fieldWeight : 0.5

        // Getting through a Focus Sash is part of turning the format off.
        let sash = breaksSashes(team).can ? 1.0 : 0.0
        return tacticScore * 0.6 + fieldScore * 0.25 + sash * 0.15
    }

    /// The real evaluation, run on finished teams only.
    ///
    /// `opponentLimit` trims the pool for search passes that need to score
    /// hundreds of candidate teams; the finalists are always re-scored against
    /// everything.
    /// The same evaluation, breathing between opponents.
    ///
    /// Scoring a six against thirty-one teams is a third of a second in one
    /// piece, which is twenty frames the interface cannot draw. An earlier
    /// attempt at this only warmed the caches and then called the synchronous
    /// version, so it changed nothing: the loop itself has to let go.
    func evaluate(_ team: Team, plan: Archetype, yielding: Bool,
                  opponentLimit: Int? = nil) async -> (TeamScore, [(String, Int)]) {
        guard yielding else {
            return evaluate(team, plan: plan, opponentLimit: opponentLimit)
        }
        let advisor = TeamAdvisor(team: team, store: store)
        let analysis = TeamAnalysis(team: team, store: store)
        var score = TeamScore()
        let held = advisor.rolesPresent
        let hasTailwind = !(held[.tailwind]?.isEmpty ?? true)
        let hasTrickRoom = !(held[.trickRoom]?.isEmpty ?? true)

        // Building the pool is itself a chunk of work the first time, since
        // every opponent is fleshed out from a team list. Breathe through it
        // rather than in front of it.
        let opponents = await opponentPoolYielding(for: team, limit: opponentLimit)
        var perArchetype: [(String, Int)] = []
        var total = 0.0, weight = 0.0
        for (index, opponent) in opponents.enumerated() {
            if index % 2 == 0 { await breathe("matchups") }
            let theirs = opponent.team
            let matchup = Matchup(mine: team, theirs: theirs, rules: store.rulebook,
                                  field: field(for: team, against: theirs),
                                  myTailwind: hasTailwind, theirTailwind: true,
                                  myTrickRoom: hasTrickRoom)
            let edge = matchup.verdict.score
            perArchetype.append((opponent.name, edge))
            total += Double(edge) * opponent.weight
            weight += opponent.weight
        }
        score.matchup = weight > 0 ? total / weight : 0
        await breathe("matchups tail")
        finishScore(&score, team: team, plan: plan, advisor: advisor, analysis: analysis)
        return (score, perArchetype)
    }

    /// The pool, built a few at a time.
    private func opponentPoolYielding(for team: Team, limit: Int? = nil) async
        -> [(name: String, team: Team, weight: Double)] {
        await warmOpponentTeams(format: team.format)
        return opponentPool(for: team, limit: limit)
    }

    /// Build every opponent team the search will need, a few at a time.
    ///
    /// Only breathes where there is something to breathe through. Once these
    /// are built the loop is nothing but sleeping, and the refiner asks for the
    /// pool a few thousand times: it was spending 45ms per evaluation
    /// suspending over an entirely warm cache.
    private func warmOpponentTeams(format: String) async {
        var built = 0
        for meta in store.data.metaTeams
        where meta.format == format && !store.hasOpponentTeam(meta) {
            if built % 6 == 0 { await breathe("opponent pool") }
            _ = store.opponentTeam(meta)
            built += 1
        }
    }

    /// Who a team is scored against, in one place so both paths agree.
    private func opponentPool(for team: Team, limit: Int?)
        -> [(name: String, team: Team, weight: Double)] {
        let written = store.data.metaTeams.filter { $0.format == team.format && $0.record == nil }
        let played = store.data.metaTeams
            .filter { $0.format == team.format && $0.record != nil }
            .sorted { ($0.winRate ?? 0, $0.gamesPlayed) > ($1.winRate ?? 0, $1.gamesPlayed) }
            .prefix(16)
        var opponents: [(name: String, team: Team, weight: Double)] =
            (written + played).map { ($0.name, store.opponentTeam($0), 1.0) }
        for (sampled, share) in store.ladderTeams(format: format) {
            opponents.append((sampled.name, sampled, max(0.5, share * 3)))
        }
        if let limit, opponents.count > limit {
            opponents = Array(opponents.sorted { $0.weight > $1.weight }.prefix(limit))
        }
        return opponents
    }

    /// Everything after the matchups, which both paths share.
    private func finishScore(_ score: inout TeamScore, team: Team, plan: Archetype,
                             advisor: TeamAdvisor, analysis: TeamAnalysis) {
        let held = advisor.rolesPresent
        _ = held
        let meta = MetaModel(store: store, format: format)
        let structure = store.winningStructure(format: format)
        var carried = 0.0, expected = 0.0
        for (group, share) in structure {
            expected += share
            if !meta.fills(group, in: team).isEmpty { carried += share }
        }
        score.roles = expected > 0 ? carried / expected : 0
        score.defence = 1 - min(1, Double(analysis.softSpots.count) / 8)
        score.coverage = Double(analysis.coverage.filter { !$0.carriers.isEmpty }.count) / 18
        let detected = advisor.archetypes
        score.synergy = detected.contains { $0.archetype == plan && $0.isSupported } ? 1
            : (detected.contains { $0.isSupported } ? 0.6 : 0.25)
        score.disruption = disruption(of: team)
        if team.slots.contains(where: { slot in
            slot.moves.contains { store.move($0)?.name == "Revival Blessing" }
        }) {
            score.synergy = min(1, score.synergy + 0.25)
        }
        score.violations = team.violations(in: store)
    }

    func evaluate(_ team: Team, plan: Archetype,
                  opponentLimit: Int? = nil) -> (TeamScore, [(String, Int)]) {
        let advisor = TeamAdvisor(team: team, store: store)
        let analysis = TeamAnalysis(team: team, store: store)
        var score = TeamScore()

        // Matchups, with the team's own speed control switched on — this is the
        // fix for the trade model undervaluing support.
        let held = advisor.rolesPresent
        let hasTailwind = !(held[.tailwind]?.isEmpty ?? true)
        let hasTrickRoom = !(held[.trickRoom]?.isEmpty ?? true)
        var perArchetype: [(String, Int)] = []
        var total = 0.0, weight = 0.0

        // Hand-written archetypes describe strategies; teams sampled from the
        // usage table describe what you will actually be queued against. Both
        // count, with the measured ones weighted by how much of the ladder they
        // represent, so the score no longer rests on seven of my opinions.
        // Every tournament team is kept in the dataset, because the weight
        // calibration wants the largest sample it can get. Scoring against all
        // of them is a different matter: it was sixty-three matchups per
        // evaluation, and the extra forty said nothing the first sixteen had
        // not. The best-performing ones are the ones worth answering.
        let written = store.data.metaTeams.filter { $0.format == team.format && $0.record == nil }
        let played = store.data.metaTeams
            .filter { $0.format == team.format && $0.record != nil }
            .sorted { ($0.winRate ?? 0, $0.gamesPlayed) > ($1.winRate ?? 0, $1.gamesPlayed) }
            .prefix(16)
        var opponents: [(name: String, team: Team, weight: Double)] =
            (written + played).map { ($0.name, store.opponentTeam($0), 1.0) }
        for (sampled, share) in store.ladderTeams(format: format) {
            opponents.append((sampled.name, sampled, max(0.5, share * 3)))
        }
        if let limit = opponentLimit, opponents.count > limit {
            // Keep a spread: the heaviest-weighted first, which is the measured
            // ladder, then whatever archetypes fit.
            opponents = Array(opponents.sorted { $0.weight > $1.weight }.prefix(limit))
        }

        for opponent in opponents {
            let theirs = opponent.team
            // Opponents in this format nearly all carry Tailwind of their own.
            let matchup = Matchup(mine: team, theirs: theirs, rules: store.rulebook,
                                  field: field(for: team, against: theirs),
                                  myTailwind: hasTailwind, theirTailwind: true,
                                  myTrickRoom: hasTrickRoom)
            let edge = matchup.verdict.score
            perArchetype.append((opponent.name, edge))
            total += Double(edge) * opponent.weight
            weight += opponent.weight
        }
        score.matchup = weight > 0 ? total / weight : 0

        // Jobs a team needs done, weighted by how often teams that actually won
        // carry them, rather than a checklist of five categories I chose.
        let meta = MetaModel(store: store, format: format)
        let structure = store.winningStructure(format: format)
        var carried = 0.0, expected = 0.0
        for (group, share) in structure {
            expected += share
            if !meta.fills(group, in: team).isEmpty { carried += share }
        }
        score.roles = expected > 0 ? carried / expected : 0
        score.defence = 1 - min(1, Double(analysis.softSpots.count) / 8)
        score.coverage = Double(analysis.coverage.filter { !$0.carriers.isEmpty }.count) / 18
        let detected = advisor.archetypes
        score.synergy = detected.contains { $0.archetype == plan && $0.isSupported } ? 1
            : (detected.contains { $0.isSupported } ? 0.6 : 0.25)
        score.disruption = disruption(of: team)
        // Revival Blessing brings a fainted member back at half health. In a
        // format where you bring four, that is close to a fifth body, and it
        // scored nothing at all because it deals no damage.
        if team.slots.contains(where: { slot in
            slot.moves.contains { store.move($0)?.name == "Revival Blessing" }
        }) {
            score.synergy = min(1, score.synergy + 0.25)
        }
        score.violations = team.violations(in: store)
        return (score, perArchetype)
    }
}
