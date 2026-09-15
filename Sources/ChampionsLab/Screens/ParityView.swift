//  ParityView.swift
//  Checking the battle model against the dex, live, from inside the app.
//
//  The point of this screen is to be able to answer "does the simulator
//  actually know what Rocky Helmet does" without reading any source. It plays
//  every move, tries every ability and holds every item on a fixed pair of
//  boards, and reports only what it could prove by watching the game come out
//  differently. Nothing here is a lookup table that could fall out of date:
//  the answer is produced by the same engine that runs battles.

import SwiftUI

// MARK: - Model

@MainActor
final class ParityModel: ObservableObject {
    enum Phase: Equatable { case idle, working, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step: ParityAudit.Progress?
    @Published private(set) var report: ParityAudit.Report?
    /// Set when the audit's own control fails. When a name the model has never
    /// heard of still changes the game, every number the run would print is
    /// meaningless, so the screen says so instead of showing them.
    @Published private(set) var controlFailure: String?

    /// Nonisolated so `deinit` can reach it. Only the main actor ever writes
    /// it, and by the time deinit runs nothing else holds a reference.
    nonisolated(unsafe) private var task: Task<Void, Never>?

    var isWorking: Bool { phase == .working }

    func run(store: Store) {
        guard !isWorking else { return }
        phase = .working
        step = nil
        report = nil
        controlFailure = nil

        let rules = store.rulebook
        let usage = store.data.usage
        let items = store.data.items

        // Detached on purpose, and held on to, so Stop actually stops it. The
        // audit plays a few hundred thousand turns; a cancel that only hid the
        // progress bar would leave every core busy for another minute.
        task = Task.detached(priority: .utility) { [weak self] in
            // The control first and alone. It is fast, and if it fails there is
            // no point spending a minute on numbers built on top of it.
            if let failure = ParityAudit.controlFailure(rules: rules) {
                await MainActor.run {
                    self?.controlFailure = failure
                    self?.phase = .finished
                }
                return
            }
            guard !Task.isCancelled else { return }

            let report = ParityAudit.full(rules: rules, usage: usage, items: items) { step in
                Task { @MainActor in self?.step = step }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finish(report) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        step = nil
    }

    /// Leaving the screen stops the work.
    ///
    /// Without this the audit carried on after the view was gone: a quarter of
    /// a million turns, a minute and a half of saturated cores, with the Stop
    /// button no longer on screen and nothing to say it was still going. The
    /// app just felt stuttery for no visible reason.
    deinit { task?.cancel() }

    /// Put a finished report on screen without running one, so the snapshot
    /// tool can check the results layout without spending a minute on it.
    func show(_ report: ParityAudit.Report) {
        self.report = report
        self.phase = .finished
    }

    private func finish(_ report: ParityAudit.Report) {
        self.report = report
        self.phase = .finished
    }
}

// MARK: - Screen

struct ParityView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = ParityModel()
    @State private var kind: ParityAudit.Finding.Kind = .move
    @State private var onlyGaps = true
    @State private var search = ""
    @Environment(\.snapshotMode) private var snapshotMode
    /// Only the snapshot tool passes this, to render the results state.
    var preloaded: ParityAudit.Report? = nil

    // ImageRenderer lays out a plain stack but produces an empty image for a
    // ScrollView, so the snapshot tool gets the content without one.
    @ViewBuilder var body: some View {
        if snapshotMode { seeded } else {
            ScrollView { content }
                .background(Palette.canvas)
                .onDisappear { model.cancel() }
        }
    }

    private var seeded: some View {
        content.onAppear { if let preloaded { model.show(preloaded) } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch model.phase {
            case .idle:     intro
            case .working:  running
            case .finished:
                if let failure = model.controlFailure { controlFailed(failure) }
                else if let report = model.report { results(report) }
            }
        }
        .padding(24)
        .frame(maxWidth: 1080, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(Palette.canvas)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parity Check")
                .font(.system(size: 26, weight: .semibold))
            Text("Play every move, try every ability and hold every item against the "
                 + "battle model, and report only what can be proved by watching the "
                 + "game come out differently.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Idle

    private var intro: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(passes.enumerated()), id: \.offset) { index, pass in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(width: 22, height: 22)
                            .background(Palette.accent.opacity(0.15))
                            .foregroundStyle(Palette.accent)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pass.0).font(.system(size: 13, weight: .semibold))
                            Text(pass.1)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button { model.run(store: store) } label: {
                        Label("Run the check", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Text("About a minute. Nothing is written or sent anywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.fainter)
                }
            }
        }
    }

    private var passes: [(String, String)] {
        [("A control, first",
          "A made-up ability and a made-up item are tried before anything else. "
          + "If the model reacts to a name that does not exist, the battery is "
          + "finding differences that are not there and the run stops."),
         ("Every move",
          "Each move is used, then the identical turn is played without it. "
          + "Anything the move did is the difference between the two boards, and "
          + "nothing the other side did can be mistaken for it."),
         ("Every ability",
          "Every weather, every terrain, an attack of each type in both "
          + "directions, and a provocation from the other side — a stat drop, a "
          + "burn, a flinch, a confusion — each played twice, once with the "
          + "ability and once with none."),
         ("Every item",
          "The same turns again, holding the item and holding nothing, "
          + "including a position where it has already been used up.")]
    }

    // MARK: Working

    private var running: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.step?.phase ?? "Setting up")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(percentText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.dim)
                        .monospacedDigit()
                }
                ProgressView(value: model.step?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)

                if let note = model.step?.note, !note.isEmpty {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        Text(note)
                            .font(.system(size: 13, weight: .medium))
                            .contentTransition(.identity)
                        Spacer()
                    }
                }
                if let explains = model.step?.explains, !explains.isEmpty {
                    Text(explains)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack(spacing: 12) {
                    Button("Stop") { model.cancel() }
                        .buttonStyle(.bordered)
                    Text("Leaving this screen stops the check.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.fainter)
                }
            }
        }
    }

    private var percentText: String {
        guard let step = model.step, step.total > 0 else { return "" }
        return "\(Int(step.fraction * 100))%"
    }

    // MARK: Control failure

    private func controlFailed(_ failure: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("The control failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.bad)
                Text(failure)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Text("A name the model has never heard of still changed the game, so the "
                     + "battery is seeing differences that are not there. Every number a "
                     + "run produced now would be meaningless, so none are shown.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { model.run(store: store) }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Results

    private func results(_ report: ParityAudit.Report) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            scoreboard(report)
            controls
            findings(report)
        }
    }

    private func scoreboard(_ report: ParityAudit.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                      spacing: 14) {
                ForEach(ParityAudit.Finding.Kind.allCases, id: \.self) { kind in
                    scoreCard(kind, report)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.good)
                Text("The control passed: a made-up ability and a made-up item both "
                     + "read as no effect.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text(String(format: "%.0fs", report.seconds))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.fainter)
                    .monospacedDigit()
            }
        }
    }

    private func scoreCard(_ kind: ParityAudit.Finding.Kind, _ report: ParityAudit.Report) -> some View {
        // Two numbers, answering two questions. The big one is coverage of
        // what people actually bring, which is what decides whether the
        // simulator can be trusted. The small one counts the whole legal dex,
        // most of which belongs to Pokémon nobody plays.
        let all = report.of(kind)
        let played = kind == .item ? all : all.filter { $0.usage > 0 }
        let covered = played.filter { $0.verdict.isCovered || $0.verdict == .notModelled }.count
        let share = played.isEmpty ? 0 : Int(Double(covered) / Double(played.count) * 100)
        let allCovered = all.filter { $0.verdict.isCovered || $0.verdict == .notModelled }.count
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kind.plural.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.dim)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(share)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.grade(share))
                        .monospacedDigit()
                    Text("of what is played")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
                Text("\(covered) of \(played.count) carried by something people bring")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                Text("\(allCovered) of \(all.count) across the whole legal dex")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fainter)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $kind) {
                ForEach(ParityAudit.Finding.Kind.allCases, id: \.self) {
                    Text($0.plural.capitalized).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Toggle("Only what is unproven", isOn: $onlyGaps)
                .toggleStyle(.switch)
                .font(.system(size: 12))

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fainter)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 150)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Button { model.run(store: store) } label: {
                Label("Run again", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
    }

    private func findings(_ report: ParityAudit.Report) -> some View {
        let rows = report.of(kind)
            // Out of scope is a decision that has already been made, not
            // something to go and look at, so it stays out of this list.
            .filter { !onlyGaps || $0.verdict == .noEffect }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Card {
                    Text(onlyGaps
                         ? "Nothing unproven here. Every \(kind.rawValue) the battery tried "
                           + "either changed the game in a way it could measure, or parses "
                           + "into a rule the model applies."
                         : "No \(kind.plural) match that search.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.dim)
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Divider().opacity(0.5) }
                            FindingRow(finding: finding)
                        }
                    }
                }
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fainter)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        "\"Not proven\" means the battery could not make it matter, which is where to "
        + "look — it is not proof that the rule is missing. Something that only shows "
        + "up in a position the battery does not set up will read this way."
    }
}

// MARK: - One finding

private struct FindingRow: View {
    let finding: ParityAudit.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VerdictBadge(verdict: finding.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name)
                    .font(.system(size: 13, weight: .medium))
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if finding.usage > 0 {
                Text(String(format: "%.1f%%", finding.usage))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.fainter)
                    .monospacedDigit()
                    .help("Seen on \(String(format: "%.1f", finding.usage))% of teams")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct VerdictBadge: View {
    let verdict: ParityAudit.Finding.Verdict

    var body: some View {
        Text(verdict.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(width: 84, alignment: .leading)
    }

    private var tint: Color {
        switch verdict {
        case .implemented: return Palette.good
        case .byRule:      return Palette.accent
        case .noEffect:    return Palette.warn
        case .notModelled: return Palette.dim
        }
    }
}
