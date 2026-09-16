//  SimulationService.swift
//  A simulation that keeps going when you look at something else.
//
//  It used to live on the view, which meant leaving the Simulate tab threw the
//  run away. Three thousand games is forty minutes, and forty minutes during
//  which the rest of the app is off limits is not a feature anybody would use.
//
//  Moving it out here is the easy half. The half worth being careful about is
//  that work you cannot see is exactly what made this app feel broken once
//  before: a parity audit carried on after its screen was gone, saturating
//  every core with nothing on screen to say why. The difference is not that
//  this one is allowed to and that one was not — it is that this one is asked
//  for deliberately, says so while it runs from wherever you are in the app,
//  and can be stopped from there too. Background work with no indicator is the
//  bug; background work with one is a feature.

import Foundation

@MainActor
final class SimulationService: ObservableObject {
    static let shared = SimulationService()

    struct Running {
        let teamID: String
        let teamName: String
        let wanted: Int
        var progress: TeamLab.Progress?
    }

    /// The one run in flight, if there is one.
    ///
    /// One at a time on purpose. The games are single-threaded — the turn
    /// model keeps its dice in one place — so two runs would not go twice as
    /// fast, they would take twice as long each and make the machine
    /// unpleasant while they did it.
    @Published private(set) var running: Running?
    /// Bumped when a run finishes, so views reading the stored report know to
    /// look again.
    @Published private(set) var finished = 0

    nonisolated(unsafe) private var task: Task<Void, Never>?

    private init() {}

    func isRunning(_ team: Team) -> Bool { running?.teamID == team.id.uuidString }

    /// `only` narrows the run to a single opponent, which turns a survey of
    /// the field into a head-to-head.
    func start(team: Team, store: Store, games: Int, depth: Double, only: String? = nil) {
        guard running == nil else { return }
        running = Running(teamID: team.id.uuidString, teamName: team.name, wanted: games)

        let rules = store.rulebook
        var planner = SpreadPlanner(store: store)
        planner.field = Field(isDoubles: true)
        let whole = SelfPlay.teams(from: store.data, rules: rules, planner: planner)
        let field = only.flatMap { name in
            whole.first { $0.name == name }.map { [$0] }
        } ?? whole
        let already = store.measured(for: team)?.games ?? 0

        task = Task.detached(priority: .utility) { [weak self] in
            let found = TeamLab.run(
                team: team, against: field, rules: rules,
                games: games, budget: depth, resumeFrom: already,
                progress: { step in
                    Task { @MainActor in self?.running?.progress = step }
                },
                shouldStop: { Task.isCancelled })
            await MainActor.run {
                guard let self else { return }
                // A cancelled run still keeps what it played. Those games
                // happened; throwing them away because somebody pressed Stop
                // would make stopping expensive, and it is meant to be free.
                if found.games > 0 { store.remember(found, for: team) }
                self.running = nil
                self.task = nil
                self.finished += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = nil
    }

    deinit { task?.cancel() }
}
