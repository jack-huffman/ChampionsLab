//  MetaView.swift
//  Usage rankings and the builds that go with them.

import SwiftUI

struct MetaView: View {
    @EnvironmentObject private var store: Store
    @State private var format = "doubles"
    @State private var showProjected = true
    @State private var selection: String?

    private var entries: [UsageEntry] {
        store.data.usage
            .filter { $0.formats.contains(format) }
            .filter { showProjected || !$0.isProjected }
            .sorted { lhs, rhs in
                // Measured usage first, then the projected M-C arrivals by tier.
                if lhs.isProjected != rhs.isProjected { return !lhs.isProjected }
                if lhs.isProjected { return tierRank(lhs.tier) < tierRank(rhs.tier) }
                return lhs.usage > rhs.usage
            }
    }

    private func tierRank(_ tier: String) -> Int {
        ["S": 0, "A": 1, "B": 2, "C": 3][tier] ?? 4
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                controls
                Divider()
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            UsageRow(entry: entry, rank: (entries.firstIndex(of: entry) ?? 0) + 1,
                                     isSelected: selection == entry.name)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = entry.name }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 420, idealWidth: 500)

            Group {
                if let selection, let entry = store.data.usage.first(where: { $0.name == selection }) {
                    UsageDetail(entry: entry)
                } else {
                    EmptyHint(symbol: "chart.bar.xaxis", title: "Select a threat",
                              detail: "Measured figures are the last full Regulation M-A/M-B numbers. M-C entries are projections until the ladder settles.")
                }
            }
            .frame(minWidth: 400)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $format) {
                ForEach(store.data.rules.formats) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Toggle("Include M-C projections", isOn: $showProjected)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                Text("\(entries.count) tracked")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            Text("Regulation M-C opened \(store.data.regulation.start), so it has no usage history of its own yet. Percentages below are the last measured figures; rows marked “projected” are placed by their stats and abilities.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }
}

private struct UsageRow: View {
    @EnvironmentObject private var store: Store
    let entry: UsageEntry
    let rank: Int
    let isSelected: Bool

    var body: some View {
        let form = store.form(named: entry.name)
        return HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)

            if let form {
                SpriteImage(form: form, side: 36)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .frame(width: 36, height: 36).foregroundStyle(.quaternary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.name).font(.system(size: 13, weight: .medium))
                    TierBadge(tier: entry.tier)
                }
                Text(entry.role).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            if entry.isProjected {
                Text("projected")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.warn.opacity(0.18))
                    .foregroundStyle(Palette.warn)
                    .clipShape(Capsule())
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", entry.usage))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    GeometryReader { geo in
                        Capsule()
                            .fill(Palette.tier(entry.tier))
                            .frame(width: geo.size.width * min(1, entry.usage / 55))
                    }
                    .frame(width: 70, height: 4)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isSelected ? Palette.accent.opacity(0.16) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

private struct UsageDetail: View {
    @EnvironmentObject private var store: Store
    let entry: UsageEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let form = store.form(named: entry.name)

                Card {
                    HStack(alignment: .top, spacing: 14) {
                        if let form { SpriteImage(form: form, side: 72) }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(entry.name)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                TierBadge(tier: entry.tier)
                            }
                            if let form {
                                HStack(spacing: 4) {
                                    ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                                }
                            }
                            Text(entry.role).font(.system(size: 12)).foregroundStyle(.secondary)
                            if entry.isProjected {
                                Label("Projected placement — no M-C ladder data yet",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.warn)
                            } else {
                                Text(String(format: "%.1f%% usage", entry.usage))
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                            }
                        }
                        Spacer()
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Why it matters")
                        Text(entry.why)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Common build")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Items").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(entry.commonItems, id: \.self) { name in
                                HStack(spacing: 6) {
                                    ItemIcon(name: name, side: 20)
                                    Text(name).font(.system(size: 12))
                                    if let item = store.item(named: name) {
                                        Text(item.blurb)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Moves").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(entry.keyMoves, id: \.self) { name in
                                if let move = store.data.moves.values.first(where: { $0.name == name }) {
                                    MoveRow(move: move)
                                } else {
                                    Text(name).font(.system(size: 12))
                                }
                            }
                        }
                    }
                }

                if let form {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Stats")
                            ForEach(Stat.allCases) { stat in
                                StatBar(stat: stat, base: form.stats[stat.rawValue],
                                        computed: ChampionsStats.maxValue(
                                            base: form.stats[stat.rawValue],
                                            stat: stat, boosting: true))
                            }
                        }
                    }
                } else {
                    Card {
                        Text("\(entry.name) is part of Regulation M-C but has not appeared in Serebii's Champions dex yet, so there are no stats to show. Re-run mkdata.py once it lands.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
    }
}
