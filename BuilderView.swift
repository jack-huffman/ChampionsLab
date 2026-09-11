//  BuilderView.swift
//  Pick something to build around; get several complete teams back.

import SwiftUI

struct BuilderView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    @State private var seedID = ""
    @State private var format = "doubles"
    @State private var blueprints: [Blueprint] = []
    @State private var working = false
    @State private var expanded: UUID?
    @State private var picks: [Forecast.Pick] = []
    /// Two Megas is the default: only one may Mega Evolve per battle, and you
    /// bring four of six, so the second is a whole alternate team rather than a
    /// wasted slot.
    @State private var dualMega = true
    @State private var fellBack = false

    /// Pre-generated results, so tools/snapshot.sh can render the populated
    /// state — it has no view lifecycle to trigger a build from.
    init(preGenerated: [Blueprint] = [], seedID: String = "") {
        _blueprints = State(initialValue: preGenerated)
        _seedID = State(initialValue: seedID)
        _expanded = State(initialValue: preGenerated.first?.id)
    }

    private var seed: Form? { store.formsByID[seedID] }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if snapshotMode { content } else { ScrollView { content } }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Build around")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            LookupField(kind: .form, placeholder: "Choose a Pokémon",
                        options: store.formOptions, selection: $seedID,
                        allowsNone: false)
                .frame(width: 260)
            Picker("", selection: $format) {
                ForEach(store.data.rules.formats) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(width: 150).controlSize(.small)

            Toggle("Two Megas", isOn: $dualMega)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Build around two Mega Evolutions. Only one can Mega Evolve per battle, so each defines its own four to bring — a primary line and an alternate.")

            Button(working ? "Building…" : "Build teams") { generate() }
                .disabled(seedID.isEmpty || working)
                .keyboardShortcut(.return)
            Spacer()
            if !blueprints.isEmpty {
                Text("\(blueprints.count) plans")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        // Picks are cached across builds; a usage refresh invalidates them.
        .onChange(of: store.usageVersion) { _ in picks = [] }
    }

    private func generate() {
        guard let seed else { return }
        working = true
        fellBack = false
        if picks.isEmpty {
            picks = Forecast(store: store, format: format).picks(limit: 400)
        }
        var builder = TeamBuilder(store: store)
        builder.format = format
        blueprints = builder.blueprints(seed: seed, picks: picks, dualMega: dualMega)
        // Not every seed can support a second Mega — a Trick Room plan built
        // around a slow wall often cannot. Say so rather than returning nothing.
        if dualMega && blueprints.isEmpty {
            blueprints = builder.blueprints(seed: seed, picks: picks)
            fellBack = !blueprints.isEmpty
        }
        expanded = blueprints.first?.id
        working = false
    }

    @ViewBuilder private var content: some View {
        if blueprints.isEmpty {
            intro
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if fellBack {
                    Label("No two-Mega six held together around this Pokémon, so these are single-Mega builds.",
                          systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.warn)
                }
                ForEach(blueprints) { blueprint in
                    card(blueprint)
                }
                methodology
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            EmptyHint(symbol: "square.stack.3d.up",
                      title: "Pick something to build around",
                      detail: "Every plan the Pokémon can support gets a complete six, scored against the bundled meta archetypes and checked for the roles a doubles team needs.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Or start from one of these")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                    ForEach(store.newMegas) { form in
                        Button {
                            seedID = form.id
                            generate()
                        } label: {
                            HStack(spacing: 8) {
                                SpriteImage(form: form, side: 30)
                                Text(form.formLabel)
                                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Palette.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.bottom, 40)
        }
    }

    // MARK: One blueprint

    private func card(_ blueprint: Blueprint) -> some View {
        let isOpen = expanded == blueprint.id
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header(blueprint, isOpen: isOpen)
                if isOpen {
                    Divider()
                    breakdown(blueprint)
                    members(blueprint)
                    if blueprint.isDualMega { linesCard(blueprint) }
                    GamePlanCard(team: blueprint.team, format: format,
                                 precomputed: blueprint.answers)
                    archetypeRow(blueprint)
                    if !blueprint.notes.isEmpty {
                        Text(blueprint.notes.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.warn)
                    }
                    HStack {
                        Button("Save as team") { save(blueprint) }
                        Button("Copy as text") { copy(blueprint) }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded = isOpen ? nil : blueprint.id }
    }

    private func header(_ blueprint: Blueprint, isOpen: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Palette.hairline, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(blueprint.score.total) / 100)
                    .stroke(Palette.grade(blueprint.score.total),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(blueprint.score.total)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(blueprint.plan.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                Text(blueprint.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(isOpen ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
            }

            Spacer(minLength: 8)

            HStack(spacing: 3) {
                ForEach(blueprint.team.slots) { slot in
                    if let form = slot.form(in: store) {
                        SpriteImage(form: form, side: 30)
                    }
                }
            }
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func breakdown(_ blueprint: Blueprint) -> some View {
        HStack(spacing: 14) {
            component("Matchup", (blueprint.score.matchup + 100) / 200,
                      label: String(format: "%+.0f", blueprint.score.matchup))
            component("Roles", blueprint.score.roles,
                      label: "\(Int(blueprint.score.roles * 5))/5")
            component("Defence", blueprint.score.defence)
            component("Coverage", blueprint.score.coverage,
                      label: "\(Int(blueprint.score.coverage * 18))/18")
            component("Synergy", blueprint.score.synergy)
            component("Disruption", blueprint.score.disruption)
        }
    }

    private func component(_ name: String, _ value: Double, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name.uppercased())
                .font(.system(size: 9, weight: .semibold)).kerning(0.4)
                .foregroundStyle(.tertiary)
            Text(label ?? String(format: "%.0f%%", value * 100))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule().fill(Palette.grade(Int(value * 100)))
                        .frame(width: geo.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func members(_ blueprint: Blueprint) -> some View {
        VStack(spacing: 4) {
            ForEach(blueprint.team.slots) { slot in
                if let form = slot.form(in: store) {
                    HStack(spacing: 8) {
                        SpriteImage(form: form, side: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(form.formLabel)
                                    .font(.system(size: 12, weight: .medium))
                                ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                            }
                            Text("\(slot.ability) · \(slot.item) · \(slot.alignmentName)")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text(slot.moves.compactMap { store.move($0)?.name }
                                .joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: The two ways to play it

    private func linesCard(_ blueprint: Blueprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "How to play it",
                          subtitle: "Only one Pokémon may Mega Evolve, and you bring four of six — so each Mega has its own four.")
            HStack(alignment: .top, spacing: 10) {
                ForEach(blueprint.lines) { line in
                    lineCard(line)
                }
            }
        }
    }

    private func lineCard(_ line: BattlePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(line.isPrimary ? "PRIMARY" : "ALTERNATE")
                    .font(.system(size: 9, weight: .bold)).kerning(0.5)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((line.isPrimary ? Palette.accent : Palette.dim).opacity(0.18))
                    .foregroundStyle(line.isPrimary ? Palette.accent : Palette.dim)
                    .clipShape(Capsule())
                Spacer()
                Text(line.edge > 0 ? "+\(line.edge)" : "\(line.edge)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.grade((line.edge + 100) / 2))
            }

            HStack(spacing: 5) {
                SpriteImage(form: line.mega, side: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.mega.formLabel)
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 3) {
                        ForEach(line.mega.pokeTypes) { TypeChip(type: $0, size: .small) }
                    }
                }
            }

            // The four to bring, in lead order — the front two first.
            HStack(spacing: 4) {
                ForEach(Array(line.bring.enumerated()), id: \.element.id) { position, slot in
                    if let form = slot.battleForm(in: store) {
                        VStack(spacing: 2) {
                            SpriteImage(form: form, side: 28)
                            Text(position < 2 ? "lead" : "back")
                                .font(.system(size: 8))
                                .foregroundStyle(position < 2 ? Palette.accent : Palette.dim)
                        }
                        .help(form.formLabel)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(line.strategy)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !line.bestInto.isEmpty {
                Text("Best into " + line.bestInto.prefix(3).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.good)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            line.isPrimary ? Palette.accent.opacity(0.4) : Palette.hairline))
    }

    private func archetypeRow(_ blueprint: Blueprint) -> some View {
        HStack(spacing: 6) {
            ForEach(blueprint.perArchetype, id: \.name) { entry in
                VStack(spacing: 1) {
                    Text(entry.edge > 0 ? "+\(entry.edge)" : "\(entry.edge)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(entry.edge >= 8 ? Palette.good
                                         : (entry.edge <= -8 ? Palette.bad : Palette.dim))
                    Text(entry.name)
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var methodology: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("How these are scored")
                    .font(.system(size: 12, weight: .semibold))
                Text("Each plan is searched separately and the six are scored on six things: the average edge against the bundled meta archetypes, how many of the five essential doubles roles are filled, whether any type weakness is stacked, how many attacking types are represented, whether the plan hangs together — an enabler with nothing that benefits is marked down — and how much of what the format is actually doing the team can turn off.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Disruption is weighted by measured usage, not by how clever an answer sounds. Priority is on 60% of teams and Intimidate on 46%, so carrying an answer to those counts for far more than an answer to something nobody is running. Matchups themselves are run across the terrain and weather the format actually puts up rather than on an empty field — Grassy Terrain is up in roughly a third of games, and a pick that only works with no terrain is not a pick.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The matchup half is deliberately not the whole score. Scored purely on one-on-one trades this engine recommends cutting Whimsicott, because a trade model cannot see that Tailwind doubles the whole side's Speed. Matchups here are run with your own speed control switched on, and roles are scored separately on top.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A two-Mega six is scored on whether the second Mega answers what the first cannot — types it resists that the first does not, one physical and one special, a real Speed gap. Two Megas weak to the same thing is one Mega and a dead slot. Each Mega\'s four is then chosen by running every combination of it plus three partners against the bundled archetypes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Move choice is priced on what a move is worth, not its base power: accuracy counts twice, once as expected value and once as a preference for consistency, and recoil, crash damage, self-inflicted damage and stat drops are all charged against it.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Suggested spreads are sensible defaults, not tuned benchmarks — the builder does not know what you specifically need to outrun or survive.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func save(_ blueprint: Blueprint) {
        var team = blueprint.team
        team.id = UUID()
        team.notes = "\(blueprint.plan.rawValue). \(blueprint.rationale)\n\nGenerated by the builder, score \(blueprint.score.total)/100."
        store.save(team)
    }

    private func copy(_ blueprint: Blueprint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TeamPaste.export(blueprint.team, store: store), forType: .string)
    }
}
