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

struct SimulationView: View {
    let team: Team
    /// A finished run handed in, so a shot can show the findings without
    /// spending two minutes playing them first.
    var seeded: TeamLab.Report?
    @EnvironmentObject private var store: Store
    /// The run lives outside the screen, so leaving does not stop it.
    @ObservedObject private var lab = SimulationService.shared
    @State private var games = 400
    @State private var depth = 0.03
    /// Empty means the whole field. A name pins it to one opponent, which is
    /// the difference between "how good is this team" and "how does it do into
    /// that".
    @State private var opponent = ""
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            sides
            Divider()
            if snapshotMode { content } else { ScrollView { content } }
        }
        // Deliberately nothing here. The run outlives the screen; the sidebar
        // says it is going and can stop it from anywhere.
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
                .disabled(lab.isRunning(team))

                Picker("Depth", selection: $depth) {
                    Text("Quick — shallow play").tag(0.015)
                    Text("Normal").tag(0.03)
                    Text("Careful — slow, plays better").tag(0.08)
                }
                .frame(width: 230).labelsHidden().controlSize(.small)
                .disabled(lab.isRunning(team))

                Picker("Against", selection: $opponent) {
                    Text("The whole field").tag("")
                    ForEach(store.data.metaTeams.map(\.name).sorted(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(width: 210).labelsHidden().controlSize(.small)
                .disabled(lab.running != nil)

                if lab.isRunning(team) {
                    Button("Stop") { lab.stop() }.controlSize(.small)
                } else {
                    Button(store.measured(for: team) == nil ? "Run" : "Run again") {
                        lab.start(team: team, store: store, games: games, depth: depth,
                                  only: opponent.isEmpty ? nil : opponent)
                    }
                    .controlSize(.small)
                    .disabled(team.slots.count < 4 || lab.running != nil)
                }
                Spacer()
                if let report = seeded ?? store.measured(for: team),
                   !lab.isRunning(team) {
                    Text(report.runs > 1
                         ? "\(report.games) games over \(report.runs) runs"
                         : "\(report.games) games")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text("Runs add to each other: play four hundred now and four hundred later and "
                 + "the team has eight hundred games behind it, continuing round the field "
                 + "rather than repeating. Editing the team starts a new version rather than "
                 + "wiping the record: the old games were about a different team, so they are "
                 + "kept separately and shown below as history.\n\n"
                 + "Real games against every published list, both sides played by the engine. "
                 + "A few hundred is enough to see which Pokémon are carrying the team; a "
                 + "thousand before believing a matchup. It runs on one core — the turn "
                 + "model keeps its dice in one place, so games cannot share threads — and "
                 + "it keeps going while you work elsewhere in the app. The timings are at "
                 + "Normal depth; Quick is about twice as fast and Careful about half.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let running = lab.running, running.teamID != team.id.uuidString {
                Text("Simulating \(running.teamName) at the moment — one at a time, "
                     + "because the games run on a single core.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
            if team.slots.count < 4 {
                Text("A team needs four Pokémon before it can be played.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
        }
        .padding(12)
    }

    // MARK: - The two teams

    /// Yours on the left, theirs on the right.
    ///
    /// While a run is going the right-hand six is whoever is being played at
    /// that moment, cycling through the field as the games go by — which makes
    /// a long run something to watch rather than a progress bar to wait on,
    /// and makes it obvious at a glance that the field is being covered evenly
    /// rather than the same opponent over and over.
    private var sides: some View {
        HStack(alignment: .center, spacing: 14) {
            six(team.slots.compactMap { $0.battleForm(in: store.rulebook) },
                title: team.name, mine: true)
            VStack(spacing: 2) {
                Text("VS").font(.system(size: 11, weight: .heavy)).kerning(1)
                    .foregroundStyle(Palette.accent)
                if let step = lab.running?.progress, lab.isRunning(team) {
                    Text("\(step.played)/\(step.of)")
                        .font(.system(size: 9, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            six(facing, title: facingName, mine: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    /// The six currently opposite: whoever is being played, or the chosen
    /// opponent, or nobody in particular when it is the whole field.
    private var facing: [Form] {
        if lab.isRunning(team), let step = lab.running?.progress {
            return step.againstForms.compactMap { store.formsByID[$0] }
        }
        if !opponent.isEmpty,
           let chosen = store.data.metaTeams.first(where: { $0.name == opponent }) {
            return chosen.members.compactMap { member in
                store.data.forms.first { $0.formLabel == member.form || $0.name == member.form }
            }
        }
        return []
    }

    private var facingName: String {
        if lab.isRunning(team), let step = lab.running?.progress { return step.against }
        return opponent.isEmpty ? "the whole field" : opponent
    }

    private func six(_ forms: [Form], title: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .leading : .trailing, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).kerning(0.5)
                .foregroundStyle(mine ? Palette.accent : .secondary)
                .lineLimit(1).truncationMode(.tail)
            HStack(spacing: 5) {
                if forms.isEmpty {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle().strokeBorder(Palette.hairline,
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 34, height: 34)
                    }
                } else {
                    ForEach(Array(forms.prefix(6).enumerated()), id: \.offset) { _, form in
                        SpriteImage(form: form, side: 34)
                            .help(form.formLabel)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .leading : .trailing)
    }

    // MARK: - What it found

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lab.isRunning(team) { working }
            if let report = seeded ?? store.measured(for: team),
               report.games > 0 {
                headline(report)
                carrying(report)
                fours(report)
                hardest(report)
                unused(report)
                versions()
                acrossTeams()
            } else if !lab.isRunning(team) {
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
                if let step = lab.running?.progress {
                    Text("\(step.played) of \(step.of) — \(step.wins) won, "
                         + "against \(step.against)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Building the field…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let step = lab.running?.progress {
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

    /// Earlier versions of this team, and whether changing it helped.
    ///
    /// The whole point of simulating a team is to change it and simulate again.
    /// Records used to be dropped the moment the team was edited, which threw
    /// away the one comparison that makes the exercise worth doing.
    @ViewBuilder private func versions() -> some View {
        let past = store.history(for: team)
        if !past.isEmpty {
            let now = store.measured(for: team)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "What changing it did",
                                  subtitle: "Earlier versions of this team, newest first, "
                                          + "with what changed after each one. The comparison "
                                          + "is the reason to keep them.")
                    if let now {
                        versionRow(label: "now", rate: now.winRate, games: now.games,
                                   against: nil, changed: [])
                    }
                    ForEach(Array(past.enumerated()), id: \.offset) { _, older in
                        versionRow(label: shortDate(older.entry.ran),
                                   rate: older.entry.report.winRate,
                                   games: older.entry.report.games,
                                   against: now?.winRate,
                                   changed: older.changed)
                    }
                }
            }
        }
    }

    private func shortDate(_ date: Date) -> String {
        let out = DateFormatter()
        out.dateFormat = "d MMM"
        return out.string(from: date)
    }

    private func versionRow(label: String, rate: Double, games: Int,
                            against: Double?, changed: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 11, weight: .semibold))
                    .frame(width: 54, alignment: .leading)
                Text(String(format: "%.1f%%", rate * 100))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(width: 52, alignment: .trailing)
                Text("of \(games)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 58, alignment: .trailing)
                if let against {
                    let delta = (against - rate) * 100
                    Text(String(format: "%+.1f since", delta))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(delta >= 0 ? Palette.good : Palette.bad)
                }
                Spacer(minLength: 0)
            }
            if !changed.isEmpty {
                Text("then you " + changed.prefix(3).joined(separator: ", ")
                     + (changed.count > 3 ? " and \(changed.count - 3) more" : ""))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.leading, 54)
            }
        }
    }

    /// The same Pokémon, pooled over every team of yours that has been run.
    ///
    /// A per-team report cannot see this. A Pokémon can look like an unlucky
    /// passenger on one team and be a genuine problem on four — and the second
    /// is a fact about the Pokémon rather than about any of the teams, which
    /// calls for something different to be done about it.
    @ViewBuilder private func acrossTeams() -> some View {
        let roster = store.roster.filter { $0.teams.count > 1 }
        if !roster.isEmpty {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        title: "Across your teams",
                        subtitle: "Pokémon on more than one team you have simulated, pooled. "
                                + "Worst trade first — this is where a Pokémon that is quietly "
                                + "costing you games on several teams at once shows up.")
                    ForEach(roster) { entry in
                        HStack(spacing: 10) {
                            Text(entry.form).font(.system(size: 12))
                                .frame(width: 150, alignment: .leading).lineLimit(1)
                            Text("\(entry.teams.count) teams")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .trailing)
                            Text("\(entry.record.knockouts) : \(entry.record.faints)")
                                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                                .frame(width: 84, alignment: .trailing)
                            Text(String(format: "%.2f", entry.trade))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(entry.trade >= 1 ? Palette.good
                                                 : entry.trade >= 0.7 ? Palette.warn : Palette.bad)
                                .frame(width: 44, alignment: .trailing)
                            Text(entry.netDamage >= 0
                                 ? "+\(entry.netDamage)" : "\(entry.netDamage)")
                                .font(.system(size: 10, design: .rounded)).monospacedDigit()
                                .foregroundStyle(entry.netDamage >= 0 ? .secondary : Palette.bad)
                                .frame(width: 76, alignment: .trailing)
                            Spacer(minLength: 0)
                        }
                        .help("\(entry.form) on: \(entry.teams.joined(separator: ", "))")
                    }
                    Text("Damage dealt less damage taken, across every game.")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
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
