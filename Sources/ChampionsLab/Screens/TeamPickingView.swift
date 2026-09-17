//  TeamPickingView.swift
//  The first screen of a battle: which of yours, against which of theirs.
//
//  Your saved teams down one side, the published lists and your other teams
//  down the other, with a search. It owns nothing but the search text; the two
//  choices go back up to the battle screen, which is what works the lobby out
//  and moves on to the versus page.

import SwiftUI

struct TeamPickingView: View {
    /// Every six you could line up against, with what it is made of.
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let tag: String
        let group: String
        let forms: [Form?]
    }

    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    let myTeamID: String
    let opponentID: String
    @Binding var opponentSearch: String
    let onChooseMine: (String) -> Void
    let onChooseTheirs: (String) -> Void
    let singles: Bool

    private var format: String { singles ? "singles" : "doubles" }

    /// Both teams chosen by their six, side by side. Choosing the second one
    /// goes straight to the versus page.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                pickingHeader("Your team", count: store.teams.count,
                              hint: "One of your saved teams.")
                if store.teams.isEmpty {
                    EmptyHint(symbol: "person.3", title: "No teams yet",
                              detail: "Build one in Teams first.")
                } else {
                    MaybeScroll {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(store.teams) { team in
                                Button { onChooseMine(team.id.uuidString) } label: {
                                    SixCard(name: team.name,
                                            tag: "\(team.slots.count) Pokémon · \(team.format)",
                                            forms: team.slots.map { $0.battleForm(in: store.rulebook) },
                                            selected: team.id.uuidString == myTeamID)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 400, maxWidth: 440, maxHeight: .infinity,
                   alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    pickingHeader("Opponent", count: opponentCandidates.count,
                                  hint: "A meta archetype, a real tournament team, or another of yours.")
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("Team, player or a Pokémon on it", text: $opponentSearch)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.hairline, lineWidth: 1))
                    .frame(width: 260)
                }
                MaybeScroll {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(["Meta archetypes", "Tournament results", "My teams"], id: \.self) {
                            group in
                            // A snapshot has no scroll view to put a hundred
                            // tournament teams in, so it shows a handful.
                            let all = opponentCandidates.filter { $0.group == group }
                            let rows = snapshotMode ? Array(all.prefix(4)) : all
                            if !rows.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.uppercased())
                                        .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                        .foregroundStyle(.tertiary)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                                              alignment: .leading, spacing: 8) {
                                        ForEach(rows) { candidate in
                                            Button { onChooseTheirs(candidate.id) } label: {
                                                SixCard(name: candidate.name, tag: candidate.tag,
                                                        forms: candidate.forms,
                                                        selected: candidate.id == opponentID)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var opponentCandidates: [Candidate] {
        var out: [Candidate] = []
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
        for saved in store.teams where saved.id.uuidString != myTeamID {
            out.append(Candidate(id: saved.id.uuidString, name: saved.name,
                                 tag: "\(saved.slots.count) Pokémon · \(saved.format)",
                                 group: "My teams",
                                 forms: saved.slots.map { $0.battleForm(in: store.rulebook) }))
        }
        guard !opponentSearch.isEmpty else { return out }
        let needle = opponentSearch.lowercased()
        return out.filter { candidate in
            candidate.name.lowercased().contains(needle)
                || candidate.forms.contains { ($0?.formLabel.lowercased().contains(needle)) == true }
        }
    }

    @ViewBuilder

    private func pickingHeader(_ title: String, count: Int, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("\(count)").font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Text(hint).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}
