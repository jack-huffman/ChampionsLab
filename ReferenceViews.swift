//  ReferenceViews.swift
//  The straight reference tables: every move, item and ability in the format.

import SwiftUI

// MARK: - Moves

struct MoveDexView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var typeFilter: PokeType?
    @State private var categoryFilter = "All"
    @State private var spreadOnly = false
    @State private var priorityOnly = false
    @State private var learnableOnly = true
    @State private var sort = "Name"

    private var moves: [Move] {
        var all = Array(store.data.moves.values)
        if learnableOnly { all = all.filter(\.learnable) }
        if !query.isEmpty {
            let needle = query.lowercased()
            all = all.filter {
                $0.name.lowercased().contains(needle) || $0.effect.lowercased().contains(needle)
            }
        }
        if let typeFilter { all = all.filter { $0.type == typeFilter.rawValue } }
        if categoryFilter != "All" { all = all.filter { $0.category == categoryFilter } }
        if spreadOnly { all = all.filter(\.isSpread) }
        if priorityOnly { all = all.filter { $0.priority != 0 } }

        switch sort {
        case "Power":    all.sort { $0.power > $1.power }
        case "Priority": all.sort { $0.priority > $1.priority }
        case "Accuracy": all.sort { $0.accuracy > $1.accuracy }
        default:         all.sort { $0.name < $1.name }
        }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Move name or effect", text: $query).textFieldStyle(.plain)
                    Spacer()
                    Picker("", selection: $sort) {
                        ForEach(["Name", "Power", "Priority", "Accuracy"], id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 100).controlSize(.small)
                }
                .padding(8)
                .background(Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Picker("", selection: $categoryFilter) {
                        ForEach(["All", "Physical", "Special", "Other"], id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 110).controlSize(.small)
                    Toggle("Spread", isOn: $spreadOnly).toggleStyle(.button).controlSize(.small)
                    Toggle("Priority", isOn: $priorityOnly).toggleStyle(.button).controlSize(.small)
                    Toggle("Learnable only", isOn: $learnableOnly).toggleStyle(.button).controlSize(.small)
                    Spacer()
                    Text("\(moves.count) moves").font(.system(size: 11)).foregroundStyle(.tertiary)
                }

                HStack(spacing: 3) {
                    ForEach(PokeType.allCases) { type in
                        Button { typeFilter = typeFilter == type ? nil : type } label: {
                            TypeIcon(type: type, side: 19)
                                .opacity(typeFilter == nil || typeFilter == type ? 1 : 0.3)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(12)

            MoveTableHeader()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(moves) { move in
                        VStack(alignment: .leading, spacing: 3) {
                            MoveRow(move: move)
                            if !move.effect.isEmpty {
                                Text(move.effect)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

// MARK: - Items

struct ItemDexView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var newOnly = false

    private var items: [Item] {
        var all = store.data.items
        if newOnly { all = all.filter(\.addedInMC) }
        if !query.isEmpty {
            let needle = query.lowercased()
            all = all.filter {
                $0.name.lowercased().contains(needle) || $0.effect.lowercased().contains(needle)
            }
        }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Item name or effect", text: $query).textFieldStyle(.plain)
                Toggle("New in M-C", isOn: $newOnly).toggleStyle(.button).controlSize(.small)
                Text("\(items.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        Card(padding: 12, height: 150) {
                            HStack(alignment: .top, spacing: 10) {
                                ItemIcon(name: item.name, side: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(item.name).font(.system(size: 13, weight: .semibold))
                                        if item.addedInMC { NewBadge() }
                                    }
                                    Text(item.effect)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                    if let note = item.note, !note.isEmpty {
                                        Text(note)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.accent)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if item.fling > 0 {
                                        Text("Fling \(item.fling) BP")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .help(item.effect)
                    }
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Abilities

struct AbilityDexView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var selection: String?

    private var abilities: [AbilityEntry] {
        let all = store.data.abilities.values.sorted { $0.name < $1.name }
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.desc.lowercased().contains(needle)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Ability or effect", text: $query).textFieldStyle(.plain)
                    Text("\(abilities.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(12)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(abilities) { ability in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ability.name).font(.system(size: 12, weight: .medium))
                                Text("\(ability.users.count) Pokémon")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(selection == ability.name
                                        ? Palette.accent.opacity(0.16) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = ability.name }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            Group {
                if let selection, let ability = store.data.abilities[selection] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ability.name)
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                    Text(ability.desc.isEmpty ? "No description recorded." : ability.desc)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    SectionHeader(title: "Available to",
                                                  subtitle: "\(ability.users.count) legal forms")
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150),
                                                                 spacing: 6)], spacing: 6) {
                                        ForEach(ability.users, id: \.self) { name in
                                            HStack(spacing: 6) {
                                                if let form = store.form(named: name) {
                                                    SpriteImage(form: form, side: 24)
                                                }
                                                Text(name).font(.system(size: 11)).lineLimit(1)
                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    EmptyHint(symbol: "wand.and.stars", title: "Select an ability")
                }
            }
            .frame(minWidth: 380)
        }
    }
}
