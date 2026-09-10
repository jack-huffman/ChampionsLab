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
                Text("Teams").font(.system(size: 15, weight: .semibold))
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
            // Both panes' headers are pinned to the same height so the divider
            // runs straight across the split, whatever controls sit in them.
            .padding(.horizontal, 12)
            .frame(height: HeaderBar.height)
            if let warning = store.teamWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
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
    @Environment(\.snapshotMode) private var snapshotMode

    enum Tab: String, CaseIterable, Identifiable {
        case build = "Build", assist = "Assist", analysis = "Analysis"
        case threats = "Threats", versus = "Versus"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch tab {
            case .build:    buildTab
            case .assist:
                AdvisorView(team: team, onAdd: team.locked ? nil : { form in
                    appendSlot(form)
                })
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
            Button {
                team.locked.toggle()
                onSave()
            } label: {
                Image(systemName: team.locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(team.locked ? Palette.dim : Palette.accent)
            }
            .buttonStyle(.borderless)
            .help(team.locked ? "Locked — click to edit" : "Editable — click to lock")

            if team.locked {
                Text(team.name.isEmpty ? "Untitled" : team.name)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 260, alignment: .leading)
                    .lineLimit(1)
            } else {
                TextField("Team name", text: $team.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 260)
                    .onSubmit(onSave)
            }

            Picker("", selection: $team.format) {
                ForEach(store.data.rules.formats) { format in
                    Text(format.name).tag(format.id)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .controlSize(.small)
            .disabled(team.locked)

            Spacer()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 400)

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
        .padding(.horizontal, 12)
        .frame(height: HeaderBar.height)
    }

    @ViewBuilder private var buildTab: some View {
        if snapshotMode { buildContent } else { ScrollView { buildContent } }
    }

    private var buildContent: some View {
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
                                   locked: team.locked,
                                   onRemove: { team.slots.remove(at: index); onSave() },
                                   onChange: onSave)
                    } else if !team.locked {
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
                        if team.locked {
                            Text(team.notes.isEmpty ? "No notes." : team.notes)
                                .font(.system(size: 12))
                                .foregroundStyle(team.notes.isEmpty ? Palette.fainter : Palette.normal)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TextEditor(text: $team.notes)
                                .font(.system(size: 12))
                                .frame(minHeight: 70)
                                .scrollContentBackground(.hidden)
                        }
                        if !team.replicaCode.isEmpty {
                            DetailRow(label: "Replica code", value: team.replicaCode)
                        }
                    }
                }
        }
        .padding(16)
    }

    /// Add a recommendation straight onto the end of the team.
    private func appendSlot(_ form: Form) {
        guard team.slots.count < (store.data.rules.formats
            .first { $0.id == team.format }?.teamSize ?? 6) else { return }
        var slot = TeamSlot(formID: form.id)
        slot.ability = form.abilities.first?.name ?? ""
        // A Mega is useless without its stone, so fill it in.
        if form.isMega { slot.item = form.megaStone.isEmpty ? "Mega Stone" : form.megaStone }
        team.slots.append(slot)
        onSave()
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
    var locked: Bool = false
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
                        if locked {
                            HStack(alignment: .top, spacing: 18) {
                                summary(form)
                                statReadout(form)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 18) {
                                loadout(form)
                                statPlanner(form)
                            }
                            moves(form)
                        }
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
            Button {
                store.pendingCalculation = CalculatorPreload(slot: slot, store: store)
                NotificationCenter.default.post(name: .openCalculator, object: nil)
            } label: {
                Image(systemName: "function")
            }
            .buttonStyle(.borderless)
            .help("Open \(form.formLabel) in the calculator with this build")

            Text("\(slot.spUsed)/\(ChampionsStats.spTotal) SP")
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(slot.spUsed > ChampionsStats.spTotal ? Palette.bad : Palette.dim)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            if !locked {
                Button(action: onRemove) {
                    Image(systemName: "trash").foregroundStyle(Palette.bad)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Locked rendering: plain text, no controls. This is the fast path.
    private func summary(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailRow(label: "Ability", value: slot.ability.isEmpty ? "—" : slot.ability)
            HStack(alignment: .top, spacing: 8) {
                Text("Item").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                HStack(spacing: 5) {
                    if !slot.item.isEmpty { ItemIcon(name: slot.item, side: 16) }
                    Text(slot.item.isEmpty ? "—" : slot.item).font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
            DetailRow(label: "Alignment", value: slot.alignment.label)
            VStack(alignment: .leading, spacing: 3) {
                Text("Moves").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(slot.moves, id: \.self) { id in
                    if let move = store.move(id) { MoveRow(move: move) }
                }
                if slot.moves.isEmpty {
                    Text("—").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// Locked stat readout: the same rails, not draggable.
    private func statReadout(_ form: Form) -> some View {
        let battle = slot.battleForm(in: store) ?? form
        let mega = slot.megaEvolution(in: store)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(mega == nil ? "Stats" : "Stats as \(mega!.formLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(slot.spUsed)/\(ChampionsStats.spTotal) SP")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Stat.allCases) { stat in
                StatLine(
                    stat: stat,
                    value: ChampionsStats.value(base: battle.stats[stat.rawValue],
                                                sp: slot.sp[stat.rawValue], stat: stat,
                                                alignment: slot.alignment),
                    sp: slot.sp[stat.rawValue],
                    budget: ChampionsStats.spTotal - slot.spUsed,
                    boosted: slot.alignment.up == stat,
                    lowered: slot.alignment.down == stat)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadout(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("Ability", info: abilityInfo(form)) {
                Picker("", selection: $slot.ability) {
                    ForEach(form.abilities, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.ability) { _ in onChange() }
            }

            labelled("Item", info: itemInfo()) {
                LookupField(kind: .item, placeholder: "Item",
                            options: store.itemOptions, selection: $slot.item)
                    .onChange(of: slot.item) { _ in onChange() }
            }

            labelled("Alignment", info: alignmentInfo()) {
                Picker("", selection: $slot.alignmentName) {
                    ForEach(Alignment.all) { Text($0.label).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
                .onChange(of: slot.alignmentName) { _ in onChange() }
            }
        }
        .frame(maxWidth: 300)
    }

    /// What the currently selected ability does.
    private func abilityInfo(_ form: Form) -> (String, String) {
        let name = slot.ability.isEmpty
            ? (form.abilities.first?.name ?? "") : slot.ability
        return (name, store.data.abilities[name]?.desc ?? "")
    }

    private func itemInfo() -> (String, String) {
        guard !slot.item.isEmpty, let item = store.item(named: slot.item) else {
            return ("Item", "")
        }
        // blurb prefers the curated wording, which matters where Serebii's text
        // describes an older generation's behaviour — Mental Herb is the one
        // item in the set where that is true.
        var text = item.blurb
        if let note = item.note, !note.isEmpty { text += "\n\n" + note }
        return (item.name, text)
    }

    /// Stat Alignment is Champions' name for a nature, and the arithmetic is
    /// worth spelling out — it multiplies the final stat, not the base.
    private func alignmentInfo() -> (String, String) {
        let alignment = slot.alignment
        guard let up = alignment.up, let down = alignment.down else {
            return (alignment.name, "Neutral: no stat is raised or lowered. Serious is the only neutral alignment Champions offers.")
        }
        return (alignment.name,
                "Raises \(up.long) by 10% and lowers \(down.long) by 10%. The multiplier applies to the finished stat — base plus 20 plus Stat Points at Level 50 — so it is worth more on a high base stat than a low one.")
    }

    private func labelled<V: View>(_ text: String, info: (String, String)? = nil,
                                   @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
            if let info {
                InfoButton(title: info.0, body: info.1)
            }
        }
    }

    private func statPlanner(_ form: Form) -> some View {
        let remaining = ChampionsStats.spTotal - slot.spUsed
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Stat Points")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(slot.spUsed)/\(ChampionsStats.spTotal)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == 0 ? Palette.good : Palette.dim)
                Text(remaining == 0 ? "spent" : "\(remaining) left")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Palette.fainter)
            }
            ForEach(Stat.allCases) { stat in
                StatLine(
                    stat: stat,
                    value: ChampionsStats.value(base: form.stats[stat.rawValue],
                                                sp: slot.sp[stat.rawValue], stat: stat,
                                                alignment: slot.alignment),
                    sp: slot.sp[stat.rawValue],
                    // What is left over once this stat's own spend is returned,
                    // so the rail can grey out what the total no longer allows.
                    budget: remaining,
                    boosted: slot.alignment.up == stat,
                    lowered: slot.alignment.down == stat,
                    interactive: true,
                    onChange: { value in
                        slot.sp[stat.rawValue] = value
                        onChange()
                    })
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func moves(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Moves \(slot.moves.count)/4")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                MoveStatHeader()
            }
            ForEach(0..<4, id: \.self) { index in
                MoveSlotPicker(form: form, slot: $slot, index: index, onChange: onChange)
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
        HStack(spacing: MoveColumn.spacing) {
            LookupField(kind: .move, placeholder: "Move \(index + 1)",
                        options: store.moveOptions(for: form), selection: selection)
                .frame(maxWidth: .infinity)

            MoveStats(move: move)

            // Opens the full record, the same popover the move tables use.
            if let move {
                MoveInfoButton(move: move)
            } else {
                Color.clear.frame(width: 13, height: 13)
            }
        }
    }
}

/// Column labels for the inline move stats.
struct MoveStatHeader: View {
    var body: some View {
        HStack(spacing: MoveColumn.spacing) {
            label("Class", MoveColumn.category, .center)
            label("Pow", MoveColumn.power, .trailing)
            label("Acc", MoveColumn.accuracy, .trailing)
            label("Pri", MoveColumn.priority, .center)
            label("", MoveColumn.flags, .leading)
            Color.clear.frame(width: 13, height: 1)
        }
    }

    private func label(_ text: String, _ width: CGFloat,
                       _ alignment: SwiftUI.Alignment) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }
}

/// The numeric half of a move row, in the shared column widths so the editor
/// and the learnset table line up with each other.
struct MoveStats: View {
    let move: Move?

    var body: some View {
        HStack(spacing: MoveColumn.spacing) {
            if let move {
                CategoryBadge(category: move.category)
                Text(move.power > 0 ? "\(move.power)" : "—")
                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                    .foregroundStyle(move.power > 0 ? Palette.normal : Palette.fainter)
                    .frame(width: MoveColumn.power, alignment: .trailing)
                Text(move.accuracyLabel)
                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.dim)
                    .frame(width: MoveColumn.accuracy, alignment: .trailing)
                Group {
                    if move.priority != 0 {
                        Text(move.priority > 0 ? "+\(move.priority)" : "\(move.priority)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: MoveColumn.priority, height: 16)
                            .background(move.priority > 0
                                        ? Palette.good.opacity(0.20) : Palette.bad.opacity(0.20))
                            .foregroundStyle(move.priority > 0 ? Palette.good : Palette.bad)
                            .clipShape(Capsule())
                    } else {
                        Color.clear.frame(width: MoveColumn.priority, height: 16)
                    }
                }
                HStack(spacing: 4) {
                    flag("arrow.left.and.right", shown: move.isSpread, colour: Palette.warn,
                         hint: move.target)
                    flag("hand.tap.fill", shown: move.makesContact, colour: Palette.fainter,
                         hint: "Makes contact — taxed by Rocky Helmet and Aura Guard")
                }
                .frame(width: MoveColumn.flags, alignment: .leading)
            } else {
                // Keep the columns even while the slot is empty.
                Color.clear.frame(width: MoveColumn.category, height: 18)
                Color.clear.frame(width: MoveColumn.power, height: 1)
                Color.clear.frame(width: MoveColumn.accuracy, height: 1)
                Color.clear.frame(width: MoveColumn.priority, height: 1)
                Color.clear.frame(width: MoveColumn.flags, height: 1)
            }
        }
    }

    private func flag(_ symbol: String, shown: Bool, colour: Color, hint: String) -> some View {
        Color.clear
            .frame(width: MoveColumn.flag, height: 12)
            .overlay {
                if shown {
                    Image(systemName: symbol)
                        .font(.system(size: 9)).foregroundStyle(colour).help(hint)
                }
            }
    }
}

/// An "i" that opens the full move record.
struct MoveInfoButton: View {
    let move: Move
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .help(move.effect.isEmpty ? move.name : move.effect)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            MoveDetail(move: move)
        }
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


/// Renders a team's build tab read-only, for tools/snapshot.sh.
struct TeamEditorPreview: View {
    @State var team: Team
    var body: some View {
        TeamEditor(team: $team, onSave: {})
    }
}
