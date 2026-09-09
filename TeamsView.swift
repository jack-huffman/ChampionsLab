//  TeamsView.swift
//  Saved teams, the slot editor, and the analysis that goes with them.

import SwiftUI

struct TeamsView: View {
    @EnvironmentObject private var store: Store
    @State private var selected: UUID?
    @State private var draft: Team?
    @State private var importing = false

    private var current: Binding<Team>? {
        guard let draft, draft.id == selected else { return nil }
        return Binding(
            get: { self.draft ?? draft },
            set: { self.draft = $0 }
        )
    }

    var body: some View {
        HSplitView {
            teamList
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)

            if let binding = current {
                TeamEditor(team: binding, onSave: {
                    var team = binding.wrappedValue
                    team.modified = Date()
                    store.save(team)
                    draft = team
                })
                .frame(minWidth: 620)
            } else {
                EmptyHint(symbol: "person.3.sequence",
                          title: store.teams.isEmpty ? "No teams yet" : "Select a team",
                          detail: "Teams are saved to Application Support and persist between launches.")
                    .frame(minWidth: 620)
            }
        }
        .sheet(isPresented: $importing) {
            ImportSheet { imported in
                store.save(imported)
                selected = imported.id
                draft = imported
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTeam)) { _ in newTeam() }
        .onReceive(NotificationCenter.default.publisher(for: .importTeam)) { _ in importing = true }
        .onAppear {
            if selected == nil, let first = store.teams.first {
                selected = first.id
                draft = first
            }
        }
    }

    private var teamList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Teams").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { importing = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import from a Showdown or Pokepaste list")
                Button(action: newTeam) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New team (⌘N)")
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.teams) { team in
                        teamRow(team)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected = team.id
                                draft = team
                            }
                            .contextMenu {
                                Button("Duplicate") { duplicate(team) }
                                Button("Delete", role: .destructive) { delete(team) }
                            }
                    }
                }
                .padding(8)
            }
        }
    }

    private func teamRow(_ team: Team) -> some View {
        let isSelected = selected == team.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(team.name.isEmpty ? "Untitled" : team.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(team.isDoubles ? "2v2" : "1v1")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.surfaceRaised)
                    .clipShape(Capsule())
            }
            HStack(spacing: 2) {
                ForEach(team.slots) { slot in
                    if let form = slot.form(in: store) {
                        SpriteImage(form: form, side: 26)
                    }
                }
                if team.slots.isEmpty {
                    Text("Empty").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(isSelected ? Palette.accent.opacity(0.16) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private func newTeam() {
        let team = Team(name: "Team \(store.teams.count + 1)")
        store.save(team)
        selected = team.id
        draft = team
    }

    private func duplicate(_ team: Team) {
        var copy = team
        copy.id = UUID()
        copy.name = team.name + " copy"
        copy.slots = team.slots.map { slot in
            var new = slot
            new.id = UUID()
            return new
        }
        store.save(copy)
        selected = copy.id
        draft = copy
    }

    private func delete(_ team: Team) {
        store.delete(team)
        if selected == team.id {
            selected = store.teams.first?.id
            draft = store.teams.first
        }
    }
}

// MARK: - Editor

struct TeamEditor: View {
    @EnvironmentObject private var store: Store
    @Binding var team: Team
    let onSave: () -> Void

    @State private var tab: Tab = .build
    @State private var picking: Int?

    enum Tab: String, CaseIterable, Identifiable {
        case build = "Build", analysis = "Analysis"
        case threats = "Threats", versus = "Versus"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch tab {
            case .build:    buildTab
            case .analysis: TeamAnalysisView(team: team)
            case .threats:  ThreatMatrixView(team: team)
            case .versus:   MatchupView(team: team)
            }
        }
        .sheet(item: Binding(
            get: { picking.map { SlotIndex(value: $0) } },
            set: { picking = $0?.value }
        )) { index in
            FormPicker { form in
                assign(form, at: index.value)
                picking = nil
            }
        }
    }

    private struct SlotIndex: Identifiable { let value: Int; var id: Int { value } }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Team name", text: $team.name)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: 260)
                .onSubmit(onSave)

            Picker("", selection: $team.format) {
                ForEach(store.data.rules.formats) { format in
                    Text(format.name).tag(format.id)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .controlSize(.small)

            Spacer()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)

            Button {
                let text = TeamPaste.export(team, store: store)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Copy as Showdown text")

            Button("Save", action: onSave)
                .keyboardShortcut("s")
        }
        .padding(12)
    }

    private var buildTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let violations = team.violations(in: store)
                if !violations.isEmpty {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Legality", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.warn)
                            ForEach(violations, id: \.self) { text in
                                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                let size = store.data.rules.formats.first { $0.id == team.format }?.teamSize ?? 6
                ForEach(0..<size, id: \.self) { index in
                    if index < team.slots.count {
                        SlotEditor(slot: $team.slots[index],
                                   onRemove: { team.slots.remove(at: index); onSave() },
                                   onChange: onSave)
                    } else {
                        Button { picking = index } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Pokémon \(index + 1)")
                                Spacer()
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(Palette.surface.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .foregroundStyle(Palette.hairline)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Notes")
                        TextEditor(text: $team.notes)
                            .font(.system(size: 12))
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                    }
                }
            }
            .padding(16)
        }
    }

    private func assign(_ form: Form, at index: Int) {
        var slot = TeamSlot(formID: form.id)
        slot.ability = form.abilities.first?.name ?? ""
        if index < team.slots.count {
            team.slots[index] = slot
        } else {
            team.slots.append(slot)
        }
        onSave()
    }
}

// MARK: - Slot editor

struct SlotEditor: View {
    @EnvironmentObject private var store: Store
    @Binding var slot: TeamSlot
    let onRemove: () -> Void
    let onChange: () -> Void

    @State private var expanded = true

    private var form: Form? { slot.form(in: store) }

    var body: some View {
        Card(padding: 14) {
            if let form {
                VStack(alignment: .leading, spacing: 12) {
                    header(form)
                    if expanded {
                        Divider()
                        HStack(alignment: .top, spacing: 18) {
                            loadout(form)
                            statPlanner(form)
                        }
                        moves(form)
                    }
                }
            } else {
                Text("Missing form").foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ form: Form) -> some View {
        HStack(spacing: 12) {
            SpriteImage(form: form, side: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(form.formLabel).font(.system(size: 15, weight: .semibold))
                    // Champions registers the base Pokémon holding its stone, so
                    // say plainly what it becomes — the analysis uses those stats.
                    if let mega = slot.megaEvolution(in: store) {
                        Text("→ \(mega.formLabel)")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.18))
                            .foregroundStyle(Palette.accent)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    ForEach((slot.megaEvolution(in: store) ?? form).pokeTypes) {
                        TypeChip(type: $0, size: .small)
                    }
                    if !slot.item.isEmpty {
                        HStack(spacing: 3) {
                            ItemIcon(name: slot.item, side: 16)
                            Text(slot.item).font(.system(size: 10))
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Palette.surfaceRaised)
                        .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            Text("\(slot.spUsed)/\(ChampionsStats.spTotal) SP")
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(slot.spUsed > ChampionsStats.spTotal ? Palette.bad : Palette.dim)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(Palette.bad)
            }
            .buttonStyle(.borderless)
        }
    }

    private func loadout(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("Ability") {
                Picker("", selection: $slot.ability) {
                    ForEach(form.abilities, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.ability) { _ in onChange() }
            }

            labelled("Item") {
                Picker("", selection: $slot.item) {
                    Text("None").tag("")
                    ForEach(store.data.items) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.item) { _ in onChange() }
            }

            labelled("Alignment") {
                Picker("", selection: $slot.alignmentName) {
                    ForEach(Alignment.all) { Text($0.label).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.alignmentName) { _ in onChange() }
            }

            labelled("Tera") {
                Picker("", selection: $slot.teraType) {
                    Text("None").tag("")
                    ForEach(PokeType.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.teraType) { _ in onChange() }
            }

            if form.isMega && !slot.teraType.isEmpty {
                Text("One gimmick per battle — a Mega cannot also Terastallize.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 250)
    }

    private func labelled<V: View>(_ text: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }

    private func statPlanner(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Stat Points")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ChampionsStats.spTotal - slot.spUsed) left")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(slot.spUsed > ChampionsStats.spTotal ? Palette.bad : Palette.fainter)
            }
            ForEach(Stat.allCases) { stat in
                HStack(spacing: 8) {
                    Text(stat.short)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(slot.sp[stat.rawValue]) },
                            set: { slot.sp[stat.rawValue] = Int($0); onChange() }
                        ),
                        in: 0...Double(ChampionsStats.spPerStat), step: 1
                    )
                    .controlSize(.mini)

                    Text("\(slot.sp[stat.rawValue])")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)

                    Text("\(ChampionsStats.value(base: form.stats[stat.rawValue], sp: slot.sp[stat.rawValue], stat: stat, alignment: slot.alignment))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func moves(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moves \(slot.moves.count)/4")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    MoveSlotPicker(form: form, slot: $slot, index: index, onChange: onChange)
                }
            }
        }
    }
}

/// One of the four move dropdowns.
struct MoveSlotPicker: View {
    @EnvironmentObject private var store: Store
    let form: Form
    @Binding var slot: TeamSlot
    let index: Int
    let onChange: () -> Void

    private var selection: Binding<String> {
        Binding(
            get: { index < slot.moves.count ? slot.moves[index] : "" },
            set: { value in
                var moves = slot.moves
                while moves.count <= index { moves.append("") }
                moves[index] = value
                slot.moves = moves.filter { !$0.isEmpty }
                onChange()
            }
        )
    }

    var body: some View {
        let move = index < slot.moves.count ? store.move(slot.moves[index]) : nil
        VStack(spacing: 3) {
            Picker("", selection: selection) {
                Text("—").tag("")
                ForEach(store.moves(for: form)) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .controlSize(.small)

            if let move {
                HStack(spacing: 4) {
                    if let type = PokeType(loose: move.type) { TypeIcon(type: type, side: 14) }
                    Text(move.power > 0 ? "\(move.power)" : "—")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                    if move.isSpread {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 8)).foregroundStyle(Palette.warn)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Picker sheet

struct FormPicker: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let onPick: (Form) -> Void

    @State private var query = ""

    private var results: [Form] {
        guard !query.isEmpty else {
            // Lead with the things people actually build around.
            let usage = store.data.usage.compactMap { store.form(named: $0.name) }
            let rest = store.data.forms.filter { form in
                !usage.contains { $0.id == form.id }
            }
            return usage + rest
        }
        let needle = query.lowercased()
        return store.data.forms.filter {
            $0.formLabel.lowercased().contains(needle)
                || $0.types.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search the M-C roster", text: $query)
                    .textFieldStyle(.plain)
                Button("Cancel") { dismiss() }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results.prefix(240)) { form in
                        HStack(spacing: 10) {
                            SpriteImage(form: form, side: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(form.formLabel).font(.system(size: 12, weight: .medium))
                                HStack(spacing: 3) {
                                    ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                                }
                            }
                            Spacer()
                            Text("\(form.bst)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(form) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 460, height: 540)
    }
}
