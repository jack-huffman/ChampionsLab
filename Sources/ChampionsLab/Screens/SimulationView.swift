//  SimulationView.swift
//  Put the team on the field a few thousand times and see what happens.
//
//  Everything else in the app reasons about a team. This one plays it: real
//  games, the real turn model, the same engine that sits in the battle screen,
//  in both chairs, against the field the team will actually meet.
//
//  It exists because the things worth knowing about a team are the ones that
//  only show up in aggregate. A Pokémon whose typing looks fine and which
//  still dies twice for every knockout it takes. Two fours from the same six,
//  one winning half its games and the other a fifth. A move in a slot that
//  never once gets chosen. None of that is visible from a team list.
//
//  On not making the app stutter, which it has done before: the work runs on a
//  held detached task, the screen stops it on the way out, and the model kills
//  it in deinit. A cancel that only hid the progress bar would leave every
//  core busy for another two minutes with nothing on screen to say why — which
//  is exactly what the parity audit used to do.

import SwiftUI

@MainActor
final class SimulationModel: ObservableObject {
    enum Phase { case idle, working, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: TeamLab.Progress?
    @Published private(set) var report: TeamLab.Report?

    /// Nonisolated so `deinit` can reach it. Only the main actor writes it.
    nonisolated(unsafe) private var task: Task<Void, Never>?

    var isWorking: Bool { phase == .working }

    func run(team: Team, store: Store, games: Int, depth: Double) {
        guard !isWorking else { return }
        phase = .working
        progress = nil
        report = nil

        let rules = store.rulebook
        // The field is built the way the app would build it rather than with
        // one crude spread for everybody, or the run measures your spreads
        // against nobody's.
        var planner = SpreadPlanner(store: store)
        planner.field = Field(isDoubles: true)
        let field = SelfPlay.teams(from: store.data, rules: rules, planner: planner)
        // Where the last run left off, so this one plays new games rather than
        // the same ones over again.
        let already = store.measured(for: team)?.games ?? 0

        task = Task.detached(priority: .utility) { [weak self] in
            let found = TeamLab.run(
                team: team, against: field, rules: rules,
                games: games, budget: depth, resumeFrom: already,
                progress: { step in Task { @MainActor in self?.progress = step } },
                shouldStop: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.report = found
                self?.phase = .finished
                // Kept, so the picker can use it and so the minutes are not
                // spent again for the same answer.
                if found.games > 0 { store.remember(found, for: team) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .working { phase = report == nil ? .idle : .finished }
        progress = nil
    }

    /// Leaving the screen stops the games.
    deinit { task?.cancel() }
}

struct SimulationView: View {
    let team: Team
    /// A finished run handed in, so a shot can show the findings without
    /// spending two minutes playing them first.
    var seeded: TeamLab.Report?
    @EnvironmentObject private var store: Store
    @StateObject private var model = SimulationModel()
    @State private var games = 400
    @State private var depth = 0.03
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if snapshotMode { content } else { ScrollView { content } }
        }
        .onDisappear { model.cancel() }
    }

    // MARK: - Setting it going

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Games", selection: $games) {
                    Text("200 — a look, about 2 minutes").tag(200)
                    Text("400 — a reading, about 5").tag(400)
                    Text("1,000 — a verdict, about 12").tag(1000)
                    Text("3,000 — the lot, about 40").tag(3000)
                }
                .frame(width: 250).labelsHidden().controlSize(.small)
                .disabled(model.isWorking)

                Picker("Depth", selection: $depth) {
                    Text("Quick — shallow play").tag(0.015)
                    Text("Normal").tag(0.03)
                    Text("Careful — slow, plays better").tag(0.08)
                }
                .frame(width: 230).labelsHidden().controlSize(.small)
                .disabled(model.isWorking)

                if model.isWorking {
                    Button("Stop") { model.cancel() }.controlSize(.small)
                } else {
                    Button(model.report == nil ? "Run" : "Run again") {
                        model.run(team: team, store: store, games: games, depth: depth)
                    }
                    .controlSize(.small)
                    .disabled(team.slots.count < 4)
                }
                Spacer()
                if let report = seeded ?? model.report ?? store.measured(for: team),
                   !model.isWorking {
                    Text(report.runs > 1
                         ? "\(report.games) games over \(report.runs) runs"
                         : "\(report.games) games")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text("Runs add to each other: play four hundred now and four hundred later and "
                 + "the team has eight hundred games behind it, continuing round the field "
                 + "rather than repeating. Editing the team starts the record again, because "
                 + "the old games were about a different team.\n\n"
                 + "Real games against every published list, both sides played by the engine. "
                 + "A few hundred is enough to see which Pokémon are carrying the team; a "
                 + "thousand before believing a matchup. It runs on one core — the turn "
                 + "model keeps its dice in one place, so games cannot share threads — and "
                 + "it keeps going while you work elsewhere in the app. The timings are at "
                 + "Normal depth; Quick is about twice as fast and Careful about half.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if team.slots.count < 4 {
                Text("A team needs four Pokémon before it can be played.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
        }
        .padding(12)
    }

    // MARK: - What it found

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isWorking { working }
            if let report = seeded ?? model.report ?? store.measured(for: team),
               report.games > 0 {
                headline(report)
                carrying(report)
                fours(report)
                hardest(report)
                unused(report)
            } else if !model.isWorking {
                Text("Nothing run yet.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .padding(12)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let step = model.progress {
                    Text("\(step.played) of \(step.of) — \(step.wins) won, "
                         + "against \(step.against)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Building the field…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let step = model.progress {
                ProgressView(value: Double(step.played), total: Double(max(1, step.of)))
                    .progressViewStyle(.linear)
            }
        }
    }

    private func headline(_ report: TeamLab.Report) -> some View {
        Card(padding: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f%%", report.winRate * 100))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(report.winRate >= 0.55 ? Palette.good
                                         : report.winRate >= 0.45 ? Palette.warn : Palette.bad)
                    Text("of \(report.games) games").font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                stat("turns a game", String(format: "%.1f", report.turnsPerGame))
                let workable = report.fours(least: max(4, report.games / 40))
                stat("fours that work",
                     "\(workable.filter { Double($0.wins) / Double($0.games) >= 0.5 }.count)"
                     + " of \(workable.count)")
                if report.draws > 0 { stat("went the distance", "\(report.draws)") }
                Spacer()
                if report.runs > 1 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(report.runs) runs pooled")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text("running again adds to this")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    /// Who is carrying the team and who is being carried.
    private func carrying(_ report: TeamLab.Report) -> some View {
        let rows = report.byTrade
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Who is carrying it",
                              subtitle: "Knockouts against times fainted. Around one is an "
                                      + "even trade; well under it is a Pokémon costing the "
                                      + "team more than it brings, whatever its typing says.")
                ForEach(rows, id: \.form) { row in
                    HStack(spacing: 10) {
                        Text(row.form).font(.system(size: 12))
                            .frame(width: 150, alignment: .leading).lineLimit(1)
                        Text(String(format: "%.0f%% kept", row.record.broughtShare * 100))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("\(row.record.knockouts) : \(row.record.faints)")
                            .font(.system(size: 11, design: .rounded)).monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                        Text(String(format: "%.2f", row.record.trade))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(row.record.trade >= 1 ? Palette.good
                                             : row.record.trade >= 0.7 ? Palette.warn : Palette.bad)
                            .frame(width: 44, alignment: .trailing)
                        GeometryReader { geo in
                            Capsule()
                                .fill(row.record.trade >= 1 ? Palette.good : Palette.bad)
                                .frame(width: geo.size.width
                                       * min(1, row.record.trade / 2.5))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }

    /// The four to bring, measured rather than reasoned.
    private func fours(_ report: TeamLab.Report) -> some View {
        let least = max(4, report.games / 40)
        let rows = report.fours(least: least)
        return Group {
            if rows.count >= 2 {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Which four to bring",
                                      subtitle: "The same six, chosen differently. This is a "
                                              + "team-preview decision, and it is usually worth "
                                              + "more than any change to the team.")
                        ForEach(rows.prefix(6), id: \.four) { row in
                            bringRow(row)
                        }
                        if rows.count > 6, let worst = rows.last {
                            Text("worst of \(rows.count):").font(.system(size: 10))
                                .foregroundStyle(.tertiary).padding(.top, 2)
                            bringRow(worst)
                        }
                    }
                }
            }
        }
    }

    private func bringRow(_ row: (four: String, wins: Int, games: Int)) -> some View {
        let rate = Double(row.wins) / Double(max(1, row.games))
        return HStack(spacing: 10) {
            Text(row.four).font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(String(format: "%.0f%%", rate * 100))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(rate >= 0.55 ? Palette.good
                                 : rate >= 0.45 ? Palette.warn : Palette.bad)
                .frame(width: 44, alignment: .trailing)
            Text("of \(row.games)").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// The teams it cannot beat.
    private func hardest(_ report: TeamLab.Report) -> some View {
        let rows = report.matchups(least: max(3, report.games / 120))
        return Group {
            if rows.count >= 3 {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "What it cannot beat",
                                      subtitle: "Worst matchups in the field, and the best, "
                                              + "over enough games to mean something.")
                        ForEach(rows.prefix(5), id: \.foe) { row in matchupRow(row) }
                        if let best = rows.last, rows.count > 5 {
                            Text("and the easiest:").font(.system(size: 10))
                                .foregroundStyle(.tertiary).padding(.top, 2)
                            matchupRow(best)
                        }
                    }
                }
            }
        }
    }

    private func matchupRow(_ row: (foe: String, wins: Int, games: Int)) -> some View {
        let rate = Double(row.wins) / Double(max(1, row.games))
        return HStack(spacing: 10) {
            Text(row.foe).font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(String(format: "%.0f%%", rate * 100))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(rate >= 0.5 ? Palette.good : Palette.bad)
                .frame(width: 44, alignment: .trailing)
            Text("of \(row.games)").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// Slots doing nothing.
    private func unused(_ report: TeamLab.Report) -> some View {
        let quiet = report.quietMoves.prefix(6)
        return Group {
            if !quiet.isEmpty {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Moves it rarely reaches for",
                                      subtitle: "Across every game. A move at the bottom of "
                                              + "this over a thousand games is a slot the team "
                                              + "is not using.")
                        ForEach(Array(quiet), id: \.move) { row in
                            HStack {
                                Text(row.move).font(.system(size: 11))
                                Spacer()
                                Text("\(row.uses)").font(.system(size: 11, design: .rounded))
                                    .monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
