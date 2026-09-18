//  CommandDeckView.swift
//  Giving orders, the way the game does it.
//
//  One Pokemon at a time: first the choice between fighting and switching, then
//  the specific move and where it goes, or the partner to bring in. The engine's
//  own line sits beside each choice as a share, the Mega toggle sits beside the
//  move as the game puts it, and a locked strip shows the order already given
//  to the other one. When both are in, the turn can be played -- and until it
//  has been, taken back. Everything here reads and writes the session; nothing
//  is remembered by the deck itself.

import SwiftUI

struct CommandDeckView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    @ObservedObject var session: BattleSession
    @ObservedObject var playback: TurnPlayback
    let board: Board
    private var turn: Int { get { session.turn } nonmutating set { session.turn = newValue } }
    private var leftPick: Choice? { get { session.leftPick } nonmutating set { session.leftPick = newValue } }
    private var rightPick: Choice? { get { session.rightPick } nonmutating set { session.rightPick = newValue } }
    private var megaSlot: Int? { get { session.megaSlot } nonmutating set { session.megaSlot = newValue } }
    private var command: BattleSession.Command { get { session.command } nonmutating set { session.command = newValue } }
    private var thinking: Bool { get { session.thinking } nonmutating set { session.thinking = newValue } }
    private var thought: BattleEngine.Result? { get { session.thought } nonmutating set { session.thought = newValue } }
    private var solved: TurnGame.Solution? { get { session.solved } nonmutating set { session.solved = newValue } }
    private var searchNote: String { get { session.searchNote } nonmutating set { session.searchNote = newValue } }
    private var playing: Bool { get { session.playing } nonmutating set { session.playing = newValue } }
    private var history: [(board: Board, log: [String], turn: Int)] { get { session.history } nonmutating set { session.history = newValue } }
    private var grade: String? { get { session.grade } nonmutating set { session.grade = newValue } }
    private var replay: [Board.Step] { get { playback.replay } nonmutating set { playback.replay = newValue } }
    private var at: Int { get { playback.at } nonmutating set { playback.at = newValue } }

    @ViewBuilder
    var body: some View {
        let living = (0..<board.activeCount).filter {
            board.mine.indices.contains($0) && !board.mine[$0].fainted
        }
        let pending = living.first { session.pick(for: $0) == nil }
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // What is already locked in, as a strip along the top.
                lockedStrip(board, living: living)
                Divider()
                MaybeScroll {
                    if let slot = pending {
                        commandDeck(board, slot: slot)
                    } else {
                        readyToPlay(board)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The orders given so far. Click one to change it.
    private func lockedStrip(_ board: Board, living: [Int]) -> some View {
        HStack(spacing: 10) {
            ForEach(living, id: \.self) { slot in
                let fighter = board.mine[slot]
                let chosen = session.pick(for: slot)
                Button {
                    // Reopen this one's orders.
                    session.set(nil, slot: slot)
                    command = .menu
                } label: {
                    HStack(spacing: 7) {
                        SpriteImage(form: fighter.build.form, side: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fighter.build.form.formLabel)
                                .font(.system(size: 11, weight: .semibold))
                            Text(chosen.map { describeChoice($0, board: board, slot: slot) }
                                 ?? "awaiting orders")
                                .font(.system(size: 10))
                                .foregroundStyle(chosen == nil ? AnyShapeStyle(.tertiary)
                                                               : AnyShapeStyle(Palette.accent))
                                .lineLimit(1)
                        }
                        if megaSlot == slot, fighter.pendingMega != nil {
                            Image(systemName: "sparkles").font(.system(size: 10))
                                .foregroundStyle(Palette.warn)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(chosen == nil ? Color.clear : Palette.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(chosen == nil)
            }
            Spacer()
            if !history.isEmpty {
                Button("Take back") { session.undo() }.controlSize(.small)
            }
            if !searchNote.isEmpty {
                Text(searchNote).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func describeChoice(_ choice: Choice, board: Board, slot: Int) -> String {
        var game = TurnGame(board: board)
        game.width = 10
        return game.describe(choice, fighter: board.mine[slot],
                             foes: Array(board.theirs.prefix(board.activeCount)),
                             team: board.mine)
    }

    /// The command menu for one Pokémon.
    private func commandDeck(_ board: Board, slot: Int) -> some View {
        let fighter = board.mine[slot]
        let ahead = session.evolving(fighter, slot: slot, board: board)
        return VStack(alignment: .leading, spacing: 12) {
            // Who is being commanded, and the two things that are true of it
            // whatever you pick.
            HStack(spacing: 10) {
                SpriteImage(form: ahead.build.form, side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("What will \(ahead.build.form.formLabel) do?")
                            .font(.system(size: 14, weight: .semibold))
                        if fighter.status != .none {
                            Text(fighter.status.rawValue.uppercased())
                                .font(.system(size: 8, weight: .bold)).kerning(0.4)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Palette.warn.opacity(0.2))
                                .foregroundStyle(Palette.warn)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Speed \(ahead.build.speed(in: ahead.field))")
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(megaSlot == slot && fighter.pendingMega != nil
                                             ? AnyShapeStyle(Palette.warn)
                                             : AnyShapeStyle(.tertiary))
                        Text("\(fighter.hp)/\(fighter.maxHP)")
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let mega = fighter.pendingMega,
                   !board.mine.contains(where: \.hasMegaEvolved) {
                    megaToggle(slot: slot, becoming: mega)
                }
                if command != .menu {
                    Button {
                        command = .menu
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }
            }

            engineLine(board)

            switch command {
            case .menu:
                HStack(spacing: 12) {
                    bigCommand("Fight", symbol: "flame.fill", tint: Palette.bad) {
                        command = .fight
                    }
                    bigCommand("Party", symbol: "arrow.left.arrow.right", tint: Palette.good,
                               enabled: !switchOptions(board).isEmpty,
                               note: engineSwitchShare(slot: slot) >= 0.1
                                 ? String(format: "engine switches %.0f%%",
                                          engineSwitchShare(slot: slot) * 100) : nil) {
                        command = .party
                    }
                }
            case .fight:
                fightGrid(board, slot: slot, fighter: fighter)
            case .aiming(let move):
                if fighter.moves.indices.contains(move) {
                    targetScreen(board, slot: slot, move: fighter.moves[move], index: move)
                }
            case .party:
                partyList(board, slot: slot)
            }
        }
        .padding(16)
    }

    /// The line the engine expects from them, with how sure it is.
    private var theirExpected: (play: Play, share: Double)? {
        guard let solved, let top = solved.theirMix.indices.max(by: { solved.theirMix[$0] < solved.theirMix[$1] }),
              solved.theirPlays.indices.contains(top) else { return nil }
        return (solved.theirPlays[top], solved.theirMix[top])
    }

    /// The position in a word, so the number next to it means something.
    private func standing(_ value: Double) -> String {
        let size = abs(value)
        let side = value >= 0 ? "ahead" : "behind"
        if size < 0.15 { return "even" }
        if size < 0.6 { return "slightly \(side)" }
        if size < 1.5 { return side }
        return "well \(side)"
    }

    /// The engine's answer where you are choosing: what it would do, how
    /// firmly, what it expects back, and where it thinks you stand. Two short
    /// lines, because the numbers are the point and the prose is not.
    @ViewBuilder
    private func engineLine(_ board: Board) -> some View {
        if let thought, let pick = enginePick {
            var game = TurnGame(board: board)
            let _ = { game.width = 10 }()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 10))
                        .foregroundStyle(Palette.accent)
                    Text("Engine:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text(game.describe(pick, mine: true))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(String(format: "· %.0f%%", (thought.mix.max() ?? 0) * 100))
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("How often it would choose this line. Under 100% means it mixes on purpose, so the other side cannot read it.")
                    Text("· \(standing(thought.value)) (\(String(format: "%+.2f", thought.value)))"
                         + " · \(thought.depth) turn\(thought.depth == 1 ? "" : "s") deep")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if thought.uncertainty > 0.2 {
                        Text("· depends on their item")
                            .font(.system(size: 10)).foregroundStyle(Palette.warn)
                            .help("The answer swings on what they are holding, which nobody can see.")
                    }
                    Spacer(minLength: 0)
                    Button {
                        session.engineOrders(board, result: thought)
                        command = .menu
                    } label: {
                        Text("Take its orders").font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.small)
                }
                if let expected = theirExpected {
                    HStack(spacing: 8) {
                        Image(systemName: "eye").font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Expects them to:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(game.describe(expected.play, mine: false))
                            .font(.system(size: 11)).lineLimit(1)
                        Text(String(format: "· %.0f%%", expected.share * 100))
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if thinking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Engine is searching…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    /// The two big buttons the game gives you.
    private func bigCommand(_ title: String, symbol: String, tint: Color,
                            enabled: Bool = true, note: String? = nil,
                            act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 15, weight: .heavy)).kerning(1.2)
                if let note {
                    Text(note).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white.opacity(0.25)).clipShape(Capsule())
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: tint.opacity(0.35), radius: 8, y: 3)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// How often the engine's lines evolve this slot this turn.
    private func engineMegaShare(slot: Int) -> Double {
        guard let thought else { return 0 }
        var total = 0.0
        for (index, play) in thought.plays.enumerated() where thought.mix.indices.contains(index) {
            if play.megaSlot == slot { total += thought.mix[index] }
        }
        return total
    }

    /// Mega Evolution is once a game and cannot be taken back, so it is the
    /// biggest decision on the screen. It used to read as a small grey capsule
    /// beside the Pokémon's name, quieter than the move buttons underneath it,
    /// and was easy to click past without noticing.
    private func megaToggle(slot: Int, becoming: Form) -> some View {
        let share = engineMegaShare(slot: slot)
        let on = megaSlot == slot
        return Button { megaSlot = on ? nil : slot } label: {
            HStack(spacing: 7) {
                SpriteImage(form: becoming, side: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on ? "Mega Evolving" : "Mega Evolve")
                        .font(.system(size: 12, weight: .bold))
                    Text(on ? "Becomes \(becoming.formLabel) first" : "Once a game")
                        .font(.system(size: 9))
                        .foregroundStyle(on ? AnyShapeStyle(Palette.warn.opacity(0.85))
                                            : AnyShapeStyle(.tertiary))
                }
                if thought != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 8))
                        Text(share >= 0.995 ? "yes" : share <= 0.005 ? "not yet"
                             : String(format: "%.0f%%", share * 100))
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.16))
                    .foregroundStyle(Palette.accent)
                    .clipShape(Capsule())
                    .help(share <= 0.005
                          ? "The engine holds the stone this turn — usually so its weather lands second, or to keep the option."
                          : "How often the engine's lines evolve now")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(on ? Palette.warn.opacity(0.22) : Palette.surfaceRaised)
            )
            .foregroundStyle(on ? AnyShapeStyle(Palette.warn) : AnyShapeStyle(.primary))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(on ? Palette.warn : Palette.warn.opacity(0.45),
                                  lineWidth: on ? 2 : 1.5)
            )
            .shadow(color: on ? Palette.warn.opacity(0.35) : .clear, radius: 7)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: on)
        .help("Becomes \(becoming.formLabel) before anything else happens this turn. "
              + "If both sides evolve, the slower one goes second — and when both bring "
              + "weather, the second one is the weather that stays.")
    }

    /// The four moves, two by two, coloured by type the way the game draws them.
    private func fightGrid(_ board: Board, slot: Int, fighter: Fighter,
                           aiming: Int? = nil) -> some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(fighter.moves.prefix(4).enumerated()), id: \.offset) { index, move in
                moveTile(board, slot: slot, index: index, move: move, fighter: fighter,
                         aiming: aiming == index)
            }
        }
    }

    private func moveTile(_ board: Board, slot: Int, index: Int, move: Move,
                          fighter: Fighter, aiming: Bool) -> some View {
        // What the move is on this field — after the Mega Evolution toggled
        // beside it, if that brings weather. Weather Ball reads Fire and 100
        // under sun, not the Normal and 50 printed on it.
        let ahead = session.evolving(fighter, slot: slot, board: board)
        let form = DamageCalc.fieldForm(of: move, in: ahead.field)
        let ate = AteAbility.resolve(type: form.type, ability: ahead.build.ability)
        let type = move.isDamaging ? ate.type : form.type
        let retyped = move.isDamaging && ate.type != form.type
        let aim = move.aim
        // Revival Blessing has nobody to bring back until somebody has gone.
        let fallen = (board.activeCount..<board.mine.count).filter { board.mine[$0].fainted }
        let usable = (!move.drawbacks.firstTurnOnly || fighter.justArrived)
            && !(move.aim == .party && fallen.isEmpty)
        // What it does to each of them, on the tile, before anything is
        // clicked. The point of a practice board is seeing the numbers — and
        // a target it cannot touch is said so, not left off.
        let perTarget: [(name: String, text: String, mega: String?, tint: Color)] =
            (aim == .foe || aim == .spread) && move.isDamaging
            ? Seat.farSlotsLeftToRight(board).compactMap { target in
                guard !board.theirs[target].fainted else { return nil }
                let name = board.theirs[target].build.form.formLabel
                guard let read = MovePreview(session: session, store: store).reading(board, fighter: fighter, slot: slot,
                                         choice: .attack(move: index, target: target),
                                         only: target)
                else { return (name, "no effect", nil, Palette.dim) }
                return (name, read.text, read.mega, read.tint)
            } : []
        return Button {
            guard usable else { return }
            if aim == .foe || aim == .party {
                command = .aiming(move: index)
            } else {
                session.set(.attack(move: index, target: 0), slot: slot)
                command = .menu
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(move.name)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer()
                    let share = engineShare(slot: slot, move: index)
                    if share >= 0.1 {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu").font(.system(size: 8))
                            Text(String(format: "%.0f%%", share * 100))
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.28))
                        .clipShape(Capsule())
                        .help("How often the engine would click this, across the lines it rates")
                    }
                    if move.priority != 0 {
                        Text(move.priority > 0 ? "+\(move.priority)" : "\(move.priority)")
                            .font(.system(size: 11, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.22))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text(type.rawValue.uppercased())
                        .font(.system(size: 9, weight: .heavy)).kerning(0.6)
                        .opacity(0.9)
                    Text(form.power > 0 ? "\(form.power) power" : move.category == "Other" ? "status" : "—")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .opacity(0.85)
                    if form.note != nil {
                        Text(ahead.field.weather != .none ? "in \(ahead.field.weather.rawValue.lowercased())"
                             : "on \(ahead.field.terrain.rawValue.lowercased()) terrain")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.22))
                            .clipShape(Capsule())
                            .help("Read from the field as the move would be used, so whatever weather is up when it resolves is what it becomes.")
                    }
                    if retyped {
                        Text("\(ahead.build.ability): \(type.rawValue)")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.22))
                            .clipShape(Capsule())
                            .help("\(ahead.build.ability) turns this Normal move into a \(type.rawValue) move and adds a fifth to its power.")
                    }
                    if let charge = move.charge {
                        let waived = charge.skipsIn != nil && ahead.field.weather == charge.skipsIn
                        let boost = charge.boosts.map { "+\($1) \($0.short)" }.joined(separator: " ")
                        Text(waived ? "fires at once in \(ahead.field.weather.rawValue.lowercased())"
                                    + (boost.isEmpty ? "" : " · \(boost) first")
                             : "charges a turn" + (boost.isEmpty ? "" : " · \(boost) now")
                                    + (charge.hides ? " · out of reach" : ""))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.22))
                            .clipShape(Capsule())
                            .help(waived
                                  ? "The weather waives the charging turn: it boosts and fires this turn."
                                  : "This turn winds it up; next turn it fires at the same target, whatever else happens. Switching out gives up the charge.")
                    }
                    if Move.protectMoves.contains(move.name), fighter.protectStreak > 0 {
                        Text("\(Int((fighter.protectChance * 100).rounded()))% chance after last turn's")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Palette.warn.opacity(0.55))
                            .clipShape(Capsule())
                            .help("Protect in a row: a third of the chance each time, back to certain after a turn without it or one that fails.")
                    }
                    Text(move.accuracyLabel == "—" ? "never misses" : "\(move.accuracyLabel)% acc")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .opacity(0.85)
                    Spacer(minLength: 0)
                }
                // One line per target, each with room for a name and a
                // number. Flowed inline they wrapped wherever the name
                // happened to be long, so no two tiles were the same height.
                VStack(alignment: .leading, spacing: 2) {
                    if perTarget.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: aimSymbol(aim)).font(.system(size: 9))
                            Text(aimLabel(aim)).font(.system(size: 10)).lineLimit(1)
                            if !usable {
                                Text(aim == .party ? "· nobody has fainted yet"
                                                   : "· only on the turn it comes in")
                                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(Array(perTarget.enumerated()), id: \.offset) { _, read in
                        HStack(spacing: 5) {
                            Image(systemName: aimSymbol(aim)).font(.system(size: 9))
                            Text(read.name)
                                .font(.system(size: 10)).lineLimit(1)
                                .layoutPriority(-1)
                            Spacer(minLength: 4)
                            Text(read.text)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).fixedSize()
                            if let mega = read.mega {
                                Text(mega)
                                    .font(.system(size: 9, design: .rounded))
                                    .monospacedDigit().lineLimit(1).fixedSize()
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.white.opacity(0.18))
                                    .clipShape(Capsule())
                                    .help("What it does if that one Mega Evolves first, which happens before any move.")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 11)
            // Every tile the same height, whatever it has to say. A grid of
            // four buttons no two of which are the same size is hard to read
            // at a glance and harder to click confidently.
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
            .background(
                LinearGradient(colors: [type.color, type.color.opacity(0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(aiming ? .white : .white.opacity(0.18), lineWidth: aiming ? 2 : 1))
            .shadow(color: type.color.opacity(aiming ? 0.5 : 0.25), radius: aiming ? 10 : 5, y: 2)
            .saturation(usable ? 1 : 0.2)
            .opacity(usable ? 1 : 0.55)
            .scaleEffect(aiming ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .help(move.effect)
        .animation(.easeOut(duration: 0.15), value: aiming)
    }

    private func aimSymbol(_ aim: Move.Aim) -> String {
        switch aim {
        case .foe:    return "scope"
        case .spread: return "rays"
        case .user:   return "person.fill"
        case .ally:   return "person.2.fill"
        case .side:   return "flag.fill"
        case .party:  return "arrow.uturn.up"
        }
    }

    private func aimLabel(_ aim: Move.Aim) -> String {
        switch aim {
        case .foe:    return "pick a target"
        case .spread: return "hits everything it reaches"
        case .user:   return "itself"
        case .ally:   return "its partner"
        case .side:   return "your side"
        case .party:  return "a fainted teammate"
        }
    }

    /// Which of them to aim at, with what it would do to each.
    /// Where a move goes: the whole panel, laid out like the field. Theirs on
    /// the right, your own partner on the left for the techs that want it,
    /// each with what the move would do to it.
    @ViewBuilder
    private func targetScreen(_ board: Board, slot: Int, move: Move, index: Int) -> some View {
        if move.aim == .party {
            partyTargets(board, slot: slot, move: move, index: index)
        } else {
            let partner = slot == 0 ? 1 : 0
            let ahead = session.evolving(board.mine[slot], slot: slot, board: board)
            let form = DamageCalc.fieldForm(of: move, in: ahead.field)
            let type = move.isDamaging ? AteAbility.resolve(type: form.type, ability: ahead.build.ability).type : form.type
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(move.name.uppercased())
                        .font(.system(size: 14, weight: .heavy)).kerning(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(type.color)
                        .clipShape(Capsule())
                    Text("Aim at")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { command = .fight } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("Back").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .controlSize(.small)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR SIDE").font(.system(size: 9, weight: .bold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                        if board.activeCount > 1, board.mine.indices.contains(partner),
                           !board.mine[partner].fainted {
                            targetCard(board, slot: slot, index: index, fighter: board.mine[partner],
                                       choice: Choice.attackingAlly(move: index), tint: Palette.accent,
                                       note: "your own — for the tech")
                        } else {
                            Text("Nobody beside you.").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("THEIR SIDE").font(.system(size: 9, weight: .bold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                        ForEach(Seat.farSlotsLeftToRight(board), id: \.self) { foe in
                            if !board.theirs[foe].fainted {
                                targetCard(board, slot: slot, index: index, fighter: board.theirs[foe],
                                           choice: .attack(move: index, target: foe), tint: Palette.warn,
                                           note: nil)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private func targetCard(_ board: Board, slot: Int, index: Int, fighter: Fighter,
                            choice: Choice, tint: Color, note: String?) -> some View {
        let reading = MovePreview(session: session, store: store).reading(board, fighter: board.mine[slot], slot: slot, choice: choice)
        return Button {
            session.set(choice, slot: slot)
            command = .menu
        } label: {
            HStack(spacing: 12) {
                SpriteImage(form: fighter.build.form, side: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(fighter.build.form.formLabel)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(fighter.hp)/\(fighter.maxHP)")
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let reading {
                        Text(reading.text)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(reading.tint)
                    } else {
                        Text("no damage").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if let note {
                        Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "scope").foregroundStyle(tint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// Which of your fallen to bring back.
    private func partyTargets(_ board: Board, slot: Int, move: Move, index: Int) -> some View {
        let fallen = (board.activeCount..<board.mine.count).filter { board.mine[$0].fainted }
        return VStack(alignment: .leading, spacing: 8) {
            Text("BRING BACK")
                .font(.system(size: 9, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                ForEach(fallen, id: \.self) { bench in
                    let fighter = board.mine[bench]
                    Button {
                        session.set(.attack(move: index, target: bench), slot: slot)
                        command = .menu
                    } label: {
                        HStack(spacing: 10) {
                            SpriteImage(form: fighter.build.form, side: 40).saturation(0.3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fighter.build.form.formLabel)
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text("back at \(fighter.maxHP / 2)/\(fighter.maxHP), on the bench")
                                    .font(.system(size: 10, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.uturn.up").foregroundStyle(Palette.good)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Palette.good.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.good.opacity(0.6), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                Button { command = .fight } label: {
                    Text("Back").font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    /// The bench, to switch to.
    private func partyList(_ board: Board, slot: Int) -> some View {
        let options = switchOptions(board)
            .map { (index: $0, reading: BattleSession.sendInReading(board, bench: $0)) }
            .sorted { $0.reading.score > $1.reading.score }
        return VStack(alignment: .leading, spacing: 8) {
            Text("SWITCH TO")
                .font(.system(size: 9, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)
            Text("Switching happens before anything else, and whoever comes in takes whatever was aimed at this slot.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { rank, option in
                    let fighter = board.mine[option.index]
                    Button {
                        session.set(.swap(to: option.index), slot: slot)
                        command = .menu
                    } label: {
                        HStack(spacing: 10) {
                            SpriteImage(form: fighter.build.form, side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(fighter.build.form.formLabel)
                                        .font(.system(size: 12, weight: .semibold))
                                    if rank == 0 && options.count > 1 {
                                        Text("BEST").font(.system(size: 8, weight: .bold)).kerning(0.4)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Palette.good.opacity(0.2))
                                            .foregroundStyle(Palette.good)
                                            .clipShape(Capsule())
                                    }
                                }
                                HStack(spacing: 4) {
                                    Text("\(fighter.hp)/\(fighter.maxHP)")
                                        .font(.system(size: 9, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                    ForEach(fighter.build.form.pokeTypes) { TypeChip(type: $0, size: .small) }
                                }
                                Text(option.reading.why)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rank == 0 ? Palette.good.opacity(0.10) : Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(rank == 0 ? Palette.good.opacity(0.5) : Palette.hairline,
                                          lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Both orders given: the order they will go in, and the button.
    private func readyToPlay(_ board: Board) -> some View {
        let mine = session.ordersAsPlay(board)
            ?? Play(left: leftPick ?? .pass, right: rightPick ?? .pass, megaSlot: megaSlot)
        return VStack(alignment: .leading, spacing: 12) {
            orderPreview(board)
            // Yours against the engine's, before you commit. Both are scored
            // against their mix, on one scale, so the gap means something.
            if let pick = enginePick, let yours = worth(mine), let best = worth(pick) {
                var game = TurnGame(board: board)
                let _ = { game.width = 10 }()
                HStack(spacing: 10) {
                    Text(String(format: "Your line %+.2f", yours))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "engine's %+.2f", best))
                        .font(.system(size: 11, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    if best - yours > 0.05 {
                        Text("· \(String(format: "%.2f", best - yours)) behind — it would \(game.describe(pick, mine: true))")
                            .font(.system(size: 10)).foregroundStyle(Palette.warn)
                            .lineLimit(1)
                    } else {
                        Text("· as good as the engine's").font(.system(size: 10))
                            .foregroundStyle(Palette.good)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.surfaceRaised.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if let grade {
                    Text(grade).font(.system(size: 10))
                        .foregroundStyle(grade.hasPrefix("That is")
                                         ? AnyShapeStyle(Palette.good) : AnyShapeStyle(Palette.warn))
                }
                if session.link == nil {
                    Toggle("Let the engine play me", isOn: $session.watching)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("The engine gives your orders too, so you can watch a game out and see what it does.")
                } else if let waiting = session.waitingOn, playing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(waiting).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    session.playTurn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        // Over a link the button locks your moves in; the turn
                        // plays once the other player has too.
                        Text(session.link == nil ? "PLAY THE TURN" : "CONFIRM MOVES").font(.system(size: 13, weight: .heavy)).kerning(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.75)],
                                               startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .shadow(color: Palette.accent.opacity(0.4), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(playing)
                .opacity(playing ? 0.6 : 1)
            }
        }
        .padding(16)
    }

    /// The benched Pokémon that could come in.
    private func switchOptions(_ board: Board) -> [Int] {
        guard board.mine.count > board.activeCount else { return [] }
        return (board.activeCount..<board.mine.count).filter { !board.mine[$0].fainted }
    }

    /// Who moves first, worked out before the turn is committed.
    ///
    /// Turn order is the thing a beginner gets wrong and an expert checks every
    /// time, and it is not only Speed: priority comes first, Trick Room inverts
    /// the rest, and a switch happens before any of it.
    private func orderPreview(_ board: Board) -> some View {
        var entries: [(label: String, detail: String, mine: Bool,
                       rank: Int, speed: Int)] = []
        func add(_ fighter: Fighter, choice: Choice?, mine: Bool, slot: Int) {
            guard !fighter.fainted else { return }
            let ahead: (build: Combatant, field: Field) = mine
                ? session.evolving(fighter, slot: slot, board: board)
                : (build: fighter.build, field: board.field)
            let speed = (mine ? ahead.build.speed(in: ahead.field)
                              : BattleSession.visibleSpeed(fighter, mine: mine, field: board.field))
                * ((mine ? board.myTailwind : board.theirTailwind) > 0 ? 2 : 1)
            if let choice, choice.isSwap {
                entries.append((fighter.build.form.formLabel, "switches, before anything",
                                mine, 99, speed))
                return
            }
            var priority = 0
            if let choice, case .attack(let index, _) = choice,
               fighter.moves.indices.contains(index) {
                priority = fighter.moves[index].priority
            } else if let choice, case .protectSelf(let index) = choice,
                      fighter.moves.indices.contains(index) {
                priority = fighter.moves[index].priority
            }
            let note = priority > 0 ? "priority +\(priority)"
                : (mine ? "Speed \(speed)" : "Speed about \(speed), item unseen")
            entries.append((fighter.build.form.formLabel, note, mine, priority, speed))
        }
        add(board.mine[0], choice: leftPick, mine: true, slot: 0)
        if board.activeCount > 1, board.mine.count > 1 {
            add(board.mine[1], choice: rightPick, mine: true, slot: 1)
        }
        for slot in 0..<min(board.activeCount, board.theirs.count) {
            add(board.theirs[slot], choice: nil, mine: false, slot: slot)
        }
        // Switches first, then priority, then Speed — and Trick Room turns the
        // Speed half upside down. Listing them in the order they were added
        // said a Speed 80 Pokémon moves before a Speed 130 one.
        entries.sort { first, second in
            if first.rank != second.rank { return first.rank > second.rank }
            return board.trickRoom > 0 ? first.speed < second.speed
                                       : first.speed > second.speed
        }
        return HStack(spacing: 6) {
            Text("LIKELY ORDER")
                .font(.system(size: 9, weight: .bold)).kerning(0.5)
                .foregroundStyle(.tertiary)
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 7))
                        .foregroundStyle(.quaternary)
                }
                Text(entry.label)
                    .font(.system(size: 10, weight: entry.mine ? .semibold : .regular))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((entry.mine ? Palette.accent : Palette.warn).opacity(0.14))
                    .foregroundStyle(entry.mine ? Palette.accent : Palette.warn)
                    .clipShape(Capsule())
                    .help(entry.detail)
            }
            Spacer(minLength: 0)
        }
    }

    /// How often the engine would click each of this Pokémon's moves, summed
    /// over every line in its mix that uses it. This is the number that goes
    /// on the tile, because it is the one worth seeing while choosing.
    private func engineShare(slot: Int, move: Int) -> Double {
        guard let thought else { return 0 }
        var total = 0.0
        for (index, play) in thought.plays.enumerated() where thought.mix.indices.contains(index) {
            let choice = slot == 0 ? play.left : play.right
            if case .attack(let m, _) = choice, m == move { total += thought.mix[index] }
        }
        return total
    }

    /// How often the engine would switch this slot out.
    private func engineSwitchShare(slot: Int) -> Double {
        guard let thought else { return 0 }
        var total = 0.0
        for (index, play) in thought.plays.enumerated() where thought.mix.indices.contains(index) {
            if (slot == 0 ? play.left : play.right).isSwap { total += thought.mix[index] }
        }
        return total
    }

    /// The single line the engine likes most.
    private var enginePick: Play? {
        guard let thought, let top = thought.mix.indices.max(by: { thought.mix[$0] < thought.mix[$1] }),
              thought.plays.indices.contains(top) else { return nil }
        return thought.plays[top]
    }

    /// What a pair of orders is worth against their mix, on the same scale the
    /// engine values its own line — so yours and its can sit side by side.
    private func worth(_ play: Play) -> Double? {
        guard let solved else { return nil }
        if let row = solved.myPlays.firstIndex(of: play) {
            return zip(solved.payoff[row], solved.theirMix).reduce(0) { $0 + $1.0 * $1.1 }
        }
        // A line the engine never listed — a third target, a move it trimmed —
        // is still yours to play, so it is scored the same way, against their
        // mix, rather than left blank.
        var total = 0.0
        // No belief board here: this only resolves cells, it never solves a
        // matrix, and it runs inside a view body.
        let game = TurnGame(board: board)
        for (column, theirs) in solved.theirPlays.enumerated() where solved.theirMix[column] > 0.001 {
            total += game.settle(play, theirs).expected * solved.theirMix[column]
        }
        return total
    }
}

/// One choice, which is a button you want to press.
private struct ActionButton: View {
    let label: String
    let symbol: String
    var detail: String? = nil
    var tint: Color? = nil
    let chosen: Bool
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(chosen ? AnyShapeStyle(Palette.accent)
                                            : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint ?? Palette.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(chosen ? Palette.accent.opacity(0.20)
                               : (hovering ? Palette.hairline.opacity(0.6) : Palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(chosen ? Palette.accent : Palette.hairline,
                              lineWidth: chosen ? 1.5 : 1))
            .scaleEffect(hovering && !chosen ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: chosen)
    }
}
