//  TeamChooser.swift
//  One side of the lobby being chosen: which of yours, or which of theirs.
//
//  Your saved teams for your side; the published lists and your other teams,
//  with a search, for theirs. It owns nothing but the search text; the choice
//  goes back up to the battle screen, which is what works the lobby out.

import SwiftUI

struct TeamChooser: View {
    enum Side: Identifiable {
        case mine, theirs
        var id: Self { self }
    }

    /// Every six that could stand on this side, with what it is made of.
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let tag: String
        let group: String
        let forms: [Form?]
    }

    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    let side: Side
    let myTeamID: String
    let opponentID: String
    let singles: Bool
    let onChoose: (String) -> Void
    @State private var search = ""

    private var format: String { singles ? "singles" : "doubles" }
    private var chosen: String { side == .mine ? myTeamID : opponentID }
    private var groups: [String] {
        side == .mine ? ["My teams"] : ["Meta archetypes", "Tournament results", "My teams"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                header
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(side == .mine ? "Team or a Pokemon on it" : "Team, player or a Pokemon on it",
                              text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(width: 240)
            }
            if side == .mine, store.teams.isEmpty {
                EmptyHint(symbol: "person.3", title: "No teams yet",
                          detail: "Build one in Teams first.")
            } else if candidates.isEmpty {
                EmptyHint(symbol: "magnifyingglass", title: "Nothing matches",
                          detail: "Try a team's name, a player, or a Pokemon on it.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.self) { group in
                            // A snapshot has no scroll view to put a hundred
                            // tournament teams in, so it shows a handful.
                            let all = candidates.filter { $0.group == group }
                            let rows = snapshotMode ? Array(all.prefix(4)) : all
                            if !rows.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    if groups.count > 1 {
                                        Text(group.uppercased())
                                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                            .foregroundStyle(.tertiary)
                                    }
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                                              alignment: .leading, spacing: 8) {
                                        ForEach(rows) { candidate in
                                            Button { onChoose(candidate.id) } label: {
                                                SixCard(name: candidate.name, tag: candidate.tag,
                                                        forms: candidate.forms,
                                                        selected: candidate.id == chosen)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text((side == .mine ? "Your team" : "Opponent").uppercased())
                    .font(.system(size: 13, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("\(candidates.count)").font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Text(side == .mine ? "One of your saved teams."
                 : "A meta archetype, a real tournament team, or another of yours.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private var candidates: [Candidate] {
        var out: [Candidate] = []
        if side == .theirs {
            for meta in store.data.metaTeams where meta.format == format {
                out.append(Candidate(
                    id: meta.id,
                    name: meta.name,
                    tag: meta.projected ? "projected"
                        : (meta.record.map { "\($0)\(meta.placement.map { p in " · \(p)" } ?? "")" }
                           ?? meta.archetype),
                    group: meta.record == nil ? "Meta archetypes" : "Tournament results",
                    forms: meta.members.map { store.form(named: $0.form) }))
            }
        }
        for saved in store.teams where side == .mine || saved.id.uuidString != myTeamID {
            out.append(Candidate(id: saved.id.uuidString, name: saved.name,
                                 tag: "\(saved.slots.count) Pokémon · \(saved.format)",
                                 group: "My teams",
                                 forms: saved.slots.map { $0.battleForm(in: store.rulebook) }))
        }
        guard !search.isEmpty else { return out }
        let needle = search.lowercased()
        return out.filter { candidate in
            candidate.name.lowercased().contains(needle)
                || candidate.forms.contains { ($0?.formLabel.lowercased().contains(needle)) == true }
        }
    }
}
