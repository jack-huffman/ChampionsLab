//  CalculatorView.swift
//  Damage calculator, using Champions' Stat Point maths.

import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject private var store: Store

    @State private var attacker: Side
    @State private var defender: Side

    /// Optionally start on a given matchup. Seeded in init rather than onAppear
    /// so it is set before the first render — tools/snapshot.sh has no view
    /// lifecycle to fire onAppear from.
    init(preload: CalculatorPreload? = nil,
         initialAttacker: String? = nil, initialDefender: String? = nil,
         initialMove: String? = nil) {
        var attacking = Side()
        if let preload {
            // Everything the slot was actually built with.
            attacking.formID = preload.formID
            attacking.ability = preload.ability
            attacking.item = preload.item
            attacking.sp = preload.sp
            attacking.alignmentName = preload.alignmentName
            attacking.moveID = preload.moveID
        } else if let initialAttacker {
            attacking.formID = initialAttacker
            attacking.sp = [2, 32, 0, 0, 0, 32]
            attacking.alignmentName = "Adamant"
        }
        if let initialMove { attacking.moveID = initialMove }
        var defending = Side()
        if let initialDefender {
            defending.formID = initialDefender
            defending.sp = [32, 0, 2, 0, 32, 0]
            defending.alignmentName = "Careful"
        }
        _attacker = State(initialValue: attacking)
        _defender = State(initialValue: defending)
    }
    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none
    @State private var doubles = true
    @State private var screen = false
    @State private var critical = false

    /// Everything the UI lets you set for one side.
    struct Side {
        var formID: String = ""
        var ability = ""
        var item = ""
        var sp = Array(repeating: 0, count: 6)
        var alignmentName = "Serious"
        var boosts = Array(repeating: 0, count: 6)
        var wideOpen = false
        var moveID = ""
        var fallen = 0
    }

    private var field: Field {
        Field(weather: weather, terrain: terrain, isDoubles: doubles,
              screen: screen, critical: critical)
    }

    private func combatant(_ side: Side) -> Combatant? {
        guard let form = store.formsByID[side.formID] else { return nil }
        var c = Combatant(form: form, ability: side.ability, item: side.item,
                          sp: side.sp, alignment: Alignment.named(side.alignmentName))
        c.boosts = side.boosts
        c.wideOpen = side.wideOpen
        c.fallenAllies = side.fallen
        return c
    }

    private var result: DamageResult? {
        guard let a = combatant(attacker), let d = combatant(defender),
              let move = store.move(attacker.moveID) else { return nil }
        return DamageCalc.calculate(attacker: a, defender: d, move: move, field: field)
    }

    @Environment(\.snapshotMode) private var snapshotMode

    @ViewBuilder var body: some View {
        if snapshotMode { content } else { ScrollView { content } }
    }

    var content: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                SideEditor(title: "Attacker", side: $attacker, isAttacker: true)
                SideEditor(title: "Defender", side: $defender, isAttacker: false)
            }
            fieldCard
            resultCard
        }
        .padding(20)
    }

    private var fieldCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Field")
                HStack(spacing: 14) {
                    Picker("Weather", selection: $weather) {
                        ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 190).controlSize(.small)
                    Picker("Terrain", selection: $terrain) {
                        ForEach(Terrain.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 190).controlSize(.small)
                    Toggle("Doubles", isOn: $doubles).controlSize(.small)
                    Toggle("Screen", isOn: $screen).controlSize(.small)
                    Toggle("Critical", isOn: $critical).controlSize(.small)
                    Toggle("Target used Glaive Rush", isOn: $defender.wideOpen)
                        .controlSize(.small)
                        .help("Glaive Rush leaves its user Wide Open until its next action: attacks against it cannot miss and deal double damage.")
                    Spacer()
                }
            }
        }
    }

    private var resultCard: some View {
        Card(padding: 18) {
            if let result, let move = store.move(attacker.moveID) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(result.summary)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(colour(for: result))
                        Spacer()
                        Text("×\(TypeChart.label(result.effectiveness)) effective")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TypeChart.color(result.effectiveness))
                    }

                    Text("\(result.minDamage) – \(result.maxDamage) damage to \(result.targetHP) HP")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)

                    // Damage bar against the target's HP.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.hairline)
                            Capsule()
                                .fill(colour(for: result).opacity(0.35))
                                .frame(width: geo.size.width * min(1, result.maxPercent / 100))
                            Capsule()
                                .fill(colour(for: result))
                                .frame(width: geo.size.width * min(1, result.minPercent / 100))
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 6) {
                        if let type = PokeType(loose: move.type) { TypeChip(type: type, size: .small) }
                        CategoryBadge(category: move.category)
                        Text("\(move.power) BP · \(move.accuracyLabel) acc · \(move.target)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if !result.notes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(result.notes, id: \.self) { note in
                                Text("• " + note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Pick an attacker, a defender, and a move.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }
        }
    }

    private func colour(for result: DamageResult) -> Color {
        if result.isGuaranteedOHKO { return Palette.bad }
        if result.isPossibleOHKO { return Palette.warn }
        if result.maxPercent >= 50 { return Palette.accent }
        return Palette.good
    }
}

// MARK: - One side

private struct SideEditor: View {
    @EnvironmentObject private var store: Store
    let title: String
    @Binding var side: CalculatorView.Side
    let isAttacker: Bool

    private var form: Form? { store.formsByID[side.formID] }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title)

                LookupField(kind: .form, placeholder: "Choose a Pokémon",
                            options: store.formOptions, selection: $side.formID,
                            allowsNone: false)
                .onChange(of: side.formID) { _ in
                    side.ability = store.formsByID[side.formID]?.abilities.first?.name ?? ""
                    side.moveID = ""
                }

                if let form {
                    HStack(spacing: 10) {
                        SpriteImage(form: form, side: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                            }
                            Text("\(form.bst) BST")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }

                    row("Ability") {
                        Picker("", selection: $side.ability) {
                            ForEach(form.abilities, id: \.name) { Text($0.name).tag($0.name) }
                        }.labelsHidden().controlSize(.small)
                    }

                    row("Item") {
                        LookupField(kind: .item, placeholder: "Item",
                                    options: store.itemOptions, selection: $side.item)
                    }

                    row("Alignment") {
                        Picker("", selection: $side.alignmentName) {
                            ForEach(Alignment.all) { Text($0.label).tag($0.name) }
                        }.labelsHidden().controlSize(.small)
                    }


                    if isAttacker {
                        row("Move") {
                            LookupField(kind: .move, placeholder: "Move",
                                        options: store.moveOptions(for: form),
                                        selection: $side.moveID, allowsNone: false)
                        }
                        if side.ability == "Supreme Overlord" {
                            row("Fallen") {
                                Stepper("\(side.fallen)", value: $side.fallen, in: 0...5)
                                    .controlSize(.small)
                            }
                        }
                    }

                    Divider()

                    // Same 66-point budget the game enforces, plus the battle
                    // stage for that stat.
                    let remaining = ChampionsStats.spTotal - side.sp.reduce(0, +)
                    ForEach(Stat.allCases) { stat in
                        HStack(spacing: 8) {
                            StatLine(
                                stat: stat,
                                value: staged(form, stat),
                                sp: side.sp[stat.rawValue],
                                budget: remaining,
                                boosted: Alignment.named(side.alignmentName).up == stat,
                                lowered: Alignment.named(side.alignmentName).down == stat,
                                interactive: true,
                                onChange: { side.sp[stat.rawValue] = $0 })

                            if stat != .hp {
                                StageStepper(stage: Binding(
                                    get: { side.boosts[stat.rawValue] },
                                    set: { side.boosts[stat.rawValue] = $0 }))
                            } else {
                                Color.clear.frame(width: 66, height: 1)
                            }
                        }
                    }

                    boostShortcuts(form)

                    HStack {
                        Text("\(side.sp.reduce(0, +))/\(ChampionsStats.spTotal) SP")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(side.sp.reduce(0, +) > ChampionsStats.spTotal
                                             ? Palette.bad : Palette.fainter)
                        Spacer()
                        Button("Clear") { side.sp = Array(repeating: 0, count: 6) }
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    /// The stat after Stat Points, alignment and any battle stages.
    private func staged(_ form: Form, _ stat: Stat) -> Int {
        let base = ChampionsStats.value(base: form.stats[stat.rawValue],
                                        sp: side.sp[stat.rawValue], stat: stat,
                                        alignment: Alignment.named(side.alignmentName))
        return stat == .hp ? base
            : ChampionsStats.staged(base, stage: side.boosts[stat.rawValue])
    }

    /// One-click stages for things that actually happen in a turn: the setup
    /// moves this Pokémon knows, the ability boosts it has, and Intimidate.
    @ViewBuilder private func boostShortcuts(_ form: Form) -> some View {
        let setup = store.moves(for: form)
            .filter { !$0.selfBoosts.isEmpty }
            .sorted { $0.name < $1.name }
        let ability = side.ability

        if !setup.isEmpty || ability == "Thermal Exchange" || ability == "Defiant" {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Apply").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { side.boosts = Array(repeating: 0, count: 6) }
                        .controlSize(.mini)
                        .disabled(side.boosts.allSatisfy { $0 == 0 })
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                    ForEach(setup) { move in
                        chip(move.name, move.selfBoosts.map { ($0.key, $0.value) })
                    }
                    if ability == "Thermal Exchange" {
                        chip("Hit by Fire", [(.attack, 1)])
                    }
                    if ability == "Defiant" {
                        chip("Intimidated", [(.attack, 2)])
                    }
                    chip("Intimidate", [(.attack, -1)])
                }
            }
            .padding(.top, 2)
        }
    }

    private func chip(_ label: String, _ changes: [(Stat, Int)]) -> some View {
        Button {
            for (stat, amount) in changes {
                side.boosts[stat.rawValue] = max(-6, min(6, side.boosts[stat.rawValue] + amount))
            }
        } label: {
            let summary = changes
                .map { "\($0.1 > 0 ? "+" : "")\($0.1) \($0.0.short)" }
                .joined(separator: " ")
            VStack(spacing: 0) {
                Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Text(summary).font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func row<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}
