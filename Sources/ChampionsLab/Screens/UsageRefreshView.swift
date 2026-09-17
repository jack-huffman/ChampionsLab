//  UsageRefreshView.swift
//  The sheet that pulls a fresh ladder table down, from Smogon's published
//  statistics or from Pikalytics.

import SwiftUI

@MainActor
final class UsageRefreshModel: ObservableObject {
    enum Phase: Equatable {
        case idle, working, finished, failed(String)
    }

    /// Where the table comes from. Smogon is one file with the spreads in
    /// it; Pikalytics is a page a Pokemon, with winrates.
    enum Source: String, CaseIterable {
        case smogon, pikalytics
    }
    @Published var source: Source = .smogon
    @Published var format = UsageFeed.formats.first?.id ?? ""
    @Published var customSlug = ""
    @Published var usesCustom = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var current = ""
    @Published private(set) var result: UsageFeed.Snapshot?
    @Published private(set) var saveWarning: String?

    private var task: Task<Void, Never>?

    var slug: String {
        usesCustom ? customSlug.trimmingCharacters(in: .whitespaces) : format
    }
    /// The formats a source publishes. Smogon has the Showdown ladders;
    /// Pikalytics adds its own in-game and tournament tables.
    var formats: [UsageFeed.FormatChoice] {
        source == .smogon ? UsageFeed.formats.filter { $0.id.hasPrefix("gen9champions") }
                          : UsageFeed.formats
    }
    func choose(_ newSource: Source) {
        source = newSource
        if !usesCustom, !formats.contains(where: { $0.id == format }) {
            format = formats.first?.id ?? ""
        }
    }

    var isWorking: Bool { phase == .working }

    var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    func start(store: Store) {
        guard !slug.isEmpty, !isWorking else { return }
        let index = store.usageIndex()
        let target = slug
        phase = .working
        done = 0
        total = 0
        current = ""
        result = nil
        saveWarning = nil

        let from = source
        task = Task { [weak self] in
            do {
                let tell: @MainActor @Sendable (Int, Int, String) -> Void = { done, total, name in
                    guard let self else { return }
                    self.done = done
                    self.total = total
                    self.current = name
                }
                let snapshot = from == .smogon
                    ? try await SmogonFeed.refresh(format: target, index: index, progress: tell)
                    : try await UsageFeed.refresh(format: target, index: index, progress: tell)
                guard !Task.isCancelled else { return }
                store.apply(snapshot)
                do {
                    try UsageFeed.save(snapshot)
                } catch {
                    // The table is live in memory either way; say that it will
                    // not survive a relaunch rather than failing the refresh.
                    self?.saveWarning = "Fetched, but could not be written to disk: \(error.localizedDescription)"
                }
                self?.result = snapshot
                self?.phase = .finished
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}

struct UsageRefreshSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = UsageRefreshModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourcePicker
                    formatPicker
                    scopeNote
                    switch model.phase {
                    case .idle:      EmptyView()
                    case .working:   progressCard
                    case .finished:  if let result = model.result { summary(result) }
                    case .failed(let message): failure(message)
                    }
                    if let warning = model.saveWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Refresh usage data")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(model.source == .smogon
                 ? "Pulls the latest month of Smogon's published ladder statistics: usage, and the share of sets running each move, item, ability and Stat Point spread. The teams built from the table are what the lobby plays against."
                 : "Pulls the measured ladder table from Pikalytics: usage, winrate, and the share of sets running each move, item and ability.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Source")
            row(selected: model.source == .smogon, title: "Smogon usage statistics",
                detail: "One file a month, with the Stat Point spreads actually run. Seconds.") {
                model.choose(.smogon)
            }
            row(selected: model.source == .pikalytics, title: "Pikalytics",
                detail: "A page per Pokemon, with winrates and in-game ranked data. A few minutes.") {
                model.choose(.pikalytics)
            }
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Format")
            ForEach(model.formats) { choice in
                row(selected: !model.usesCustom && model.format == choice.id,
                    title: choice.name, detail: choice.detail) {
                    model.usesCustom = false
                    model.format = choice.id
                }
            }
            row(selected: model.usesCustom, title: "Another format",
                detail: model.source == .smogon ? "Type the Showdown format id, as Smogon's file is named"
                                                : "Type the slug from the Pikalytics URL") {
                model.usesCustom = true
            }
            if model.usesCustom {
                TextField("gen9championsvgc2026regmd", text: $model.customSlug)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.leading, 24)
            }
        }
    }

    private func row(selected: Bool, title: String, detail: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Palette.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    /// Being explicit about what a refresh does *not* cover — the dex is a
    /// separate, much heavier scrape.
    private var scopeNote: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What this updates")
                    .font(.system(size: 11, weight: .semibold))
                Text("The usage table only: rankings, winrates, common moves, items, abilities and teammates. Pokémon, learnsets, abilities and items come from Serebii and stay a build-time job — run ./mkdata.py for those.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text((model.source == .smogon ? SmogonFeed.credit + "." : "Data from Pikalytics, \(UsageFeed.license).")
                     + " Every fetched reference is checked against the bundled dex and dropped if the Pokémon cannot legally do it.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.fraction)
                HStack {
                    Text(model.current).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if model.total > 0 {
                        Text("\(model.done)/\(model.total)")
                            .font(.system(size: 11, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func summary(_ snapshot: UsageFeed.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(snapshot.entries.count) Pokémon updated",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.good)
                    ForEach(snapshot.entries.prefix(6)) { entry in
                        HStack(spacing: 8) {
                            if let form = store.form(named: entry.name) {
                                SpriteImage(form: form, side: 24)
                            }
                            Text(entry.name).font(.system(size: 11))
                            Spacer()
                            Text(String(format: "%.1f%%", entry.usage))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    if snapshot.entries.count > 6 {
                        Text("…and \(snapshot.entries.count - 6) more")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            if !snapshot.dropped.isEmpty {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(snapshot.dropped.count) reference\(snapshot.dropped.count == 1 ? "" : "s") discarded")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.warn)
                        ForEach(snapshot.dropped.prefix(8), id: \.self) { line in
                            Text("· " + line).font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if snapshot.dropped.count > 8 {
                            Text("…and \(snapshot.dropped.count - 8) more")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Refresh failed", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.bad)
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The previous table is still in place — nothing was overwritten.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.liveUsage != nil {
                Button("Use bundled data") {
                    store.revertToBundledUsage()
                    dismiss()
                }
                .controlSize(.small)
            }
            Spacer()
            if model.isWorking {
                Button("Stop") { model.cancel() }
            } else {
                Button(model.phase == .finished ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fetch") { model.start(store: store) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.slug.isEmpty)
            }
        }
        .padding(14)
    }
}
