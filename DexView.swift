//  DexView.swift
//  Browse every legal form, with the detail you need while building.

import SwiftUI

struct DexView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var typeFilter: PokeType?
    @State private var megasOnly = false
    @State private var newOnly = false
    @State private var sort: SortKey = .dex
    @State private var selection: String?

    enum SortKey: String, CaseIterable, Identifiable {
        case dex = "Dex", name = "Name", bst = "Total"
        case hp = "HP", attack = "Atk", defense = "Def"
        case spAttack = "SpA", spDefense = "SpD", speed = "Spe"
        var id: String { rawValue }
    }

    private var results: [Form] {
        var forms = store.data.forms

        if !query.isEmpty {
            let needle = query.lowercased()
            forms = forms.filter {
                $0.formLabel.lowercased().contains(needle)
                    || $0.name.lowercased().contains(needle)
                    || $0.abilities.contains { $0.name.lowercased().contains(needle) }
                    || $0.types.contains { $0.lowercased().contains(needle) }
            }
        }
        if let typeFilter {
            forms = forms.filter { $0.pokeTypes.contains(typeFilter) }
        }
        if megasOnly { forms = forms.filter(\.isMega) }
        if newOnly {
            let names = Set(store.data.regulation.newPokemon.map { $0.split(separator: " (").first.map(String.init) ?? $0 })
            forms = forms.filter { names.contains($0.name) }
        }

        switch sort {
        case .dex:       forms.sort { ($0.dex, $0.suffix) < ($1.dex, $1.suffix) }
        case .name:      forms.sort { $0.formLabel < $1.formLabel }
        case .bst:       forms.sort { $0.bst > $1.bst }
        case .hp:        forms.sort { $0.hp > $1.hp }
        case .attack:    forms.sort { $0.attack > $1.attack }
        case .defense:   forms.sort { $0.defense > $1.defense }
        case .spAttack:  forms.sort { $0.spAttack > $1.spAttack }
        case .spDefense: forms.sort { $0.spDefense > $1.spDefense }
        case .speed:     forms.sort { $0.speed > $1.speed }
        }
        return forms
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list
            }
            .frame(minWidth: 380, idealWidth: 440)

            Group {
                if let selection, let form = store.formsByID[selection] {
                    FormDetail(form: form)
                } else {
                    EmptyHint(symbol: "sidebar.right", title: "Select a Pokémon",
                              detail: "\(results.count) legal forms in Regulation M-C, Megas included.")
                }
            }
            .frame(minWidth: 420)
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Name, type, or ability", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Toggle("Megas", isOn: $megasOnly).toggleStyle(.button).controlSize(.small)
                Toggle("New in M-C", isOn: $newOnly).toggleStyle(.button).controlSize(.small)
                Spacer()
                Picker("", selection: $sort) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 84)
                .controlSize(.small)
            }

            // Type filter strip — click to narrow, click again to clear.
            HStack(spacing: 3) {
                ForEach(PokeType.allCases) { type in
                    Button {
                        typeFilter = typeFilter == type ? nil : type
                    } label: {
                        TypeIcon(type: type, side: 19)
                            .opacity(typeFilter == nil || typeFilter == type ? 1 : 0.3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.primary.opacity(typeFilter == type ? 0.7 : 0),
                                                  lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(results) { form in
                    DexRow(form: form, isSelected: selection == form.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = form.id }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Row

private struct DexRow: View {
    let form: Form
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SpriteImage(form: form, side: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(form.formLabel)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if form.isZMega {
                        Text("Z").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.accent).foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 3) {
                    ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Stat.allCases) { stat in
                    Text("\(form.stats[stat.rawValue])")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(form.stats[stat.rawValue] >= 130 ? Palette.good : Palette.dim)
                        .frame(width: 24, alignment: .trailing)
                }
                Text("\(form.bst)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Palette.accent.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Detail

struct FormDetail: View {
    @EnvironmentObject private var store: Store
    let form: Form
    @State private var moveQuery = ""

    private var usage: UsageEntry? {
        store.data.usage.first { $0.name == form.formLabel || $0.name == form.name }
    }

    @Environment(\.snapshotMode) private var snapshotMode

    @ViewBuilder var body: some View {
        if snapshotMode { content } else { ScrollView { content } }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statsCard
            abilitiesCard
            weaknessCard
            if let usage { usageCard(usage) }
            movesCard
        }
        .padding(20)
    }

    private var header: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                SpriteImage(form: form, side: 88)
                VStack(alignment: .leading, spacing: 8) {
                    Text(form.formLabel)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    HStack(spacing: 5) {
                        ForEach(form.pokeTypes) { TypeChip(type: $0, size: .regular) }
                    }
                    HStack(spacing: 10) {
                        Text("#\(String(format: "%04d", form.dex))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("\(form.bst) BST")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        if form.isMega {
                            Text("Mega Evolution")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.accent.opacity(0.18))
                                .foregroundStyle(Palette.accent)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private var statsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Base stats",
                              subtitle: "Right column: Level 50 with 32 SP and a boosting alignment.")
                ForEach(Stat.allCases) { stat in
                    StatBar(stat: stat, base: form.stats[stat.rawValue],
                            computed: ChampionsStats.maxValue(
                                base: form.stats[stat.rawValue], stat: stat, boosting: true))
                }
            }
        }
    }

    private var abilitiesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: form.abilities.count == 1 ? "Ability" : "Abilities")
                ForEach(form.abilities, id: \.name) { ability in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ability.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        if !ability.desc.isEmpty {
                            Text(ability.desc)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if form.abilities.count > 1 && !form.suffix.isEmpty && !form.isMega {
                    Text("Serebii lists abilities per species, so a regional form may show the whole family's pool. Pick the one that actually applies.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var weaknessCard: some View {
        let ability = form.abilities.first?.name
        let chart = form.weaknesses(ability: ability)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Damage taken",
                              subtitle: ability.map { "Including \($0)" })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                    ForEach(PokeType.allCases) { type in
                        let value = chart[type] ?? 1
                        VStack(spacing: 3) {
                            TypeIcon(type: type, side: 22)
                            Text(TypeChart.label(value))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(TypeChart.color(value).opacity(value == 1 ? 0.10 : 0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    private func usageCard(_ entry: UsageEntry) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Competitive profile")
                    Spacer()
                    TierBadge(tier: entry.tier)
                }
                if entry.isProjected {
                    Label("Projected — M-C has no ladder data yet",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                } else {
                    Text(String(format: "%.1f%% usage", entry.usage))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                DetailRow(label: "Role", value: entry.role)
                DetailRow(label: "Items", value: entry.commonItems.joined(separator: ", "))
                DetailRow(label: "Moves", value: entry.keyMoves.joined(separator: ", "))
                Text(entry.why)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var movesCard: some View {
        let moves = store.moves(for: form).filter {
            moveQuery.isEmpty || $0.name.lowercased().contains(moveQuery.lowercased())
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Learnset", subtitle: "\(form.moves.count) moves")
                    Spacer()
                    TextField("Filter", text: $moveQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .controlSize(.small)
                }
                MoveTableHeader()
                ForEach(moves) { move in
                    MoveRow(move: move)
                }
            }
        }
    }
}

// MARK: - Shared move row

struct MoveRow: View {
    let move: Move
    @State private var showingDetail = false

    var body: some View {
        row
            .contentShape(Rectangle())
            .onTapGesture { showingDetail = true }
            .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
                MoveDetail(move: move)
            }
    }

    private var row: some View {
        HStack(spacing: MoveColumn.spacing) {
            // Every column keeps its slot whether or not it has content —
            // otherwise an absent type icon, a "Status" pill, or a move with no
            // priority shifts everything to its right and the table stops
            // reading as columns.
            Color.clear
                .frame(width: MoveColumn.type, height: MoveColumn.type)
                .overlay {
                    if let type = PokeType(loose: move.type) {
                        TypeIcon(type: type, side: MoveColumn.type)
                    }
                }

            Text(move.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: MoveColumn.name, alignment: .leading)

            CategoryBadge(category: move.category)

            Text(move.power > 0 ? "\(move.power)" : "—")
                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                .foregroundStyle(move.power > 0 ? Palette.normal : Palette.fainter)
                .frame(width: MoveColumn.power, alignment: .trailing)

            Text(move.accuracyLabel)
                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.dim)
                .frame(width: MoveColumn.accuracy, alignment: .trailing)

            priorityCell
                .frame(width: MoveColumn.priority)

            HStack(spacing: 4) {
                flag("arrow.left.and.right", shown: move.isSpread,
                     colour: Palette.warn, hint: move.target)
                flag("hand.tap.fill", shown: move.makesContact,
                     colour: Palette.fainter,
                     hint: "Makes contact — taxed by Rocky Helmet and Aura Guard")
            }
            .frame(width: MoveColumn.flags, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help("Click for full details")
    }

    @ViewBuilder private var priorityCell: some View {
        if move.priority != 0 {
            Text(move.priority > 0 ? "+\(move.priority)" : "\(move.priority)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: MoveColumn.priority, height: 16)
                .background(move.priority > 0
                            ? Palette.good.opacity(0.20) : Palette.bad.opacity(0.20))
                .foregroundStyle(move.priority > 0 ? Palette.good : Palette.bad)
                .clipShape(Capsule())
                .help("Speed priority \(move.priority > 0 ? "+" : "")\(move.priority)")
        } else {
            Color.clear.frame(height: 16)
        }
    }

    /// One flag slot. Drawn as an overlay on a clear rectangle rather than a
    /// conditional view: an empty `Group` collapses to an EmptyView, which
    /// ignores `.frame` and lets the next flag slide into this slot — spread-only
    /// and contact-only moves then showed their icon at the same x position.
    private func flag(_ symbol: String, shown: Bool,
                      colour: Color, hint: String) -> some View {
        Color.clear
            .frame(width: MoveColumn.flag, height: 12)
            .overlay {
                if shown {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(colour)
                        .help(hint)
                }
            }
    }
}


// MARK: - Move detail

/// The full record for a move, shown when a row is clicked. The table columns
/// only have room for power, accuracy and priority; everything that actually
/// decides whether a move is usable — its target, its flags, its secondary
/// effect — lives here.
struct MoveDetail: View {
    @EnvironmentObject private var store: Store
    let move: Move

    private var learners: [Form] {
        store.data.forms.filter { $0.moves.contains(move.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                numbers
                if !move.effect.isEmpty { effectCard }
                flagsCard
                learnersCard
            }
            .padding(16)
        }
        .frame(width: 400, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(move.name)
                .font(.system(size: 19, weight: .bold, design: .rounded))
            HStack(spacing: 6) {
                if let type = PokeType(loose: move.type) { TypeChip(type: type) }
                CategoryBadge(category: move.category, width: nil)
                if !move.learnable {
                    Text("no legal user")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.warn.opacity(0.18))
                        .foregroundStyle(Palette.warn)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var numbers: some View {
        HStack(spacing: 0) {
            stat("Power", move.power > 0 ? "\(move.power)" : "—")
            stat("Accuracy", move.accuracyLabel)
            stat("PP", move.pp > 0 ? "\(move.pp)" : "—")
            stat("Priority", move.priority == 0 ? "0"
                 : (move.priority > 0 ? "+\(move.priority)" : "\(move.priority)"))
            stat("Crit", move.critRate > 0 ? String(format: "%.1f%%", move.critRate) : "—")
        }
        .padding(.vertical, 8)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var effectCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Effect")
            Text(move.effect)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if move.effectRate > 0 {
                Text(String(format: "Triggers %.0f%% of the time.", move.effectRate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var flagsCard: some View {
        let on = move.flags.filter { $0.value }.keys.sorted()
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Targeting and flags")
            DetailRow(label: "Targets", value: move.target)
            if move.isSpread {
                Text(move.hitsAlly
                     ? "Hits your partner too, and takes the 0.75× spread penalty."
                     : "Hits both opponents, and takes the 0.75× spread penalty.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if on.isEmpty {
                Text("No flags").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                FlowRow(items: on.map(Self.flagLabel))
            }
            if move.makesContact {
                Text("Contact: taxed by Rocky Helmet, halved by Aura Guard, boosted by Tough Claws.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func flagLabel(_ key: String) -> String {
        [
            "contact": "Contact", "sound": "Sound", "punch": "Punch",
            "bite": "Biting", "slicing": "Slicing", "bullet": "Bullet",
            "wind": "Wind", "powder": "Powder", "snatchable": "Snatchable",
            "metronome": "Metronome", "gravity": "Gravity-affected",
            "defrosts": "Defrosts", "reflectable": "Magic Bounce",
            "protectable": "Blocked by Protect", "copyable": "Mirror Move",
        ][key] ?? key.capitalized
    }

    private var learnersCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Learned by", subtitle: "\(learners.count) legal forms")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                ForEach(learners.prefix(60)) { form in
                    HStack(spacing: 5) {
                        SpriteImage(form: form, side: 22)
                        Text(form.formLabel)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            if learners.count > 60 {
                Text("+ \(learners.count - 60) more")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowRow: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 4)], spacing: 4) {
            ForEach(items, id: \.self) { text in
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(Palette.surfaceRaised)
                    .clipShape(Capsule())
            }
        }
    }
}
