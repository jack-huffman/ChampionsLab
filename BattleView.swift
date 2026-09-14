//  BattleView.swift
//  Playing the game out, with the engine's reasoning on screen beside it.
//
//  Everything else in this app is a verdict on a team. This is the team being
//  played: two of yours facing two of theirs, health going down, choices made
//  one turn at a time against an opponent that is choosing at the same moment
//  and cannot see what you picked either.
//
//  The point is not the battle. It is the two panels beside it — what the
//  engine thinks you should do and why, and what it believes they are thinking,
//  including the things neither side can see. Playing a matchup out with that
//  showing is how you learn a matchup; a score out of a hundred is not.

import SwiftUI

struct BattleView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    // -- setting it up ------------------------------------------------------
    @State private var myTeamID = ""
    @State private var opponentID = ""
    @State private var singles = false
    @State private var started = false

    // -- the game -----------------------------------------------------------
    @State private var board: Board?
    @State private var log: [String] = []
    @State private var turn = 1
    @State private var leftPick: Choice?
    @State private var rightPick: Choice?
    @State private var thinking = false
    @State private var advice: BattleEngine.Result?
    @State private var adviceLines: [String] = []
    @State private var theirThinking: [String] = []
    @State private var finished: String?
    /// Start a battle without anybody pressing anything, for tools/snapshot.sh.
    var opening: (mine: String, theirs: String)? = nil

    private var myTeam: Team? { store.teams.first { $0.id.uuidString == myTeamID } }
    private var theirTeam: Team? {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            return store.opponentTeam(meta)
        }
        return store.teams.first { $0.id.uuidString == opponentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            setupBar
            Divider()
            if let board, started {
                if snapshotMode { field(board) } else { ScrollView { field(board) } }
            } else if opening == nil {
                EmptyHint(symbol: "gamecontroller",
                          title: "Play a matchup out",
                          detail: "Pick your six and theirs. The engine searches the position each turn and shows what it is thinking, what it believes they are thinking, and what neither of you can see.")
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard let opening, !started else { return }
            myTeamID = opening.mine
            opponentID = opening.theirs
            start()
        }
    }

    // MARK: Setting up

    private var setupBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $myTeamID) {
                Text("Your team").tag("")
                ForEach(store.teams) { Text($0.name).tag($0.id.uuidString) }
            }.labelsHidden().frame(width: 190).controlSize(.small)

            Text("versus").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            Picker("", selection: $opponentID) {
                Text("Opponent").tag("")
                SwiftUI.Section("Meta archetypes") {
                    ForEach(store.data.metaTeams.filter { $0.record == nil }) {
                        Text($0.name).tag($0.id)
                    }
                }
                SwiftUI.Section("My teams") {
                    ForEach(store.teams) { Text($0.name).tag($0.id.uuidString) }
                }
            }.labelsHidden().frame(width: 210).controlSize(.small)

            Picker("", selection: $singles) {
                Text("Doubles").tag(false)
                Text("Singles").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)

            Button(started ? "Restart" : "Start") { start() }
                .controlSize(.small)
                .disabled(myTeam == nil || theirTeam == nil)
            Spacer()
            if started { Text("Turn \(turn)").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(12)
    }

    private func start() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        var made = Board(mine: mine, theirs: theirs, store: store,
                         field: Field(isDoubles: !singles))
        made.activeCount = singles ? 1 : 2
        board = made
        started = true
        turn = 1
        log = ["Both sides send out their leads. Neither knows what the other is holding."]
        leftPick = nil; rightPick = nil; finished = nil
        advice = nil; adviceLines = []; theirThinking = []
        think()
    }

    // MARK: The board

    private func field(_ board: Board) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let finished {
                Card { Label(finished, systemImage: "flag.checkered")
                    .font(.system(size: 14, weight: .semibold)) }
            }
            Card(padding: 16) {
                VStack(spacing: 14) {
                    side(board.theirs, active: board.activeCount, mine: false)
                    Divider()
                    side(board.mine, active: board.activeCount, mine: true)
                }
            }
            if finished == nil { choices(board) }
            thoughts()
            if !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader(title: "What happened")
                        ForEach(Array(log.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func side(_ team: [Fighter], active: Int, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mine ? "YOURS" : "THEIRS")
                .font(.system(size: 9, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(team.prefix(active).enumerated()), id: \.offset) { _, fighter in
                    fighterCard(fighter, big: true, mine: mine)
                }
                if team.count > active {
                    Rectangle().fill(Palette.hairline).frame(width: 1, height: 54)
                    ForEach(Array(team.dropFirst(active).enumerated()), id: \.offset) { _, f in
                        fighterCard(f, big: false, mine: mine)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func fighterCard(_ fighter: Fighter, big: Bool, mine: Bool) -> some View {
        let share = fighter.share
        return VStack(spacing: 3) {
            SpriteImage(form: fighter.build.form, side: big ? 58 : 34)
                .opacity(fighter.fainted ? 0.25 : 1)
                .saturation(fighter.fainted ? 0 : 1)
            Text(fighter.build.form.formLabel)
                .font(.system(size: big ? 11 : 9, weight: big ? .medium : .regular))
                .lineLimit(1).minimumScaleFactor(0.7)
            if big {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.hairline)
                        Capsule()
                            .fill(share > 0.5 ? Palette.good
                                  : (share > 0.2 ? Palette.warn : Palette.bad))
                            .frame(width: geo.size.width * share)
                    }
                }
                .frame(height: 5)
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                // Yours is known; theirs is a belief until something goes off.
                // Showing the prior rather than a blank is the whole point —
                // you do not know a Whimsicott has a Focus Sash, you know most
                // of them do and you play the turn accordingly.
                Text(mine ? fighter.build.item : guessedItem(fighter))
                    .font(.system(size: 9))
                    .foregroundStyle(mine ? AnyShapeStyle(.tertiary)
                                          : AnyShapeStyle(Palette.warn.opacity(0.8)))
                    .lineLimit(1)
                    .help(mine ? fighter.build.item
                               : "What the measured ladder says this Pokémon usually holds. It is a guess until the item goes off.")
            }
        }
        .frame(width: big ? 96 : 56)
    }

    /// What they are probably holding, from measured usage.
    private func guessedItem(_ fighter: Fighter) -> String {
        let engine = BattleEngine(store: store)
        guard let best = engine.itemOdds(for: fighter.build.form).first else {
            return "item unknown"
        }
        if best.chance >= 0.99 { return best.item }
        return String(format: "likely %@ (%.0f%%)", best.item, best.chance * 100)
    }

    // MARK: Choosing

    @ViewBuilder
    private func choices(_ board: Board) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your turn",
                              subtitle: "Both sides lock in at the same moment")
                ForEach(0..<board.activeCount, id: \.self) { slot in
                    if board.mine.indices.contains(slot), !board.mine[slot].fainted {
                        slotChoices(board, slot: slot)
                    }
                }
                HStack {
                    Button(thinking ? "Thinking…" : "Think again") { think() }
                        .controlSize(.small).disabled(thinking)
                    Spacer()
                    Button("Play the turn") { playTurn() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(leftPick == nil
                                  || (board.activeCount > 1
                                      && board.mine.count > 1
                                      && !board.mine[1].fainted && rightPick == nil))
                }
            }
        }
    }

    private func slotChoices(_ board: Board, slot: Int) -> some View {
        var game = TurnGame(board: board, store: store)
        game.width = 8
        let options = game.choices(forMine: true, slot: slot)
        let fighter = board.mine[slot]
        let picked = slot == 0 ? leftPick : rightPick
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SpriteImage(form: fighter.build.form, side: 24)
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, choice in
                    let label = game.describe(choice, fighter: fighter,
                                              foes: Array(board.theirs.prefix(board.activeCount)),
                                              team: board.mine)
                    let chosen = picked == choice
                    Button {
                        if slot == 0 { leftPick = choice } else { rightPick = choice }
                    } label: {
                        Text(label.isEmpty ? "do nothing" : label)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(chosen ? Palette.accent.opacity(0.2) : Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                                chosen ? Palette.accent : Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: What both sides are thinking

    private func thoughts() -> some View {
        HStack(alignment: .top, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHeader(title: "What we are thinking",
                                  subtitle: advice.map {
                                      "searched \($0.depth) turns ahead, \($0.nodes) positions"
                                  })
                    if adviceLines.isEmpty {
                        Text(thinking ? "Searching…" : "Press Think.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(adviceLines, id: \.self) { line in
                        Text(line).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHeader(title: "What they are thinking",
                                  subtitle: "and what neither side can see")
                    ForEach(theirThinking, id: \.self) { line in
                        Text(line).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Running a turn

    private func think() {
        guard let board else { return }
        thinking = true
        Task { @MainActor in
            await breathe("battle think")
            var engine = BattleEngine(store: store, budget: 0.5)
            let result = engine.think(board)
            var game = TurnGame(board: board, store: store)
            game.width = engine.beam + 2
            let solved = game.solve()

            var lines: [String] = []
            if let top = result.mix.indices.max(by: { result.mix[$0] < result.mix[$1] }),
               result.plays.indices.contains(top) {
                lines.append(String(format: "Best line, %.0f%% of the time: %@.",
                                    result.mix[top] * 100,
                                    game.describe(result.plays[top], mine: true)))
            }
            lines.append(String(format: "The position is worth %+.2f to you looking %d turns out.",
                                result.value, result.depth))
            if abs(result.drift) > 0.15 {
                lines.append(String(format: "Looking deeper moved that by %+.2f, so the shallow read was %@.",
                                    result.drift,
                                    result.drift < 0 ? "too optimistic" : "too pessimistic"))
            }
            if result.uncertainty > 0.2 {
                lines.append(String(format: "It swings %.2f depending on what they are actually holding, so this turn is a guess as much as a calculation.",
                                    result.uncertainty))
            }
            lines += result.principal
            adviceLines = lines
            advice = result

            var theirs: [String] = []
            if let likely = solved.theirMix.indices.max(by: {
                solved.theirMix[$0] < solved.theirMix[$1] }),
               solved.theirPlays.indices.contains(likely) {
                theirs.append(String(format: "Most likely: %@, about %.0f%% of the time.",
                                     game.describe(solved.theirPlays[likely], mine: false),
                                     solved.theirMix[likely] * 100))
            }
            theirs += game.readingNotes(solved)
            // What they cannot see, which is the other half of the turn.
            let hidden = board.mine.prefix(board.activeCount)
                .map { "\($0.build.form.formLabel)'s \($0.build.item)" }
            if !hidden.isEmpty {
                theirs.append("They cannot see " + hidden.joined(separator: " or ")
                              + ", nor which of your six you brought, so they are playing the likeliest version of you.")
            }
            theirThinking = theirs
            thinking = false
        }
    }

    private func playTurn() {
        guard var current = board, let left = leftPick else { return }
        var game = TurnGame(board: current, store: store)
        game.width = 8
        let solved = game.solve()
        // They choose from their own equilibrium, sampled rather than fixed, so
        // the same position does not always play out the same way.
        let roll = Double.random(in: 0...1)
        var running = 0.0
        var theirPlay = solved.theirPlays.first ?? Play(left: .pass, right: .pass)
        for (index, weight) in solved.theirMix.enumerated() {
            running += weight
            if roll <= running, solved.theirPlays.indices.contains(index) {
                theirPlay = solved.theirPlays[index]
                break
            }
        }
        let mine = Play(left: left,
                        right: current.activeCount > 1 ? (rightPick ?? .pass) : .pass)
        let before = current
        current = TurnModel.resolve(current, mine: mine, theirs: theirPlay, store: store)
        current.fillGaps()

        var entry = "Turn \(turn): you \(game.describe(mine, mine: true)); "
            + "they \(game.describe(theirPlay, mine: false))."
        for (index, fighter) in current.theirs.enumerated()
        where index < before.theirs.count {
            let lost = before.theirs[index].hp - fighter.hp
            if lost > 0 { entry += " \(fighter.build.form.formLabel) took \(lost)." }
            if fighter.fainted && !before.theirs[index].fainted {
                entry += " \(fighter.build.form.formLabel) fainted."
            }
        }
        for (index, fighter) in current.mine.enumerated() where index < before.mine.count {
            let lost = before.mine[index].hp - fighter.hp
            if lost > 0 { entry += " Your \(fighter.build.form.formLabel) took \(lost)." }
            if fighter.fainted && !before.mine[index].fainted {
                entry += " Your \(fighter.build.form.formLabel) fainted."
            }
        }
        log.append(entry)

        board = current
        turn += 1
        leftPick = nil; rightPick = nil
        if current.isOut(mine: false) { finished = "They have nothing left. You win." }
        else if current.isOut(mine: true) { finished = "You have nothing left. They win." }
        else { think() }
    }
}
