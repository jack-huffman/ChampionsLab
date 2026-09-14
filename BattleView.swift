//  BattleView.swift
//  Playing the matchup out, with both sides' reasoning on screen beside it.
//
//  A game starts at Team Preview, not at turn one: you see six and theirs, and
//  you choose four and an order before anything happens. That choice is most of
//  the game and it is made with less information than any later one, so it gets
//  its own screen rather than being assumed away.
//
//  Then the field, laid out as a field: yours on the left, theirs on the right,
//  both pairs facing. Each side carries its own analysis — what you should be
//  thinking about, and what they are probably thinking, including the parts
//  neither of you can see.
//
//  The battle is not the point. Playing a matchup out with the reasoning
//  showing is how a matchup is learned; a score out of a hundred is not.

import SwiftUI

struct BattleView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    enum Stage { case setup, preview, battle }

    @State private var stage: Stage = .setup
    @State private var myTeamID = ""
    @State private var opponentID = ""
    @State private var singles = false

    /// The four being brought, in order. The first two lead.
    @State private var bringing: [String] = []

    @State private var board: Board?
    @State private var log: [String] = []
    @State private var turn = 1
    @State private var leftPick: Choice?
    @State private var rightPick: Choice?
    @State private var thinking = false
    @State private var mySide: [String] = []
    @State private var theirSide: [String] = []
    @State private var searchNote = ""
    @State private var finished: String?
    /// Toggled beside the move, the way the game asks for it.
    @State private var megaSlot: Int?
    /// Who took a hit on the last turn, so they can flinch on screen.
    @State private var struck: Set<Int> = []
    @State private var struckTheirs: Set<Int> = []

    /// Seeded state, so tools/snapshot.sh can render a screen nobody has
    /// clicked into. Done through init rather than onAppear, which an
    /// ImageRenderer never calls.
    init(openTeams: (mine: String, theirs: String)? = nil,
         previewing: [String] = [],
         playing: Board? = nil) {
        if let openTeams {
            _myTeamID = State(initialValue: openTeams.mine)
            _opponentID = State(initialValue: openTeams.theirs)
            _stage = State(initialValue: .preview)
        }
        if !previewing.isEmpty { _bringing = State(initialValue: previewing) }
        if let playing {
            _board = State(initialValue: playing)
            _stage = State(initialValue: .battle)
            _log = State(initialValue: ["Both sides send out their leads. Neither knows what the other is holding, nor which four came."])
        }
    }

    private var myTeam: Team? { store.teams.first { $0.id.uuidString == myTeamID } }
    private var theirTeam: Team? {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            return store.opponentTeam(meta)
        }
        return store.teams.first { $0.id.uuidString == opponentID }
    }
    private var bringCount: Int { singles ? 3 : 4 }
    private var leadCount: Int { singles ? 1 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            setupBar
            Divider()
            Group {
                switch stage {
                case .setup:
                    EmptyHint(symbol: "gamecontroller", title: "Play a matchup out",
                              detail: "Pick your six and theirs, then choose which four you bring and in what order. The engine searches each turn and shows what it is thinking, what it believes they are thinking, and what neither of you can see.")
                case .preview:
                    if snapshotMode { previewBoard } else { ScrollView { previewBoard } }
                case .battle:
                    if let board {
                        if snapshotMode { field(board) } else { ScrollView { field(board) } }
                    }
                }
            }
        }
    }

    // MARK: Choosing the teams

    private var setupBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $myTeamID) {
                Text("Your team").tag("")
                ForEach(store.teams) { Text($0.name).tag($0.id.uuidString) }
            }.labelsHidden().frame(width: 180).controlSize(.small)
            .onChange(of: myTeamID) { _ in reset() }

            Text("versus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)

            Picker("", selection: $opponentID) {
                Text("Opponent").tag("")
                SwiftUI.Section("Meta archetypes") {
                    ForEach(store.data.metaTeams.filter { $0.record == nil }) {
                        Text($0.name).tag($0.id)
                    }
                }
                SwiftUI.Section("Tournament results") {
                    ForEach(store.data.metaTeams.filter { $0.record != nil }.prefix(40)) {
                        Text($0.name).tag($0.id)
                    }
                }
                SwiftUI.Section("My teams") {
                    ForEach(store.teams) { Text($0.name).tag($0.id.uuidString) }
                }
            }.labelsHidden().frame(width: 200).controlSize(.small)
            .onChange(of: opponentID) { _ in reset() }

            Picker("", selection: $singles) {
                Text("Doubles").tag(false)
                Text("Singles").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .onChange(of: singles) { _ in reset() }

            Button("Team Preview") {
                stage = .preview
                bringing = []
            }
            .controlSize(.small)
            .disabled(myTeam == nil || theirTeam == nil)

            if stage == .battle {
                Button("Back to preview") { stage = .preview }.controlSize(.small)
            }
            Spacer()
            if stage == .battle {
                Text("Turn \(turn)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func reset() {
        stage = .setup; bringing = []; board = nil; finished = nil
        log = []; mySide = []; theirSide = []
    }

    // MARK: Team Preview

    private var previewBoard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(
                        title: "Team Preview",
                        subtitle: "Choose the \(bringCount) you bring, in order. "
                            + (singles ? "The first leads."
                                       : "The first two lead; the others come in behind."))
                    if let mine = myTeam {
                        HStack(spacing: 8) {
                            ForEach(Array(mine.slots.enumerated()), id: \.offset) { _, slot in
                                previewTile(slot)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(bringing.isEmpty
                             ? "Nothing chosen yet."
                             : "Bringing: " + bringing.enumerated().map { index, id in
                                "\(index + 1). \(label(id))" }.joined(separator: "   "))
                            .font(.system(size: 11))
                            .foregroundStyle(bringing.isEmpty ? .tertiary : .secondary)
                        Spacer()
                        Button("Suggest") { autoPick() }.controlSize(.small)
                        Button("Clear") { bringing = [] }.controlSize(.small)
                        Button("Start the battle") { begin() }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                            .disabled(bringing.count < bringCount)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "What they registered",
                                  subtitle: "They choose their own four, and you do not get to see which")
                    if let theirs = theirTeam {
                        HStack(spacing: 8) {
                            ForEach(Array(theirs.slots.enumerated()), id: \.offset) { _, slot in
                                if let form = slot.battleForm(in: store) {
                                    VStack(spacing: 3) {
                                        SpriteImage(form: form, side: 52)
                                        Text(form.formLabel).font(.system(size: 10))
                                            .lineLimit(1).minimumScaleFactor(0.7)
                                        Text(likelyItem(form)).font(.system(size: 9))
                                            .foregroundStyle(Palette.warn.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 86)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func previewTile(_ slot: TeamSlot) -> some View {
        let form = slot.battleForm(in: store)
        let id = slot.formID
        let order = bringing.firstIndex(of: id).map { $0 + 1 }
        return Button {
            if let at = bringing.firstIndex(of: id) { bringing.remove(at: at) }
            else if bringing.count < bringCount { bringing.append(id) }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    if let form { SpriteImage(form: form, side: 62) }
                    if let order {
                        Text("\(order)")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 17, height: 17)
                            .background(order <= leadCount ? Palette.accent : Palette.dim)
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                }
                Text(form?.formLabel ?? slot.formID)
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
                Text(order.map { $0 <= leadCount ? "leads" : "in the back" } ?? " ")
                    .font(.system(size: 9))
                    .foregroundStyle(order != nil && order! <= leadCount
                                     ? AnyShapeStyle(Palette.accent)
                                     : AnyShapeStyle(.tertiary))
            }
            .frame(width: 96)
            .padding(.vertical, 8)
            .background(order != nil ? Palette.accent.opacity(0.14) : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                order != nil ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// What it is called on the field, not what it is called on the list: a
    /// slot registered as Charizard holding a Charizardite is a Mega Charizard
    /// Y, and the tiles above already say so.
    private func label(_ formID: String) -> String {
        if let slot = myTeam?.slots.first(where: { $0.formID == formID }),
           let form = slot.battleForm(in: store) {
            return form.formLabel
        }
        return store.formsByID[formID]?.formLabel ?? formID
    }

    /// What the bring-four search would take, as a starting point.
    private func autoPick() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        let grid = Matchup(mine: mine, theirs: theirs, store: store,
                           field: Field(isDoubles: !singles))
        let picker = BringFour(matchup: grid, store: store, bring: bringCount)
        guard let plan = picker.plans.first else { return }
        // The plan names battle forms; the preview is keyed on what is
        // registered, which for a Mega is the base.
        bringing = plan.bring.compactMap { form in
            mine.slots.first { $0.battleForm(in: store)?.id == form.id }?.formID
        }
    }

    private func begin() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        // Only the four, in the order chosen.
        var brought = mine
        brought.slots = bringing.compactMap { id in mine.slots.first { $0.formID == id } }
        guard brought.slots.count >= leadCount else { return }

        // They choose their own four the same way, against your six.
        let grid = Matchup(mine: theirs, theirs: mine, store: store,
                           field: Field(isDoubles: !singles))
        let picker = BringFour(matchup: grid, store: store, bring: bringCount)
        var theirBrought = theirs
        if let plan = picker.plans.first {
            theirBrought.slots = plan.bring.compactMap { form in
                theirs.slots.first { $0.battleForm(in: store)?.id == form.id }
            }
        }
        if theirBrought.slots.count < leadCount { theirBrought = theirs }

        var made = Board(mine: brought, theirs: theirBrought, store: store,
                         field: Field(isDoubles: !singles), alreadyEvolved: false)
        made.activeCount = leadCount
        board = made
        stage = .battle
        turn = 1
        finished = nil
        leftPick = nil; rightPick = nil; megaSlot = nil
        log = ["Both sides send out their leads. Neither knows what the other is holding, nor which four came."]
        think()
    }

    // MARK: The field

    private func field(_ board: Board) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let finished {
                Card { Label(finished, systemImage: "flag.checkered")
                    .font(.system(size: 14, weight: .semibold)) }
            }
            arena(board)
            if finished == nil { choices(board) }
            analysisPanels()
            if !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader(title: "What happened")
                        ForEach(Array(log.enumerated().reversed()), id: \.offset) {
                            index, line in
                            let latest = index == log.count - 1
                            Text(line)
                                .font(.system(size: 11, weight: latest ? .medium : .regular))
                                .foregroundStyle(latest ? AnyShapeStyle(.primary)
                                                        : AnyShapeStyle(.secondary))
                                .padding(.horizontal, latest ? 8 : 0)
                                .padding(.vertical, latest ? 5 : 0)
                                .background(latest ? Palette.accent.opacity(0.10) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    /// The field itself. Tinted by whatever weather is up, because that is the
    /// single most useful thing to be able to see without reading.
    private func arena(_ board: Board) -> some View {
        let tint: Color = {
            switch board.field.weather {
            case .sun:  return Color(red: 0.95, green: 0.62, blue: 0.20)
            case .rain: return Color(red: 0.30, green: 0.55, blue: 0.90)
            case .sand: return Color(red: 0.80, green: 0.68, blue: 0.36)
            case .snow: return Color(red: 0.62, green: 0.82, blue: 0.92)
            case .none:
                switch board.field.terrain {
                case .grassy:   return Color(red: 0.40, green: 0.74, blue: 0.38)
                case .electric: return Color(red: 0.93, green: 0.82, blue: 0.25)
                case .psychic:  return Color(red: 0.86, green: 0.38, blue: 0.60)
                case .misty:    return Color(red: 0.80, green: 0.56, blue: 0.86)
                case .none:     return Palette.accent
                }
            }
        }()
        let lit = board.field.weather != .none || board.field.terrain != .none
        return VStack(spacing: 10) {
            fieldState(board)
            HStack(alignment: .top, spacing: 0) {
                sideColumn(board, mine: true)
                VStack(spacing: 5) {
                    Rectangle().fill(tint.opacity(0.35)).frame(width: 1, height: 64)
                    Text("VS").font(.system(size: 10, weight: .heavy)).kerning(1)
                        .foregroundStyle(tint.opacity(0.85))
                    Rectangle().fill(tint.opacity(0.35)).frame(width: 1, height: 64)
                }
                .frame(width: 54)
                sideColumn(board, mine: false)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [tint.opacity(lit ? 0.16 : 0.07),
                                    tint.opacity(lit ? 0.05 : 0.02)],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(lit ? 0.45 : 0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: board.field.weather)
        .animation(.easeInOut(duration: 0.4), value: board.field.terrain)
    }

    @ViewBuilder
    private func fieldState(_ board: Board) -> some View {
        let bits = [board.field.weather != .none ? board.field.weather.rawValue : nil,
                    board.field.terrain != .none ? "\(board.field.terrain.rawValue) Terrain" : nil,
                    board.myTailwind > 0 ? "your Tailwind \(board.myTailwind)" : nil,
                    board.theirTailwind > 0 ? "their Tailwind \(board.theirTailwind)" : nil,
                    board.trickRoom > 0 ? "Trick Room \(board.trickRoom)" : nil]
            .compactMap { $0 }
        if bits.isEmpty {
            Text("clear field")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 5) {
                Image(systemName: weatherSymbol(board.field))
                    .font(.system(size: 10))
                Text(bits.joined(separator: " · "))
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    private func weatherSymbol(_ field: Field) -> String {
        switch field.weather {
        case .sun:  return "sun.max.fill"
        case .rain: return "cloud.rain.fill"
        case .sand: return "aqi.medium"
        case .snow: return "snowflake"
        case .none: return field.terrain == .none ? "circle.grid.cross" : "square.stack.3d.down.forward.fill"
        }
    }

    private func sideColumn(_ board: Board, mine: Bool) -> some View {
        let team = mine ? board.mine : board.theirs
        return VStack(alignment: mine ? .leading : .trailing, spacing: 8) {
            Text(mine ? "YOURS" : "THEIRS")
                .font(.system(size: 9, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                if !mine { Spacer(minLength: 0) }
                ForEach(Array(team.prefix(board.activeCount).enumerated()), id: \.offset) {
                    slot, fighter in
                    fighterCard(fighter, mine: mine, slot: slot, field: board.field)
                }
                if mine { Spacer(minLength: 0) }
            }
            HStack(spacing: 4) {
                if !mine { Spacer(minLength: 0) }
                ForEach(Array(team.dropFirst(board.activeCount).enumerated()), id: \.offset) {
                    _, fighter in
                    VStack(spacing: 2) {
                        SpriteImage(form: fighter.build.form, side: 30)
                            .opacity(fighter.fainted ? 0.25 : 1)
                            .saturation(fighter.fainted ? 0 : 1)
                        Text(fighter.build.form.formLabel)
                            .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: 52)
                }
                if mine { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fighterCard(_ fighter: Fighter, mine: Bool, slot: Int,
                             field: Field) -> some View {
        let hit = mine ? struck.contains(slot) : struckTheirs.contains(slot)
        let health = fighter.share
        let bar: Color = health > 0.5 ? Palette.good
            : (health > 0.2 ? Palette.warn : Palette.bad)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                SpriteImage(form: fighter.build.form, side: 78)
                    .opacity(fighter.fainted ? 0.22 : 1)
                    .saturation(fighter.fainted ? 0 : 1)
                    .scaleEffect(fighter.fainted ? 0.86 : (hit ? 1.1 : 1))
                    .rotationEffect(.degrees(fighter.fainted ? -12 : 0))
                    .shadow(color: hit ? Palette.bad.opacity(0.55) : .clear, radius: 9)
                    .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                    .animation(.easeOut(duration: 0.35), value: fighter.fainted)
                if fighter.pendingMega != nil {
                    Text("M").font(.system(size: 9, weight: .heavy))
                        .frame(width: 17, height: 17)
                        .background(Palette.warn).foregroundStyle(.white)
                        .clipShape(Circle())
                        .help("Holding its stone. It Mega Evolves only if you toggle it on "
                              + "with a move, before anything else happens, in Speed order.")
                } else if fighter.build.form.isMega {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warn)
                        .help("Mega Evolved")
                }
            }
            Text(fighter.build.form.formLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.65)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(height: 7)
                GeometryReader { geo in
                    Capsule().fill(bar).frame(width: geo.size.width * health)
                }
                .frame(height: 7)
            }
            .frame(height: 7)
            .animation(.easeOut(duration: 0.45), value: fighter.hp)
            HStack(spacing: 4) {
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                // Yours is what it is. Theirs is what you could work out from
                // the stat, because showing the real number would quietly tell
                // you about the Choice Scarf the card above says you cannot see.
                Text("· \(visibleSpeed(fighter, mine: mine, field: field))\(mine ? "" : "?")")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help(mine
                          ? "Speed on the field, item and weather abilities included"
                          : "What its Speed would be with no item. You cannot see what it is holding, so you cannot see a Choice Scarf either.")
            }
            Text(mine ? (fighter.build.item.isEmpty ? "no item" : fighter.build.item)
                      : likelyItem(fighter.build.form))
                .font(.system(size: 9))
                .foregroundStyle(mine ? AnyShapeStyle(.tertiary)
                                      : AnyShapeStyle(Palette.warn.opacity(0.85)))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(fighter.build.ability)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.accent.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 118)
        .padding(.vertical, 8).padding(.horizontal, 4)
        .background(fighter.fainted ? Color.clear : Palette.surfaceRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Their Speed as far as anybody could know it: the stat, without the item
    /// nobody has seen yet.
    private func visibleSpeed(_ fighter: Fighter, mine: Bool, field: Field) -> Int {
        guard !mine else { return fighter.build.speed(in: field) }
        var blind = fighter.build
        blind.item = ""
        return blind.speed(in: field)
    }

    /// What the measured ladder says they are probably holding.
    private func likelyItem(_ form: Form) -> String {
        let engine = BattleEngine(store: store)
        guard let best = engine.itemOdds(for: form).first else { return "item unknown" }
        if best.chance >= 0.99 { return best.item }
        return String(format: "likely %@ (%.0f%%)", best.item, best.chance * 100)
    }

    // MARK: Choosing

    @ViewBuilder
    private func choices(_ board: Board) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your turn",
                              subtitle: "Both sides lock in at the same moment, then Speed decides the order")
                ForEach(0..<board.activeCount, id: \.self) { slot in
                    if board.mine.indices.contains(slot), !board.mine[slot].fainted {
                        slotChoices(board, slot: slot)
                    }
                }
                orderPreview(board)
                HStack {
                    Button(thinking ? "Thinking…" : "Think again") { think() }
                        .controlSize(.small).disabled(thinking)
                    if !searchNote.isEmpty {
                        Text(searchNote).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Play the turn") { playTurn() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready(board))
                }
            }
        }
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
            let speed = visibleSpeed(fighter, mine: mine, field: board.field)
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

    private func ready(_ board: Board) -> Bool {
        guard leftPick != nil else { return false }
        guard board.activeCount > 1, board.mine.count > 1, !board.mine[1].fainted
        else { return true }
        return rightPick != nil
    }

    private func slotChoices(_ board: Board, slot: Int) -> some View {
        var game = TurnGame(board: board, store: store)
        game.width = 10
        let options = game.choices(forMine: true, slot: slot)
        let fighter = board.mine[slot]
        let picked = slot == 0 ? leftPick : rightPick
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SpriteImage(form: fighter.build.form, side: 24)
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .semibold))
                Text("Speed \(fighter.build.speed(in: board.field))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                // The toggle sits with the move because that is where the game
                // puts it: you flip it on as you choose what this Pokémon does.
                if let mega = fighter.pendingMega,
                   !board.mine.contains(where: \.hasMegaEvolved) {
                    Button {
                        megaSlot = megaSlot == slot ? nil : slot
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: megaSlot == slot
                                  ? "sparkles" : "circle.dashed")
                                .font(.system(size: 9))
                            Text("Mega Evolve")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(megaSlot == slot ? Palette.warn.opacity(0.22)
                                                     : Palette.surface)
                        .foregroundStyle(megaSlot == slot
                                         ? AnyShapeStyle(Palette.warn)
                                         : AnyShapeStyle(.secondary))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            megaSlot == slot ? Palette.warn.opacity(0.7) : Palette.hairline,
                            lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Becomes \(mega.formLabel) before anything else happens this turn. "
                          + "If both sides evolve, the slower one goes second — and when both "
                          + "bring weather, the second one is the weather that stays.")
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, choice in
                    let label = game.describe(choice, fighter: fighter,
                                              foes: Array(board.theirs.prefix(board.activeCount)),
                                              team: board.mine)
                    let chosen = picked == choice
                    ActionButton(label: label.isEmpty ? "do nothing" : label,
                                 symbol: choice.isSwap ? "arrow.left.arrow.right"
                                    : (choice.isProtect ? "shield.lefthalf.filled" : "bolt.fill"),
                                 chosen: chosen) {
                        if slot == 0 { leftPick = choice } else { rightPick = choice }
                    }
                }
            }
        }
    }

    // MARK: The two analyses

    private func analysisPanels() -> some View {
        HStack(alignment: .top, spacing: 14) {
            analysis("Your side", mySide, Palette.accent,
                     empty: thinking ? "Searching…" : "Press Think.")
            analysis("Their side", theirSide, Palette.warn,
                     empty: "What they are probably weighing, and what they cannot see.")
        }
    }

    private func analysis(_ title: String, _ lines: [String], _ tint: Color,
                          empty: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                SectionHeader(title: title)
                if lines.isEmpty {
                    Text(empty).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
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

            var ours: [String] = []
            if let top = result.mix.indices.max(by: { result.mix[$0] < result.mix[$1] }),
               result.plays.indices.contains(top) {
                ours.append(String(format: "Best line, about %.0f%% of the time: %@.",
                                   result.mix[top] * 100,
                                   game.describe(result.plays[top], mine: true)))
            }
            ours.append(String(format: "Looking %d turns out the position is worth %+.2f to you.",
                               result.depth, result.value))
            if abs(result.drift) > 0.15 {
                ours.append(String(format: "Searching deeper moved that by %+.2f, so the quick read was %@.",
                                   result.drift,
                                   result.drift < 0 ? "too optimistic" : "too pessimistic"))
            }
            if result.uncertainty > 0.2 {
                ours.append(String(format: "It swings %.2f on what they are actually holding, so this turn is a guess as much as a calculation.",
                                   result.uncertainty))
            }
            // Mega Evolution ordering, which decides a weather war on turn one.
            let evolvingMine = board.mine.prefix(board.activeCount).first { $0.pendingMega != nil }
            let evolvingTheirs = board.theirs.prefix(board.activeCount).first { $0.pendingMega != nil }
            if let ours1 = evolvingMine, let theirs1 = evolvingTheirs {
                let mySpeed = ours1.build.speed(in: board.field)
                let theirSpeed = theirs1.build.speed(in: board.field)
                let second = mySpeed < theirSpeed ? ours1 : theirs1
                ours.append("Both sides Mega Evolve before any move, fastest first. \(second.build.form.formLabel) is slower, so it evolves second — and if both bring weather or terrain, the second one is the one that sticks.")
            } else if let ours1 = evolvingMine {
                ours.append("\(ours1.build.form.formLabel) Mega Evolves before any move this turn, bringing whatever its new ability does with it.")
            }
            // If the line it likes involves evolving, say which and why the
            // order matters, since that is the toggle sitting on screen.
            if let top = result.mix.indices.max(by: { result.mix[$0] < result.mix[$1] }),
               result.plays.indices.contains(top),
               let wants = result.plays[top].megaSlot,
               board.mine.indices.contains(wants),
               let becoming = board.mine[wants].pendingMega {
                ours.append("It wants \(board.mine[wants].build.form.formLabel) to Mega Evolve into \(becoming.formLabel) this turn — the toggle beside its move.")
            }
            ours += result.principal
            mySide = ours
            searchNote = "searched \(result.depth) turns, \(result.nodes) positions"

            var theirs: [String] = []
            if let likely = solved.theirMix.indices.max(by: {
                solved.theirMix[$0] < solved.theirMix[$1] }),
               solved.theirPlays.indices.contains(likely) {
                theirs.append(String(format: "Most likely: %@, about %.0f%% of the time.",
                                     game.describe(solved.theirPlays[likely], mine: false),
                                     solved.theirMix[likely] * 100))
            }
            theirs += game.readingNotes(solved)
            let hidden = board.mine.prefix(board.activeCount)
                .map { "\($0.build.form.formLabel)'s \($0.build.item)" }
            if !hidden.isEmpty {
                theirs.append("They cannot see " + hidden.joined(separator: " or ")
                              + ", nor which four you brought, so they are playing the likeliest version of you.")
            }
            theirSide = theirs
            thinking = false
        }
    }

    private func playTurn() {
        guard var current = board, let left = leftPick else { return }
        var game = TurnGame(board: current, store: store)
        game.width = 10
        let solved = game.solve()
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
                        right: current.activeCount > 1 ? (rightPick ?? .pass) : .pass,
                        megaSlot: megaSlot)
        let before = current
        current = TurnModel.resolve(current, mine: mine, theirs: theirPlay, store: store)
        current.fillGaps()

        var entry = "Turn \(turn): you \(game.describe(mine, mine: true)); "
            + "they \(game.describe(theirPlay, mine: false))."
        // Mega Evolution is the first thing that happens, so it is the first
        // thing reported.
        for (index, fighter) in current.mine.enumerated() where index < before.mine.count {
            if before.mine[index].pendingMega != nil && fighter.pendingMega == nil {
                entry += " Your \(fighter.build.form.formLabel) Mega Evolved."
            }
        }
        for (index, fighter) in current.theirs.enumerated() where index < before.theirs.count {
            if before.theirs[index].pendingMega != nil && fighter.pendingMega == nil {
                entry += " Their \(fighter.build.form.formLabel) Mega Evolved."
            }
        }
        if current.field.weather != before.field.weather {
            entry += " The weather turned to \(current.field.weather.rawValue)."
        }
        if current.field.terrain != before.field.terrain {
            entry += " \(current.field.terrain.rawValue) Terrain went up."
        }
        for (index, fighter) in current.theirs.enumerated() where index < before.theirs.count {
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

        // Light up whatever took a hit, then let it settle.
        var hitMine: Set<Int> = [], hitTheirs: Set<Int> = []
        for index in current.mine.indices where index < before.mine.count
            && current.mine[index].hp < before.mine[index].hp { hitMine.insert(index) }
        for index in current.theirs.indices where index < before.theirs.count
            && current.theirs[index].hp < before.theirs[index].hp { hitTheirs.insert(index) }

        board = current
        turn += 1
        leftPick = nil; rightPick = nil; megaSlot = nil
        struck = hitMine; struckTheirs = hitTheirs
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            struck = []; struckTheirs = []
        }
        if current.isOut(mine: false) { finished = "They have nothing left. You win." }
        else if current.isOut(mine: true) { finished = "You have nothing left. They win." }
        else { think() }
    }
}

/// One choice, which is a button you want to press.
private struct ActionButton: View {
    let label: String
    let symbol: String
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
                Text(label)
                    .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                    .lineLimit(1)
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
