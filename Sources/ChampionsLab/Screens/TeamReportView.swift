//  TeamReportView.swift
//  Everything that can be said about a team without playing it.
//
//  This was three tabs — Assist, Analysis and Threats — and they were three
//  answers to one question. A grade is an opinion about what beats the team; a
//  threat list is the evidence for that opinion; a prescription is what to do
//  about it. Splitting them meant reading the verdict on one screen, the
//  evidence on another and the fix on a third, with no way to hold any two of
//  them side by side.
//
//  So it reads in the order somebody actually wants it: how good is this team,
//  then what beats it, then what to do about that. One scroll, and the section
//  headers are the navigation.
//
//  What went in the bin on the way. Three separate cards recommended Pokémon to
//  add — "Add next", "How to fix it" and "Would patch this team". The third was
//  a strict subset of the other two and was the only one you could not click to
//  actually add anything, so it is gone rather than moved.
//
//  The field picker used to belong to the Threats tab alone, which was odd: a
//  defensive matrix and a speed tier are both read differently under rain, and
//  only one screen let you say so. It now governs the whole report.

import SwiftUI

struct TeamReportView: View {
    let team: Team
    /// nil when the team is locked; the advice then explains rather than offers.
    let onAdd: ((Form) -> Void)?
    var onReplace: ((Team) -> Void)? = nil

    @EnvironmentObject private var store: Store
    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none
    @Environment(\.snapshotMode) private var snapshotMode

    private var field: Field {
        Field(weather: weather, terrain: terrain, isDoubles: team.isDoubles)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !team.slots.isEmpty {
                picker
                Divider()
            }
            if snapshotMode { content } else { ScrollView { content } }
        }
    }

    private var picker: some View {
        HStack(spacing: 10) {
            Text("Read it under")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: $weather) {
                ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 110).controlSize(.small)
            Picker("", selection: $terrain) {
                ForEach(Terrain.allCases) { Text($0.rawValue + " Terrain").tag($0) }
            }.labelsHidden().frame(width: 150).controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if team.slots.isEmpty {
            EmptyHint(symbol: "chart.bar.doc.horizontal",
                      title: "Add Pokémon to analyse",
                      detail: "The grade weighs each threat by its usage, so losing to "
                            + "Garchomp costs more than losing to Pincurchin.")
                .frame(height: 320)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                // How good is it.
                TeamAnalysisView(team: team, onReplace: onReplace, field: field, embedded: true)
                // What beats it.
                Card { ThreatsCard(team: team, field: field) }
                    .padding(.horizontal, 20)
                // What to do about it.
                AdvisorView(team: team, onAdd: onAdd, onReplace: onReplace, embedded: true)
            }
            .padding(.vertical, 2)
        }
    }
}
