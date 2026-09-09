//  CalculatorView.swift
//  Damage calculator, using Champions' Stat Point maths.

import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject private var store: Store

    @State private var attacker = Side()
    @State private var defender = Side()
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

                Picker("", selection: $side.formID) {
                    Text("Choose…").tag("")
                    ForEach(store.data.forms) { Text($0.formLabel).tag($0.id) }
                }
                .labelsHidden()
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
                        Picker("", selection: $side.item) {
                            Text("None").tag("")
                            ForEach(store.data.items) { Text($0.name).tag($0.name) }
                        }.labelsHidden().controlSize(.small)
                    }

                    row("Alignment") {
                        Picker("", selection: $side.alignmentName) {
                            ForEach(Alignment.all) { Text($0.label).tag($0.name) }
                        }.labelsHidden().controlSize(.small)
                    }


                    if isAttacker {
                        row("Move") {
                            Picker("", selection: $side.moveID) {
                                Text("Choose…").tag("")
                                ForEach(store.moves(for: form).filter(\.isDamaging)) {
                                    Text($0.name).tag($0.id)
                                }
                            }.labelsHidden().controlSize(.small)
                        }
                        if side.ability == "Supreme Overlord" {
                            row("Fallen") {
                                Stepper("\(side.fallen)", value: $side.fallen, in: 0...5)
                                    .controlSize(.small)
                            }
                        }
                    }

                    Divider()

                    // SP and battle stages together, since both change the number.
                    ForEach(Stat.allCases) { stat in
                        HStack(spacing: 6) {
                            Text(stat.short)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(side.sp[stat.rawValue]) },
                                    set: { side.sp[stat.rawValue] = Int($0) }
                                ),
                                in: 0...Double(ChampionsStats.spPerStat), step: 1
                            ).controlSize(.mini)
                            Text("\(side.sp[stat.rawValue])")
                                .font(.system(size: 9, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                            if stat != .hp {
                                Picker("", selection: Binding(
                                    get: { side.boosts[stat.rawValue] },
                                    set: { side.boosts[stat.rawValue] = $0 }
                                )) {
                                    ForEach(-6...6, id: \.self) { value in
                                        Text(value == 0 ? "—" : (value > 0 ? "+\(value)" : "\(value)"))
                                            .tag(value)
                                    }
                                }
                                .labelsHidden().controlSize(.mini).frame(width: 52)
                            } else {
                                Color.clear.frame(width: 52, height: 1)
                            }
                            Text("\(ChampionsStats.value(base: form.stats[stat.rawValue], sp: side.sp[stat.rawValue], stat: stat, alignment: Alignment.named(side.alignmentName)))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        }
                    }

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

    private func row<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}
