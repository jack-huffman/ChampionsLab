//  MatchupView.swift
//  The versus screen: your team against a meta archetype or another saved team.

import SwiftUI

struct MatchupView: View {
    @EnvironmentObject private var store: Store
    let team: Team

    @State private var opponentID: String = ""
    /// Preselect an opponent (used by tools/snapshot.sh).
    var initialOpponent: String? = nil
    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none
    /// Which of the fours the reader is looking at. Nil means the best one.
    @State private var selectedPlan: String?
    /// The Pokémon whose build is open in the lineup.
    @State private var inspecting: String?
    @State private var choosing = false
    @State private var opponentSearch = ""
    @State private var turnRead: [String] = []
    @State private var turnReading: [String] = []
    @State private var turnExploits: [TurnGame.Exploit] = []
    @State private var turnLines: [TurnGame.Solution.Line] = []
    @State private var turnLabels: [String: String] = [:]
    @State private var solvingTurn = false
    @Environment(\.snapshotMode) private var snapshotMode

    /// Two ways of asking about the same opponent.
    ///
    /// The grid is what the matchup looks like before a turn is played; the
    /// tree is what your decisions inside it are worth. They were two tabs that
    /// each opened by asking who you were playing, which is one question asked
    /// twice — so the opponent is chosen once, above, and this says what to do
    /// with the answer.
    enum Mode: String, CaseIterable, Identifiable {
        case grid = "The matchup", lines = "Your lines"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .grid

    /// Meta archetypes first, then the user's other saved teams.
    private var opponent: Team? {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            return TeamPaste.team(from: meta, store: store)
        }
        if let saved = store.teams.first(where: { $0.id.uuidString == opponentID }) {
            return saved
        }
        return nil
    }

    private var metaNote: MetaTeam? {
        store.data.metaTeams.first { $0.id == opponentID }
    }

    private var matchup: Matchup? {
        guard let opponent, !opponent.slots.isEmpty, !team.slots.isEmpty else { return nil }
        return Matchup(mine: team, theirs: opponent, rules: store.rulebook,
                       field: Field(weather: weather, terrain: terrain,
                                    isDoubles: team.isDoubles))
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            if team.slots.isEmpty {
                EmptyHint(symbol: "person.3", title: "Add Pokémon to your team first")
            } else if let matchup, let opponent {
                HStack {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                Divider()
                switch mode {
                case .grid:
                    if snapshotMode { content(matchup) } else { ScrollView { content(matchup) } }
                case .lines:
                    TreeView(team: team, against: opponent)
                }
            } else {
                EmptyHint(symbol: "arrow.left.arrow.right.square",
                          title: "Choose an opponent",
                          detail: "Compare against a known meta structure, or against another team you have saved.")
            }
        }
        .onAppear {
            if let initialOpponent, opponentID.isEmpty { opponentID = initialOpponent }
        }
        // A four chosen against one opponent means nothing against the next, and
        // the same four can exist in both — so the selection is cleared rather
        // than left to match by accident.
        .onChange(of: opponentID) { _ in
            selectedPlan = nil
            turnRead = []; turnLines = []; turnLabels = [:]
            turnReading = []; turnExploits = []
        }
        .onChange(of: weather) { _ in selectedPlan = nil }
        .onChange(of: terrain) { _ in selectedPlan = nil }
        .sheet(isPresented: $choosing) { opponentPicker }
    }

    // MARK: Controls

    /// Every six you could line up against, with what it is made of.
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let tag: String
        let group: String
        let forms: [Form?]
    }

    private var candidates: [Candidate] {
        var out: [Candidate] = []
        for meta in store.data.metaTeams where meta.format == team.format {
            out.append(Candidate(
                id: meta.id,
                name: meta.name,
                tag: meta.projected ? "projected"
                    : (meta.record.map { "\($0)\(meta.placement.map { p in " · \(p)" } ?? "")" }
                       ?? meta.archetype),
                group: meta.record == nil ? "Meta archetypes" : "Tournament results",
                forms: meta.members.map { store.form(named: $0.form) }))
        }
        for saved in store.teams where saved.id != team.id {
            out.append(Candidate(id: saved.id.uuidString, name: saved.name,
                                 tag: "\(saved.slots.count) Pokémon", group: "My teams",
                                 forms: saved.slots.map { $0.battleForm(in: store.rulebook) }))
        }
        guard !opponentSearch.isEmpty else { return out }
        let needle = opponentSearch.lowercased()
        return out.filter { candidate in
            candidate.name.lowercased().contains(needle)
                || candidate.forms.contains { ($0?.formLabel.lowercased().contains(needle)) == true }
        }
    }

    private var chosen: Candidate? { candidates.first { $0.id == opponentID } }

    /// A sheet of six-sprite cards rather than a menu of names.
    ///
    /// The menu said "MiggleVGC — Thavorian Trials 8", which tells you nothing
    /// about what you are about to play against. What you want while choosing
    /// is the same thing you want at Team Preview: the six.
    private var opponentPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Team, player or a Pokémon on it", text: $opponentSearch)
                    .textFieldStyle(.plain)
                Text("\(candidates.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Done") { choosing = false }.controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(["My teams", "Meta archetypes", "Tournament results"], id: \.self) {
                        group in
                        let rows = candidates.filter { $0.group == group }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                    .foregroundStyle(.tertiary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)],
                                          alignment: .leading, spacing: 8) {
                                    ForEach(rows) { candidate in
                                        Button {
                                            opponentID = candidate.id
                                            choosing = false
                                        } label: { candidateCard(candidate) }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 900, height: 640)
    }

    private func candidateCard(_ candidate: Candidate) -> some View {
        SixCard(name: candidate.name, tag: candidate.tag, forms: candidate.forms,
                selected: candidate.id == opponentID, spriteSide: 32)
    }

    private var picker: some View {
        HStack(spacing: 12) {
            Text("Versus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Button { choosing = true } label: {
                HStack(spacing: 6) {
                    if let chosen {
                        ForEach(Array(chosen.forms.prefix(6).enumerated()), id: \.offset) { _, f in
                            if let f { SpriteImage(form: f, side: 24) }
                        }
                        Text(chosen.name).font(.system(size: 12)).lineLimit(1)
                    } else {
                        Image(systemName: "person.2.badge.plus")
                        Text("Choose an opponent").font(.system(size: 12))
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 18)

            Picker("", selection: $weather) {
                ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 110).controlSize(.small)
            Picker("", selection: $terrain) {
                ForEach(Terrain.allCases) { Text($0.rawValue + " Terrain").tag($0) }
            }.labelsHidden().frame(width: 150).controlSize(.small)
            Spacer()
        }
        .padding(12)
    }

    // MARK: Body

    private func content(_ matchup: Matchup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            lineupCard(matchup)
            verdictCard(matchup)
            bringFourCard(matchup)
            turnCard(matchup)
            if let metaNote { provenance(metaNote) }
            gridCard(matchup)
            opposingCard(matchup)
        }
        .padding(20)
    }

    private func verdictCard(_ matchup: Matchup) -> some View {
        let verdict = matchup.verdict
        // Map −100…100 onto a 0…1 arc.
        let fraction = (Double(verdict.score) + 100) / 200
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(Palette.hairline, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(fraction))
                            .stroke(Palette.grade(Int(fraction * 100)),
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(verdict.score > 0 ? "+\(verdict.score)" : "\(verdict.score)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("edge").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 84, height: 84)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(verdict.headline)
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 14) {
                            tally("Winning", verdict.winCount, Palette.good)
                            tally("Losing", verdict.lossCount, Palette.bad)
                            tally("Cells", verdict.totalCells, Palette.dim)
                            tally("You faster", verdict.speedEdge, Palette.accent, suffix: "%")
                        }
                    }
                    Spacer()
                }

                if !verdict.advice.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(verdict.advice, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Lineup

    /// The two sixes, face to face.
    ///
    /// The opponent picker says "MiggleVGC — Thavorian Trials 8", which tells
    /// you nothing about what you are about to play against. What you want at
    /// the top of this screen is the thing you see at Team Preview: their six
    /// beside yours, and one click to see what any of them is carrying.
    private func lineupCard(_ matchup: Matchup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(team.name)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("versus")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(opponent?.name ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.trailing)
                }
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        ForEach(Array(team.slots.enumerated()), id: \.offset) { index, slot in
                            lineupRow(slot, side: "mine", index: index, trailing: false)
                        }
                    }
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                    VStack(spacing: 6) {
                        ForEach(Array((opponent?.slots ?? []).enumerated()), id: \.offset) {
                            index, slot in
                            lineupRow(slot, side: "theirs", index: index, trailing: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineupRow(_ slot: TeamSlot, side: String, index: Int,
                           trailing: Bool) -> some View {
        let key = "\(side)-\(index)"
        let open = inspecting == key
        let form = slot.battleForm(in: store.rulebook)
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            Button {
                inspecting = open ? nil : key
            } label: {
                HStack(spacing: 8) {
                    if trailing { Spacer(minLength: 0) }
                    if !trailing, let form { SpriteImage(form: form, side: 34) }
                    VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
                        Text(form?.formLabel ?? slot.formID)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if !slot.item.isEmpty {
                                ItemIcon(name: slot.item, side: 13)
                                Text(slot.item)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("no item")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if trailing, let form { SpriteImage(form: form, side: 34) }
                    if !trailing { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(open ? Palette.accent.opacity(0.14) : Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(open ? Palette.accent.opacity(0.5) : Palette.hairline,
                                  lineWidth: 1))
            }
            .buttonStyle(.plain)

            if open { buildDetail(slot, form: form, trailing: trailing) }
        }
    }

    /// What the slot is actually carrying, which is the reason to click it.
    @ViewBuilder
    private func buildDetail(_ slot: TeamSlot, form: Form?, trailing: Bool) -> some View {
        let combatant = slot.combatant(in: store.rulebook)
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            if let form {
                HStack(spacing: 4) {
                    if trailing { Spacer(minLength: 0) }
                    ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                    if !trailing { Spacer(minLength: 0) }
                }
            }
            let ability = slot.megaEvolution(in: store.rulebook)?.abilities.first?.name
                ?? (slot.ability.isEmpty ? form?.abilities.first?.name ?? "" : slot.ability)
            if !ability.isEmpty {
                Text(ability).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            ForEach(slot.moves, id: \.self) { id in
                if let move = store.move(id) {
                    HStack(spacing: 5) {
                        if trailing { Spacer(minLength: 0) }
                        TypeChip(type: PokeType(loose: move.type) ?? .normal, size: .small)
                        Text(move.name).font(.system(size: 11))
                        if move.power > 0 {
                            Text("\(move.power)")
                                .font(.system(size: 10, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        if !trailing { Spacer(minLength: 0) }
                    }
                }
            }
            if slot.moves.isEmpty {
                Text("no moves set").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            // The spread, and what it actually comes out as.
            let spelled = Stat.allCases.filter { slot.sp[$0.rawValue] > 0 }
                .map { "\($0.short) \(slot.sp[$0.rawValue])" }.joined(separator: " / ")
            Text(spelled.isEmpty ? "\(slot.alignmentName), no points spent"
                                 : "\(slot.alignmentName) · \(spelled)")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let combatant {
                Text(Stat.allCases.map { "\($0.short) \(combatant.stat($0))" }
                        .joined(separator: "  "))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .background(Palette.hairline.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: The first turn

    /// The opening turn, solved as the simultaneous game it is.
    ///
    /// Everything above this reasons about matchups, which is the right frame
    /// for building a team and the wrong one for playing it: both sides lock in
    /// two choices knowing nothing about the other's. That is a matrix game,
    /// and what players call reading an opponent is a mixed strategy — there is
    /// no single best move, there is a distribution, and someone who always
    /// picks the same one can be beaten every time.
    @ViewBuilder
    private func turnCard(_ matchup: Matchup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "The first turn",
                    subtitle: "Both sides choose blind, so there is a mix rather than a move",
                    accessory: AnyView(
                        Button(solvingTurn ? "Solving…" : "Solve the turn") {
                            solveTurn(matchup)
                        }
                        .controlSize(.small)
                        .disabled(solvingTurn || opponent == nil)))

                if turnRead.isEmpty {
                    Text("Leads come from the four above. Every pair of your choices is played against every pair of theirs, and the result is solved for the mix that cannot be read — plus what each line is worth when they guess right, and when they guess wrong.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(turnRead, id: \.self) { line in
                            noteRow(line, symbol: "arrow.turn.down.right", colour: .secondary)
                        }
                    }
                    if !turnReading.isEmpty {
                        Divider()
                        Text("READING THEM")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(turnReading, id: \.self) { line in
                                noteRow(line, symbol: "eye", colour: .secondary)
                            }
                        }
                    }
                    if !turnExploits.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(turnExploits.prefix(5)) { exploit in
                                HStack(spacing: 8) {
                                    Text(exploit.read.shorthand)
                                        .font(.system(size: 11))
                                        .frame(width: 160, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                    Text(exploit.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    // Gain against the read, and what being
                                    // wrong costs. The trade, as two numbers.
                                    Text(String(format: "%+.2f", exploit.gain))
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.good)
                                    Text("risk").font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Text(String(format: "%.2f", exploit.cost))
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(exploit.worthIt ? Palette.dim : Palette.bad)
                                }
                            }
                        }
                    }
                    if !turnLines.isEmpty {
                        Divider()
                        ForEach(turnLines.prefix(4)) { line in
                            HStack(spacing: 10) {
                                Text(String(format: "%.0f%%", line.weight * 100))
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.accent)
                                    .frame(width: 38, alignment: .trailing)
                                Text(turnLabels[line.id] ?? "—")
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                // The gap between these two is what "greedy"
                                // means, and it is the whole decision.
                                Text(String(format: "%+.2f", line.worst))
                                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(line.worst < 0 ? Palette.bad : Palette.dim)
                                Text("to").font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(String(format: "%+.2f", line.best))
                                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(Palette.good)
                            }
                        }
                    }
                }
            }
        }
    }

    private func solveTurn(_ matchup: Matchup) {
        guard let opponent else { return }
        solvingTurn = true
        Task { @MainActor in
            await breathe("turn")
            // The leads the bring-four search settled on, so the two screens
            // agree about which turn is being solved.
            let size = store.data.rules.formats.first { $0.id == team.format }?.bring ?? 4
            let picker = bringPicker(matchup, size: size)
            let plan = picker.plans.first
            await breathe("turn leads")
            let board = Board(mine: team, theirs: opponent, rules: store.rulebook,
                              myLeads: plan?.leads.map(\.id) ?? [],
                              theirLeads: Array(picker.theirLikelyFour.prefix(2).map(\.id)),
                              field: Field(weather: weather, terrain: terrain,
                                           isDoubles: team.isDoubles))
            await breathe("turn board")
            let game = TurnGame(board: board)
            let (solution, deep) = await game.solveDeep()
            turnRead = game.read(solution)
            await breathe("turn read")
            turnReading = game.lookaheadNotes(shallow: solution, deep: deep)
                + game.readingNotes(solution)
            turnExploits = game.exploits(solution)
            turnLines = solution.lines.filter { $0.weight > 0.01 }
            turnLabels = Dictionary(
                solution.lines.map { ($0.id, game.describe($0.play, mine: true)) },
                uniquingKeysWith: { first, _ in first })
            solvingTurn = false
        }
    }

    // MARK: Bring four

    /// The picker, told what this team has actually been measured to do.
    ///
    /// One place, so the measured record cannot be wired into one call site and
    /// quietly forgotten in the other.
    private func bringPicker(_ matchup: Matchup, size: Int) -> BringFour {
        var picker = BringFour(matchup: matchup, rules: store.rulebook, bring: size)
        picker.measured = store.measuredFours(for: team)
        return picker
    }

    /// Six are registered and four are brought, so this is the decision the
    /// screen exists to help with. Everything here is read off the same grid
    /// the verdict above is read off.
    @ViewBuilder
    private func bringFourCard(_ matchup: Matchup) -> some View {
        let size = store.data.rules.formats.first { $0.id == team.format }?.bring ?? 4
        let picker = bringPicker(matchup, size: size)
        let plans = picker.plans
        let chosen = plans.first { $0.id == selectedPlan } ?? plans.first

        if let chosen, team.slots.count > size {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        title: "Bring \(size)",
                        subtitle: "Which \(size) to take into this matchup, and which two to lead")

                    theirLikely(picker.theirLikelyFour)
                    Divider()
                    chosenFour(chosen)

                    if plans.count > 1 {
                        Divider()
                        alternates(plans, chosen: chosen)
                    }
                }
            }
        }
    }

    private func theirLikely(_ forms: [Form]) -> some View {
        HStack(spacing: 8) {
            Text("They will most likely bring")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(forms) { form in
                HStack(spacing: 4) {
                    SpriteImage(form: form, side: 26)
                    Text(form.formLabel).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Palette.hairline.opacity(0.45))
                .clipShape(Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func chosenFour(_ plan: BringFour.Plan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(plan.leads) { bringSlot($0, badge: "Lead", accent: Palette.accent) }
                if !plan.back.isEmpty {
                    Rectangle().fill(Palette.hairline).frame(width: 1, height: 62)
                    ForEach(plan.back) { bringSlot($0, badge: "Back", accent: Palette.dim) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(plan.score > 0 ? "+\(plan.score)" : "\(plan.score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.grade((plan.score + 100) / 2))
                    // Not "edge": the verdict above already owns that word for
                    // the whole six, and two different numbers under one label
                    // is worse than no label.
                    Text("THIS \(plan.bring.count)")
                        .font(.system(size: 9, weight: .semibold)).kerning(0.4)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 2)
                Text(plan.turnOne.line)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(plan.reasons.prefix(5), id: \.self) { line in
                    noteRow(line, symbol: "arrow.turn.down.right", colour: .secondary)
                }
                ForEach(plan.warnings, id: \.self) { line in
                    noteRow(line, symbol: "exclamationmark.triangle.fill", colour: Palette.warn)
                }
            }
        }
    }

    private func noteRow(_ text: String, symbol: String,
                         colour: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(colour == .secondary ? AnyShapeStyle(.tertiary)
                                                      : AnyShapeStyle(colour))
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(colour == .secondary ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(colour))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bringSlot(_ form: Form, badge: String, accent: Color) -> some View {
        VStack(spacing: 3) {
            SpriteImage(form: form, side: 44)
            Text(badge.uppercased())
                .font(.system(size: 8, weight: .bold)).kerning(0.5)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(accent.opacity(0.18))
                .foregroundStyle(accent)
                .clipShape(Capsule())
            Text(form.formLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 92)
    }

    /// The other fours, so the call stays the reader's. Each says what it is
    /// worth, which is the only way to tell whether the top one is a clear
    /// choice or a coin flip.
    private func alternates(_ plans: [BringFour.Plan],
                            chosen: BringFour.Plan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // Whether the decision is worth making at all. A two-point spread
            // means bring whoever you like; a thirty-point one means this is
            // the game.
            let spread = (plans.first?.score ?? 0) - (plans.last?.score ?? 0)
            HStack(spacing: 6) {
                Text("Other ways to bring \(chosen.bring.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(spread >= 8
                     ? "· best to worst is \(spread) points, so this choice decides a lot"
                     : "· only \(spread) points between best and worst, so bring what you like")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            // A grid rather than a horizontal scroller: six of these fit the
            // card at any sensible width, and anything that has to be scrolled
            // sideways to be found may as well not be on the screen.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(plans.prefix(6)) { plan in
                    Button { selectedPlan = plan.id } label: {
                        planChip(plan, isSelected: plan.id == chosen.id)
                    }
                    .buttonStyle(.plain)
                    .help(plan.bring.map(\.formLabel).joined(separator: ", "))
                }
            }
        }
    }

    private func planChip(_ plan: BringFour.Plan, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(plan.bring) { SpriteImage(form: $0, side: 24) }
            Text(plan.score > 0 ? "+\(plan.score)" : "\(plan.score)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.grade((plan.score + 100) / 2))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(isSelected ? Palette.accent.opacity(0.16) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Palette.accent.opacity(0.55) : Palette.hairline,
                          lineWidth: 1))
    }

    private func tally(_ label: String, _ value: Int, _ colour: Color,
                       suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)\(suffix)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(colour)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
        }
    }

    private func provenance(_ meta: MetaTeam) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(meta.archetype)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.18))
                        .foregroundStyle(Palette.accent)
                        .clipShape(Capsule())
                    if meta.projected {
                        Text("projected — no M-C ladder data")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.warn)
                    }
                }
                Text(meta.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Grid

    private func gridCard(_ matchup: Matchup) -> some View {
        let reports = matchup.memberReports
        let opposing = matchup.opposingReports
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "One-on-one grid",
                              subtitle: "Your team down the side, theirs across the top. Speed breaks ties.")
                MaybeHScroll(active: !snapshotMode) {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Color.clear.frame(width: 150, height: 34)
                            ForEach(opposing) { report in
                                VStack(spacing: 1) {
                                    SpriteImage(form: report.form, side: 30)
                                }
                                .frame(width: 62)
                                .help(report.form.formLabel)
                            }
                        }
                        ForEach(reports) { report in
                            HStack(spacing: 3) {
                                HStack(spacing: 6) {
                                    SpriteImage(form: report.form, side: 26)
                                    Text(report.form.formLabel)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)

                                ForEach(report.duels) { duel in
                                    cell(duel)
                                }
                            }
                        }
                    }
                }
                legend
            }
        }
    }

    private func cell(_ duel: Duel) -> some View {
        VStack(spacing: 1) {
            Text(duel.outcome.rawValue)
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%.0f/%.0f", duel.outgoing * 100, duel.incoming * 100))
                .font(.system(size: 9, design: .rounded))
                .monospacedDigit()
                .opacity(0.75)
        }
        .frame(width: 62, height: 34)
        .background(colour(duel.outcome).opacity(duel.outcome == .neutral ? 0.10 : 0.28))
        .foregroundStyle(duel.outcome == .neutral ? Palette.dim : colour(duel.outcome))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .topTrailing) {
            if duel.iAmFaster {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Palette.warn)
                    .padding(2)
            }
        }
        .help("\(duel.mine.formLabel) \(duel.myBestMove) → \(Int(duel.outgoing * 100))%  ·  "
              + "\(duel.theirs.formLabel) \(duel.theirBestMove) → \(Int(duel.incoming * 100))%  ·  "
              + "Speed \(duel.mySpeed) vs \(duel.theirSpeed)")
    }

    private func colour(_ outcome: Duel.Outcome) -> Color {
        switch outcome {
        case .win:      return Palette.good
        case .favoured: return Color(red: 0.55, green: 0.70, blue: 0.35)
        case .neutral:  return Palette.dim
        case .against:  return Palette.warn
        case .loss:     return Palette.bad
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([Duel.Outcome.win, .favoured, .neutral, .against, .loss], id: \.rawValue) { outcome in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colour(outcome).opacity(0.28))
                        .frame(width: 12, height: 12)
                    Text(outcome.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(Palette.warn)
                Text("you outspeed").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("cell shows your % / their %")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Their threats

    private func opposingCard(_ matchup: Matchup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Their team, hardest first",
                              subtitle: "Who you have an answer to, and who you do not.")
                ForEach(matchup.opposingReports) { report in
                    HStack(spacing: 10) {
                        SpriteImage(form: report.form, side: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.form.formLabel)
                                .font(.system(size: 12, weight: .medium))
                            if report.isUnanswered {
                                Text("Nothing on your team beats it")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.bad)
                            } else {
                                Text("Answered by " + report.answeredBy.map(\.formLabel)
                                        .joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.good)
                            }
                            if !report.beats.isEmpty {
                                Text("Beats " + report.beats.map(\.formLabel)
                                        .joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach(report.form.pokeTypes) { TypeChip(type: $0, size: .small) }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let onImport: (Team) -> Void

    @State private var text = ""
    @State private var teamName = ""
    @State private var replicaCode = ""
    @State private var preview: TeamPaste.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import a team").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Paste",
                                          subtitle: "Showdown or Pokepaste text. EVs are converted to Stat Points on the way in.")
                            TextEditor(text: $text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 200)
                                .scrollContentBackground(.hidden)
                                .background(Palette.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            HStack {
                                Button("Paste from clipboard") {
                                    text = NSPasteboard.general.string(forType: .string) ?? text
                                    refresh()
                                }
                                .controlSize(.small)
                                Button("Check") { refresh() }
                                    .controlSize(.small)
                                Spacer()
                            }
                        }
                    }

                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Details")
                            HStack(spacing: 8) {
                                Text("Name").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                TextField("Imported team", text: $teamName)
                                    .textFieldStyle(.roundedBorder).controlSize(.small)
                            }
                            HStack(spacing: 8) {
                                Text("Replica code").font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                TextField("e.g. GESXQDU369", text: $replicaCode)
                                    .textFieldStyle(.roundedBorder).controlSize(.small)
                            }
                            Text("Champions' Replica Team codes are resolved by the game's servers, so the app cannot expand one into a team. Paste the list above and keep the code here as a label.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let preview {
                        Card(padding: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: "Preview",
                                              subtitle: "\(preview.team.slots.count) Pokémon")
                                ForEach(preview.team.slots) { slot in
                                    if let form = slot.form(in: store.rulebook) {
                                        HStack(spacing: 8) {
                                            SpriteImage(form: form, side: 30)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(form.formLabel)
                                                    .font(.system(size: 12, weight: .medium))
                                                Text("\(slot.ability) · \(slot.item.isEmpty ? "no item" : slot.item) · \(slot.alignmentName) · \(slot.spUsed) SP")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                if !preview.warnings.isEmpty {
                                    Divider()
                                    ForEach(preview.warnings, id: \.self) { warning in
                                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.warn)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            HStack {
                Spacer()
                Button("Import") {
                    guard var team = preview?.team else { return }
                    if !teamName.isEmpty { team.name = teamName }
                    team.replicaCode = replicaCode
                    onImport(team)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((preview?.team.slots.isEmpty ?? true))
            }
            .padding(14)
        }
        .frame(width: 620, height: 680)
        .onChange(of: text) { _ in refresh() }
    }

    private func refresh() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = nil
            return
        }
        preview = TeamPaste.parse(text, store: store,
                                  name: teamName.isEmpty ? nil : teamName)
    }
}
