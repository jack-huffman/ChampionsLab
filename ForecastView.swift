//  ForecastView.swift
//  Format predictions and anti-meta picks.
//
//  Two halves, kept visibly separate. The computed half — attacking types,
//  speed, the pick ranking — falls out of the dataset and the damage calculator.
//  The written half is judgement, and each card says which it is.

import SwiftUI

struct ForecastView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    @State private var format = "doubles"
    @State private var report: Forecast.Report?
    @State private var showMegas = true

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if snapshotMode { content } else { ScrollView { content } }
        }
        .onAppear(perform: recompute)
        .onChange(of: format) { _ in recompute() }
        // A live usage refresh changes the field these are computed against.
        .onChange(of: store.usageVersion) { _ in recompute() }
    }

    /// Computed once per format change and held, never recomputed in a body:
    /// it is ~350 candidates against 30 threats.
    private func recompute() {
        report = Forecast(store: store, format: format).report()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $format) {
                ForEach(store.data.rules.formats) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            Toggle("Include Megas", isOn: $showMegas)
                .toggleStyle(.checkbox).controlSize(.small)
            Spacer()
            if let report {
                Text("\(report.measuredCount) measured · \(report.projectedCount) projected")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if let report {
            VStack(alignment: .leading, spacing: 20) {
                caveat(report)
                fieldCard(report)
                tacticsCard(report)
                typeLandscape(report)
                speedCard(report)
                picksCard(report)
                predictionsCard
            }
            .padding(24)
        } else {
            EmptyHint(symbol: "chart.line.uptrend.xyaxis", title: "Working it out…")
                .frame(height: 300)
        }
    }

    // MARK: Caveat

    private func caveat(_ report: Forecast.Report) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Format forecast")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(store.data.regulation.id)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.18))
                        .foregroundStyle(Palette.accent)
                        .clipShape(Capsule())
                }
                Text(report.projectedCount == 0
                     ? "Everything below the written predictions is computed from the dataset. The field is real measured Regulation M-C ladder usage, so the weights are no longer assumptions — the type numbers are arithmetic over that table and the picks come from the damage calculator run against every legal form."
                     : "Everything below the written predictions is computed from the dataset — the type numbers are arithmetic over the usage table, and the picks come from the damage calculator run against every legal form. What is soft is the field itself: \(report.projectedCount) of the \(report.fieldSize) tracked threats have no measured usage yet and carry an assumed weight. Treat the ordering as an argument and the arithmetic as fact.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: What the field is actually doing

    private func fieldCard(_ report: Forecast.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "The field you are actually playing on",
                          subtitle: "Who sets what, how often, and what it does to the moves people are clicking.")
            if report.fieldPressures.isEmpty {
                Card(padding: 14) {
                    Text("No terrain or weather setter has measurable usage in this format, so the field is neutral.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(report.fieldPressures) { pressure in
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text(pressure.label)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(String(format: "up in ~%.0f%% of games", pressure.probability * 100))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Palette.accent.opacity(0.16))
                                    .foregroundStyle(Palette.accent)
                                    .clipShape(Capsule())
                                Spacer()
                                Text("set by " + pressure.setters.prefix(3)
                                        .map { String(format: "%@ %.0f%%", $0.name, $0.value * 100) }
                                        .joined(separator: ", "))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.hairline)
                                    Capsule().fill(Palette.accent.opacity(0.6))
                                        .frame(width: geo.size.width * min(1, pressure.probability))
                                }
                            }
                            .frame(height: 5)
                            ForEach(pressure.consequences, id: \.self) { line in
                                Text("· " + line)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text("Anti-meta picks below are scored across these states — "
                     + report.states.map { String(format: "%@ %.0f%%", $0.label, $0.weight * 100) }
                        .joined(separator: ", ")
                     + " — rather than on an empty field, because that is not the game being played.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: What the field is trying to do to you

    private func tacticsCard(_ report: Forecast.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "How the format wants to win",
                          subtitle: "Measured from the sets people are running, with what turns each one off.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(report.tactics) { tactic in
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(tactic.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(String(format: "%.0f%%", tactic.share * 100))
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(tactic.share >= 0.4 ? Palette.bad
                                                     : (tactic.share >= 0.2 ? Palette.warn : Palette.dim))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.hairline)
                                    Capsule()
                                        .fill(tactic.share >= 0.4 ? Palette.bad : Palette.warn)
                                        .frame(width: geo.size.width * min(1, tactic.share))
                                }
                            }
                            .frame(height: 4)
                            HStack(spacing: 4) {
                                ForEach(tactic.carriers.prefix(5)) { carrier in
                                    if let form = store.form(named: carrier.name) {
                                        SpriteImage(form: form, side: 24)
                                            .help(String(format: "%@ · %.0f%% of teams",
                                                         carrier.name, carrier.value * 100))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            Text(tactic.effect)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(tactic.answers, id: \.self) { answer in
                                Label(answer, systemImage: "arrow.turn.down.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.good)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Types

    private func typeLandscape(_ report: Forecast.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Attacking type landscape",
                          subtitle: "Average effectiveness into the field, weighted by usage. Above 1.00 means the format is soft to it.")
            HStack(alignment: .top, spacing: 12) {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BEST").font(.system(size: 10, weight: .bold))
                            .kerning(0.5).foregroundStyle(Palette.good)
                        ForEach(report.attackingTypes) { bar($0, best: true) }
                    }
                }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WORST").font(.system(size: 10, weight: .bold))
                            .kerning(0.5).foregroundStyle(Palette.bad)
                        ForEach(report.worstAttackingTypes) { bar($0, best: false) }
                    }
                }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CROWDED TYPES").font(.system(size: 10, weight: .bold))
                            .kerning(0.5).foregroundStyle(.secondary)
                        ForEach(report.typeShare, id: \.type) { share in
                            HStack(spacing: 6) {
                                TypeIcon(type: share.type, side: 18)
                                Text(share.type.rawValue).font(.system(size: 11))
                                Spacer()
                                Text("\(share.count)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bar(_ score: Forecast.TypeScore, best: Bool) -> some View {
        HStack(spacing: 6) {
            TypeIcon(type: score.type, side: 18)
            Text(score.type.rawValue).font(.system(size: 11)).frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(best ? Palette.good : Palette.bad)
                    // 0.6…1.3 is the range these actually occupy.
                    .frame(width: geo.size.width * min(1, max(0.05, (score.value - 0.55) / 0.75)))
            }
            .frame(height: 5)
            Text(String(format: "%.2f", score.value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: Speed

    private func speedCard(_ report: Forecast.Report) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Speed landscape",
                              subtitle: "The field at 32 SP and a boosting alignment — the numbers you have to beat.")
                ForEach(Array(report.speedLandscape.enumerated()), id: \.element.id) { index, mark in
                    let previous = index > 0 ? report.speedLandscape[index - 1].speed : mark.speed
                    let gap = previous - mark.speed
                    VStack(spacing: 2) {
                        if gap >= 12 {
                            HStack(spacing: 6) {
                                Rectangle().fill(Palette.hairline).frame(height: 1)
                                Text("\(gap) point gap")
                                    .font(.system(size: 9)).foregroundStyle(Palette.warn)
                                Rectangle().fill(Palette.hairline).frame(height: 1)
                            }
                            .padding(.vertical, 1)
                        }
                        HStack(spacing: 8) {
                            Text("\(mark.speed)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                            SpriteImage(form: mark.form, side: 22)
                            Text(mark.name).font(.system(size: 11))
                            Spacer()
                            GeometryReader { geo in
                                Capsule().fill(Palette.accent.opacity(0.55))
                                    .frame(width: geo.size.width * min(1, Double(mark.speed) / 230))
                            }
                            .frame(width: 220, height: 5)
                        }
                    }
                }
            }
        }
    }

    // MARK: Picks

    private func picksCard(_ report: Forecast.Report) -> some View {
        let picks = report.picks.filter { showMegas || !$0.form.isMega }.prefix(18)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Anti-meta picks",
                              subtitle: "Every legal form run against the whole field with a standard build, ranked by usage-weighted outcome.")
                ForEach(Array(picks)) { pick in
                    HStack(alignment: .top, spacing: 10) {
                        SpriteImage(form: pick.form, side: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(pick.form.formLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                ForEach(pick.form.pokeTypes) { TypeChip(type: $0, size: .small) }
                            }
                            Text("Beats \(pick.beats.count) of \(pick.fieldSize) · outspeeds \(pick.outspeeds) · best attack \(pick.bestMove)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            if !pick.beats.isEmpty {
                                Text(pick.beats.prefix(6).joined(separator: ", ")
                                     + (pick.beats.count > 6 ? "…" : ""))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.good)
                                    .lineLimit(1)
                            }
                            if !pick.losesTo.isEmpty {
                                Text("Loses to " + pick.losesTo.prefix(4).joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.bad)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(String(format: "%+.2f", pick.score))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Palette.grade(Int((pick.score + 1) * 50)))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.hairline)
                                    Capsule()
                                        .fill(Palette.grade(Int((pick.score + 1) * 50)))
                                        .frame(width: geo.size.width * min(1, max(0, pick.score)))
                                }
                            }
                            .frame(width: 70, height: 4)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.35)
                }
            }
        }
    }

    // MARK: Written calls

    private var predictionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Predictions",
                          subtitle: "Each says whether it is arithmetic or judgement.")
            ForEach(store.data.predictions) { prediction in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(prediction.title)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(prediction.confidence)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(confidenceColour(prediction.confidence).opacity(0.18))
                                .foregroundStyle(confidenceColour(prediction.confidence))
                                .clipShape(Capsule())
                        }
                        Text(prediction.call)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(prediction.why)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(prediction.basis)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func confidenceColour(_ text: String) -> Color {
        switch text.lowercased() {
        case "certain", "high": return Palette.good
        case "medium":          return Palette.warn
        default:                return Palette.dim
        }
    }
}
