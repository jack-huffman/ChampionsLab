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

    enum Stage { case setup, versus, preview, battle }

    @State private var stage: Stage = .setup
    @State private var myTeamID = ""
    @State private var opponentID = ""
    @State private var opponentSearch = ""
    @State private var startHover = false
    /// Which search the view is waiting on; an older one's answer is dropped.
    @State private var thinkTicket = 0
    /// A turn is being played out: the button waits rather than starting a
    /// second one on top of the first.
    @State private var playing = false
    /// Every turn of this game, marked. Read back in the Review panel.
    @State private var review: [TurnReview] = []
    /// Which lobby is being worked out; an older one's answer is dropped.
    @State private var lobbyTicket = 0
    /// The start of the game, being shown: the flash, the leads coming out,
    /// their abilities going off. Nil once orders can be given.
    @State private var opening = false
    @State private var startFlash = false
    /// Which fighters have come out so far, as "m0", "t1".
    @State private var shown: Set<String> = []
    /// The line being called out over the field right now.
    @State private var callout: String?
    /// Replacements chosen so far this turn, sent in together once every gap
    /// has one, in Speed order alongside theirs.
    @State private var chosenSends: [(slot: Int, bench: Int)] = []
    /// Which of the three readings the side panel is showing.
    enum Panel: String, CaseIterable {
        case engine = "Engine", theirs = "Their read", review = "Review", log = "Log"
    }

    /// One turn, marked. What you did, what it was worth against the mix they
    /// were actually playing, and what the engine would have done instead —
    /// kept for every turn, so a finished game can be read back.
    struct TurnReview: Identifiable {
        let id = UUID()
        let turn: Int
        let yours: String
        let theirs: String
        /// Both on the same scale: what your line and the engine's were worth
        /// against their mix. Judging a choice against what they happened to
        /// play would reward luck.
        let played: Double
        let best: Double
        let bestLine: String
        /// The board as it stood before the turn, so it can be played again.
        let before: Board
        var lost: Double { max(0, best - played) }
    }
    @State private var panel: Panel = .engine
    /// What the two sixes say about each other, worked out once both are
    /// chosen and read by the versus page and Team Preview.
    @State private var lobby = Lobby()
    @State private var singles = false

    /// The four being brought, in order. The first two lead.
    @State private var bringing: [String] = []
    /// Whose matchups their side is showing. The one just picked, unless
    /// another of yours is clicked.
    @State private var focused: String?

    @State private var board: Board?
    @State private var log: [String] = []
    @State private var turn = 1
    @State private var leftPick: Choice?
    @State private var rightPick: Choice?
    @State private var thinking = false
    @State private var mySide: [String] = []
    /// The search itself, kept so the tiles can read it.
    @State private var thought: BattleEngine.Result?
    @State private var solved: TurnGame.Solution?
    /// Let the engine give my orders too, to watch a game out.
    @State private var watching = false
    @State private var theirSide: [String] = []
    @State private var searchNote = ""
    @State private var finished: String?
    /// Toggled beside the move, the way the game asks for it.
    @State private var megaSlot: Int?
    /// Who took a hit on the last turn, so they can flinch on screen.
    @State private var struck: Set<Int> = []
    @State private var struckTheirs: Set<Int> = []

    // -- a turn, played rather than printed ----------------------------------
    //
    // A turn resolves all at once; it used to appear all at once too, with one
    // flash on whatever had lost health. These walk the steps the model
    // recorded and show them in the order they happened.

    /// How long one move takes on screen. Four actions a turn, so this is the
    /// number that decides whether a turn feels brisk or slow.
    ///
    /// It was 0.52, which put four actions inside two seconds and ran them
    /// together into one event you could not follow. A move wants long enough
    /// to be read as a thing that happened to somebody.
    static let flourishSeconds: Double = 0.92
    /// A beat between one action and the next.
    ///
    /// Without it the moves were continuous — the second beam left before the
    /// first had finished bursting — and four separate decisions looked like
    /// one animation. The pause is what makes them four.
    static let betweenActions: Double = 0.24
    /// How far through a move the blow actually lands. The beam is travelling
    /// before this and bursting after it, and the board is held at the state
    /// *before* the move until this moment — so the health bar drops as the
    /// move arrives rather than before it has been thrown.
    static let impactAt: Double = 0.55

    /// The move being shown right now, and when it started. The start date is
    /// what the animation reads, so nothing in this view changes per frame.
    @State private var flourish: Flourish?
    @State private var flourishFrom = Date()
    /// The Pokémon leaning into a physical move, and how far.
    /// A slow rise and fall on every sprite. One repeating animation on a
    /// single value, so the render server owns it and nothing is rebuilt per
    /// frame — this screen has had enough trouble with things that redraw.
    /// What each Pokémon just lost, floating off it as the blow lands. The
    /// number is the thing a player actually wants at that moment and the log
    /// is the last place to look for it.
    @State private var damage: [Seat: Int] = [:]
    @State private var bob: CGFloat = 0
    @State private var lunging: Seat?
    @State private var lungeBy: CGSize = .zero
    /// The walk through a turn's steps. Held so that leaving the screen, or
    /// taking a turn back, stops it: a detached task nobody cancelled is what
    /// made this app stutter once already.
    @State private var playback: Task<Void, Never>?
    /// Every board so far, so a turn can be taken back and tried again.
    @State private var history: [(board: Board, log: [String], turn: Int)] = []
    /// What the engine wanted, against what was actually played.
    @State private var grade: String?
    /// The turn being walked through, and how far into it we are.
    @State private var replay: [Board.Step] = []
    @State private var at = 0
    /// The board the steps were recorded against, before anything fainted was
    /// replaced. Stepping through the finished board would map the health of a
    /// Pokémon that fainted onto the one that came in for it.
    @State private var replayBoard: Board?
    /// Where you are in giving orders to the Pokémon being commanded.
    @State private var command: Command = .menu
    /// Slots of mine standing empty, waiting for somebody to be sent in.
    @State private var sending: [Int] = []

    /// Seeded state, so tools/snapshot.sh can render a screen nobody has
    /// clicked into. Done through init rather than onAppear, which an
    /// ImageRenderer never calls.
    init(openTeams: (mine: String, theirs: String)? = nil,
         arriving: Stage? = nil,
         previewing: [String] = [],
         playing: Board? = nil,
         showing: Command = .menu,
         reviewing: [TurnReview] = [],
         logging: [String] = [],
         thinking seeded: (BattleEngine.Result, TurnGame.Solution)? = nil) {
        _command = State(initialValue: showing)
        if !logging.isEmpty {
            _log = State(initialValue: logging)
            _panel = State(initialValue: .log)
        }
        if !reviewing.isEmpty {
            _review = State(initialValue: reviewing)
            _panel = State(initialValue: .review)
        }
        // The search runs as a task, which a snapshot never gets to run, so a
        // snapshot hands the answer in ready-made.
        if let seeded {
            _thought = State(initialValue: seeded.0)
            _solved = State(initialValue: seeded.1)
        }
        if let openTeams {
            _myTeamID = State(initialValue: openTeams.mine)
            _opponentID = State(initialValue: openTeams.theirs)
            let stage = arriving ?? .preview
            _stage = State(initialValue: stage)
            // A snapshot never runs the step that works the two sixes out, so
            // it is done here, against the shared store the sprites also use.
            let shared = Store.shared
            if stage != .setup,
               let mine = shared.teams.first(where: { $0.id.uuidString == openTeams.mine }),
               let theirs = shared.data.metaTeams.first(where: { $0.id == openTeams.theirs })
                   .map({ shared.opponentTeam($0) })
                   ?? shared.teams.first(where: { $0.id.uuidString == openTeams.theirs }) {
                _lobby = State(initialValue: BattleView.lobby(mine: mine, theirs: theirs,
                                                              singles: false, rules: shared.rulebook))
            }
        }
        if !previewing.isEmpty { _bringing = State(initialValue: previewing) }
        if let playing {
            _board = State(initialValue: playing)
            _stage = State(initialValue: .battle)
            _log = State(initialValue: [BattleView.opener] + playing.story)
        }
    }

    static let opener = "Both sides send out their leads. Neither knows what the other is holding, nor which four came."
    /// A log line that is a turn marker rather than an event.
    static let dividerMark = "\u{00A7}"

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
                    teamPicking
                case .versus:
                    versusPage
                case .preview:
                    previewBoard
                case .battle:
                    if let board { field(board) }
                    else { openingCard.padding(14) }
                }
            }
        }
    }

    // MARK: Choosing the teams

    private var setupBar: some View {
        let ready = myTeam != nil && theirTeam != nil
        return HStack(spacing: 10) {
            Picker("", selection: $singles) {
                Text("Doubles").tag(false)
                Text("Singles").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .onChange(of: singles) { _ in reset() }

            Divider().frame(height: 18)

            crumb("Teams", .setup, symbol: "person.3", enabled: true)
            crumbArrow
            crumb("Versus", .versus, symbol: "bolt.fill", enabled: ready)
            crumbArrow
            crumb("Team Preview", .preview, symbol: "list.number", enabled: ready)
            crumbArrow
            crumb("Battle", .battle, symbol: "flag.2.crossed", enabled: board != nil)

            Spacer()
            if stage == .battle {
                Text("Turn \(turn)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var crumbArrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.quaternary)
    }

    private func crumb(_ title: String, _ target: Stage, symbol: String, enabled: Bool) -> some View {
        let current = stage == target
        return Button { go(to: target) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: current ? .semibold : .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(current ? Palette.accent.opacity(0.16) : Color.clear)
            .foregroundStyle(current ? AnyShapeStyle(Palette.accent)
                             : enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Move between the screens. Going forward works the two sixes out if that
    /// has not been done yet; going back never loses anything.
    private func go(to target: Stage) {
        switch target {
        case .setup:
            stage = .setup
        case .versus:
            if lobby.verdict == nil { enterVersus() } else { stage = .versus }
        case .preview:
            if lobby.verdict == nil { enterVersus() }
            stage = .preview
        case .battle:
            if board != nil { stage = .battle }
        }
    }

    private func reset() {
        stage = .setup; bringing = []; focused = nil; board = nil; finished = nil
        log = []; mySide = []; theirSide = []; lobby = Lobby()
    }

    // MARK: Choosing the teams

    /// Everything the two sixes say about each other, worked out once both
    /// are chosen: what you would bring, what they would, and what each side
    /// has reason to fear.
    struct Lobby {
        var verdict: Matchup.Verdict?
        var myPlan: BringFour.Plan?
        var theirPlan: BringFour.Plan?
        /// Yours that nothing on their six beats — what they are staring at.
        var theirFears: [Form] = []
        /// Theirs that nothing on your six beats.
        var myFears: [Form] = []
        /// The four they will expect you to bring, from their chair.
        var theirExpectation: [Form] = []
    }

    /// Two grids of thirty-six duels and two bring-four searches. Nothing here
    /// touches the store or the interface, so it runs wherever it is put.
    nonisolated static func lobby(mine: Team, theirs: Team, singles: Bool,
                                  rules: Rulebook) -> Lobby {
        let field = Field(isDoubles: !singles)
        let bring = singles ? 3 : 4
        let grid = Matchup(mine: mine, theirs: theirs, rules: rules, field: field)
        // The same arithmetic from the other side of the table: their four
        // is chosen against your six exactly as yours is against theirs.
        let flipped = Matchup(mine: theirs, theirs: mine, rules: rules, field: field)
        let theirPicker = BringFour(matchup: flipped, rules: rules, bring: bring)
        var out = Lobby()
        let verdict = grid.verdict
        out.verdict = verdict
        out.myFears = verdict.unanswered
        out.myPlan = BringFour(matchup: grid, rules: rules, bring: bring).plans.first
        out.theirPlan = theirPicker.plans.first
        out.theirExpectation = theirPicker.theirLikelyFour
        out.theirFears = flipped.verdict.unanswered
        return out
    }

    /// Show the versus page at once and work the two sixes out behind it: the
    /// page is mostly sprites, and the part that needs the arithmetic can
    /// arrive a moment later.
    private func enterVersus() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        bringing = []; focused = nil; board = nil; finished = nil
        log = []; mySide = []; theirSide = []
        lobby = Lobby()
        stage = .versus
        let rules = store.rulebook, singles = singles
        let ticket = lobbyTicket + 1
        lobbyTicket = ticket
        Task { @MainActor in
            let made = await Task.detached(priority: .userInitiated) {
                Self.lobby(mine: mine, theirs: theirs, singles: singles, rules: rules)
            }.value
            guard ticket == lobbyTicket else { return }
            withAnimation(.easeOut(duration: 0.25)) { lobby = made }
        }
    }

    private func choose(mine id: String) {
        myTeamID = id
        lobby = Lobby(); board = nil
        if theirTeam != nil { enterVersus() }
    }

    private func choose(theirs id: String) {
        opponentID = id
        lobby = Lobby(); board = nil
        if myTeam != nil { enterVersus() }
    }

    /// Every six you could line up against, with what it is made of.
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let tag: String
        let group: String
        let forms: [Form?]
    }

    private var format: String { singles ? "singles" : "doubles" }

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

    /// Both teams chosen by their six, side by side. Choosing the second one
    /// goes straight to the versus page.
    private var teamPicking: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                pickingHeader("Your team", count: store.teams.count,
                              hint: "One of your saved teams.")
                if store.teams.isEmpty {
                    EmptyHint(symbol: "person.3", title: "No teams yet",
                              detail: "Build one in Teams first.")
                } else {
                    scrolling {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(store.teams) { team in
                                Button { choose(mine: team.id.uuidString) } label: {
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
                scrolling {
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
                                            Button { choose(theirs: candidate.id) } label: {
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

    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if snapshotMode { content() } else { ScrollView { content() } }
    }

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

    // MARK: Versus

    private var versusPage: some View {
        VStack(spacing: 14) {
            if let mine = myTeam, let theirs = theirTeam {
                VersusBanner(mine: bannerSide(mine, plan: lobby.myPlan, title: "YOUR TEAM",
                                              tag: "\(mine.slots.count) Pokémon · \(format)",
                                              tint: Palette.accent),
                             theirs: bannerSide(theirs, plan: lobby.theirPlan, title: "THEIR TEAM",
                                                tag: theirTag, tint: Palette.bad),
                             score: lobby.verdict?.score ?? 0,
                             verdict: edgeWords(lobby.verdict?.score ?? 0))
                    .frame(height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))

                HStack(alignment: .top, spacing: 14) {
                    yourSideCard
                    theirSideCard
                }

                HStack {
                    Spacer()
                    Button {
                        bringing = []; focused = nil
                        stage = .preview
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "flag.2.crossed.fill")
                                .rotationEffect(.degrees(startHover ? -12 : 0))
                                .scaleEffect(startHover ? 1.15 : 1)
                            Text("START BATTLE").font(.system(size: 14, weight: .heavy))
                                .kerning(startHover ? 2.2 : 1.2)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 13)
                        .background(
                            // The two sides' colours meet in the button; on hover
                            // the seam slides, the way the divider above leans.
                            LinearGradient(colors: [Palette.accent, Palette.bad],
                                           startPoint: startHover ? .topLeading : .leading,
                                           endPoint: startHover ? .bottomTrailing : .trailing))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(startHover ? 0.55 : 0), lineWidth: 1.5))
                        .shadow(color: Palette.accent.opacity(startHover ? 0.6 : 0.4),
                                radius: startHover ? 18 : 10, y: startHover ? 6 : 4)
                        .shadow(color: Palette.bad.opacity(startHover ? 0.45 : 0),
                                radius: 18, y: 6)
                        .scaleEffect(startHover ? 1.06 : 1)
                        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: startHover)
                    }
                    .buttonStyle(.plain)
                    .onHover { startHover = $0 }
                    .keyboardShortcut(.defaultAction)
                    .help("On to Team Preview: choose the \(bringCount) you bring and their order, while they choose theirs.")
                    Spacer()
                }
            } else {
                EmptyHint(symbol: "bolt", title: "Choose both teams first")
            }
        }
        .padding(20)
    }

    /// What a slot is registered as — a Charizard, not the Mega it becomes.
    /// Plans and grids speak in battle forms; anything shown before the battle
    /// speaks in these, because that is what walks out.
    private func registered(_ battle: Form, in team: Team) -> Form {
        team.slots.first { $0.battleForm(in: store.rulebook)?.id == battle.id }?.form(in: store.rulebook) ?? battle
    }

    private func stoneHolders(_ team: Team) -> Set<String> {
        Set(team.slots.filter { $0.megaEvolution(in: store.rulebook) != nil }
                      .compactMap { $0.form(in: store.rulebook)?.id })
    }

    /// Theirs that *could* be holding a stone. Nobody's items are on show at
    /// Team Preview, so what you actually know about their Charizard is that
    /// Charizard has a Mega — not whether this one is carrying it. Reading
    /// their list would answer a question the game does not let you ask.
    private func possibleMegas(_ team: Team) -> Set<String> {
        Set(team.slots.compactMap { slot -> String? in
            guard let form = slot.form(in: store.rulebook) else { return nil }
            let couldMega = store.data.forms.contains { $0.isMega && $0.species == form.species }
            return couldMega ? form.id : nil
        })
    }

    /// How often that species actually carries its stone on the ladder.
    private func stoneOdds(_ form: Form) -> String {
        let engine = BattleEngine(rules: store.rulebook)
        guard let stone = engine.itemOdds(for: form).first(where: { $0.item.hasSuffix("ite") || $0.item.hasSuffix("ite X") || $0.item.hasSuffix("ite Y") || $0.item.hasSuffix("ite Z") })
        else { return "" }
        return String(format: " About %.0f%% of them carry %@.", stone.chance * 100, stone.item)
    }

    private func bannerSide(_ team: Team, plan: BringFour.Plan?, title: String, tag: String,
                            tint: Color) -> VersusBanner.Side {
        let all = team.slots.compactMap { $0.battleForm(in: store.rulebook) }
        // The predicted four first, leads leading; the two left home last.
        let ordered: [Form]
        if let plan {
            ordered = plan.bring + all.filter { form in !plan.bring.contains { $0.id == form.id } }
        } else {
            ordered = all
        }
        let mine = team.id == myTeam?.id
        return VersusBanner.Side(title: title, name: team.name, tag: tag,
                                 forms: ordered.map { registered($0, in: team) },
                                 megas: mine ? stoneHolders(team) : possibleMegas(team),
                                 megasUncertain: !mine,
                                 leadCount: plan == nil ? 0 : leadCount, tint: tint)
    }

    private var theirTag: String {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            if meta.projected { return "projected · \(meta.archetype)" }
            if let record = meta.record {
                return ([record] + [meta.placement].compactMap { $0 }).joined(separator: " · ")
            }
            return meta.archetype
        }
        return "\(theirTeam?.slots.count ?? 0) Pokémon · \(theirTeam?.format ?? format)"
    }

    private var yourSideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your side", subtitle: "What the engine would bring, and why")
                if let plan = lobby.myPlan, let mine = myTeam {
                    fourRow(plan.bring.map { registered($0, in: mine) }, megas: stoneHolders(mine),
                            leads: leadCount, tint: Palette.accent)
                    bullets(Array(plan.reasons.prefix(2)) + Array(plan.warnings.prefix(1)),
                            tint: Palette.accent)
                    if !lobby.myFears.isEmpty {
                        Label("Nothing on your six beats their \(names(lobby.myFears)). That is the matchup.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Your six are at or under the limit, so everyone comes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var theirSideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Through their eyes",
                              subtitle: "What they see when they look at your six")
                if let plan = lobby.theirPlan, let theirs = theirTeam {
                    Text("They will most likely bring")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    fourRow(plan.bring.map { registered($0, in: theirs) }, megas: possibleMegas(theirs),
                            uncertain: true, leads: leadCount, tint: Palette.bad)
                    bullets(plan.reasons.prefix(2).map(fromTheirChair), tint: Palette.bad)
                    if !lobby.theirFears.isEmpty {
                        Label("Nothing on their six beats your \(names(lobby.theirFears)) — expect them to play around it, not into it.",
                              systemImage: "eye.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !lobby.theirExpectation.isEmpty {
                        Text("They cannot see which four you bring or what anyone holds. From your six they will expect \(names(lobby.theirExpectation)).")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Their six are at or under the limit, so everyone comes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fourRow(_ forms: [Form], megas: Set<String> = [], uncertain: Bool = false,
                         leads: Int, tint: Color) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(forms.enumerated()), id: \.offset) { index, form in
                VStack(spacing: 2) {
                    ZStack(alignment: .topLeading) {
                        SpriteImage(form: form, side: 52)
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(index < leads ? tint : Palette.dim)
                            .clipShape(Circle())
                        if megas.contains(form.id) {
                            megaBadge(uncertain: uncertain, form: form)
                                .frame(maxWidth: .infinity, alignment: .topTrailing)
                                .frame(width: 52)
                        }
                    }
                    Text(form.formLabel)
                        .font(.system(size: 10, weight: index < leads ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if index < leads {
                        Text("LEAD").font(.system(size: 7, weight: .heavy)).kerning(0.5)
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 72)
            }
            Spacer(minLength: 0)
        }
    }

    private func bullets(_ lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 5)
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func names(_ forms: [Form]) -> String {
        let labels = forms.map(\.formLabel)
        if labels.count <= 1 { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + " and " + labels.last!
    }

    /// A reason written for the side that made the plan, read from the other
    /// chair: their "your" is your "their", and the other way round.
    private func fromTheirChair(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "Your ", with: "\u{1}")
        out = out.replacingOccurrences(of: "your ", with: "\u{2}")
        out = out.replacingOccurrences(of: "Their ", with: "Your ")
        out = out.replacingOccurrences(of: "their ", with: "your ")
        out = out.replacingOccurrences(of: "\u{1}", with: "Their ")
        out = out.replacingOccurrences(of: "\u{2}", with: "their ")
        out = out.replacingOccurrences(of: " you left home", with: " they left home")
        out = out.replacingOccurrences(of: "off you", with: "off them")
        return out
    }

    // MARK: Team Preview

    private var previewBoard: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let lean = tan(25 * CGFloat.pi / 180) * h / 2
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09)
                Slab(lean: lean, left: true)
                    .fill(LinearGradient(colors: [Palette.accent.opacity(0.50), Palette.accent.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Slab(lean: lean, left: false)
                    .fill(LinearGradient(colors: [Palette.bad.opacity(0.06), Palette.bad.opacity(0.50)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                SlantLines(lean: lean, spacing: 44).stroke(.white.opacity(0.05), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2 + lean, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width / 2 - lean, y: h))
                }
                .stroke(.white.opacity(0.35), lineWidth: 2)
                .shadow(color: .white.opacity(0.3), radius: 8)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TEAM PREVIEW").font(.system(size: 26, weight: .black)).italic()
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                            Text("Choose the \(bringCount) you bring, in order. "
                                 + (singles ? "The first leads."
                                            : "The first two lead; the others come in behind.")
                                 + " They are choosing too: their likely four is marked, and each shows how the one you just picked fares against it.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 620, alignment: .leading)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("BRINGING").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            Text("\(bringing.count) of \(bringCount)")
                                .font(.system(size: 22, weight: .black, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.white)
                        }
                    }

                    HStack(alignment: .top, spacing: 72) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR SIX").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            ForEach(Array((myTeam?.slots ?? []).enumerated()), id: \.offset) {
                                _, slot in
                                previewRow(slot)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 6) {
                            Text("THEIR SIX").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            ForEach(Array((theirTeam?.slots ?? []).enumerated()), id: \.offset) {
                                _, slot in
                                opposingRow(slot)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        Text(bringing.isEmpty
                             ? "Nothing chosen yet. Click your Pokémon in the order they should come."
                             : bringing.enumerated().map { index, id in
                                "\(index + 1). \(label(id))" }.joined(separator: "   "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(bringing.isEmpty ? 0.55 : 0.9))
                        Spacer()
                        previewButton("Suggest", symbol: "wand.and.stars") { autoPick() }
                        previewButton("Clear", symbol: "xmark") { bringing = []; focused = nil }
                        Button { begin() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "flag.2.crossed.fill")
                                Text("START THE BATTLE").font(.system(size: 13, weight: .heavy)).kerning(1.2)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 11)
                            .background(LinearGradient(colors: [Palette.accent, Palette.bad],
                                                       startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                            .opacity(bringing.count < bringCount ? 0.4 : 1)
                            .shadow(color: Palette.accent.opacity(bringing.count < bringCount ? 0 : 0.45), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(bringing.count < bringCount)
                    }
                }
                .padding(22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .padding(14)
    }

    /// The mark the field puts on a stone-holder: it starts as itself. On
    /// their side it is a question, because their items are not on show.
    private func megaBadge(uncertain: Bool, form: Form) -> some View {
        Text(uncertain ? "M?" : "M")
            .font(.system(size: uncertain ? 7 : 8, weight: .heavy)).foregroundStyle(.white)
            .frame(width: uncertain ? 18 : 14, height: 14)
            .background(uncertain ? Palette.warn.opacity(0.7) : Palette.warn)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(uncertain ? 0.5 : 0),
                                            style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
            .help(uncertain
                  ? "\(form.formLabel) has a Mega, and you cannot see what this one holds." + stoneOdds(form)
                  : "Holding its stone. It starts as itself and Mega Evolves when it uses a move.")
    }

    private func previewButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// One of mine, in the order it is being brought.
    private func previewRow(_ slot: TeamSlot) -> some View {
        let form = slot.form(in: store.rulebook)
        let holdsStone = slot.megaEvolution(in: store.rulebook) != nil   // yours: you know
        let id = slot.formID
        let order = bringing.firstIndex(of: id).map { $0 + 1 }
        let isFocus = focused == id || (focused == nil && bringing.last == id)
        return Button {
            if let at = bringing.firstIndex(of: id) {
                bringing.remove(at: at)
                focused = bringing.last
            } else if bringing.count < bringCount {
                bringing.append(id)
                focused = id
            } else {
                focused = bringing.contains(id) ? id : focused
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(order == nil ? Color.white.opacity(0.15)
                              : (order! <= leadCount ? Palette.accent : Color.white.opacity(0.35)))
                        .frame(width: 20, height: 20)
                    Text(order.map(String.init) ?? "")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                if let form {
                    ZStack(alignment: .topTrailing) {
                        SpriteImage(form: form, side: 46).shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        if holdsStone { megaBadge(uncertain: false, form: form) }
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(form?.formLabel ?? id)
                        .font(.system(size: 12, weight: order == nil ? .regular : .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        ForEach(form?.pokeTypes ?? []) { TypeChip(type: $0, size: .small) }
                        if let order, order <= leadCount {
                            Text("LEADS").font(.system(size: 8, weight: .bold)).kerning(0.4)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
                if isFocus, order != nil {
                    Image(systemName: "eye.fill").font(.system(size: 9))
                        .foregroundStyle(Palette.accent)
                        .help("Their side is showing how this one fares")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(order != nil ? Palette.accent.opacity(isFocus ? 0.42 : 0.26)
                                     : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                isFocus && order != nil ? Color.white.opacity(0.8) : Color.white.opacity(0.14),
                lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// One of theirs, marked with how the Pokémon in focus fares against it.
    private func opposingRow(_ slot: TeamSlot) -> some View {
        let form = slot.form(in: store.rulebook)
        let battle = slot.battleForm(in: store.rulebook)
        // Theirs: not what it holds, which you cannot see, but whether the
        // species has a Mega at all.
        let couldMega = form.map { theirTeam.map(possibleMegas)?.contains($0.id) ?? false } ?? false
        let reading = matchupMark(against: slot)
        // Where this one sits in the four they will most likely bring.
        let expected = lobby.theirPlan?.bring.firstIndex { $0.id == battle?.id }
        let likelyHome = lobby.theirPlan != nil && expected == nil
        return HStack(spacing: 9) {
            if let reading {
                HStack(spacing: 2) {
                    Image(systemName: reading.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(reading.tint)
                    if reading.shock {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.bad)
                    }
                }
                .help(reading.note)
                .frame(width: 34, alignment: .leading)
            } else {
                Color.clear.frame(width: 34, height: 1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(form?.formLabel ?? slot.formID)
                    .font(.system(size: 12, weight: expected == nil ? .regular : .semibold))
                    .foregroundStyle(.white.opacity(likelyHome ? 0.7 : 1))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let expected {
                        Text(expected < leadCount ? "LIKELY LEADS" : "LIKELY BRINGS")
                            .font(.system(size: 8, weight: .bold)).kerning(0.4)
                            .foregroundStyle(expected < leadCount ? Palette.bad : Palette.warn)
                    } else if likelyHome {
                        Text("LIKELY HOME").font(.system(size: 8, weight: .bold)).kerning(0.4)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(form?.pokeTypes ?? []) { TypeChip(type: $0, size: .small) }
                }
            }
            if let form {
                ZStack(alignment: .topTrailing) {
                    SpriteImage(form: form, side: 46).opacity(likelyHome ? 0.6 : 1)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    if couldMega { megaBadge(uncertain: true, form: form) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(likelyHome ? 0.05 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(reading?.tint.opacity(0.55) ?? Color.white.opacity(0.14), lineWidth: 1))
    }

    /// How the Pokémon in focus fares against one of theirs.
    ///
    /// Read off the versus grid rather than off the type chart, so it knows
    /// that a Pokémon resisting your attack still loses if it cannot hurt you
    /// back. Nothing shows until something is picked, because there is nothing
    /// to compare against yet.
    private func matchupMark(against theirs: TeamSlot)
        -> (symbol: String, tint: Color, shock: Bool, note: String)? {
        guard let mine = myTeam, let theirTeam,
              let focusID = focused ?? bringing.last,
              let mineSlot = mine.slots.first(where: { $0.formID == focusID }),
              let mineForm = mineSlot.battleForm(in: store.rulebook),
              let theirForm = theirs.battleForm(in: store.rulebook) else { return nil }
        let grid = Matchup(mine: mine, theirs: theirTeam, rules: store.rulebook,
                           field: Field(isDoubles: !singles))
        guard let cell = grid.cell(mine: mineForm, theirs: theirForm) else { return nil }
        let against = "\(mineForm.formLabel) against \(theirForm.formLabel)"
        switch cell.outcome {
        case .win:
            return ("arrow.up.circle.fill", Palette.good, false,
                    "\(against): \(mineForm.formLabel) wins this one.")
        case .favoured:
            return ("arrow.up", Palette.good, false,
                    "\(against): the better side of it.")
        case .neutral:
            return ("minus", Palette.dim, false, "\(against): even.")
        case .against:
            return ("arrow.down", Palette.warn, false,
                    "\(against): the worse side of it.")
        case .loss:
            return ("arrow.down.circle.fill", Palette.bad, true,
                    "\(against): \(mineForm.formLabel) loses this badly. Bring an answer.")
        }
    }

    private func label(_ formID: String) -> String {
        if let slot = myTeam?.slots.first(where: { $0.formID == formID }),
           let form = slot.battleForm(in: store.rulebook) {
            return form.formLabel
        }
        return store.formsByID[formID]?.formLabel ?? formID
    }

    /// What the bring-four search would take, as a starting point.
    private func autoPick() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        let grid = Matchup(mine: mine, theirs: theirs, rules: store.rulebook,
                           field: Field(isDoubles: !singles))
        let picker = BringFour(matchup: grid, rules: store.rulebook, bring: bringCount)
        guard let plan = picker.plans.first else { return }
        // The plan names battle forms; the preview is keyed on what is
        // registered, which for a Mega is the base.
        bringing = plan.bring.compactMap { form in
            mine.slots.first { $0.battleForm(in: store.rulebook)?.id == form.id }?.formID
        }
    }

    private func begin() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        guard bringing.count >= leadCount else { return }
        stage = .battle
        turn = 1
        finished = nil
        history = []; grade = nil; replay = []; at = 0; replayBoard = nil; sending = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        chosenSends = []; review = []; playing = false
        log = [BattleView.opener]
        board = nil
        opening = true
        shown = []
        callout = nil
        // Their four is chosen against your six the way you chose yours, and
        // each side's back two go on the board as guesses: the game knows the
        // truth so it can be played, and neither side's advice reads past what
        // has been seen. Two bring-four searches and two grids to work that
        // out, so it happens off the main thread while the flash is up.
        let rules = store.rulebook, singles = singles, bringing = bringing
        func built() async -> Board {
            await Task.detached(priority: .userInitiated) {
                Board.opening(mine: mine, bringing: bringing, theirs: theirs,
                              rules: rules, singles: singles, sendOut: false)
            }.value
        }
        if snapshotMode {
            var start = Board.opening(mine: mine, bringing: bringing, theirs: theirs,
                                      rules: rules, singles: singles, sendOut: false)
            start.sendOutLeads()
            board = start
            log += start.story
            opening = false
            think()
            return
        }
        // The start of the game, shown as it happens: the flash, the leads
        // coming out one by one, then their abilities in Speed order — the
        // slower weather landing second and staying, an Intimidate cutting
        // what is already out. Orders wait until it is done.
        startFlash = true
        Task { @MainActor in
            let start = await built()
            board = start
            let order = start.leadOrder
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeOut(duration: 0.35)) { startFlash = false }
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Yours and theirs alternate coming out, the way the game shows it.
            let arrivals = (0..<start.activeCount).flatMap { slot in
                ["m\(slot)", "t\(slot)"]
            }
            for key in arrivals {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { _ = shown.insert(key) }
                try? await Task.sleep(nanoseconds: 380_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            var running = start
            for entry in order {
                let before = running.story.count
                running.landed(mine: entry.mine, slot: entry.slot)
                let said = Array(running.story.dropFirst(before))
                guard !said.isEmpty else { continue }
                withAnimation(.easeInOut(duration: 0.4)) {
                    board = running
                    callout = said.joined(separator: " ")
                }
                log += said
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
            withAnimation(.easeOut(duration: 0.3)) { callout = nil }
            board = running
            opening = false
            think()
        }
    }

    // MARK: The field

    private func field(_ live: Board) -> some View {
        // Mid-replay the field shows the moment being described, not where the
        // turn ended up.
        let board = replay.indices.contains(at)
            ? rewound(replayBoard ?? live, to: replay[at]) : live
        // Half the window is the field, half is what you are doing about it,
        // and the deck on the left is as tall as the readings on the right.
        // A turn should never need scrolling to play.
        return GeometryReader { geo in
            let gap: CGFloat = 12
            let banner: CGFloat = finished == nil ? 0 : 40
            let half = (geo.size.height - gap - (banner > 0 ? banner + gap : 0)) / 2
            VStack(alignment: .leading, spacing: gap) {
                if let finished {
                    Card(padding: 10) { Label(finished, systemImage: "flag.checkered")
                        .font(.system(size: 14, weight: .semibold)) }
                        .frame(height: banner)
                }
                arena(board).frame(height: half)
                HStack(alignment: .top, spacing: gap) {
                    Group {
                        if opening { openingCard }
                        else if !replay.isEmpty { stepper() }
                        else if !sending.isEmpty, finished == nil { replacement(board) }
                        else if finished == nil { choices(board) }
                        else { afterGame }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Two fifths of the width. It was a fixed 340 points,
                    // which on a wide window left the engine's reasoning in a
                    // narrow column wrapping every other word while the
                    // orders beside it had room to spare. A floor keeps it
                    // readable if the window is dragged narrow.
                    sidePanel
                        .frame(width: Swift.max(340, geo.size.width * 0.4))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: half)
            }
        }
        .padding(14)
        // Leaving the screen stops the turn being played out. The parity audit
        // taught this one: a detached task that outlived the view it belonged
        // to is what made the app stutter, and it was invisible because the
        // work was correct — it was just still going.
        .onAppear {
            guard bob == 0 else { return }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                bob = -3.5
            }
        }
        .onDisappear {
            playback?.cancel(); playback = nil
            flourish = nil; lunging = nil; lungeBy = .zero
        }
    }

    /// While the leads come out and their abilities go off.
    private var openingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Battle start",
                              subtitle: "Both sides send out their leads. Abilities go off in Speed order — the slower weather is the one that stays.")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(callout ?? (shown.isEmpty ? "Go!" : "Sending out…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The game is over; what is left to do is look back or go again.
    private var afterGame: some View {
        let worst = review.filter { $0.lost > 0.05 }.sorted { $0.lost > $1.lost }
        let lost = review.reduce(0) { $0 + $1.lost }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Game over", subtitle: finished ?? "")
                if review.isEmpty {
                    Text("No turns to look back on.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if worst.isEmpty {
                    Label(String(format: "Every turn on the engine's line. Nothing left on the table across %d turns.", review.count),
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.good)
                } else {
                    Text(String(format: "%.2f left on the table across %d turns. The ones that cost the most:", lost, review.count))
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(worst.prefix(3)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(format: "−%.2f", entry.lost))
                                .font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.warn)
                                .frame(width: 44, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Turn \(entry.turn): you \(entry.yours)")
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("the engine wanted \(entry.bestLine)")
                                    .font(.system(size: 10)).foregroundStyle(Palette.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Play it again") { rewind(to: entry.turn) }
                                .controlSize(.small)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Back to Team Preview") { stage = .preview }.controlSize(.small)
                    Button("Undo the last turn") { undo() }.controlSize(.small)
                        .disabled(history.isEmpty)
                    Button("Every turn") { panel = .review }.controlSize(.small)
                        .disabled(review.isEmpty)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The readings, one at a time: what the engine makes of your turn, what
    /// it believes they are weighing, and what has happened so far.
    private var sidePanel: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(Panel.allCases, id: \.self) { choice in
                        Button { panel = choice } label: {
                            Text(choice.rawValue)
                                .font(.system(size: 11, weight: panel == choice ? .semibold : .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(panel == choice ? Palette.accent.opacity(0.16) : Color.clear)
                                .foregroundStyle(panel == choice ? AnyShapeStyle(Palette.accent)
                                                                 : AnyShapeStyle(.secondary))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    if !searchNote.isEmpty, panel == .engine {
                        Text(searchNote).font(.system(size: 9)).foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                scrolling {
                    VStack(alignment: .leading, spacing: 7) {
                        switch panel {
                        case .engine:
                            reading(mySide, Palette.accent,
                                    empty: thinking ? "Searching…" : "Press Think, or give orders: the engine searches when a turn begins.")
                        case .theirs:
                            reading(theirSide, Palette.warn,
                                    empty: "What they are probably weighing, and what they cannot see.")
                        case .review:
                            reviewPanel
                        case .log:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .opacity(panel == .log ? 0 : 1)
                .frame(maxHeight: panel == .log ? 0 : nil)
                if panel == .log { logPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Every turn of the game, marked. While a game is running it reads in
    /// order; once it is over the worst turns come first, because that is what
    /// there is to learn from. Clicking one takes the game back to it.
    @ViewBuilder
    private var reviewPanel: some View {
        if review.isEmpty {
            Text("Nothing to review yet. Every turn you play is marked here: what you did, what it was worth, and what the engine would have done instead.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let lost = review.reduce(0) { $0 + $1.lost }
            let ordered = finished == nil ? review : review.sorted { $0.lost > $1.lost }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(String(format: "%.2f", lost))
                        .font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(lost > 0.5 ? Palette.warn : Palette.good)
                    Text("left on the table across \(review.count) turn\(review.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help("The sum of what each turn cost against the line the engine wanted. Nought is perfect play by its own lights.")
                ForEach(ordered) { entry in
                    Button { rewind(to: entry.turn) } label: { reviewRow(entry) }
                        .buttonStyle(.plain)
                        .help("Take the game back to turn \(entry.turn) and play it differently")
                }
            }
        }
    }

    private func reviewRow(_ entry: TurnReview) -> some View {
        let bad = entry.lost > 0.05
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("TURN \(entry.turn)")
                    .font(.system(size: 9, weight: .heavy)).kerning(0.5)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(bad ? String(format: "−%.2f", entry.lost) : "on the line")
                    .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(bad ? Palette.warn : Palette.good))
            }
            Text(entry.yours).font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("they \(entry.theirs)").font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if bad {
                Text("wanted: \(entry.bestLine)")
                    .font(.system(size: 10)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(bad ? Palette.warn.opacity(0.4) : Palette.hairline, lineWidth: 1))
    }

    /// What has happened, oldest at the top and the latest at the bottom where
    /// a conversation puts it, with each turn ruled off from the last. It
    /// follows the newest line on its own.
    /// One thing that happened, with whatever the model had to say about it.
    ///
    /// The turn model already marks a detail by opening the line with two
    /// spaces — "  A critical hit!", "  Spread: x0.75" — and the log used to
    /// render every line as its own identical rounded box, so a turn read as
    /// nine separate events of equal weight. They are one event and its
    /// reasons, and now they look like it.
    private struct LogEntry: Identifiable {
        let id: Int
        let headline: String
        let details: [String]
        let isDivider: Bool
    }

    private var logEntries: [LogEntry] {
        var out: [LogEntry] = []
        for (index, line) in log.enumerated() {
            if line.hasPrefix(BattleView.dividerMark) {
                out.append(LogEntry(id: index,
                                    headline: String(line.dropFirst()).uppercased(),
                                    details: [], isDivider: true))
                continue
            }
            let detail = line.hasPrefix("  ")
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // A detail with nothing above it to belong to still has to appear.
            if detail, let last = out.last, !last.isDivider {
                // A spread move works each target out separately, so the same
                // reason arrives once per target: "Spread: x0.75" twice, the
                // terrain halving it twice. Said once is enough.
                guard !last.details.contains(text) else { continue }
                out[out.count - 1] = LogEntry(id: last.id, headline: last.headline,
                                              details: last.details + [text],
                                              isDivider: false)
            } else {
                out.append(LogEntry(id: index, headline: text, details: [], isDivider: false))
            }
        }
        return out
    }

    private var logPanel: some View {
        let entries = logEntries
        let latest = entries.last { !$0.isDivider }?.id
        // The last *entry*, not the last line: a detail line is folded into
        // the entry above it and no longer carries an id of its own, so
        // scrolling to `log.count - 1` would sometimes aim at nothing.
        let bottom = entries.last?.id ?? 0
        let body = VStack(alignment: .leading, spacing: 5) {
            if entries.isEmpty {
                Text("Nothing has happened yet.").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                if entry.isDivider {
                    HStack(spacing: 8) {
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                        Text(entry.headline)
                            .font(.system(size: 9, weight: .heavy)).kerning(1.2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                    }
                    .padding(.vertical, 6)
                    .id(entry.id)
                } else {
                    let live = entry.id == latest
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.headline)
                            .font(.system(size: 11, weight: live ? .semibold : .regular))
                            .foregroundStyle(live ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                        // The reasons, hung under the thing they explain.
                        ForEach(Array(entry.details.enumerated()), id: \.offset) { _, detail in
                            HStack(alignment: .top, spacing: 6) {
                                Rectangle()
                                    .fill(live ? Palette.accent.opacity(0.45) : Palette.hairline)
                                    .frame(width: 2)
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 2)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(live ? Palette.accent.opacity(0.12)
                                     : Palette.surfaceRaised.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(entry.id)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)

        return Group {
            if snapshotMode {
                body
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        body
                    }
                    .onAppear { proxy.scrollTo(bottom, anchor: .bottom) }
                    .onChange(of: log.count) { _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottom, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reading(_ lines: [String], _ tint: Color, empty: String) -> some View {
        if lines.isEmpty {
            Text(empty).font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
                    .padding(.top, 5)
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The field itself, laid out the way the game shows it: your first
    /// Pokémon up and to the left, the second diagonally down from it, and
    /// theirs the same way across the line. Tinted by whatever weather is up,
    /// because that is the single most useful thing to see without reading.
    /// Whether to draw the shield on a Pokémon.
    ///
    /// `isProtected` is true only *during* the turn, because the shield now
    /// comes down at the end of the turn it covered — which is right, and
    /// which quietly meant the dome never appeared at all, since the board the
    /// screen draws between turns always had it false. So while the turn is
    /// still playing out, whoever protected on it is shown protected.
    /// Which of your two the command panel is currently asking about.
    ///
    /// The panel says the name; the field did not, so on a turn where both are
    /// alive there was nothing connecting "What will Charizard do?" to the
    /// Charizard on the board. A ring is enough.
    private func awaitingOrders(_ board: Board) -> Int? {
        guard finished == nil, sending.isEmpty, !playing, playback == nil else { return nil }
        let living = (0..<board.activeCount).filter {
            board.mine.indices.contains($0) && !board.mine[$0].fainted
        }
        return living.first { pick(for: $0) == nil }
    }

    private func guarding(_ fighter: Fighter) -> Bool {
        guard !fighter.fainted else { return false }
        return fighter.isProtected || (playback != nil && fighter.protectedLast)
    }

    /// How far a card leans when it is throwing a physical move: a short step
    /// toward whoever it is hitting, and back.
    private func lunge(_ seat: Seat) -> CGSize {
        lunging == seat ? lungeBy : .zero
    }

    /// Weather thinning out as its clock runs down, so the last turn of a rain
    /// looks like the last turn of a rain. Zero turns left means it was handed
    /// a field and told to hold it, which is full strength.
    private func fade(_ turns: Int) -> Double {
        switch turns {
        case 0:  return 1
        case 1:  return 0.45
        case 2:  return 0.75
        default: return 1
        }
    }

    /// Where a Pokémon's card sits in the arena, as a fraction of it.
    ///
    /// The cards and the animations both read this. They used to be two copies
    /// of the same four pairs of numbers, which is fine until one of them is
    /// edited and a Flamethrower starts arriving a little above Garchomp.
    private static func seatFraction(_ seat: Seat, singles: Bool) -> CGPoint {
        if singles { return CGPoint(x: seat.mine ? 0.26 : 0.74, y: 0.50) }
        if seat.mine { return seat.slot == 0 ? CGPoint(x: 0.17, y: 0.40) : CGPoint(x: 0.35, y: 0.64) }
        return seat.slot == 0 ? CGPoint(x: 0.65, y: 0.36) : CGPoint(x: 0.83, y: 0.60)
    }

    /// The same place in points — and raised, because a move is aimed at the
    /// Pokémon and the sprite sits above the middle of its card.
    private static func seatPoint(_ seat: Seat, w: CGFloat, h: CGFloat,
                                  singles: Bool) -> CGPoint {
        let fraction = seatFraction(seat, singles: singles)
        return CGPoint(x: w * fraction.x, y: h * fraction.y - 30)
    }

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
        let singlesGame = board.activeCount == 1
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lean = h * 0.18
            ZStack {
                // The room the battle happens in, behind everything else. It
                // thins out as the weather runs down, so a rain about to stop
                // looks like one.
                TerrainLayer(terrain: board.field.terrain,
                             strength: fade(board.terrainTurns))
                WeatherLayer(weather: board.field.weather,
                             strength: fade(board.weatherTurns))
                // The line down the middle, leaning the way the versus page does.
                SlantLines(lean: lean, spacing: 72)
                    .stroke(tint.opacity(lit ? 0.09 : 0.05), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: w / 2 + lean, y: 0))
                    p.addLine(to: CGPoint(x: w / 2 - lean, y: h))
                }
                .stroke(tint.opacity(lit ? 0.5 : 0.28), lineWidth: 1.5)
                Text("VS").font(.system(size: 11, weight: .heavy)).kerning(1)
                    .foregroundStyle(tint.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.surface)
                    .clipShape(Capsule())
                    .position(x: w / 2, y: h / 2)

                // Yours: first up and left, second diagonally down and in.
                ForEach(0..<min(board.activeCount, board.mine.count), id: \.self) { slot in
                    let out = !opening || shown.contains("m\(slot)")
                    fighterCard(board.mine[slot], mine: true, slot: slot, field: board.field,
                                tailwind: board.myTailwind > 0, trickRoom: board.trickRoom > 0)
                        .opacity(out ? 1 : 0)
                        .scaleEffect(out ? 1 : 0.4)
                        .offset(lunge(Seat(mine: true, slot: slot)))
                        .position(x: w * BattleView.seatFraction(Seat(mine: true, slot: slot),
                                                                 singles: singlesGame).x,
                                  y: h * BattleView.seatFraction(Seat(mine: true, slot: slot),
                                                                 singles: singlesGame).y)
                }
                // Theirs: first up and left of their side, second down and right.
                ForEach(0..<min(board.activeCount, board.theirs.count), id: \.self) { slot in
                    let out = !opening || shown.contains("t\(slot)")
                    fighterCard(board.theirs[slot], mine: false, slot: slot, field: board.field,
                                tailwind: board.theirTailwind > 0, trickRoom: board.trickRoom > 0)
                        .opacity(out ? 1 : 0)
                        .scaleEffect(out ? 1 : 0.4)
                        .offset(lunge(Seat(mine: false, slot: slot)))
                        .position(x: w * BattleView.seatFraction(Seat(mine: false, slot: slot),
                                                                 singles: singlesGame).x,
                                  y: h * BattleView.seatFraction(Seat(mine: false, slot: slot),
                                                                 singles: singlesGame).y)
                }
                sideState(board, mine: true).position(x: w * 0.25, y: 18)
                sideState(board, mine: false).position(x: w * 0.75, y: 18)
                // The move being used, over the cards: a beam for a special,
                // a burst where a physical one lands, a ring for a status move.
                // Driven off a start date rather than a per-frame @State, so
                // the arena is not rebuilt sixty times a second.
                if let flourish {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { slice in
                        let progress = min(1, max(0, slice.date.timeIntervalSince(flourishFrom)
                                                     / BattleView.flourishSeconds))
                        let place: (Seat) -> CGPoint = {
                            BattleView.seatPoint($0, w: w, h: h, singles: singlesGame)
                        }
                        ZStack {
                            if flourish.isSpecial {
                                BeamLayer(flourish: flourish, progress: progress, place: place)
                            } else if flourish.isPhysical {
                                ImpactLayer(flourish: flourish, progress: progress, place: place)
                            } else if !flourish.isSwitch {
                                AuraLayer(flourish: flourish, progress: progress, place: place)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                if startFlash {
                    Text("BATTLE START")
                        .font(.system(size: 44, weight: .black)).italic().kerning(2)
                        .foregroundStyle(.white)
                        .shadow(color: tint.opacity(0.9), radius: 24)
                        .shadow(color: .black.opacity(0.7), radius: 6, y: 3)
                        .transition(.scale(scale: 1.6).combined(with: .opacity))
                        .position(x: w / 2, y: h / 2)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    fieldState(board)
                    if let callout {
                        Text(callout)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(tint.opacity(0.9)))
                            .shadow(color: tint.opacity(0.6), radius: 12, y: 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .id(callout)
                    }
                }
                .padding(.top, 10)
            }
            .overlay(alignment: .topLeading) {
                Text("YOURS").font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(.tertiary).padding(14)
            }
            .overlay(alignment: .bottomLeading) { bench(board, mine: true).padding(12) }
            .overlay(alignment: .topTrailing) { bench(board, mine: false).padding(12) }
            .overlay(alignment: .bottom) { terrainState(board).padding(.bottom, 10) }
        }
        .background(
            LinearGradient(colors: [tint.opacity(lit ? 0.18 : 0.07),
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

    /// The Pokémon waiting behind a side. Yours are yours to see; theirs are
    /// what has shown itself, question marks for what has not, and the odds
    /// on who is behind them.
    private func bench(_ board: Board, mine: Bool) -> some View {
        let team = mine ? board.mine : board.theirs
        let hiding = !mine && board.hidesTheirBench
        return VStack(alignment: mine ? .leading : .trailing, spacing: 4) {
            if !mine {
                Text("THEIRS").font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                ForEach(Array(team.dropFirst(board.activeCount).enumerated()), id: \.offset) {
                    _, fighter in
                    if hiding && !fighter.seen && !fighter.fainted {
                        // One of the two they brought behind, not yet shown.
                        // What it is stays their business until it walks on.
                        VStack(spacing: 2) {
                            ZStack {
                                Circle().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .frame(width: 30, height: 30)
                                Text("?").font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("hidden").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        .frame(width: 52)
                        .help("They brought something here, but it has not come out yet. The engine plays against the likeliest versions rather than peeking.")
                    } else {
                        // A bench slot said only what it was. Whether it is
                        // healthy, hurt or already gone is the thing you need
                        // when deciding what to send, and it was in the party
                        // screen two clicks away.
                        VStack(spacing: 2) {
                            ZStack {
                                SpriteImage(form: fighter.build.form, side: 30)
                                    .opacity(fighter.fainted ? 0.25 : 1)
                                    .saturation(fighter.fainted ? 0 : 1)
                                if fighter.fainted {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(Palette.bad.opacity(0.85))
                                }
                            }
                            if !fighter.fainted {
                                Capsule()
                                    .fill(Palette.hairline)
                                    .frame(width: 30, height: 3)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(fighter.share > 0.5 ? Palette.good
                                                  : fighter.share > 0.2 ? Palette.warn : Palette.bad)
                                            .frame(width: Swift.max(2, 30 * fighter.share), height: 3)
                                    }
                            }
                            Text(fighter.build.form.formLabel)
                                .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(fighter.fainted ? .tertiary : .secondary)
                        }
                        .frame(width: 52)
                        .help(fighter.fainted ? "\(fighter.build.form.formLabel) has fainted."
                              : "\(fighter.build.form.formLabel), \(fighter.hp) of \(fighter.maxHP).")
                    }
                }
            }
            if hiding {
                // Who is probably back there, from their six and the two they
                // led with. Weighed the way they would weigh it: by what hurts.
                HStack(spacing: 5) {
                    Text("probably").font(.system(size: 8, weight: .semibold)).kerning(0.3)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(board.theirBenchCandidates.prefix(4).enumerated()), id: \.offset) {
                        _, candidate in
                        HStack(spacing: 3) {
                            SpriteImage(form: candidate.fighter.build.form, side: 16)
                            Text(String(format: "%.0f%%", candidate.chance * 100))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(candidate.chance >= 0.5 ? AnyShapeStyle(.primary)
                                                                         : AnyShapeStyle(.secondary))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.surface)
                        .clipShape(Capsule())
                        .help("\(candidate.fighter.build.form.formLabel): \(Int((candidate.chance * 100).rounded()))% likely to be one of the two behind")
                    }
                }
            }
        }
    }

    /// A colour for each condition, so the word on the name is recognisable
    /// before it is read.
    private func statusTint(_ status: Ailment) -> Color {
        switch status {
        case .burn:      return Color(red: 0.93, green: 0.45, blue: 0.28)
        case .paralysis: return Color(red: 0.95, green: 0.78, blue: 0.20)
        case .poison, .badPoison: return Color(red: 0.72, green: 0.42, blue: 0.85)
        case .sleep:     return Color(red: 0.55, green: 0.60, blue: 0.75)
        case .freeze:    return Color(red: 0.45, green: 0.75, blue: 0.95)
        case .none:      return Palette.dim
        }
    }

    /// The stat changes, as arrows, up the right-hand edge of the card.
    ///
    /// One row per stat in the order they are thought about — Attack, Special
    /// Attack, Defense, Special Defense, Speed — and one arrow per stage, so
    /// two arrows is two stages and there is nothing to read. It used to be
    /// coloured capsules stacked under the name, three to a row, which took as
    /// much room as the Pokémon and had to be parsed rather than seen.
    ///
    /// Confusion stays a word, because it is not a stat and has nowhere to
    /// point. The condition has moved to the end of the name.
    /// Which stats have moved, in the order they are read. Speed last: it is
    /// the one that decides the turn, so it reads at the bottom where the eye
    /// finishes.
    private func changedStats(_ fighter: Fighter) -> [Stat] {
        [.attack, .spAttack, .defense, .spDefense, .speed].filter {
            fighter.build.boosts.indices.contains($0.rawValue)
                && fighter.build.boosts[$0.rawValue] != 0
        }
    }

    private func stages(_ fighter: Fighter, changed: [Stat]) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            ForEach(changed, id: \.rawValue) { stat in
                let stage = fighter.build.boosts[stat.rawValue]
                let up = stage > 0
                HStack(spacing: 1) {
                    Text(stat.short)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    ForEach(0..<min(abs(stage), 6), id: \.self) { _ in
                        Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(up ? Palette.good : Palette.bad)
                    }
                }
                .help("\(stat.short) \(up ? "raised" : "lowered") by \(abs(stage)) stage"
                      + "\(abs(stage) == 1 ? "" : "s") — ×\(String(format: "%.2f", stageMultiplier(stage)))")
            }
            if fighter.isConfused {
                Text("confused")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(red: 0.75, green: 0.45, blue: 0.85))
                    .help("Confused for up to \(fighter.confusedFor) more turn"
                          + "\(fighter.confusedFor == 1 ? "" : "s"): one action in three goes "
                          + "into its own face. Switching out clears it.")
            }
        }
    }

    private func stageMultiplier(_ stage: Int) -> Double {
        stage >= 0 ? Double(2 + stage) / 2 : 2 / Double(2 - stage)
    }

    /// The board as it stood at one step of the turn.
    private func rewound(_ board: Board, to step: Board.Step) -> Board {
        var out = board
        for index in out.mine.indices where index < step.myHP.count {
            out.mine[index].hp = step.myHP[index]
            if let form = store.formsByID[step.myForms[index]],
               form.id != out.mine[index].build.form.id {
                out.mine[index].build.form = form
            }
            if index < step.myBoosts.count { out.mine[index].build.boosts = step.myBoosts[index] }
            if index < step.myStatus.count { out.mine[index].status = step.myStatus[index] }
            if index < step.myConfused.count { out.mine[index].confusedFor = step.myConfused[index] ? max(1, out.mine[index].confusedFor) : 0 }
        }
        for index in out.theirs.indices where index < step.theirHP.count {
            out.theirs[index].hp = step.theirHP[index]
            if let form = store.formsByID[step.theirForms[index]],
               form.id != out.theirs[index].build.form.id {
                out.theirs[index].build.form = form
            }
            if index < step.theirBoosts.count { out.theirs[index].build.boosts = step.theirBoosts[index] }
            if index < step.theirStatus.count { out.theirs[index].status = step.theirStatus[index] }
            if index < step.theirConfused.count { out.theirs[index].confusedFor = step.theirConfused[index] ? max(1, out.theirs[index].confusedFor) : 0 }
        }
        out.field = step.field
        out.myTailwind = step.myTailwind
        out.theirTailwind = step.theirTailwind
        out.trickRoom = step.trickRoom
        return out
    }

    /// The weather and the speed control, over the top of the field. Weather
    /// carries its clock: it runs out, and knowing when is a turn's plan.
    @ViewBuilder
    private func fieldState(_ board: Board) -> some View {
        // Only what covers the whole field. Tailwind and screens belong to a
        // side and sit over that side.
        let control = [board.trickRoom > 0 ? "Trick Room · \(board.trickRoom) left" : nil]
            .compactMap { $0 }
        if board.field.weather == .none && control.isEmpty {
            Text("clear skies")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 8) {
                if board.field.weather != .none {
                    fieldClock(symbol: weatherSymbol(board.field), title: board.field.weather.rawValue,
                               turns: board.weatherTurns)
                }
                ForEach(control, id: \.self) { line in
                    Text(line).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
    }

    /// What one side has going for it, over that side: Tailwind, screens,
    /// Wide Guard, each with what is left of it.
    @ViewBuilder
    private func sideState(_ board: Board, mine: Bool) -> some View {
        let tailwind = mine ? board.myTailwind : board.theirTailwind
        let screens = mine ? board.myScreens : board.theirScreens
        let bits: [(String, String)] = [
            tailwind > 0 ? ("wind", "Tailwind · \(tailwind) left") : nil,
            screens.reflect > 0 ? ("shield.lefthalf.filled", "Reflect · \(screens.reflect)") : nil,
            screens.lightScreen > 0 ? ("shield.righthalf.filled", "Light Screen · \(screens.lightScreen)") : nil,
            screens.auroraVeil > 0 ? ("sparkles", "Aurora Veil · \(screens.auroraVeil)") : nil,
            screens.wideGuard ? ("shield.fill", "Wide Guard") : nil,
        ].compactMap { $0 }
        if !bits.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(bits.enumerated()), id: \.offset) { _, bit in
                    HStack(spacing: 4) {
                        Image(systemName: bit.0).font(.system(size: 9))
                        Text(bit.1).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder((mine ? Palette.accent : Palette.bad).opacity(0.6), lineWidth: 1))
                }
            }
        }
    }

    /// Terrain, along the bottom of the field, with its clock.
    @ViewBuilder
    private func terrainState(_ board: Board) -> some View {
        if board.field.terrain != .none {
            fieldClock(symbol: "square.grid.3x3.bottomleft.filled",
                       title: "\(board.field.terrain.rawValue) Terrain", turns: board.terrainTurns)
        }
    }

    private func fieldClock(symbol: String, title: String, turns: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .bold))
                Text(turns > 0 ? "\(turns) turn\(turns == 1 ? "" : "s") remaining" : "until something changes it")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Palette.hairline, lineWidth: 1))
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

    private func fighterCard(_ fighter: Fighter, mine: Bool, slot: Int,
                             field: Field, tailwind: Bool = false, trickRoom: Bool = false) -> some View {
        let hit = mine ? struck.contains(slot) : struckTheirs.contains(slot)
        let health = fighter.share
        let bar: Color = health > 0.5 ? Palette.good
            : (health > 0.2 ? Palette.warn : Palette.bad)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Behind the sprite: a dome while it is protecting, and a
                // substitute's shell if it has one up. Both are things you have
                // to know before choosing a move, and both were only visible by
                // reading the log for them.
                if guarding(fighter) {
                    Circle()
                        .fill(
                            RadialGradient(colors: [Palette.accent.opacity(0.05),
                                                    Palette.accent.opacity(0.30)],
                                           center: .center, startRadius: 16, endRadius: 46)
                        )
                        .overlay(Circle().strokeBorder(Palette.accent.opacity(0.75), lineWidth: 1.5))
                        .frame(width: 88, height: 88)
                        .transition(.scale.combined(with: .opacity))
                } else if fighter.substitute > 0 && !fighter.fainted {
                    Circle()
                        .strokeBorder(Palette.dim.opacity(0.55),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 88, height: 88)
                }
                // The ground it is standing on. A Pokémon floating on a flat
                // panel reads as a list entry; one with a platform and a
                // shadow under it reads as being somewhere. The cheapest
                // single thing that makes this a field rather than a table.
                if !fighter.fainted {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Palette.canvas.opacity(0.55), Palette.canvas.opacity(0)],
                                center: .center, startRadius: 2, endRadius: 30)
                        )
                        .frame(width: 66, height: 17)
                        .offset(y: 32)
                        .allowsHitTesting(false)
                }
                SpriteImage(form: fighter.build.form, side: 78)
                    .offset(y: fighter.fainted ? 0 : bob)
                    .opacity(fighter.fainted ? 0.22 : 1)
                    .saturation(fighter.fainted ? 0 : 1)
                    .scaleEffect(fighter.fainted ? 0.86 : (hit ? 1.1 : 1))
                    .rotationEffect(.degrees(fighter.fainted ? -12 : 0))
                    .shadow(color: hit ? Palette.bad.opacity(0.55) : .clear, radius: 9)
                    .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                    .animation(.easeOut(duration: 0.35), value: fighter.fainted)
                if guarding(fighter) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .padding(3)
                        .background(Palette.surface, in: Circle())
                        .offset(x: 2, y: 54)
                        .help("Protecting this turn. Most attacks will not reach it.")
                } else if fighter.substitute > 0 && !fighter.fainted {
                    Image(systemName: "person.fill.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .padding(3)
                        .background(Palette.surface, in: Circle())
                        .offset(x: 2, y: 54)
                        .help("A substitute is taking the hits, worth \(fighter.substitute).")
                }
            }
            // The condition rides on the name rather than taking a badge of
            // its own: it is a fact about the Pokémon, and a line that reads
            // "Kingambit · burned" needs no decoding.
            HStack(spacing: 3) {
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.65)
                if fighter.status != .none {
                    Text("· \(fighter.status.rawValue)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusTint(fighter.status))
                        .lineLimit(1).fixedSize()
                }
            }
            // What it is, which the card never said. Two small bars of the
            // type colours read faster than any word, and typing is the thing
            // a player checks first.
            HStack(spacing: 3) {
                ForEach(fighter.types, id: \.rawValue) { type in
                    Text(type.rawValue.uppercased())
                        .font(.system(size: 7, weight: .heavy)).kerning(0.3)
                        .foregroundStyle(type.onColor)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(type.color, in: Capsule())
                }
            }
            .opacity(fighter.fainted ? 0.4 : 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(height: 7)
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(colors: [bar.opacity(0.75), bar],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * health)
                        // Nearly empty still reads as a sliver rather than
                        // vanishing: one point of health is the whole
                        // difference between standing and not.
                        .frame(minWidth: fighter.fainted ? 0 : 3, alignment: .leading)
                }
                .frame(height: 7)
            }
            .frame(height: 7)
            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .animation(.easeOut(duration: 0.55), value: fighter.hp)
            HStack(spacing: 4) {
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                // Yours is what it is. Theirs is what you could work out from
                // the stat, because showing the real number would quietly tell
                // you about the Choice Scarf the card above says you cannot see.
                // The Speed it actually moves at, and why: Tailwind, a weather
                // ability, a Scarf, a paralysis. A bare number that has been
                // doubled twice is not something anyone can check.
                let reading = speedReading(fighter, mine: mine, field: field,
                                           tailwind: tailwind, trickRoom: trickRoom)
                Text("· \(reading.value)\(mine ? "" : "?")")
                    .font(.system(size: 9, weight: reading.causes.isEmpty ? .regular : .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.causes.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.accent))
                    .help((mine
                          ? "Speed on the field, everything included."
                          : "What its Speed would be with no item. You cannot see what it is holding, so you cannot see a Choice Scarf either.")
                          + (reading.causes.isEmpty ? "" : " " + reading.causes.joined(separator: ", ") + "."))
            }
            if !speedReading(fighter, mine: mine, field: field, tailwind: tailwind, trickRoom: trickRoom).causes.isEmpty {
                Text(speedReading(fighter, mine: mine, field: field, tailwind: tailwind, trickRoom: trickRoom).causes.joined(separator: " · "))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(fighter.build.itemSpent && !fighter.build.item.isEmpty
                 ? "\(fighter.build.item) · used"
                 : mine ? (fighter.build.item.isEmpty ? "no item" : fighter.build.item)
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
        // Opaque and *lighter* than the field. Two goes at this were wrong in
        // opposite directions: at 55% of a dark grey the card borrowed whatever
        // was behind it and went muddy once there was weather; at 94% of the
        // same dark grey it was darker than the ground and read as a hole. A
        // card on a battlefield is a panel lying on top of it, so it is lighter
        // than the field and carries a light edge and a shadow to say so.
        .background(fighter.fainted ? Color.clear : Palette.cardOnField)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if !fighter.fainted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(fighter.fainted ? 0 : 0.35), radius: 8, y: 3)
        .overlay {
            // The one being asked about, so the question and the Pokémon are
            // visibly the same thing.
            if mine, let board, awaitingOrders(board) == slot, !fighter.fainted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .shadow(color: Palette.accent.opacity(0.7), radius: 7)
            }
        }
        .overlay(alignment: .top) {
            if let lost = damage[Seat(mine: mine, slot: slot)], lost > 0 {
                Text("-\(lost)")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: Palette.bad, radius: 6)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .offset(y: -18)
                    .transition(.asymmetric(
                        insertion: .offset(y: 14).combined(with: .opacity),
                        removal: .offset(y: -12).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }
        }
        // In the tile's own corner rather than the sprite's, and on a backdrop:
        // a sprite is not a reliable background — Charizard's wing reaches into
        // exactly this space — and a stat change is something you check at a
        // glance rather than squint at.
        .overlay(alignment: .topTrailing) {
            // Only when there is something to draw. This used to hand the
            // backdrop an `AnyView(EmptyView())` when nothing had changed —
            // and an AnyView is not an EmptyView: the erasure hides the
            // emptiness, so the view had no size of its own, stretched to fill
            // the overlay, and painted its near-black backdrop over the whole
            // card. Every Pokémon with no stat change wore a dark sheet, which
            // lifted the moment an Intimidate gave it one.
            let changed = changedStats(fighter)
            if !changed.isEmpty || fighter.isConfused {
                stages(fighter, changed: changed)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.surface.opacity(0.88))
                    )
                    .padding(2)
                    .opacity(fighter.fainted ? 0 : 1)
            }
        }
        // The stone marker takes the other corner. It used to share the right
        // one with the stat column, which is fine at one stat changed and
        // overlapping at four.
        .overlay(alignment: .topLeading) {
            if fighter.pendingMega != nil {
                Text("M").font(.system(size: 9, weight: .heavy))
                    .frame(width: 17, height: 17)
                    .background(Palette.warn).foregroundStyle(.white)
                    .clipShape(Circle())
                    .padding(2)
                    .help("Holding its stone. It Mega Evolves only if you toggle it on "
                          + "with a move, before anything else happens, in Speed order.")
            } else if fighter.build.form.isMega {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .padding(4)
                    .help("Mega Evolved")
            }
        }
    }

    /// What a move would actually do, on the button that would do it.
    ///
    /// This is a simulator, so there is no reason to make somebody guess at
    /// arithmetic the app can already do: the range, as a share of the target,
    /// and how many of them it takes. Against their side it is worked out with
    /// the item nobody has seen left off, for the same reason their Speed is.
    /// What a Pokémon will be when the move goes off, not what it is now.
    ///
    /// Toggling Mega Evolve changes the stats, the typing and the ability, and
    /// evolution happens before any move — so a preview worked out on the base
    /// form is a preview of a turn that is not going to happen. Charizard into
    /// Mega Charizard Y is fifty points of Special Attack and a Drought that
    /// puts the sun up before the move lands, which is most of the damage.
    private func evolving(_ fighter: Fighter, slot: Int,
                          board: Board) -> (build: Combatant, field: Field) {
        guard megaSlot == slot, let mega = fighter.pendingMega else {
            return (fighter.build, board.field)
        }
        var build = Combatant(form: mega,
                              ability: mega.abilities.first?.name ?? fighter.build.ability,
                              item: fighter.build.item, sp: fighter.build.sp,
                              alignment: fighter.build.alignment)
        build.boosts = fighter.build.boosts
        build.itemSpent = fighter.build.itemSpent
        // And whatever arriving as that puts on the field, since it lands first.
        var field = board.field
        switch build.ability {
        case "Drought":        field.weather = .sun
        case "Drizzle":        field.weather = .rain
        case "Sand Stream":    field.weather = .sand
        case "Snow Warning":   field.weather = .snow
        case "Electric Surge": field.terrain = .electric
        case "Grassy Surge":   field.terrain = .grassy
        case "Misty Surge":    field.terrain = .misty
        case "Psychic Surge":  field.terrain = .psychic
        default: break
        }
        return (build, field)
    }

    /// What a move does to a target, as three pieces rather than one
    /// sentence: the damage, what it becomes against that target's Mega, and
    /// how to colour it.
    ///
    /// Kept apart because the move tiles have to line up. Glued into one
    /// string it read "36–42% · 3HKO · as Mega Salamence 25–30%", which wraps
    /// to three lines on one tile and one on the next, and a grid of four
    /// buttons no two of which are the same height is hard to read at a
    /// glance and harder to click confidently.
    private func preview(_ board: Board, fighter: Fighter, slot: Int,
                         choice: Choice, only: Int? = nil)
        -> (text: String, mega: String?, tint: Color)? {
        guard case .attack(let index, let target) = choice,
              fighter.moves.indices.contains(index) else { return nil }
        let move = fighter.moves[index]
        guard move.isDamaging else { return nil }
        let becoming = evolving(fighter, slot: slot, board: board)
        // Aimed at your own partner: read against it, item and all, since
        // that one you can see.
        let atAlly = target >= Choice.allyTarget
        let side = atAlly ? board.mine : board.theirs
        // A spread move is read across everything it reaches, unless one of
        // them is asked about on its own.
        let aimed: [Int] = only.map { [$0] }
            ?? (move.isSpread ? Array(0..<min(board.activeCount, board.theirs.count))
                : atAlly ? [slot == 0 ? 1 : 0] : [target])
        var low = 0, high = 0, best = 1.0
        var hp = 1, fullHP = 1
        for slot in aimed {
            guard side.indices.contains(slot), !side[slot].fainted
            else { continue }
            var defender = side[slot].build
            if !atAlly { defender.item = "" }            // theirs is not something you can see
            defender.atFullHP = side[slot].hp == side[slot].maxHP
            var field = becoming.field
            field.screen = board.theirScreens.blunt(move)
            var attacker = becoming.build
            attacker.lastMoveFailed = fighter.lastMoveFailed
            attacker.fallenAllies = board.mine.filter(\.fainted).count
            let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                              move: move, field: field)
            if result.maxDamage > high {
                low = result.minDamage; high = result.maxDamage
                best = result.effectiveness
                hp = side[slot].hp
                fullHP = side[slot].maxHP
            }
        }
        guard high > 0, hp > 0 else { return nil }
        // Shares of the whole bar, so a Pokémon on three points reads as the
        // knockout it is rather than as two thousand per cent.
        let lowShare = Int((Double(low) / Double(max(1, fullHP)) * 100).rounded())
        let highShare = Int((Double(high) / Double(max(1, fullHP)) * 100).rounded())
        let hits = Int(ceil(Double(hp) / Double(max(1, high))))
        let knockout = low >= hp ? "KO" : (high >= hp ? "may KO" : "\(hits)HKO")
        let tint: Color = best > 1 ? Palette.good
            : (best < 1 && best > 0 ? Palette.dim : Palette.accent)
        let text = "\(lowShare)–\(highShare)% · \(knockout)"
        var megaRead: String?
        // Mega Evolution happens before any move, so a target that could
        // evolve may take this hit as its Mega — with its Mega's defences and
        // ability. Said beside the plain number, because the difference
        // between a knockout and a miss is often exactly that.
        if aimed.count == 1, !atAlly, let slot = aimed.first, side.indices.contains(slot),
           !side[slot].build.form.isMega, !board.theirs.contains(where: \.hasMegaEvolved),
           let mega = likelyMega(of: side[slot].build.form) {
            var evolved = side[slot].build
            evolved.form = mega
            evolved.ability = mega.abilities.first?.name ?? evolved.ability
            evolved.item = ""
            evolved.atFullHP = side[slot].hp == side[slot].maxHP
            var field = becoming.field
            field.screen = board.theirScreens.blunt(move)
            var attacker = becoming.build
            attacker.lastMoveFailed = fighter.lastMoveFailed
            attacker.fallenAllies = board.mine.filter(\.fainted).count
            let asMega = DamageCalc.calculate(attacker: attacker, defender: evolved, move: move, field: field)
            if asMega.maxDamage > 0 {
                let l2 = Int((Double(asMega.minDamage) / Double(max(1, fullHP)) * 100).rounded())
                let h2 = Int((Double(asMega.maxDamage) / Double(max(1, fullHP)) * 100).rounded())
                // "Mega 25–30%", not "as Mega Salamence 25–30%". Which Mega it
                // is, is on the card across the field; the tile has room for
                // the number and not the name.
                megaRead = "Mega \(l2)–\(h2)%"
            } else {
                megaRead = "nothing to its Mega"
            }
        }
        return (text, megaRead, tint)
    }

    /// The Mega a species most likely becomes, by what the ladder carries:
    /// Charizard is a Y far more often than an X.
    private func likelyMega(of form: Form) -> Form? {
        let megas = store.data.forms.filter { $0.isMega && $0.species == form.species }
        guard !megas.isEmpty else { return nil }
        let odds = BattleEngine(rules: store.rulebook).itemOdds(for: form)
        if let stone = odds.first(where: { entry in megas.contains { $0.megaStone == entry.item } }),
           let match = megas.first(where: { $0.megaStone == stone.item }) {
            return match
        }
        return megas.first
    }

    /// Their Speed as far as anybody could know it: the stat, without the item
    /// nobody has seen yet.
    private func visibleSpeed(_ fighter: Fighter, mine: Bool, field: Field) -> Int {
        guard !mine else { return fighter.build.speed(in: field) }
        var blind = fighter.build
        blind.item = ""
        return blind.speed(in: field)
    }

    /// The Speed a Pokémon moves at this turn, and every reason it is not the
    /// number on its stat card: a Chlorophyll in the sun, a Tailwind, a Scarf
    /// you can see because it is yours, a paralysis. Trick Room is named
    /// without changing the number, since it changes the order, not the stat.
    private func speedReading(_ fighter: Fighter, mine: Bool, field: Field,
                              tailwind: Bool, trickRoom: Bool) -> (value: Int, causes: [String]) {
        var causes: [String] = []
        var build = fighter.build
        if !mine { build.item = "" }
        let plain = build.stagedStat(.speed)
        var value = build.speed(in: field)
        if value != plain {
            switch build.ability {
            case "Swift Swim" where field.weather == .rain: causes.append("Swift Swim ×2 in rain")
            case "Chlorophyll" where field.weather == .sun: causes.append("Chlorophyll ×2 in sun")
            case "Sand Rush" where field.weather == .sand: causes.append("Sand Rush ×2 in sand")
            case "Slush Rush" where field.weather == .snow: causes.append("Slush Rush ×2 in snow")
            case "Surge Surfer" where field.terrain == .electric: causes.append("Surge Surfer ×2")
            case "Unburden" where build.itemSpent: causes.append("Unburden ×2")
            default: break
            }
            if mine, build.item == "Choice Scarf" { causes.append("Scarf ×1.5") }
            if mine, build.item == "Iron Ball" || build.item == "Macho Brace" { causes.append("\(build.item) ×½") }
        }
        // The stage itself is not named here any more — the arrow column in the
        // card's corner already says "Spe ▲". What stays are the things no
        // arrow shows: the doublings, the halvings, the item.
        if tailwind { value *= 2; causes.append("Tailwind ×2") }
        if fighter.status.halvesSpeed { value /= 2; causes.append("paralysed ×½") }
        if trickRoom { causes.append("Trick Room: slower first") }
        return (value, causes)
    }

    /// What the measured ladder says they are probably holding.
    private func likelyItem(_ form: Form) -> String {
        let engine = BattleEngine(rules: store.rulebook)
        guard let best = engine.itemOdds(for: form).first else { return "item unknown" }
        if best.chance >= 0.99 { return best.item }
        return String(format: "likely %@ (%.0f%%)", best.item, best.chance * 100)
    }

    // MARK: Sending the next one in

    /// Who comes in, with a reason rather than a shrug.
    ///
    /// The game asks this and it matters: whoever arrives takes whatever lands
    /// next turn without acting first, so it is a choice between what answers
    /// what is out and what survives arriving. Both halves are worked out and
    /// the better of them named, but the pick stays yours.
    private func replacement(_ board: Board) -> some View {
        let slot = sending.first { gap in !chosenSends.contains { $0.slot == gap } } ?? sending.first ?? 0
        let options = (board.activeCount..<board.mine.count)
            .filter { index in !board.mine[index].fainted && !chosenSends.contains { $0.bench == index } }
            .map { (index: $0, reading: sendInReading(board, bench: $0)) }
            .sorted { $0.reading.score > $1.reading.score }
        let theyToo = (0..<min(board.activeCount, board.theirs.count)).contains { board.theirs[$0].fainted }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: sending.count > 1 ? "Send two in" : "Send one in",
                              subtitle: (theyToo
                                ? "They lost one too. Both sides send in at once, and the faster arrives first — its ability going off before the slower one even lands. "
                                : "")
                                + "Whoever comes arrives without acting, so it takes whatever lands next turn.")
                if let best = options.first {
                    Text("Suggested: \(board.mine[best.index].build.form.formLabel) — "
                         + best.reading.why)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { rank, option in
                        Button {
                            chosenSends.append((slot: slot, bench: option.index))
                            guard chosenSends.count >= sending.count else { return }
                            var next = board
                            next.story = []
                            next.replaceFallen(mine: chosenSends)
                            log.append(contentsOf: next.story)
                            self.board = next
                            sending = next.gapsOfMine
                            chosenSends = []
                            if sending.isEmpty { think() }
                        } label: {
                            HStack(spacing: 9) {
                                SpriteImage(form: board.mine[option.index].build.form, side: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(board.mine[option.index].build.form.formLabel)
                                            .font(.system(size: 12, weight: .medium))
                                        if rank == 0 {
                                            Text("BEST")
                                                .font(.system(size: 8, weight: .bold)).kerning(0.4)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Palette.accent.opacity(0.2))
                                                .foregroundStyle(Palette.accent)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(option.reading.why)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rank == 0 ? Palette.accent.opacity(0.12) : Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                rank == 0 ? Palette.accent.opacity(0.5) : Palette.hairline,
                                lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// How a benched Pokémon would do coming in, and why.
    private func sendInReading(_ board: Board, bench: Int) -> (score: Double, why: String) {
        let candidate = board.mine[bench]
        var worstIn = 0.0, bestOut = 0.0
        var worstFrom = "", bestInto = ""
        for foe in 0..<min(board.activeCount, board.theirs.count)
        where !board.theirs[foe].fainted {
            let them = board.theirs[foe]
            // Their item is unknown, so it is left off, as everywhere else here.
            var attacker = them.build
            attacker.item = ""
            for move in them.moves where move.isDamaging {
                let result = DamageCalc.calculate(attacker: attacker, defender: candidate.build,
                                                  move: move, field: board.field)
                let share = Double(result.maxDamage) / Double(max(1, candidate.maxHP))
                if share > worstIn { worstIn = share; worstFrom = them.build.form.formLabel }
            }
            var defender = them.build
            defender.item = ""
            for move in candidate.moves where move.isDamaging {
                let result = DamageCalc.calculate(attacker: candidate.build, defender: defender,
                                                  move: move, field: board.field)
                let share = Double(result.maxDamage) / Double(max(1, them.maxHP))
                if share > bestOut { bestOut = share; bestInto = them.build.form.formLabel }
            }
        }
        // Surviving the way in counts for more than hitting hard, because it
        // does not get to act on the turn it arrives.
        let score = min(1, bestOut) - 1.4 * min(1, worstIn)
        var why: String
        if worstIn >= 1 { why = "\(worstFrom) knocks it out as it lands" }
        else if worstIn > 0 {
            why = "takes \(Int((worstIn * 100).rounded()))% from \(worstFrom) coming in"
        } else { why = "nothing out there hurts it" }
        if bestOut >= 1 { why += ", and removes \(bestInto) in one." }
        else if bestOut > 0 {
            why += ", and hits \(bestInto) for \(Int((bestOut * 100).rounded()))%."
        } else { why += ", and cannot hurt either of them." }
        return (score, why)
    }

    // MARK: What the engine would do

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
        guard let solved, let board else { return nil }
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

    /// Give both orders from the engine's mix, sampled so a watched game varies.
    private func engineOrders(_ board: Board, result: BattleEngine.Result) {
        guard !result.plays.isEmpty else { return }
        let roll = Double.random(in: 0...1)
        var running = 0.0
        var chosen = result.plays[0]
        for (index, weight) in result.mix.enumerated() {
            running += weight
            if roll <= running, result.plays.indices.contains(index) {
                chosen = result.plays[index]; break
            }
        }
        leftPick = chosen.left
        rightPick = board.activeCount > 1 ? chosen.right : nil
        megaSlot = chosen.megaSlot
    }

    // MARK: Commanding, the way the game does it

    /// Where you are in giving orders: one Pokémon at a time, first the choice
    /// between fighting and switching, then the specific move or partner.
    enum Command: Equatable {
        case menu
        case fight
        case party
        case aiming(move: Int)
    }

    @ViewBuilder
    private func choices(_ board: Board) -> some View {
        let living = (0..<board.activeCount).filter {
            board.mine.indices.contains($0) && !board.mine[$0].fainted
        }
        let pending = living.first { pick(for: $0) == nil }
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // What is already locked in, as a strip along the top.
                lockedStrip(board, living: living)
                Divider()
                scrolling {
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

    /// The order given for a slot — or the one it has no choice about, when it
    /// is halfway through a two-turn move.
    private func pick(for slot: Int) -> Choice? {
        if let board, board.mine.indices.contains(slot), let charging = board.mine[slot].charging {
            return .attack(move: charging, target: board.mine[slot].chargingTarget)
        }
        if let board, board.mine.indices.contains(slot), let encored = board.mine[slot].encored {
            return encored
        }
        return slot == 0 ? leftPick : rightPick
    }

    /// The orders given so far. Click one to change it.
    private func lockedStrip(_ board: Board, living: [Int]) -> some View {
        HStack(spacing: 10) {
            ForEach(living, id: \.self) { slot in
                let fighter = board.mine[slot]
                let chosen = pick(for: slot)
                Button {
                    // Reopen this one's orders.
                    set(nil, slot: slot)
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
                Button("Take back") { undo() }.controlSize(.small)
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
        let ahead = evolving(fighter, slot: slot, board: board)
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
                        engineOrders(board, result: thought)
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
        let ahead = evolving(fighter, slot: slot, board: board)
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
            ? (0..<min(board.activeCount, board.theirs.count)).compactMap { target in
                guard !board.theirs[target].fainted else { return nil }
                let name = board.theirs[target].build.form.formLabel
                guard let read = preview(board, fighter: fighter, slot: slot,
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
                set(.attack(move: index, target: 0), slot: slot)
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
            let ahead = evolving(board.mine[slot], slot: slot, board: board)
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
                        ForEach(0..<min(board.activeCount, board.theirs.count), id: \.self) { foe in
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
        let reading = preview(board, fighter: board.mine[slot], slot: slot, choice: choice)
        return Button {
            set(choice, slot: slot)
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
                        set(.attack(move: index, target: bench), slot: slot)
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
            .map { (index: $0, reading: sendInReading(board, bench: $0)) }
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
                        set(.swap(to: option.index), slot: slot)
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
        let mine = ordersAsPlay(board)
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
                Toggle("Let the engine play me", isOn: $watching)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("The engine gives your orders too, so you can watch a game out and see what it does.")
                Spacer()
                Button {
                    playTurn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("PLAY THE TURN").font(.system(size: 13, weight: .heavy)).kerning(1)
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

    private func set(_ choice: Choice?, slot: Int) {
        if slot == 0 { leftPick = choice } else { rightPick = choice }
    }

    /// A turn arrives as a sequence, so it is shown as one.
    ///
    /// Everything lands at once otherwise: four actions, the residuals and two
    /// faints in a single jump, with no way to see what caused what. Stepping
    /// through it is how you learn why a turn went the way it did, which is the
    /// entire reason to play one out rather than read a score.
    private func stepper() -> some View {
        let step = replay.indices.contains(at) ? replay[at] : nil
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                SectionHeader(title: "Turn \(turn - 1), step \(at + 1) of \(replay.count)")
                if let step {
                    Text(step.text)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(replay.prefix(at).enumerated().reversed()), id: \.offset) {
                        _, earlier in
                        Text(earlier.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Back") { at = max(0, at - 1) }
                        .controlSize(.small).disabled(at == 0)
                    Button(at + 1 >= replay.count ? "Done" : "Next") {
                        if at + 1 >= replay.count { replay = []; at = 0 } else { at += 1 }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    Button("Skip to the end") { replay = []; at = 0 }.controlSize(.small)
                    Spacer()
                    if let grade {
                        Text(grade).font(.system(size: 10))
                            .foregroundStyle(grade.hasPrefix("That is")
                                             ? AnyShapeStyle(Palette.good)
                                             : AnyShapeStyle(Palette.warn))
                    }
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
            let ahead: (build: Combatant, field: Field) = mine
                ? evolving(fighter, slot: slot, board: board)
                : (build: fighter.build, field: board.field)
            let speed = (mine ? ahead.build.speed(in: ahead.field)
                              : visibleSpeed(fighter, mine: mine, field: board.field))
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


    // MARK: Running a turn

    /// The search, off the main thread. The engine is a value that knows the
    /// rulebook and nothing else, so it runs wherever it is put; the window
    /// keeps drawing and the spinner actually spins.
    private static func search(_ engine: BattleEngine, _ board: Board)
        async -> (result: BattleEngine.Result, turnSolve: TurnGame.Solution, likeliest: Board) {
        await Task.detached(priority: .userInitiated) {
            let result = engine.think(board)
            // The one-turn read is taken on the likeliest version of the board
            // rather than the board itself, so nothing shown here can name a
            // Pokémon of theirs that has not come out.
            let likeliest = engine.imagine(board, belief: BattleEngine.Belief()).first?.board ?? board
            var game = TurnGame(board: likeliest, believingTheirs: true)
            game.width = engine.beam + 2
            return (result, game.solve(), likeliest)
        }.value
    }

    private func think() {
        guard let board else { return }
        thinking = true
        thinkTicket += 1
        let ticket = thinkTicket
        let engine = BattleEngine(rules: store.rulebook, budget: 0.5)
        Task { @MainActor in
            let searched = await Self.search(engine, board)
            // The board moved on while this was thinking; the answer is to a
            // position that no longer exists.
            guard ticket == thinkTicket else { return }
            let result = searched.result
            let turnSolve = searched.turnSolve
            var game = TurnGame(board: searched.likeliest, believingTheirs: true)
            game.width = engine.beam + 2

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
            if board.hidesTheirBench {
                let odds = board.liveBenchGuesses.prefix(2).map { guess in
                    guess.fighters.map(\.build.form.formLabel).joined(separator: " + ")
                        + String(format: " %.0f%%", guess.chance * 100)
                }
                ours.append("Their back two have not shown. The search plays the likeliest pairs: "
                            + odds.joined(separator: ", ") + ".")
            }
            ours += result.principal.prefix(2)
            mySide = Array(ours.prefix(6))
            searchNote = "searched \(result.depth) turns, \(result.nodes) positions"
            thought = result
            self.solved = turnSolve

            var theirs: [String] = []
            if let likely = turnSolve.theirMix.indices.max(by: {
                turnSolve.theirMix[$0] < turnSolve.theirMix[$1] }),
               turnSolve.theirPlays.indices.contains(likely) {
                theirs.append(String(format: "Most likely: %@, about %.0f%% of the time.",
                                     game.describe(turnSolve.theirPlays[likely], mine: false),
                                     turnSolve.theirMix[likely] * 100))
            }
            theirs += game.readingNotes(turnSolve)
            let hidden = board.mine.prefix(board.activeCount)
                .map { "\($0.build.form.formLabel)'s \($0.build.item)" }
            if !hidden.isEmpty {
                theirs.append("They cannot see " + hidden.joined(separator: " or ")
                              + ", so they are playing the likeliest version of you.")
            }
            // What they make of your back two, which they cannot see either:
            // from your six and the two you led with, the pair a good player
            // would expect. It is what they are switching and spreading against.
            let expected = board.liveGuesses(mine: true).first?.fighters ?? []
            if !expected.isEmpty, board.hidesBench(mine: true) {
                let real = Set(board.myUnseenBench.map { board.mine[$0].build.form.id })
                let right = expected.filter { real.contains($0.build.form.id) }.count
                theirs.append("They have not seen your back \(real.count == 1 ? "one" : "two"). From your six and your leads they expect "
                              + expected.map(\.build.form.formLabel).joined(separator: " and ")
                              + ", and that is the version of you their orders answer"
                              + (real.isEmpty ? "." : right == expected.count ? " — they have it right." : right == 0 ? " — and they have it wrong, which is worth something." : " — half right."))
            }
            theirSide = Array(theirs.prefix(5))
            thinking = false
            // Watching: the engine gives my orders as well, and plays.
            if watching, finished == nil, sending.isEmpty {
                engineOrders(board, result: result)
                if leftPick != nil { playTurn() }
            }
        }
    }

    /// The two orders as a play, with an empty or fainted slot passing. Orders
    /// are only required of the Pokémon actually standing there.
    private func ordersAsPlay(_ board: Board) -> Play? {
        let standing = (0..<board.activeCount).filter {
            board.mine.indices.contains($0) && !board.mine[$0].fainted
        }
        guard !standing.isEmpty, standing.allSatisfy({ pick(for: $0) != nil }) else { return nil }
        return Play(left: standing.contains(0) ? (leftPick ?? .pass) : .pass,
                    right: standing.contains(1) ? (rightPick ?? .pass) : .pass,
                    megaSlot: megaSlot)
    }

    /// Play the turn out. Their orders come from a solve of the board as they
    /// see it, which is the most expensive thing that happens on a turn, so it
    /// happens off the main thread and the window keeps drawing while it does.
    private func playTurn() {
        guard let current = board, let mine = ordersAsPlay(current), !playing else { return }
        playing = true
        let playedTurn = turn
        Task { @MainActor in
            let solved = await Task.detached(priority: .userInitiated) {
                var game = TurnGame(board: current, believingTheirs: true)
                game.width = 10
                return game.solve()
            }.value
            playing = false
            // The board moved on underneath — an undo, a restart — so this
            // answer is to a position that no longer exists.
            guard turn == playedTurn, board != nil else { return }
            resolve(current, mine: mine, solved: solved)
        }
    }

    /// Everything a turn does once it is known what they played.
    private func resolve(_ current: Board, mine: Play, solved: TurnGame.Solution) {
        var game = TurnGame(board: current)
        game.width = 10
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

        // What the engine would have done, so the turn can be marked. Both
        // numbers are against their mix, which is the only fair comparison:
        // judging a choice against what they actually did rewards luck.
        func worth(_ play: Play) -> Double? {
            guard let row = solved.myPlays.firstIndex(of: play) else { return nil }
            return zip(solved.payoff[row], solved.theirMix).reduce(0) { $0 + $1.0 * $1.1 }
        }
        if let best = solved.lines.first, let played = worth(mine) {
            let gap = played - best.expected
            if solved.myPlays.firstIndex(of: mine) == nil {
                grade = nil
            } else if gap >= -0.02 {
                grade = "That is the line the engine wanted."
            } else {
                grade = String(format: "The engine preferred %@ — %.2f better.",
                               game.describe(best.play, mine: true), -gap)
            }
            review.append(TurnReview(turn: turn,
                                     yours: game.describe(mine, mine: true),
                                     theirs: game.describe(theirPlay, mine: false),
                                     played: played, best: best.expected,
                                     bestLine: game.describe(best.play, mine: true),
                                     before: current))
        } else {
            grade = nil
        }

        // Everything needed to take the turn back.
        history.append((board: current, log: log, turn: turn))

        // A battle rolls. The search does not, which is deliberate: it wants
        // the average and a player wants the dice.
        var next = TurnModel.resolve(current, mine: mine, theirs: theirPlay, rolling: true)
        let told = next.story
        let recorded = next
        // Replacements are sent in together at the end of the turn, faster
        // first. Yours is a decision, and one of the sharper ones in the game,
        // so when you have a gap the turn waits for you and theirs waits with
        // it; when you have none, theirs arrives now.
        var arrivals: [String] = []
        if next.gapsOfMine.isEmpty {
            next.story = []
            next.replaceFallen(mine: [])
            arrivals = next.story
        }

        log.append(BattleView.dividerMark + "Turn \(turn)")
        log.append("You \(game.describe(mine, mine: true)); "
                   + "they \(game.describe(theirPlay, mine: false)).")
        log.append(contentsOf: told)
        log.append(contentsOf: arrivals)

        var hitMine: Set<Int> = [], hitTheirs: Set<Int> = []
        for index in next.mine.indices where index < current.mine.count
            && next.mine[index].hp < current.mine[index].hp { hitMine.insert(index) }
        for index in next.theirs.indices where index < current.theirs.count
            && next.theirs[index].hp < current.theirs[index].hp { hitTheirs.insert(index) }

        board = next
        turn += 1
        replay = told.isEmpty ? [] : recorded.steps
        replayBoard = recorded
        at = 0
        sending = next.gapsOfMine
        chosenSends = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        thought = nil; self.solved = nil
        play(recorded.steps, hitMine: hitMine, hitTheirs: hitTheirs)
        if next.isOut(mine: false) { finished = "They have nothing left. You win." }
        else if next.isOut(mine: true) { finished = "You have nothing left. They win." }
        else { think() }
    }

    /// Walk a turn's steps and show each move as it happened.
    ///
    /// The model records one step per action, carrying who acted and with
    /// what, and the health of everything at that moment. Whoever lost health
    /// between one step and the one before it is who that move reached — which
    /// gets a spread move's two targets, a redirected move's real one, and a
    /// miss's none, without the model having to predict any of them.
    ///
    /// `hitMine` and `hitTheirs` are the whole turn's damage, kept for the end:
    /// once the moves have played, whatever took a hit flashes, which is the
    /// summary the screen used to show on its own.
    private func play(_ steps: [Board.Step], hitMine: Set<Int>, hitTheirs: Set<Int>) {
        playback?.cancel()
        struck = []; struckTheirs = []
        let actions = steps.enumerated().compactMap { index, step -> (Int, Board.Step)? in
            step.action == nil ? nil : (index, step)
        }
        guard !actions.isEmpty else {
            flourish = nil
            flash(hitMine: hitMine, hitTheirs: hitTheirs)
            return
        }
        playback = Task { @MainActor in
            for (order, (index, step)) in actions.enumerated() {
                guard !Task.isCancelled, let action = step.action else { return }
                // Hold the field on the state before this action. `replay` and
                // `at` already drive this for the scrubber; the playback just
                // walks them.
                at = Swift.max(0, index - 1)
                // Health before this step: the step before it, or the health
                // the turn started at for the first one.
                let earlier = index > 0 ? steps[index - 1] : nil
                var reached: [Seat] = []
                for slot in step.myHP.indices where slot < 2 {
                    let was = earlier?.myHP.indices.contains(slot) == true
                        ? earlier!.myHP[slot] : step.myHP[slot]
                    if step.myHP[slot] < was { reached.append(Seat(mine: true, slot: slot)) }
                }
                for slot in step.theirHP.indices where slot < 2 {
                    let was = earlier?.theirHP.indices.contains(slot) == true
                        ? earlier!.theirHP[slot] : step.theirHP[slot]
                    if step.theirHP[slot] < was { reached.append(Seat(mine: false, slot: slot)) }
                }
                // A move never animates as reaching the Pokémon that used it,
                // even when that Pokémon lost health doing it: recoil, a Life
                // Orb and Belly Drum all come off the user, and a Flare Blitz
                // that bursts on its own face reads as a bug.
                let user = Seat(mine: action.byMine, slot: action.slot)
                reached.removeAll { $0 == user }

                flourish = Flourish(id: order, action: action, targets: reached)
                flourishFrom = Date()
                leanIn(action: action, at: reached, singles: board?.activeCount == 1)
                // Travel, then the blow: the step's own health is shown at the
                // moment the move reaches, not when it was thrown.
                let whole = BattleView.flourishSeconds
                try? await Task.sleep(nanoseconds: UInt64(whole * BattleView.impactAt * 1_000_000_000))
                guard !Task.isCancelled else { return }
                at = index
                // The blow lands: show what it took, from the same health diff
                // the targets were worked out from.
                var took: [Seat: Int] = [:]
                if let earlier {
                    for seat in reached {
                        let before = seat.mine ? earlier.myHP : earlier.theirHP
                        let after = seat.mine ? step.myHP : step.theirHP
                        guard before.indices.contains(seat.slot),
                              after.indices.contains(seat.slot) else { continue }
                        let lost = before[seat.slot] - after[seat.slot]
                        if lost > 0 { took[seat] = lost }
                    }
                }
                withAnimation(.easeOut(duration: 0.18)) { damage = took }
                try? await Task.sleep(
                    nanoseconds: UInt64(whole * (1 - BattleView.impactAt) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { damage = [:] }
                // Let it land before the next one starts.
                if order < actions.count - 1 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(BattleView.betweenActions * 1_000_000_000))
                }
            }
            guard !Task.isCancelled else { return }
            flourish = nil
            lunging = nil
            damage = [:]
            // Rest on the last step rather than past it: the field shows the end
            // of the turn, and the Back and Forward buttons still work from
            // there, which is how a turn was reviewed before it was played out.
            // Stepping forward off the end clears the replay, as it always did.
            at = Swift.max(0, replay.count - 1)
            flash(hitMine: hitMine, hitTheirs: hitTheirs)
        }
    }

    /// A physical move is the Pokémon arriving in person, so the card leans
    /// into it and comes back. Two animated state changes for the whole thing
    /// rather than an offset recomputed every frame.
    private func leanIn(action: Board.Action, at targets: [Seat], singles: Bool) {
        guard action.category == "Physical" else {
            withAnimation(.easeOut(duration: 0.12)) { lunging = nil }
            return
        }
        let user = Seat(mine: action.byMine, slot: action.slot)
        // Toward whoever it reached; toward the other side when it reached
        // nobody, because the Pokémon still swung.
        let from = BattleView.seatFraction(user, singles: singles)
        let toward = targets.first.map { BattleView.seatFraction($0, singles: singles) }
            ?? CGPoint(x: user.mine ? 0.75 : 0.25, y: from.y)
        let dx = toward.x - from.x, dy = toward.y - from.y
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        // Far enough to read as a charge rather than a twitch. A physical
        // move is the Pokémon crossing the field and hitting something.
        let reach: CGFloat = 52
        let step = CGSize(width: dx / length * reach, height: dy / length * reach)
        // `lunging` first and unanimated, so the card is eligible to move but
        // has not moved; then the offset animates from nothing to the lean.
        // Setting both at once put the card there without the step.
        lunging = user
        lungeBy = .zero
        // Out fast, arriving as the blow lands, then back slower — which is
        // what a charge looks like and what a recoil from one looks like.
        let strike = BattleView.flourishSeconds * BattleView.impactAt
        withAnimation(.easeIn(duration: strike)) { lungeBy = step }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(strike * 1_000_000_000))
            guard lunging == user else { return }
            withAnimation(.easeOut(duration: BattleView.flourishSeconds * 0.45)) { lungeBy = .zero }
        }
    }

    /// What took a hit over the whole turn, flashed once at the end.
    private func flash(hitMine: Set<Int>, hitTheirs: Set<Int>) {
        struck = hitMine; struckTheirs = hitTheirs
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            struck = []; struckTheirs = []
        }
    }

    /// Put the last turn back, so a line can be tried a different way.
    private func undo() {
        guard let last = history.popLast() else { return }
        review.removeAll { $0.turn >= last.turn }
        restore(last.board, log: last.log, turn: last.turn)
    }

    /// Take the whole game back to the start of a turn, so it can be played a
    /// different way. This is what the Review panel is for: the engine has
    /// already said which turns were worth the most, and the way to learn one
    /// is to play it again rather than read about it.
    private func rewind(to target: Int) {
        guard let index = history.lastIndex(where: { $0.turn == target }) else { return }
        let entry = history[index]
        history.removeSubrange(index...)
        review.removeAll { $0.turn >= target }
        restore(entry.board, log: entry.log, turn: entry.turn)
    }

    private func restore(_ board: Board, log: [String], turn: Int) {
        // Whatever was being played belongs to a turn that no longer happened.
        playback?.cancel(); playback = nil
        flourish = nil; lunging = nil; lungeBy = .zero; damage = [:]
        self.board = board
        self.log = log
        self.turn = turn
        finished = nil
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        struck = []; struckTheirs = []
        grade = nil; replay = []; at = 0; replayBoard = nil; sending = []
        chosenSends = []; playing = false
        think()
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
