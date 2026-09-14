//  OverviewView.swift
//  The M-C briefing: what changed, and what it means for team building.

import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: Store

    private var regulation: Regulation { store.data.regulation }

    @Environment(\.snapshotMode) private var snapshotMode

    @ViewBuilder var body: some View {
        if snapshotMode { content } else { ScrollView { content } }
    }

    /// Split out from `body` so tools/snapshot.sh can render it: ImageRenderer
    /// lays out a plain stack but produces an empty image for a ScrollView.
    var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            newMegas
            newItems
            metaThreads
            antiMeta
            sources
        }
        .padding(24)
    }

    // MARK: Header

    private var header: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(regulation.name)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(store.data.notes.headline)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NewBadge(text: "LIVE")
                }

                Divider()

                HStack(alignment: .top, spacing: 28) {
                    stat("Runs", "\(regulation.start) → \(regulation.end)")
                    stat("New Pokémon", "\(regulation.newPokemon.count)")
                    stat("New Megas", "\(regulation.newMegas.count)")
                    stat("New items", "\(store.data.items.filter(\.addedInMC).count)")
                }

                Text(store.data.rules.gimmick)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                if !regulation.events.isEmpty {
                    Text("Used at: " + regulation.events.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
    }

    // MARK: New Megas

    private var newMegas: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "The six new Mega Evolutions",
                          subtitle: "Every one of these resets a speed tier or a defensive assumption.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                ForEach(store.newMegas) { form in
                    megaCard(form)
                }
            }
        }
    }

    private func megaCard(_ form: Form) -> some View {
        let usage = store.data.usage.first { $0.name == form.formLabel }
        return Card(padding: 14, height: 268) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SpriteImage(form: form, side: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(form.formLabel)
                                .font(.system(size: 14, weight: .semibold))
                            if let usage { TierBadge(tier: usage.tier) }
                        }
                        HStack(spacing: 4) {
                            ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                        }
                        Text("\(form.bst) BST")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                if let ability = form.abilities.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ability.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text(ability.desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: 3) {
                    ForEach(Stat.allCases) { stat in
                        VStack(spacing: 2) {
                            Text(stat.short)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text("\(form.stats[stat.rawValue])")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                if let usage {
                    Text(usage.why)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: New items

    private var newItems: some View {
        let items = store.data.items.filter(\.addedInMC)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "The twelve new held items",
                          subtitle: "Five of them are terrain pieces, which is the clearest signal about where M-C is going.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    Card(padding: 12, height: 122) {
                        HStack(alignment: .top, spacing: 10) {
                            ItemIcon(name: item.name, side: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    NewBadge()
                                }
                                Text(item.blurb)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let note = item.note, !note.isEmpty {
                                    Text(note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.accent)
                                        .lineLimit(3)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .help(item.effect + (item.note.map { "\n\n" + $0 } ?? ""))
                }
            }
        }
    }

    // MARK: Analysis

    private var metaThreads: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "What actually changed",
                          subtitle: "Read these before you build.")
            ForEach(store.data.notes.threads) { thread in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thread.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(thread.body)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var antiMeta: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Anti-meta angles",
                          subtitle: "Concrete lines of attack against the projected field.")
            ForEach(store.data.notes.antiMeta) { thread in
                Card(padding: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "target")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(thread.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(thread.body)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var sources: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where this comes from")
                    .font(.system(size: 12, weight: .semibold))
                Text("Roster, stats, abilities, moves and items are scraped from Serebii's Champions Pokédex and Attackdex by mkdata.py. Usage figures are the last measured Regulation M-A/M-B numbers; M-C entries marked “projected” are an argument from the new Pokémon's stats and abilities, not ladder data — M-C only opened on \(store.data.regulation.start).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Usage figures come from Pikalytics (CC BY-NC 4.0), refreshed by mkusage.py.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(store.data.sources, id: \.self) { source in
                    Text(source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
