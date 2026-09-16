//  TeamAnalysisView.swift
//  The verdict on a team: grade, holes, coverage, speed, and what to add.

import SwiftUI

struct TeamAnalysisView: View {
    @EnvironmentObject private var store: Store
    let team: Team
    /// Hand back a team with a planned spread applied, when the screen that
    /// owns the team can save it.
    var onReplace: ((Team) -> Void)? = nil
    /// The field to read the grade under, when the report's picker is driving.
    ///
    /// Deliberately not applied to `ownField`: that is the weather the team
    /// sets for *itself*, and a spread is planned against it whatever the
    /// reader is currently looking at the grade through.
    var field: Field?
    /// Rendered inside another screen's scroller, so it must not bring its own.
    var embedded = false

    @State private var spreads: [Int: SpreadPlanner.Plan] = [:]
    @State private var planning = false

    private var analysis: TeamAnalysis { TeamAnalysis(team: team, store: store) }

    /// The field this team puts up itself, so a rain team's benchmarks are
    /// judged in rain.
    private var ownField: Field {
        var out = Field(isDoubles: team.isDoubles)
        for slot in team.slots {
            let ability = slot.megaEvolution(in: store.rulebook)?.abilities.first?.name
                ?? (slot.ability.isEmpty
                    ? slot.battleForm(in: store.rulebook)?.abilities.first?.name ?? "" : slot.ability)
            switch ability {
            case "Drought":        out.weather = .sun
            case "Drizzle":        out.weather = .rain
            case "Sand Stream":    out.weather = .sand
            case "Snow Warning":   out.weather = .snow
            case "Electric Surge": out.terrain = .electric
            case "Grassy Surge":   out.terrain = .grassy
            case "Misty Surge":    out.terrain = .misty
            case "Psychic Surge":  out.terrain = .psychic
            default: break
            }
        }
        return out
    }

    /// Stat Points planned against the numbers the format presents, rather than
    /// poured into two stats out of habit.
    ///
    /// Worked out on demand rather than as the screen draws: each Pokémon is
    /// about twenty milliseconds, which is nothing to ask for and too much to
    /// spend on every redraw of six of them.
    private var spreadCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Spreads",
                    subtitle: "What 66 points buy against the numbers people actually bring",
                    accessory: AnyView(
                        Button(planning ? "Working…" : "Plan spreads") { planSpreads() }
                            .controlSize(.small)
                            .disabled(planning || team.slots.isEmpty)))

                if spreads.isEmpty {
                    Text("A spread is a set of thresholds — outspeed this, survive that — and below a threshold the points bought nothing. This works out the cheapest way to clear the ones worth clearing and puts the rest into attack.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(team.slots.indices, id: \.self) { index in
                        if let plan = spreads[index],
                           let form = team.slots[index].battleForm(in: store.rulebook) {
                            spreadRow(index: index, form: form, plan: plan)
                            if index != team.slots.indices.last { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func spreadRow(index: Int, form: Form,
                           plan: SpreadPlanner.Plan) -> some View {
        let current = team.slots[index]
        let same = current.sp == plan.sp && current.alignmentName == plan.alignment.name
        let spelled = Stat.allCases
            .filter { plan.sp[$0.rawValue] > 0 }
            .map { "\($0.short) \(plan.sp[$0.rawValue])" }
            .joined(separator: " / ")
        return HStack(alignment: .top, spacing: 10) {
            SpriteImage(form: form, side: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(form.formLabel).font(.system(size: 12, weight: .medium))
                    Text("\(plan.alignment.name) · \(spelled)")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(String(format: "clears %.0f%%", plan.cover * 100))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.grade(Int(plan.cover * 100)).opacity(0.18))
                        .foregroundStyle(Palette.grade(Int(plan.cover * 100)))
                        .clipShape(Capsule())
                }
                ForEach(plan.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let onReplace, !same {
                Button("Apply") {
                    var updated = team
                    updated.slots[index].sp = plan.sp
                    updated.slots[index].alignmentName = plan.alignment.name
                    onReplace(updated)
                }
                .controlSize(.small)
            } else if same {
                Text("in use").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func planSpreads() {
        planning = true
        Task { @MainActor in
            var planner = SpreadPlanner(store: store, format: team.format)
            planner.field = ownField
            var made: [Int: SpreadPlanner.Plan] = [:]
            let advisor = TeamAdvisor(team: team, store: store)
            // What the team's own games found beating each of these Pokémon.
            // Nil until it has been simulated, and then the spread is built
            // against the Pokémon that are actually taking it off the field
            // rather than against the ladder average.
            let record = store.measured(for: team)
            for index in team.slots.indices {
                guard let form = team.slots[index].battleForm(in: store.rulebook) else { continue }
                await breathe("spread")
                let roles = advisor.potentialRoles(of: form)
                // A redirection or speed-control slot is not spending points on
                // an attacking stat, so it is not planned as though it were.
                let support = roles.contains(.redirection) || roles.contains(.tailwind)
                    || roles.contains(.trickRoom)
                planner.measured = record?.pressure(on: SelfPlay.recordLabel(form)) ?? [:]
                made[index] = planner.plan(for: form,
                                           ability: team.slots[index].ability,
                                           item: team.slots[index].item,
                                           attacker: !support)
            }
            spreads = made
            planning = false
        }
    }

    @Environment(\.snapshotMode) private var snapshotMode

    @ViewBuilder var body: some View {
        if snapshotMode || embedded { content } else { ScrollView { content } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
                if team.slots.isEmpty {
                    EmptyHint(symbol: "chart.bar.doc.horizontal",
                              title: "Add Pokémon to analyse",
                              detail: "The grade weighs each threat by its usage, so losing to Garchomp costs more than losing to Pincurchin.")
                        .frame(height: 300)
                } else {
                    gradeCard
                    spreadCard
                    defensiveCard
                    coverageCard
                    speedCard
                }
        }
        .padding(20)
    }

    private var gradeCard: some View {
        let grade = analysis.grade(field: field ?? Field(isDoubles: team.isDoubles))
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(Palette.hairline, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(grade.score) / 100)
                            .stroke(Palette.grade(grade.score),
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(grade.score)")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("/100").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 84, height: 84)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(grade.headline)
                            .font(.system(size: 15, weight: .semibold))
                        Text("Scored against the \(store.data.usage.count) tracked threats, weighted by usage.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                if !grade.strengths.isEmpty || !grade.problems.isEmpty {
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Working", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.good)
                            ForEach(grade.strengths, id: \.self) { text in
                                Text("• " + text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            Label("Exposed", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.bad)
                            ForEach(grade.problems, id: \.self) { text in
                                Text("• " + text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var defensiveCard: some View {
        let exposures = analysis.exposures
        let members = team.slots.compactMap { $0.form(in: store.rulebook) }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Defensive matrix",
                              subtitle: "Rows are attacking types. Red columns are where this team folds.")
                MaybeHScroll(active: !snapshotMode) {
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            Color.clear.frame(width: 74, height: 20)
                            ForEach(members) { form in
                                SpriteImage(form: form, side: 28)
                                    .frame(width: 40)
                                    .help(form.formLabel)
                            }
                            Text("Σ").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary).frame(width: 34)
                        }
                        ForEach(exposures) { exposure in
                            HStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    TypeIcon(type: exposure.type, side: 16)
                                    Text(exposure.type.rawValue)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 74, alignment: .leading)

                                ForEach(Array(exposure.multipliers.enumerated()), id: \.offset) { _, value in
                                    Text(TypeChart.label(value))
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .frame(width: 40, height: 20)
                                        .background(TypeChart.color(value).opacity(value == 1 ? 0.08 : 0.30))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                Text(exposure.weakCount > 0 ? "\(exposure.weakCount)w" : "—")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(exposure.isSoft ? Palette.bad : Palette.fainter)
                                    .frame(width: 34)
                            }
                        }
                    }
                }
            }
        }
    }

    private var coverageCard: some View {
        let coverage = analysis.coverage
        let missing = coverage.filter { $0.carriers.isEmpty }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Offensive coverage",
                              subtitle: "\(18 - missing.count) of 18 attacking types on the team.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    ForEach(coverage) { entry in
                        HStack(spacing: 5) {
                            TypeIcon(type: entry.type, side: 18)
                            Text(entry.carriers.isEmpty ? "—" : "\(entry.carriers.count)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(entry.carriers.isEmpty
                                    ? Palette.hairline
                                    : entry.type.color.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(entry.carriers.isEmpty
                              ? "No \(entry.type.rawValue) attack on this team"
                              : entry.carriers.joined(separator: ", "))
                    }
                }

                let uncovered = analysis.uncoveredThreats
                if !uncovered.isEmpty {
                    Text("Nothing on this team hits these neutrally: "
                         + uncovered.prefix(6).map(\.formLabel).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var speedCard: some View {
        let rows = analysis.speedTiers
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Speed tiers",
                              subtitle: "Your builds against the field at maximum investment.")
                ForEach(rows.prefix(26)) { row in
                    HStack(spacing: 8) {
                        Text("\(row.speed)")
                            .font(.system(size: 12, weight: row.isTeam ? .bold : .regular,
                                          design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(row.isTeam ? Palette.accent : Palette.dim)
                        GeometryReader { geo in
                            Capsule()
                                .fill(row.isTeam ? Palette.accent : Palette.hairline)
                                .frame(width: geo.size.width * min(1, Double(row.speed) / 250))
                        }
                        .frame(height: 5)
                        Text(row.name)
                            .font(.system(size: 11, weight: row.isTeam ? .semibold : .regular))
                            .foregroundStyle(row.isTeam ? Palette.normal : Palette.dim)
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

}

// MARK: - Threat matrix

/// The threat list on its own, so the report can carry it without the picker
/// and the scroller that the standalone screen needed.
///
/// It used to be a tab of its own. It is evidence for the grade rather than a
/// separate question — "what beats this team" is the same enquiry as "how good
/// is this team" — so it now sits under them.
struct ThreatsCard: View {
    @EnvironmentObject private var store: Store
    let team: Team
    let field: Field
    /// How many to show before the reader asks for the rest.
    ///
    /// The whole list is forty rows and it used to have a tab to itself. Inside
    /// a report it is the longest thing on the page by a distance, and the
    /// bottom two thirds of it is the part you already beat — so the ones that
    /// beat you are shown and the rest is a click away.
    var shortlist = 10
    @State private var all = false
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        let rows = TeamAnalysis(team: team, store: store).threats(field: field)
        let shown = (all || snapshotMode) ? rows : Array(rows.prefix(shortlist))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SectionHeader(title: "What beats it",
                              subtitle: "Every threat the format actually brings, worst first, "
                                      + "weighed by how often people bring it.")
                Spacer(minLength: 8)
                if rows.count > shortlist, !snapshotMode {
                    Button(all ? "Show the worst \(shortlist)"
                               : "Show all \(rows.count)") { all.toggle() }
                        .controlSize(.small)
                }
            }
            ForEach(shown) { row in ThreatRow(assessment: row) }
            if !all, rows.count > shown.count, !snapshotMode {
                Text("\(rows.count - shown.count) more, and this team already handles them.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ThreatMatrixView: View {
    @EnvironmentObject private var store: Store
    let team: Team

    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none

    private var field: Field {
        Field(weather: weather, terrain: terrain, isDoubles: team.isDoubles)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Field").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $weather) {
                    ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 110).controlSize(.small)
                Picker("", selection: $terrain) {
                    ForEach(Terrain.allCases) { Text($0.rawValue + " Terrain").tag($0) }
                }.labelsHidden().frame(width: 150).controlSize(.small)
                Spacer()
            }
            .padding(12)
            Divider()

            if team.slots.isEmpty {
                EmptyHint(symbol: "shield.lefthalf.filled", title: "Add Pokémon first")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(TeamAnalysis(team: team, store: store).threats(field: field)) { row in
                            ThreatRow(assessment: row)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct ThreatRow: View {
    @EnvironmentObject private var store: Store
    let assessment: ThreatAssessment

    private var verdictColor: Color {
        switch assessment.verdict {
        case .favourable: return Palette.good
        case .even:       return Palette.accent
        case .shaky:      return Palette.warn
        case .losing:     return Palette.bad
        }
    }

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 12) {
                if let form = assessment.form {
                    SpriteImage(form: form, side: 40)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.quaternary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(assessment.threat.name)
                            .font(.system(size: 13, weight: .semibold))
                        TierBadge(tier: assessment.threat.tier)
                        if assessment.threat.isProjected {
                            Text("projected")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        if assessment.form == nil {
                            Text("not in dex yet")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.warn)
                        }
                    }
                    Text(assessment.threat.role)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if !assessment.checkedBy.isEmpty {
                        Text("Checked by " + assessment.checkedBy.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.good)
                    }
                    if !assessment.losesTo.isEmpty {
                        Text("Loses: " + assessment.losesTo.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.bad)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(assessment.verdict.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(verdictColor.opacity(0.20))
                        .foregroundStyle(verdictColor)
                        .clipShape(Capsule())
                    Text(String(format: "you %.0f%% · them %.0f%%",
                                assessment.bestOutgoing * 100, assessment.worstIncoming * 100))
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text("\(assessment.outspeedsCount) outspeed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}


/// A horizontal ScrollView, except while snapshotting — ImageRenderer renders
/// scroll content as blank, and the matrix is the whole point of that card.
struct MaybeHScroll<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if active {
            ScrollView(.horizontal, showsIndicators: false) { content }
        } else {
            content
        }
    }
}
