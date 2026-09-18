//  NewTeamSheet.swift
//  Where a new team comes from: an empty one, or the ladder.
//
//  Smogon publishes what was played, not the teams themselves -- usage, and
//  for every Pokemon the moves, item, ability and Stat Point spread its sets
//  ran. A team off the ladder is built from that: the Pokemon that are
//  actually brought together, each with the set the ladder gives it. It
//  arrives as a team of yours, unlocked, so the first thing you can do is
//  disagree with it.

import SwiftUI

struct NewTeamSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    /// The team to keep, handed back to the page that asked.
    let onCreate: (Team) -> Void

    private enum Choice { case asking, ladder }
    @State private var choice: Choice = .asking
    @State private var format = "doubles"
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch choice {
            case .asking: asking
            case .ladder: ladder
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 560)
        .sheet(isPresented: $refreshing) { UsageRefreshSheet().environmentObject(store) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(choice == .asking ? "New team" : "From the ladder")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(choice == .asking
                 ? "Start from nothing, or from what the ladder is actually playing."
                 : "Built from the usage table: the Pokemon brought together, each with the moves, item, ability and spread its sets run. Yours to change once it is saved.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    // MARK: - The two ways in

    private var asking: some View {
        HStack(spacing: 14) {
            way(title: "From scratch", detail: "Six empty slots, and the builder's help if you want it.",
                symbol: "square.dashed") {
                var team = Team(name: "Team \(store.teams.count + 1)")
                team.format = format
                onCreate(team)
                dismiss()
            }
            way(title: "From the ladder", detail: "A team the usage table says is being played, set for set.",
                symbol: "chart.bar.doc.horizontal") {
                choice = .ladder
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func way(title: String, detail: String, symbol: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title).font(.system(size: 14, weight: .bold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The ladder

    private var ladder: some View {
        let teams = store.ladderTeams(format: format)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $format) {
                    ForEach(store.data.rules.formats) { rule in
                        Text(rule.name).tag(rule.id)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Spacer()
                Text(store.liveUsage.map { "From \($0.formatName)" }
                     ?? "From the usage table the app shipped with")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Button("Fetch the latest from Smogon") { refreshing = true }
                    .controlSize(.small)
            }
            if teams.isEmpty {
                EmptyHint(symbol: "chart.bar", title: "No ladder teams",
                          detail: "The usage table has too little in it to build one. Fetch the latest from Smogon.")
            } else {
                MaybeScroll {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(Array(teams.enumerated()), id: \.offset) { _, ladder in
                            Button {
                                onCreate(mine(ladder.team))
                                dismiss()
                            } label: {
                                SixCard(name: ladder.team.name,
                                        tag: String(format: "%.0f%% of the field", ladder.weight * 100),
                                        forms: ladder.team.slots.map { $0.battleForm(in: store.rulebook) },
                                        spriteSide: 38)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    /// The ladder's team as one of yours: its own id, its own slots, and
    /// unlocked, because the point of taking it is to change it.
    private func mine(_ team: Team) -> Team {
        var copy = team
        copy.id = UUID()
        copy.locked = false
        copy.format = format
        copy.slots = team.slots.map { slot in
            var new = slot
            new.id = UUID()
            return new
        }
        let taken = Set(store.teams.map(\.name))
        var name = team.name
        var number = 2
        while taken.contains(name) { name = "\(team.name) \(number)"; number += 1 }
        copy.name = name
        return copy
    }

    private var footer: some View {
        HStack {
            if choice == .ladder {
                Button("Back") { choice = .asking }.controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }
}
