//  TreeView.swift
//  One matchup, and every decision you could make in it.
//
//  The Simulate tab answers "how does this team do" by playing a few thousand
//  games and averaging them. This answers the question an average cannot be
//  asked, because an average has already thrown the decisions away: in this
//  exact matchup, with these two leads, which of my plays win?
//
//  See MatchupTree.swift for why it branches one side and not the other, and
//  for the honest account of what a line's number means. The short version is
//  that the tree shortlists and the playouts measure, and the screen is laid
//  out in that order on purpose: the measured openings come first because they
//  are the part you can rely on.

import SwiftUI

struct TreeView: View {
    let team: Team
    /// A finished walk handed in, so a shot can show the findings without
    /// spending a minute searching for them.
    var seeded: MatchupTree.Report?
    /// The opponent, when the screen around this one already asked for it.
    ///
    /// Versus and Lines were two tabs that each began by asking who you were
    /// playing, which is one question. The answer now comes from above and this
    /// keeps its own picker only for standing alone.
    var against: Team?
    @EnvironmentObject private var store: Store
    @StateObject private var model = TreeModel()

    @State private var opponent = ""
    @State private var myLead: [String] = []
    @State private var theirLead: [String] = []
    @State private var depth = 3
    @State private var playouts = 20
    @Environment(\.snapshotMode) private var snapshotMode

    private var report: MatchupTree.Report? { seeded ?? model.report }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            leads
            Divider()
            if snapshotMode { content } else { ScrollView { content } }
        }
        .onDisappear { model.stop() }
        .onAppear {
            if against == nil, opponent.isEmpty {
                opponent = store.data.metaTeams.first?.name ?? ""
            }
        }
    }

    // MARK: - Setting it going

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if against == nil {
                    Picker("Against", selection: $opponent) {
                        ForEach(store.data.metaTeams.map(\.name).sorted(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .frame(width: 230).labelsHidden().controlSize(.small)
                    .disabled(model.running)
                }

                Picker("Depth", selection: $depth) {
                    Text("2 turns — seconds").tag(2)
                    Text("3 turns — about a minute").tag(3)
                    Text("4 turns — several minutes").tag(4)
                }
                .frame(width: 210).labelsHidden().controlSize(.small)
                .disabled(model.running)

                Picker("Measure", selection: $playouts) {
                    Text("No playouts — tree only").tag(0)
                    Text("20 games an opening").tag(20)
                    Text("60 games an opening").tag(60)
                }
                .frame(width: 210).labelsHidden().controlSize(.small)
                .disabled(model.running)

                if model.running {
                    Button("Stop") { model.stop() }.controlSize(.small)
                } else {
                    Button(report == nil ? "Walk it" : "Walk it again") { start() }
                        .controlSize(.small)
                        .disabled(team.slots.count < 2 || theirTeam == nil)
                }
                Spacer(minLength: 0)
                if model.running {
                    ProgressView(value: model.fraction).frame(width: 130).controlSize(.small)
                    Text(model.stage).font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if let report {
                    Text(String(format: "%d lines in %.0fs", report.leaves, report.seconds))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text("Every play you could make, three turns deep, with their side answering "
                 + "at equilibrium rather than being enumerated — exhausting both sides is "
                 + "840 positions for one turn, 705,600 for two and 36 hours for three. "
                 + "Turn one is the exception and is complete. Click below to choose each "
                 + "four in the order it is brought; the first two are the lead.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Both fours, chosen by clicking, in the order they will be brought.
    ///
    /// The first two are the lead, because that is how the board reads a team:
    /// slots one and two are the actives and the rest is the bench. So picking
    /// the four and picking the lead are one action, and the numbers on the
    /// chips are the whole of the explanation.
    private var leads: some View {
        HStack(alignment: .top, spacing: 18) {
            leadPicker(title: team.name.isEmpty ? "Yours" : team.name,
                       forms: myForms, chosen: $myLead)
            Spacer(minLength: 0)
            leadPicker(title: against?.name.isEmpty == false ? against!.name : opponent,
                       forms: theirForms, chosen: $theirLead)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var myForms: [String] {
        team.slots.compactMap { $0.battleForm(in: store.rulebook)?.formLabel }
    }

    /// Whoever is on the other side, however it was chosen.
    private var theirTeam: Team? {
        if let against { return against.slots.isEmpty ? nil : against }
        return store.data.metaTeams.first { $0.name == opponent }.map { store.opponentTeam($0) }
    }

    private var theirForms: [String] {
        theirTeam?.slots.compactMap { $0.battleForm(in: store.rulebook)?.formLabel } ?? []
    }

    @ViewBuilder private func leadPicker(title: String, forms: [String],
                                         chosen: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Text(chosen.wrappedValue.isEmpty ? "first four, first two lead"
                                                 : "1 and 2 lead")
                    .font(.system(size: 8)).foregroundStyle(.quaternary)
            }
            HStack(spacing: 5) {
                ForEach(forms, id: \.self) { form in
                    let picked = chosen.wrappedValue.contains(form)
                    let at = chosen.wrappedValue.firstIndex(of: form)
                    Button {
                        var out = chosen.wrappedValue
                        if let at { out.remove(at: at) }
                        else if out.count < 4 { out.append(form) }
                        chosen.wrappedValue = out
                    } label: {
                        HStack(spacing: 4) {
                            if let at {
                                Text("\(at + 1)")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(at < 2 ? Palette.accent : .secondary)
                            }
                            Text(form)
                                .font(.system(size: 10, weight: picked ? .semibold : .regular))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(picked ? Palette.accent.opacity(at.map { $0 < 2 ? 0.22 : 0.10 } ?? 0)
                                         : Palette.surfaceRaised))
                        .foregroundStyle(picked ? Palette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.running)
                }
            }
        }
    }

    private func start() {
        guard let theirTeam else { return }
        model.start(mine: order(team, by: myLead), theirs: order(theirTeam, by: theirLead),
                    rules: store.rulebook, depth: depth, playouts: playouts)
    }

    /// The chosen pair first, then whoever else fits in the four.
    private func order(_ team: Team, by lead: [String]) -> Team {
        var out = team
        func name(_ slot: TeamSlot) -> String {
            slot.battleForm(in: store.rulebook)?.formLabel ?? ""
        }
        var slots: [TeamSlot] = []
        for wanted in lead {
            if let hit = team.slots.first(where: { name($0) == wanted }),
               !slots.contains(where: { $0.id == hit.id }) { slots.append(hit) }
        }
        for slot in team.slots where !slots.contains(where: { $0.id == slot.id }) {
            if slots.count < 4 { slots.append(slot) }
        }
        out.slots = Array(slots.prefix(4))
        return out
    }

    // MARK: - What it found

    @ViewBuilder private var content: some View {
        if let report, report.leaves > 0 {
            VStack(alignment: .leading, spacing: 14) {
                openings(report)
                lines(report)
                pivotal(report)
                matrix(report)
            }
            .padding(16)
        } else if model.running {
            EmptyHint(symbol: "point.3.connected.trianglepath.dotted",
                      title: "Walking the tree",
                      detail: model.stage)
                .frame(height: 320)
        } else {
            EmptyHint(symbol: "point.3.connected.trianglepath.dotted",
                      title: "Pick a lead on each side, then walk it",
                      detail: "Every decision you could make in one matchup, laid out. "
                            + "The openings get played out properly; the deeper lines are "
                            + "a shortlist rather than a forecast.")
                .frame(height: 320)
        }
    }

    /// The measured half, and therefore the half that goes first.
    @ViewBuilder private func openings(_ report: MatchupTree.Report) -> some View {
        if !report.openings.isEmpty {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "The opening, played out",
                                  subtitle: "Each of these commits to turn one and then plays "
                                          + "properly. These are real games, unlike the lines "
                                          + "below, which are the board at a horizon.")
                    if let baseline = report.baseline {
                        HStack(spacing: 8) {
                            Text("playing it straight through")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", baseline * 100))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text("of \(report.baselineGames)")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(.bottom, 2)
                    }
                    ForEach(report.openings) { opening in
                        HStack(spacing: 8) {
                            Text(String(format: "%.0f%%", opening.measured * 100))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 44, alignment: .trailing)
                            if let baseline = report.baseline {
                                let delta = (opening.measured - baseline) * 100
                                Text(String(format: "%+.0f", delta))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(delta >= 0 ? Palette.good : Palette.bad)
                                    .frame(width: 30, alignment: .trailing)
                            }
                            Text(opening.play).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(String(format: "tree said %.0f%%", opening.estimate * 100))
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func lines(_ report: MatchupTree.Report) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "The lines it likes",
                              subtitle: "The board \(report.depth) turns in, which is a horizon "
                                      + "and not a forecast: good for ranking candidates, not "
                                      + "for putting a number on a game.")
                ForEach(report.best) { path in lineRow(path, good: true) }
                Divider().padding(.vertical, 2)
                Text("and the ones it does not")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(report.worst) { path in lineRow(path, good: false) }
            }
        }
    }

    private func lineRow(_ path: MatchupTree.Path, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(format: "%.0f%%", path.estimate * 100))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(good ? Palette.good : Palette.bad)
                .frame(width: 40, alignment: .trailing)
            Text(path.steps.map(\.mine).joined(separator: "  →  "))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Where the game is actually decided.
    @ViewBuilder private func pivotal(_ report: MatchupTree.Report) -> some View {
        let turns = report.pivotal.prefix(5)
        if !turns.isEmpty {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "The turns worth getting right",
                                  subtitle: "How far it is from the best play here down to the "
                                          + "worst. A turn with two points in it can be played "
                                          + "any number of ways; one with twenty cannot.")
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, decision in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("turn \(decision.turn)")
                                    .font(.system(size: 10, weight: .bold))
                                Text(String(format: "%.0f points", decision.swing * 100))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Palette.accent)
                                if !decision.after.isEmpty {
                                    Text("after " + decision.after.joined(separator: ", "))
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            ForEach(Array(decision.options.prefix(3).enumerated()),
                                    id: \.offset) { _, option in
                                optionRow(option, best: true)
                            }
                            if let worst = decision.options.last, decision.options.count > 3 {
                                optionRow(worst, best: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func optionRow(_ option: MatchupTree.Decision.Option, best: Bool) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%.0f%%", option.winChance * 100))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(best ? Palette.good : Palette.bad)
                .frame(width: 38, alignment: .trailing)
            Text(option.play).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }

    /// Turn one, whole — the only turn that gets both sides enumerated.
    @ViewBuilder private func matrix(_ report: MatchupTree.Report) -> some View {
        let columns = report.matrix.theirMix.enumerated()
            .sorted { $0.element > $1.element }.prefix(6).map(\.offset)
        let rows = report.matrix.myMix.enumerated()
            .sorted { $0.element > $1.element }.prefix(10).map(\.offset)
        // The whole grid sits within a point or two of even, because one turn
        // rarely decides a game. Shading it against 0-100 therefore painted
        // forty identical squares. Shading it against its own range is what
        // makes the shape of the turn visible, and the cost of that is that the
        // colour is relative — which the subtitle says.
        let shown = rows.flatMap { row in columns.map { report.matrix.winChance[row][$0] } }
        let low = shown.min() ?? 0, high = shown.max() ?? 1
        if !columns.isEmpty, !rows.isEmpty {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Turn one, in full",
                                  subtitle: "Every one of your \(report.matrix.mine.count) plays "
                                          + "against every one of their "
                                          + "\(report.matrix.theirs.count) answers, the likeliest "
                                          + "of each first. Shaded against the range on show "
                                          + String(format: "(%.0f to %.0f), not against even, ",
                                                   low * 100, high * 100)
                                          + "because one turn rarely moves a game far.")
                    // ImageRenderer cannot materialise a ScrollView's content,
                    // so a shot of this card would otherwise be an empty box.
                    ScrollViewIfNeeded(flat: snapshotMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text("").frame(width: 210, alignment: .leading)
                                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                    Text(short(report.matrix.theirs[column]))
                                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                                        .frame(width: 96, alignment: .leading).lineLimit(3)
                                }
                            }
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 2) {
                                    Text(short(report.matrix.mine[row]))
                                        .font(.system(size: 9)).lineLimit(1)
                                        .frame(width: 210, alignment: .leading)
                                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                        let value = report.matrix.winChance[row][column]
                                        Text(String(format: "%.1f", value * 100))
                                            .font(.system(size: 10, weight: .medium,
                                                          design: .rounded))
                                            .frame(width: 96, height: 18)
                                            .background(RoundedRectangle(cornerRadius: 3)
                                                .fill(cell(value, low: low, high: high)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A horizontal scroller everywhere but in a snapshot.
    private struct ScrollViewIfNeeded<Content: View>: View {
        let flat: Bool
        @ViewBuilder let content: Content
        var body: some View {
            if flat { content } else { ScrollView(.horizontal, showsIndicators: true) { content } }
        }
    }

    private func cell(_ value: Double, low: Double, high: Double) -> Color {
        guard high > low else { return Palette.surfaceRaised }
        let place = (value - low) / (high - low)
        return place >= 0.5 ? Palette.good.opacity((place - 0.5) * 0.7 + 0.06)
                            : Palette.bad.opacity((0.5 - place) * 0.7 + 0.06)
    }

    /// The same play, short enough to be a row label.
    ///
    /// Nearly every line on a Mega team begins "Mega Evolve into Mega Charizard
    /// Y, then", which in a 210-point column is the entire label and tells you
    /// apart from nothing.
    private func short(_ text: String) -> String {
        guard let at = text.range(of: ", then ") else { return text }
        return "(mega) " + text[at.upperBound...]
    }
}

/// The walk, off the main thread, stoppable.
///
/// Deliberately simpler than the simulation's service: a walk is seconds to a
/// few minutes rather than forty, so it does not need to outlive the screen —
/// and work that carries on invisibly after you have left is the thing that
/// made this app feel broken once before.
@MainActor
final class TreeModel: ObservableObject {
    @Published private(set) var report: MatchupTree.Report?
    @Published private(set) var running = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var stage = ""

    nonisolated(unsafe) private var task: Task<Void, Never>?

    func start(mine: Team, theirs: Team, rules: Rulebook, depth: Int, playouts: Int) {
        stop()
        running = true
        fraction = 0
        stage = "searching"
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = MatchupTree.explore(
                mine: mine, theirs: theirs, rules: rules, depth: depth,
                playouts: playouts, replay: 8,
                progress: { step in
                    Task { @MainActor in
                        self?.stage = step.stage
                        self?.fraction = Double(step.nodes) / Double(Swift.max(1, step.of))
                    }
                },
                shouldStop: { Task.isCancelled })
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                if found.leaves > 0 { self.report = found }
                self.running = false
                self.task = nil
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    deinit { task?.cancel() }
}
