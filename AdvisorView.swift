//  AdvisorView.swift
//  The assisted builder: what the team is trying to do, what it is missing,
//  and what to add next — with the additions one click away.

import SwiftUI

struct AdvisorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    let team: Team
    /// nil when the team is locked; the view then explains rather than offering.
    let onAdd: ((Form) -> Void)?

    @State private var picks: [Forecast.Pick] = []

    private var advisor: TeamAdvisor { TeamAdvisor(team: team, store: store) }

    var body: some View {
        Group {
            if team.slots.isEmpty {
                emptyState
            } else if snapshotMode {
                content
            } else {
                ScrollView { content }
            }
        }
        .onAppear {
            // The pick ranking is ~350 candidates against the field; compute it
            // once and hold it rather than re-running it inside a body.
            if picks.isEmpty {
                picks = Forecast(store: store, format: team.format).picks(limit: 400)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyHint(symbol: "wand.and.stars",
                      title: "Start with one Pokémon",
                      detail: "Add anything you want to build around and this will read the plan off it — the archetype, the roles you still need, and what fits.")
            if onAdd != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Common starting points")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                        ForEach(starters) { entry in
                            if let form = store.form(named: entry.name) {
                                Button { onAdd?(form) } label: {
                                    HStack(spacing: 8) {
                                        SpriteImage(form: form, side: 30)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(form.formLabel)
                                                .font(.system(size: 11, weight: .medium))
                                            Text(entry.role)
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                        }
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
                }
                .frame(maxWidth: 620)
                .padding(.bottom, 30)
            }
        }
    }

    /// The highest-usage entries, which are where most teams actually start.
    private var starters: [UsageEntry] {
        store.data.usage
            .filter { $0.formats.contains(team.format) && !$0.isProjected }
            .sorted { $0.usage > $1.usage }
            .prefix(6)
            .map { $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            planCard
            rolesCard
            Card { GamePlanCard(team: team, format: team.format) }
            formatCard
            metaCard
            recommendationsCard
            prescriptionsCard
        }
        .padding(20)
    }

    // MARK: What the format does to this team

    /// The other half of building a team: not what it does, but what it stops
    /// the field from doing. Weighted by measured usage, so the gaps listed
    /// first are the ones you will actually meet.
    private var formatCard: some View {
        let meta = MetaModel(store: store, format: team.format)
        let coverage = meta.coverage(of: team)
        let control = meta.fieldControl(of: team)
        let gaps = coverage.filter { !$0.isAnswered }.sorted { $0.share > $1.share }

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Against the format",
                    subtitle: "What the field is trying to do, and whether this team can turn it off.")

                ForEach(coverage.sorted { $0.share > $1.share }) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.isAnswered ? "checkmark.circle.fill"
                                                           : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.isAnswered ? Palette.good
                                             : (entry.share >= 0.35 ? Palette.bad : Palette.warn))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(entry.pressure).font(.system(size: 12, weight: .medium))
                                Text(String(format: "%.0f%% of teams", entry.share * 100))
                                    .font(.system(size: 10, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            if entry.isAnswered {
                                Text(entry.providers.prefix(3)
                                        .map { "\($0.form.formLabel) — \($0.how)" }
                                        .joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(entry.advice)
                                    .font(.system(size: 10)).foregroundStyle(Palette.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !entry.couldAnswer.isEmpty {
                                    // The cheapest fix on the board: a move slot,
                                    // not a new Pokémon.
                                    Text("One move slot away — " + entry.couldAnswer.prefix(2)
                                            .map { "\($0.form.formLabel) \($0.how)" }
                                            .joined(separator: ", "))
                                        .font(.system(size: 10)).foregroundStyle(Palette.accent)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                if !control.isEmpty {
                    Divider()
                    Text("FIELD CONTROL").font(.system(size: 9, weight: .bold)).kerning(0.5)
                        .foregroundStyle(.tertiary)
                    ForEach(control, id: \.pressure.id) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.isSelected ? "checkmark.circle.fill"
                                  : (entry.answer != nil ? "circle.dashed" : "minus.circle"))
                                .font(.system(size: 11))
                                .foregroundStyle(entry.isSelected ? Palette.good
                                                 : (entry.answer != nil ? Palette.accent : Palette.dim))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(entry.pressure.label)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(String(format: "up in ~%.0f%% of games",
                                                entry.pressure.probability * 100))
                                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                                Text(entry.answer
                                     ?? "Nothing here changes it — you play the whole game under theirs.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(entry.isSelected ? Color.secondary
                                                     : (entry.answer != nil ? Palette.accent : Color.secondary))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                if let worst = gaps.first, worst.share >= 0.3 {
                    Text("The biggest hole is \(worst.pressure), which \(Int(worst.share * 100))% of teams run. \(worst.advice)")
                        .font(.system(size: 11)).foregroundStyle(Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Plan

    private var planCard: some View {
        let detected = advisor.archetypes
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "The plan",
                              subtitle: "Read off the abilities and moves actually on the team.")
                ForEach(detected) { plan in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(plan.archetype.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Palette.accent.opacity(0.18))
                                .foregroundStyle(Palette.accent)
                                .clipShape(Capsule())
                            if !plan.enabledBy.isEmpty {
                                Text("via " + plan.enabledBy.map(\.formLabel).joined(separator: ", "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !plan.enabledBy.isEmpty && !plan.isSupported {
                                Label("nothing benefits", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.warn)
                            }
                        }
                        Text(plan.archetype.advice)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !plan.payoff.isEmpty {
                            HStack(spacing: 4) {
                                Text("benefits:").font(.system(size: 10)).foregroundStyle(.tertiary)
                                ForEach(plan.payoff) { SpriteImage(form: $0, side: 22) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Roles

    private var rolesCard: some View {
        let held = advisor.rolesPresent
        let missing = advisor.missingEssentials
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Roles",
                              subtitle: "Bold are the five a doubles team nearly always wants.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                    ForEach(TeamRole.allCases) { role in
                        let forms = held[role] ?? []
                        let essential = TeamRole.essentials.contains(role)
                        let lacking = essential && forms.isEmpty
                        HStack(spacing: 6) {
                            Image(systemName: forms.isEmpty
                                  ? (essential ? "xmark.circle.fill" : "circle")
                                  : "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(forms.isEmpty
                                                 ? (essential ? Palette.bad : Palette.fainter)
                                                 : Palette.good)
                            Text(role.rawValue)
                                .font(.system(size: 11,
                                              weight: essential ? .semibold : .regular))
                                .foregroundStyle(forms.isEmpty && !essential
                                                 ? Palette.fainter : Palette.normal)
                            Spacer(minLength: 0)
                            ForEach(forms.prefix(3)) { SpriteImage(form: $0, side: 20) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(lacking ? Palette.bad.opacity(0.10) : Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(role.blurb)
                    }
                }
                if !missing.isEmpty {
                    Text("Missing: " + missing.map(\.rawValue).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.bad)
                }
            }
        }
    }

    // MARK: M-C checks

    private var metaCard: some View {
        let notes = advisor.metaNotes
        return Group {
            if !notes.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Regulation M-C checks",
                                      subtitle: "Megas, terrain and the contact tax — what this regulation changed.")
                        ForEach(notes) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: symbol(note.severity))
                                    .font(.system(size: 12))
                                    .foregroundStyle(colour(note.severity))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(note.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func symbol(_ severity: TeamAdvisor.Note.Severity) -> String {
        switch severity {
        case .problem: return "xmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .good:    return "checkmark.circle.fill"
        }
    }

    private func colour(_ severity: TeamAdvisor.Note.Severity) -> Color {
        switch severity {
        case .problem: return Palette.bad
        case .caution: return Palette.warn
        case .good:    return Palette.good
        }
    }

    // MARK: Recommendations

    private var recommendationsCard: some View {
        let recommendations = advisor.recommendations(limit: 10, picks: picks)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Add next",
                    subtitle: onAdd == nil
                    ? "Unlock the team to add any of these."
                    : "Ranked on the roles you lack first, then what you are weak to, then quality.")
                if recommendations.isEmpty {
                    Text("Nothing scores well enough to suggest — the team is not obviously missing anything.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                ForEach(recommendations) { recommendation in
                    HStack(spacing: 10) {
                        SpriteImage(form: recommendation.form, side: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(recommendation.form.formLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                ForEach(recommendation.form.pokeTypes) {
                                    TypeChip(type: $0, size: .small)
                                }
                            }
                            if !recommendation.headline.isEmpty {
                                Text(recommendation.headline)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.accent)
                            }
                            if !recommendation.answers.isEmpty {
                                Text("Beats " + recommendation.answers.joined(separator: ", "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let onAdd {
                            Button("Add") { onAdd(recommendation.form) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Prescriptions

    private var prescriptionsCard: some View {
        let prescriptions = advisor.prescriptions(picks: picks)
        return Group {
            if !prescriptions.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "How to fix it",
                                      subtitle: "Each problem with named options from the M-C roster.")
                        ForEach(prescriptions) { prescription in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(prescription.problem)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.bad)
                                Text(prescription.fix)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !prescription.options.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(prescription.options) { form in
                                            Button { onAdd?(form) } label: {
                                                HStack(spacing: 4) {
                                                    SpriteImage(form: form, side: 22)
                                                    Text(form.formLabel)
                                                        .font(.system(size: 10))
                                                        .lineLimit(1)
                                                }
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(Palette.surfaceRaised)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(onAdd == nil)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }
}
