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

    /// The other player, when this game is between two people. Nil against
    /// the app's own opponent.
    private let link: LANLink?

    @State private var stage: Stage = .versus
    @State private var myTeamID = ""
    @State private var opponentID = ""
    /// The matchup last looked at, so the lobby opens ready. The defaults
    /// read and written directly rather than through @AppStorage: while this
    /// screen was showing, the sidebar's list lost every row, and
    /// @AppStorage was one of two things it used that no other screen did.
    private var rememberedMine: String {
        get { UserDefaults.standard.string(forKey: "battleLobbyMine") ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "battleLobbyMine") }
    }
    private var rememberedTheirs: String {
        get { UserDefaults.standard.string(forKey: "battleLobbyTheirs") ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "battleLobbyTheirs") }
    }
    @State private var startHover = false
    /// Asking whether to stop the game in progress.
    @State private var stopping = false
    /// A game between two people: my four are chosen and sent, and the page
    /// waits for the other player's.
    @State private var readied = false
    /// Which lobby is being worked out; an older one's answer is dropped.
    @State private var lobbyTicket = 0
    /// The two sixes as they stood when the lobby was worked out. A team
    /// edited in the Builder leaves the lobby holding the Pokemon that used
    /// to be on it -- the banner and the plans draw from those -- so the
    /// screen notices and works it out again.
    @State private var lobbyStamp = ""
    /// The start of the game, being shown: the flash, the leads coming out,
    /// their abilities going off. Nil once orders can be given.
    @State private var opening = false
    @State private var startFlash = false
    /// Which fighters have come out so far, as "m0", "t1".
    @State private var shown: Set<String> = []
    /// The ones whose ball has opened. Coming out is two moments -- the throw
    /// and the arrival -- and the Pokemon appears on the second, which is what
    /// makes the ball look like it brought something.
    @State private var landed: Set<String> = []
    /// Which tune this game gets, chosen once when it starts so it does not
    /// change under the player every time the view is rebuilt. Showdown picks
    /// its by the battle's id for the same reason.
    @State private var musicSeed = Int.random(in: 0..<10_000)
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
         replaying: [Board.Step] = [],
         reviewing: [TurnReview] = [],
         logging: [String] = [],
         thinking seeded: (BattleEngine.Result, TurnGame.Solution)? = nil) {
        // The search runs as a task, which a snapshot never gets to run, so a
        // snapshot hands the answer in ready-made.
        let shared = Store.shared
        let playbackObject = TurnPlayback()
        _playback = StateObject(wrappedValue: playbackObject)
        let sessionObject = BattleSession(
            rules: shared.rulebook, playback: playbackObject,
            board: playing,
            log: playing.map { [BattleSession.opener] + $0.story } ?? logging,
            command: showing, review: reviewing,
            panel: !reviewing.isEmpty ? .review : (!logging.isEmpty ? .log : .engine),
            thought: seeded?.0, solved: seeded?.1)
        // A turn on show is one that has been played, so the count is past it.
        if !replaying.isEmpty { sessionObject.turn = 2 }
        _session = StateObject(wrappedValue: sessionObject)
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
        link = nil
        if !previewing.isEmpty { _bringing = State(initialValue: previewing) }
        if playing != nil { _stage = State(initialValue: .battle) }
        // The turn just played, with every step on show, for the stepper.
        if let playing, !replaying.isEmpty {
            playbackObject.show(playing, steps: replaying, revealed: replaying.count)
        }
    }


    /// A game between two people: straight to Team Preview against the six
    /// they showed, with the session playing over the link.
    init(lan link: LANLink) {
        self.link = link
        let shared = Store.shared
        let playbackObject = TurnPlayback()
        _playback = StateObject(wrappedValue: playbackObject)
        let sessionObject = BattleSession(rules: shared.rulebook, playback: playbackObject)
        sessionObject.link = link
        _session = StateObject(wrappedValue: sessionObject)
        _myTeamID = State(initialValue: link.myTeam.id.uuidString)
        _stage = State(initialValue: .preview)
        _singles = State(initialValue: link.singles)
    }

    private var myTeam: Team? {
        if let link { return link.myTeam }
        return store.teams.first { $0.id.uuidString == myTeamID }
    }
    private var theirTeam: Team? {
        if let link { return link.theirTeamShown }
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            return store.opponentTeam(meta)
        }
        if opponentID.hasPrefix("ladder-") { return store.ladderOpponent(id: opponentID) }
        return store.teams.first { $0.id.uuidString == opponentID }
    }
    /// What the two chosen sixes are made of, down to the sets. Anything
    /// the lobby reads is in here, so a change means the lobby is stale.
    private var matchupStamp: String {
        (myTeam.map(LabStore.stamp) ?? "-") + "//" + (theirTeam.map(LabStore.stamp) ?? "-")
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
                                    bringing: $bringing, focused: $focused, onBegin: begin,
                                    beginLabel: link == nil ? "START THE BATTLE" : "READY FOR BATTLE",
                                    waiting: readied ? "Ready. Waiting for \(link?.theirName ?? "the other player")..." : nil,
                                    link: link,
                                    onBack: { bringing = []; focused = nil; stage = .versus })
                case .battle:
                    BattleFieldView(session: session, playback: playback,
                                    opening: opening, startFlash: startFlash, shown: shown,
                                    landed: landed,
                                    callout: callout, singles: singles) { stage = .preview }
                }
            }
        }
        .sheet(item: $session.explaining) { entry in
            TurnExplainer(review: entry, rules: store.rulebook) { explaining = nil }
                .environmentObject(store)
        }
        .onAppear {
            if let link { link.attach(session) } else { recallLastMatchup() }
        }
        // A team edited while the lobby is on screen.
        .onChange(of: matchupStamp) { _ in
            guard link == nil, board == nil, myTeam != nil, theirTeam != nil,
                  lobbyStamp != matchupStamp else { return }
            refreshLobby(clearing: true)
        }
        // Both fours are in: the host built the game, and the opening plays.
        .onReceive(session.$intro) { steps in
            if let steps, link != nil { playOpening(steps) }
        }
        .onChange(of: session.finished) { result in
            // Showdown stops the music when a game ends rather than playing on
            // over the result, and it is right to: the tune is the tension.
            if result != nil { recordGame(); BattleAudio.shared.stopMusic() }
        }
        .onDisappear { BattleAudio.shared.stopMusic() }
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
        // Away in the Builder and back again, with a team changed while you
        // were gone.
        if myTeam != nil, theirTeam != nil, lobby.verdict == nil || lobbyStamp != matchupStamp {
            refreshLobby(clearing: board != nil ? false : true)
            if stage == .versus { stage = .versus }
        }
    }

    /// A game played to a result goes into the history the lobby shows. A
    /// snapshot plays nothing to a result and remembers nothing.
    private func recordGame() {
        guard !snapshotMode, let board = session.board, let mine = myTeam, let theirs = theirTeam else { return }
        let review = session.review
        store.record(GameRecord(
            id: UUID(), played: Date(), format: format,
            won: board.isOut(mine: false), turns: max(1, session.turn - 1),
            myTeamID: myTeamID, myTeamName: mine.name,
            myForms: board.mine.map(\.build.form.id),
            theirID: link.map { "lan:\($0.theirName)" } ?? opponentID,
            theirName: link.map { "\(theirs.name) (\($0.theirName))" } ?? theirs.name,
            theirForms: board.theirs.map(\.build.form.id),
            leftOnTable: review.reduce(0) { $0 + $1.lost },
            reviewedTurns: review.count))
    }

    /// The game ends here, by choice: the board and its log go, the two
    /// teams stay chosen, and the lobby is where it lands.
    /// The opening of a game over the link, as a local one is shown: the
    /// flash, the leads out one by one, then each arrival's step -- its line
    /// called out over the field, its stages and abilities shown -- before
    /// orders are asked. Everything the arrivals did is held off the field
    /// until its beat.
    private func playOpening(_ steps: [Board.Step]) {
        guard let start = session.board else { session.introFinished(); return }
        stage = .battle
        readied = false
        opening = true
        shown = []
        landed = []
        callout = nil
        startFlash = true
        musicSeed = Int.random(in: 0..<10_000)
        BattleAudio.shared.startMusic(seed: musicSeed)
        playback.withhold(steps)
        let arrivals = (0..<start.activeCount).flatMap { slot in ["m\(slot)", "t\(slot)"] }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeOut(duration: 0.35)) { startFlash = false }
            try? await Task.sleep(nanoseconds: 300_000_000)
            for key in arrivals {
                // The throw, then what was in it: the ball is in the air for
                // three tenths of a second before it opens.
                _ = shown.insert(key)
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { _ = landed.insert(key) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            for step in steps {
                let lines = step.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                withAnimation(.easeInOut(duration: 0.4)) { callout = lines.joined(separator: " ") }
                playback.flash([step], withheld: true)
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
            withAnimation(.easeOut(duration: 0.3)) { callout = nil }
            opening = false
            session.introFinished()
        }
    }

    private func stopGame() {
        session.endGame()
        readied = false
        BattleAudio.shared.stopMusic()
        opening = false; startFlash = false; shown = []; landed = []; callout = nil
        bringing = []; focused = nil
        if link != nil {
            // Out of a game between two people is out of the room too.
            LANService.shared.leaveRoom()
            return
        }
        stage = .versus
    }

    // MARK: Choosing the teams

    private var setupBar: some View {
        let ready = myTeam != nil && theirTeam != nil
        return HStack(spacing: 10) {
            if let link {
                // The other player's game: the format is the host's, and the
                // engine is a switch.
                Label("vs \(link.theirName)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(link.singles ? "Singles" : "Doubles").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().frame(height: 18)
                EngineSwitch(link: link, session: session)
                Divider().frame(height: 18)
            } else {
                Picker("", selection: $singles) {
                    Text("Doubles").tag(false)
                    Text("Singles").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .onChange(of: singles) { _ in reset() }

                Divider().frame(height: 18)

                crumb("Lobby", .versus, symbol: "bolt.fill", enabled: true)
                crumbArrow
            }
            crumb("Team Preview", .preview, symbol: "list.number", enabled: ready)
            crumbArrow
            crumb("Battle", .battle, symbol: "flag.2.crossed", enabled: board != nil)

            Spacer()
            if stage == .battle {
                Text("Turn \(turn)").font(.system(size: 11)).foregroundStyle(.secondary)
                leaveButton
            }
        }
        .padding(12)
    }

    /// Asked under the button, as the other screens ask things, rather than
    /// in a confirmation dialog -- the other of the two things this screen
    /// used that no other did while the sidebar lost its rows.
    private var stopConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stop this game?").font(.system(size: 13, weight: .semibold))
            Text("The board and the turn log go. The two teams stay chosen, so another game is a click away.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep playing") { stopping = false }.controlSize(.small)
                Button("Stop the game") { stopping = false; stopGame() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.bad)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Out of the game. In progress it is a red stop that asks first; over,
    /// it is the blue way on, and the result is already in the history.
    @ViewBuilder
    private var leaveButton: some View {
        if finished == nil {
            Button { stopping = true } label: {
                Label("Stop game", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .controlSize(.small)
            .tint(Palette.bad)
            .help("End this game and go back to the lobby. The teams stay chosen.")
            .popover(isPresented: $stopping, arrowEdge: .bottom) { stopConfirmation }
        } else {
            Button { stopGame() } label: {
                Label("Finish game", systemImage: "flag.checkered")
                    .font(.system(size: 11, weight: .semibold))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.defaultAction)
            .help("Back to the lobby. The game is in the history there.")
        }
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
        BattleAudio.shared.stopMusic()
        opening = false; startFlash = false; shown = []; landed = []; callout = nil
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
        refreshLobby(clearing: true)
        if myTeam != nil, theirTeam != nil { stage = .versus }
    }

    /// Work the two sixes out again. `clearing` throws away the game and the
    /// four being brought, which is what choosing a team means; a team edited
    /// under a lobby only needs the reading redone.
    private func refreshLobby(clearing: Bool) {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        if clearing {
            bringing = []; focused = nil; board = nil; finished = nil
            log = []; mySide = []; theirSide = []
        }
        lobby = Lobby()
        lobbyStamp = matchupStamp
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
        if let link {
            // Over the link, Ready: my four go to the host, and the page waits
            // for the other player's. The host builds the game once both are
            // in, and the opening comes back as the first snapshot.
            session.endGame()
            session.link = link
            link.attach(session)
            readied = true
            link.chose(bringing: bringing)
            return
        }
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
        landed = []
        callout = nil
        musicSeed = Int.random(in: 0..<10_000)
        if !snapshotMode { BattleAudio.shared.startMusic(seed: musicSeed) }
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
                // The throw, then what was in it: the ball is in the air for
                // three tenths of a second before it opens.
                _ = shown.insert(key)
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { _ = landed.insert(key) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            var running = start
            for entry in order {
                let before = running.story.count
                let stepsBefore = running.steps.count
                running.landed(mine: entry.mine, slot: entry.slot)
                let said = Array(running.story.dropFirst(before))
                guard !said.isEmpty else { continue }
                withAnimation(.easeInOut(duration: 0.4)) {
                    board = running
                    callout = said.joined(separator: " ")
                }
                // What the arrival did, over whoever it happened to, a cause
                // at a time: the Intimidate and the stages it took, then the
                // Defiant that answered.
                playback.flash(Array(running.steps.dropFirst(stepsBefore)))
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

/// The engine's advice, on or off, in a game between two people.
struct EngineSwitch: View {
    @ObservedObject var link: LANLink
    @ObservedObject var session: BattleSession

    var body: some View {
        Toggle("Enable engine", isOn: $link.engineEnabled)
            .toggleStyle(.switch).controlSize(.mini)
            .font(.system(size: 11))
            .help("The engine's reading of the position and its suggested line. It sees only what you see.")
            .onChange(of: link.engineEnabled) { on in
                if on { session.think() } else { session.thinking = false; session.mySide = []; session.theirSide = [] }
            }
    }
}
