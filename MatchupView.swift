//  MatchupView.swift
//  The versus screen: your team against a meta archetype or another saved team.

import SwiftUI

struct MatchupView: View {
    @EnvironmentObject private var store: Store
    let team: Team

    @State private var opponentID: String = ""
    /// Preselect an opponent (used by tools/snapshot.sh).
    var initialOpponent: String? = nil
    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none
    @Environment(\.snapshotMode) private var snapshotMode

    /// Meta archetypes first, then the user's other saved teams.
    private var opponent: Team? {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            return TeamPaste.team(from: meta, store: store)
        }
        if let saved = store.teams.first(where: { $0.id.uuidString == opponentID }) {
            return saved
        }
        return nil
    }

    private var metaNote: MetaTeam? {
        store.data.metaTeams.first { $0.id == opponentID }
    }

    private var matchup: Matchup? {
        guard let opponent, !opponent.slots.isEmpty, !team.slots.isEmpty else { return nil }
        return Matchup(mine: team, theirs: opponent, store: store,
                       field: Field(weather: weather, terrain: terrain,
                                    isDoubles: team.isDoubles))
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            if team.slots.isEmpty {
                EmptyHint(symbol: "person.3", title: "Add Pokémon to your team first")
            } else if let matchup {
                if snapshotMode { content(matchup) } else { ScrollView { content(matchup) } }
            } else {
                EmptyHint(symbol: "arrow.left.arrow.right.square",
                          title: "Choose an opponent",
                          detail: "Compare against a known meta structure, or against another team you have saved.")
            }
        }
        .onAppear {
            if let initialOpponent, opponentID.isEmpty { opponentID = initialOpponent }
        }
    }

    // MARK: Controls

    private var picker: some View {
        HStack(spacing: 12) {
            Text("Versus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: $opponentID) {
                Text("Choose…").tag("")
                SwiftUI.Section("Meta archetypes") {
                    ForEach(store.data.metaTeams.filter { $0.format == team.format }) { meta in
                        Text(meta.projected ? "\(meta.name) (projected)" : meta.name)
                            .tag(meta.id)
                    }
                }
                SwiftUI.Section("My teams") {
                    ForEach(store.teams.filter { $0.id != team.id }) { saved in
                        Text(saved.name).tag(saved.id.uuidString)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 260)
            .controlSize(.small)

            Divider().frame(height: 18)

            Picker("", selection: $weather) {
                ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 110).controlSize(.small)
            Picker("", selection: $terrain) {
                ForEach(Terrain.allCases) { Text($0.rawValue + " Terrain").tag($0) }
            }.labelsHidden().frame(width: 150).controlSize(.small)
            Spacer()
        }
        .padding(12)
    }

    // MARK: Body

    private func content(_ matchup: Matchup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            verdictCard(matchup)
            if let metaNote { provenance(metaNote) }
            gridCard(matchup)
            opposingCard(matchup)
        }
        .padding(20)
    }

    private func verdictCard(_ matchup: Matchup) -> some View {
        let verdict = matchup.verdict
        // Map −100…100 onto a 0…1 arc.
        let fraction = (Double(verdict.score) + 100) / 200
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(Palette.hairline, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(fraction))
                            .stroke(Palette.grade(Int(fraction * 100)),
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(verdict.score > 0 ? "+\(verdict.score)" : "\(verdict.score)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("edge").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 84, height: 84)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(verdict.headline)
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 14) {
                            tally("Winning", verdict.winCount, Palette.good)
                            tally("Losing", verdict.lossCount, Palette.bad)
                            tally("Cells", verdict.totalCells, Palette.dim)
                            tally("You faster", verdict.speedEdge, Palette.accent, suffix: "%")
                        }
                    }
                    Spacer()
                }

                if !verdict.advice.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(verdict.advice, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tally(_ label: String, _ value: Int, _ colour: Color,
                       suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)\(suffix)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(colour)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
        }
    }

    private func provenance(_ meta: MetaTeam) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(meta.archetype)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.18))
                        .foregroundStyle(Palette.accent)
                        .clipShape(Capsule())
                    if meta.projected {
                        Text("projected — no M-C ladder data")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.warn)
                    }
                }
                Text(meta.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Grid

    private func gridCard(_ matchup: Matchup) -> some View {
        let reports = matchup.memberReports
        let opposing = matchup.opposingReports
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "One-on-one grid",
                              subtitle: "Your team down the side, theirs across the top. Speed breaks ties.")
                MaybeHScroll(active: !snapshotMode) {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Color.clear.frame(width: 150, height: 34)
                            ForEach(opposing) { report in
                                VStack(spacing: 1) {
                                    SpriteImage(form: report.form, side: 30)
                                }
                                .frame(width: 62)
                                .help(report.form.formLabel)
                            }
                        }
                        ForEach(reports) { report in
                            HStack(spacing: 3) {
                                HStack(spacing: 6) {
                                    SpriteImage(form: report.form, side: 26)
                                    Text(report.form.formLabel)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)

                                ForEach(report.duels) { duel in
                                    cell(duel)
                                }
                            }
                        }
                    }
                }
                legend
            }
        }
    }

    private func cell(_ duel: Duel) -> some View {
        VStack(spacing: 1) {
            Text(duel.outcome.rawValue)
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%.0f/%.0f", duel.outgoing * 100, duel.incoming * 100))
                .font(.system(size: 9, design: .rounded))
                .monospacedDigit()
                .opacity(0.75)
        }
        .frame(width: 62, height: 34)
        .background(colour(duel.outcome).opacity(duel.outcome == .neutral ? 0.10 : 0.28))
        .foregroundStyle(duel.outcome == .neutral ? Palette.dim : colour(duel.outcome))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .topTrailing) {
            if duel.iAmFaster {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Palette.warn)
                    .padding(2)
            }
        }
        .help("\(duel.mine.formLabel) \(duel.myBestMove) → \(Int(duel.outgoing * 100))%  ·  "
              + "\(duel.theirs.formLabel) \(duel.theirBestMove) → \(Int(duel.incoming * 100))%  ·  "
              + "Speed \(duel.mySpeed) vs \(duel.theirSpeed)")
    }

    private func colour(_ outcome: Duel.Outcome) -> Color {
        switch outcome {
        case .win:      return Palette.good
        case .favoured: return Color(red: 0.55, green: 0.70, blue: 0.35)
        case .neutral:  return Palette.dim
        case .against:  return Palette.warn
        case .loss:     return Palette.bad
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([Duel.Outcome.win, .favoured, .neutral, .against, .loss], id: \.rawValue) { outcome in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colour(outcome).opacity(0.28))
                        .frame(width: 12, height: 12)
                    Text(outcome.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(Palette.warn)
                Text("you outspeed").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("cell shows your % / their %")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Their threats

    private func opposingCard(_ matchup: Matchup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Their team, hardest first",
                              subtitle: "Who you have an answer to, and who you do not.")
                ForEach(matchup.opposingReports) { report in
                    HStack(spacing: 10) {
                        SpriteImage(form: report.form, side: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.form.formLabel)
                                .font(.system(size: 12, weight: .medium))
                            if report.isUnanswered {
                                Text("Nothing on your team beats it")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.bad)
                            } else {
                                Text("Answered by " + report.answeredBy.map(\.formLabel)
                                        .joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.good)
                            }
                            if !report.beats.isEmpty {
                                Text("Beats " + report.beats.map(\.formLabel)
                                        .joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach(report.form.pokeTypes) { TypeChip(type: $0, size: .small) }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let onImport: (Team) -> Void

    @State private var text = ""
    @State private var teamName = ""
    @State private var replicaCode = ""
    @State private var preview: TeamPaste.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import a team").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Paste",
                                          subtitle: "Showdown or Pokepaste text. EVs are converted to Stat Points on the way in.")
                            TextEditor(text: $text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 200)
                                .scrollContentBackground(.hidden)
                                .background(Palette.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            HStack {
                                Button("Paste from clipboard") {
                                    text = NSPasteboard.general.string(forType: .string) ?? text
                                    refresh()
                                }
                                .controlSize(.small)
                                Button("Check") { refresh() }
                                    .controlSize(.small)
                                Spacer()
                            }
                        }
                    }

                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Details")
                            HStack(spacing: 8) {
                                Text("Name").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                TextField("Imported team", text: $teamName)
                                    .textFieldStyle(.roundedBorder).controlSize(.small)
                            }
                            HStack(spacing: 8) {
                                Text("Replica code").font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                TextField("e.g. GESXQDU369", text: $replicaCode)
                                    .textFieldStyle(.roundedBorder).controlSize(.small)
                            }
                            Text("Champions' Replica Team codes are resolved by the game's servers, so the app cannot expand one into a team. Paste the list above and keep the code here as a label.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let preview {
                        Card(padding: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: "Preview",
                                              subtitle: "\(preview.team.slots.count) Pokémon")
                                ForEach(preview.team.slots) { slot in
                                    if let form = slot.form(in: store) {
                                        HStack(spacing: 8) {
                                            SpriteImage(form: form, side: 30)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(form.formLabel)
                                                    .font(.system(size: 12, weight: .medium))
                                                Text("\(slot.ability) · \(slot.item.isEmpty ? "no item" : slot.item) · \(slot.alignmentName) · \(slot.spUsed) SP")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                if !preview.warnings.isEmpty {
                                    Divider()
                                    ForEach(preview.warnings, id: \.self) { warning in
                                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.warn)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            HStack {
                Spacer()
                Button("Import") {
                    guard var team = preview?.team else { return }
                    if !teamName.isEmpty { team.name = teamName }
                    team.replicaCode = replicaCode
                    onImport(team)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((preview?.team.slots.isEmpty ?? true))
            }
            .padding(14)
        }
        .frame(width: 620, height: 680)
        .onChange(of: text) { _ in refresh() }
    }

    private func refresh() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = nil
            return
        }
        preview = TeamPaste.parse(text, store: store,
                                  name: teamName.isEmpty ? nil : teamName)
    }
}
