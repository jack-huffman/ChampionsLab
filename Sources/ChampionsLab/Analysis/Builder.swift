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
//
//  The builder is one type across six files, one per stage: the profiles the
//  search draws from (BuilderProfiles), the beam and its cheap score
//  (BuilderSearch), giving a chosen Pokemon its set (BuilderFlesh), two-Mega
//  lines (BuilderLines), scoring a finished team (BuilderEvaluation), and the
//  entry point here, which runs them in that order.

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

}
