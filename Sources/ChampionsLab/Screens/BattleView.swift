//  BattleView.swift
//  Playing the matchup out, with both sides' reasoning on screen beside it.
//
//  The screen opens on the lobby: the last two teams looked at, facing each
//  other, a click from starting -- or an open side asking for one. Then Team
//  Preview, not turn one: you see six and theirs, and you choose four and an
//  order before anything happens. That choice is most of the game and it is
//  made with less information than any later one, so it gets its own screen
//  rather than being assumed away.
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

    enum Stage { case versus, preview, battle }

    /// The game itself, and the turn being shown. The pre-game flow is the
    /// view's own state; everything from the first board onward lives on these
    /// two, and the accessors below are how the drawing code reads them.
    @StateObject private var session: BattleSession
    @StateObject private var playback: TurnPlayback
    typealias TurnReview = BattleSession.TurnReview
    typealias Panel = BattleSession.Panel
    typealias Command = BattleSession.Command

    private var board: Board? { get { session.board } nonmutating set { session.board = newValue } }
    private var log: [String] { get { session.log } nonmutating set { session.log = newValue } }
    private var turn: Int { get { session.turn } nonmutating set { session.turn = newValue } }
    private var leftPick: Choice? { get { session.leftPick } nonmutating set { session.leftPick = newValue } }
    private var rightPick: Choice? { get { session.rightPick } nonmutating set { session.rightPick = newValue } }
    private var megaSlot: Int? { get { session.megaSlot } nonmutating set { session.megaSlot = newValue } }
    private var command: Command { get { session.command } nonmutating set { session.command = newValue } }
    private var thinking: Bool { get { session.thinking } nonmutating set { session.thinking = newValue } }
    private var thought: BattleEngine.Result? { get { session.thought } nonmutating set { session.thought = newValue } }
    private var solved: TurnGame.Solution? { get { session.solved } nonmutating set { session.solved = newValue } }
    private var mySide: [String] { get { session.mySide } nonmutating set { session.mySide = newValue } }
    private var theirSide: [String] { get { session.theirSide } nonmutating set { session.theirSide = newValue } }
    private var playing: Bool { get { session.playing } nonmutating set { session.playing = newValue } }
    private var finished: String? { get { session.finished } nonmutating set { session.finished = newValue } }
    private var history: [(board: Board, log: [String], turn: Int)] { get { session.history } nonmutating set { session.history = newValue } }
    private var review: [TurnReview] { get { session.review } nonmutating set { session.review = newValue } }
    private var grade: String? { get { session.grade } nonmutating set { session.grade = newValue } }
    private var explaining: TurnReview? { get { session.explaining } nonmutating set { session.explaining = newValue } }
    private var sending: [Int] { get { session.sending } nonmutating set { session.sending = newValue } }
    private var chosenSends: [(slot: Int, bench: Int)] { get { session.chosenSends } nonmutating set { session.chosenSends = newValue } }
    private var panel: Panel { get { session.panel } nonmutating set { session.panel = newValue } }

    private var replay: [Board.Step] { get { playback.replay } nonmutating set { playback.replay = newValue } }
    private var at: Int { get { playback.at } nonmutating set { playback.at = newValue } }
    private var replayBoard: Board? { get { playback.replayBoard } nonmutating set { playback.replayBoard = newValue } }

    @State private var stage: Stage = .versus
    @State private var myTeamID = ""
    @State private var opponentID = ""
    /// The matchup last looked at, so the lobby opens ready.
    @AppStorage("battleLobbyMine") private var rememberedMine = ""
    @AppStorage("battleLobbyTheirs") private var rememberedTheirs = ""
    @State private var startHover = false
    /// Asking whether to stop the game in progress.
    @State private var stopping = false
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

    /// What the two sixes say about each other, worked out once both are
    /// chosen and read by the versus page and Team Preview.
    @State private var lobby = Lobby()
    @State private var singles = false

    /// The four being brought, in order. The first two lead.
    @State private var bringing: [String] = []
    /// Whose matchups their side is showing. The one just picked, unless
    /// another of yours is clicked.
    @State private var focused: String?



    // Three numbers rather than one, because an attack and a turn want opposite
    // things. An attack should be fast: a beam crosses the field, a Pokémon
    // lunges and is back. A turn should not, or four of them blur into one
    // event nobody can follow.
    //
    // These were the same number once, so slowing the turn down slowed the
    // attacks with it and every move became a languid drift. The time a turn
    // takes now lives in the pause *after* a move rather than in the move, and
    // the pause is where it belongs anyway: that is when the damage number is
    // on screen and there is something to read.



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
        // The search runs as a task, which a snapshot never gets to run, so a
        // snapshot hands the answer in ready-made.
        let shared = Store.shared
        let playbackObject = TurnPlayback()
        _playback = StateObject(wrappedValue: playbackObject)
        _session = StateObject(wrappedValue: BattleSession(
            rules: shared.rulebook, playback: playbackObject,
            board: playing,
            log: playing.map { [BattleSession.opener] + $0.story } ?? logging,
            command: showing, review: reviewing,
            panel: !reviewing.isEmpty ? .review : (!logging.isEmpty ? .log : .engine),
            thought: seeded?.0, solved: seeded?.1))
        if let openTeams {
            _myTeamID = State(initialValue: openTeams.mine)
            _opponentID = State(initialValue: openTeams.theirs)
            let stage = arriving ?? .preview
            _stage = State(initialValue: stage)
            // A snapshot never runs the step that works the two sixes out, so
            // it is done here, against the shared store the sprites also use.
            if let mine = shared.teams.first(where: { $0.id.uuidString == openTeams.mine }),
               let theirs = shared.data.metaTeams.first(where: { $0.id == openTeams.theirs })
                   .map({ shared.opponentTeam($0) })
                   ?? shared.teams.first(where: { $0.id.uuidString == openTeams.theirs }) {
                _lobby = State(initialValue: BattleView.lobby(mine: mine, theirs: theirs,
                                                              singles: false, rules: shared.rulebook))
            }
        }
        if !previewing.isEmpty { _bringing = State(initialValue: previewing) }
        if playing != nil { _stage = State(initialValue: .battle) }
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
                case .versus:
                    VersusPageView(myTeam: myTeam, theirTeam: theirTeam, lobby: lobby,
                                   myTeamID: myTeamID, opponentID: opponentID, singles: singles,
                                   startHover: $startHover,
                                   onChooseMine: { choose(mine: $0) },
                                   onChooseTheirs: { choose(theirs: $0) }) {
                        bringing = []; focused = nil
                        stage = .preview
                    }
                case .preview:
                    TeamPreviewView(myTeam: myTeam, theirTeam: theirTeam, lobby: lobby, singles: singles,
                                    bringing: $bringing, focused: $focused, onBegin: begin)
                case .battle:
                    BattleFieldView(session: session, playback: playback,
                                    opening: opening, startFlash: startFlash, shown: shown,
                                    callout: callout, singles: singles) { stage = .preview }
                }
            }
        }
        .sheet(item: $session.explaining) { entry in
            TurnExplainer(review: entry, rules: store.rulebook) { explaining = nil }
                .environmentObject(store)
        }
        .onAppear(perform: recallLastMatchup)
        .confirmationDialog("Stop this game?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop the game", role: .destructive) { stopGame() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("The board and the turn log go. The two teams stay chosen, so another game is a click away.")
        }
    }

    /// The lobby opens on the last matchup looked at, so a battle is a click
    /// away. A snapshot opens on what it was handed and remembers nothing.
    private func recallLastMatchup() {
        guard !snapshotMode else { return }
        if myTeamID.isEmpty { myTeamID = rememberedMine }
        if opponentID.isEmpty { opponentID = rememberedTheirs }
        // A team since deleted, or a list since withdrawn.
        if myTeam == nil { myTeamID = "" }
        if theirTeam == nil { opponentID = "" }
        if stage == .versus, myTeam != nil, theirTeam != nil, lobby.verdict == nil { enterVersus() }
    }

    /// The game ends here, by choice: the board and its log go, the two
    /// teams stay chosen, and the lobby is where it lands.
    private func stopGame() {
        session.endGame()
        opening = false; startFlash = false; shown = []; callout = nil
        bringing = []; focused = nil
        stage = .versus
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

            crumb("Lobby", .versus, symbol: "bolt.fill", enabled: true)
            crumbArrow
            crumb("Team Preview", .preview, symbol: "list.number", enabled: ready)
            crumbArrow
            crumb("Battle", .battle, symbol: "flag.2.crossed", enabled: board != nil)

            Spacer()
            if stage == .battle {
                Text("Turn \(turn)").font(.system(size: 11)).foregroundStyle(.secondary)
                // A game over needs no asking; one in progress does.
                Button {
                    if finished != nil { stopGame() } else { stopping = true }
                } label: {
                    Label(finished == nil ? "Stop game" : "Leave game", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
                .tint(Palette.bad)
                .help("End this game and go back to the lobby. The teams stay chosen.")
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
        case .versus:
            if lobby.verdict == nil { enterVersus() } else { stage = .versus }
        case .preview:
            if lobby.verdict == nil { enterVersus() }
            stage = .preview
        case .battle:
            if board != nil { stage = .battle }
        }
    }

    /// The format changed under the lobby: the game, if any, is off, and the
    /// two sixes are read again for the new one.
    private func reset() {
        session.endGame()
        opening = false; startFlash = false; shown = []; callout = nil
        bringing = []; focused = nil; lobby = Lobby()
        stage = .versus
        if myTeam != nil, theirTeam != nil { enterVersus() }
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
        rememberedMine = id
        lobby = Lobby(); session.endGame()
        if theirTeam != nil { enterVersus() }
    }

    private func choose(theirs id: String) {
        opponentID = id
        rememberedTheirs = id
        lobby = Lobby(); session.endGame()
        if myTeam != nil { enterVersus() }
    }


    private var format: String { singles ? "singles" : "doubles" }

    // MARK: Team Preview

    private func begin() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        guard bringing.count >= leadCount else { return }
        stage = .battle
        turn = 1
        finished = nil
        history = []; grade = nil; replay = []; at = 0; replayBoard = nil; sending = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        chosenSends = []; review = []; playing = false
        log = [BattleSession.opener]
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
            session.think()
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
            session.think()
        }
    }

    // MARK: The field

}

