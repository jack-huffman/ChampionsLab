//  BuilderEvaluation.swift
//  Scoring a finished team the expensive way.
//
//  Only complete blueprints come here: the matchup engine against every
//  published list, on the field the two teams actually start on; the roles,
//  the defensive overlap, the coverage, the synergy; and how much of what the
//  format is doing this team can turn off. The yielding version lets go of the
//  main thread between opponents, which is what a spinner needs to move.

import Foundation

extension TeamBuilder {
    /// The field a matchup between these two teams actually starts on.
    ///
    /// Every matchup was scored on an empty field, which quietly deleted the
    /// point of a weather team: a Golisopod side whose whole answer to its 4x
    /// Fire weakness is Pelipper's Drizzle was being graded as though the rain
    /// were never up. When both sides set something it is genuinely contested,
    /// so that case stays neutral rather than guessing who wins the lead.
    func field(for team: Team, against opponent: Team? = nil) -> Field {
        func conditions(_ t: Team) -> (weather: Weather, terrain: Terrain) {
            FieldSetters.set(by: t.slots.compactMap { $0.combatant(in: store.rulebook)?.ability })
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
    func warmOpponentTeams(format: String) async {
        var built = 0
        for meta in store.data.metaTeams
        where meta.format == format && !store.hasOpponentTeam(meta) {
            if built % 6 == 0 { await breathe("opponent pool") }
            _ = store.opponentTeam(meta)
            built += 1
        }
    }

    /// Who a team is scored against, in one place so both paths agree.
    func opponentPool(for team: Team, limit: Int?)
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
