//  BattleSession.swift
//  One game of doubles, as the state of it and the things that move it on.
//
//  This is what the battle screen is *about*, separated from how it is drawn.
//  The board, the turn number, every turn that has been played and marked, the
//  orders being given, what the engine thinks of the position, whose slots are
//  empty and waiting -- and the four things that change any of it: thinking
//  about the position, playing the turn, taking one back, taking several back.
//
//  It was thirty @State properties and four hundred lines of logic on a
//  four-thousand-line view, which meant the logic could not be read without
//  the drawing and could not be tested without a window. Here it is a class
//  with a Rulebook and a TurnPlayback, and nothing else: no store, no SwiftUI
//  beyond ObservableObject, no knowledge of what a card looks like.
//
//  The view keeps the pre-game flow -- picking teams, the versus page, Team
//  Preview -- which is its own state and never outlives it, and reads
//  everything here through the session.

import SwiftUI

@MainActor
final class BattleSession: ObservableObject {
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
        /// Both plays and what the turn said, so the whole thing can be
        /// explained afterwards rather than only scored.
        let minePlay: Play
        let theirPlay: Play
        let told: [String]
        var lost: Double { max(0, best - played) }
    }

    /// Which of the three readings the side panel is showing.
    enum Panel: String, CaseIterable {
        case engine = "Engine", theirs = "Their read", review = "Review", log = "Log"
    }

    /// Where you are in giving orders: one Pokémon at a time, first the choice
    /// between fighting and switching, then the specific move or partner.
    enum Command: Equatable {
        case menu
        case fight
        case party
        case aiming(move: Int)
    }

    static let opener = "Both sides send out their leads. Neither knows what the other is holding, nor which four came."
    /// A log line that is a turn marker rather than an event.
    static let dividerMark = "\u{00A7}"

    let rules: Rulebook
    /// The turn being shown as it happens. Owned here because resolving a turn
    /// is what starts the playback, and taking one back is what stops it.
    let playback: TurnPlayback

    @Published var board: Board?
    @Published var log: [String] = []
    @Published var turn = 1
    @Published var leftPick: Choice?
    @Published var rightPick: Choice?
    /// Toggled beside the move, the way the game asks for it.
    @Published var megaSlot: Int?
    /// Where you are in giving orders to the Pokemon being commanded.
    @Published var command: Command = .menu
    @Published var thinking = false
    /// Which search is being waited on; an older one's answer is dropped.
    private var thinkTicket = 0
    /// The search itself, kept so the tiles can read it.
    @Published var thought: BattleEngine.Result?
    @Published var solved: TurnGame.Solution?
    @Published var mySide: [String] = []
    @Published var theirSide: [String] = []
    @Published var searchNote = ""
    /// Let the engine give my orders too, to watch a game out.
    @Published var watching = false
    /// A turn is being played out: the button waits rather than starting a
    /// second one on top of the first.
    @Published var playing = false
    @Published var finished: String?
    /// Whose side won, once somebody has: the crown goes over them. Read off
    /// the board rather than kept, so it cannot disagree with it.
    func won(_ board: Board) -> Bool? {
        guard finished != nil else { return nil }
        if board.isOut(mine: false) { return true }
        if board.isOut(mine: true) { return false }
        return nil
    }
    /// Every board so far, so a turn can be taken back and tried again.
    /// The game Showdown is running, when the engine is the one resolving.
    ///
    /// The choices are still ours -- what the player picks, and what the
    /// search picks for the opponent -- and the rules are entirely its. That
    /// split is the point: a decision is a decision either way, and turn
    /// order, damage, ability timing and every interaction between them is
    /// the thing worth having from somebody who has already got it right.
    var showdown: ShowdownBattle?

    @Published var history: [(board: Board, log: [String], turn: Int)] = []
    /// Every turn of this game, marked. Read back in the Review panel.
    @Published var review: [TurnReview] = []
    /// What the engine wanted, against what was actually played.
    @Published var grade: String?
    /// The turn being explained, if the sheet is open.
    @Published var explaining: TurnReview?
    /// A review waiting on the turn's own story, which is not known until the
    /// turn has actually been resolved.
    @Published var pendingReview: (turn: Int, yours: String, theirs: String,
                                   played: Double, best: Double, bestLine: String,
                                   before: Board, minePlay: Play, theirPlay: Play)?
    /// Slots of mine standing empty, waiting for somebody to be sent in.
    @Published var sending: [Int] = []
    /// Replacements chosen so far this turn, sent in together once every gap
    /// has one, in Speed order alongside theirs.
    @Published var chosenSends: [(slot: Int, bench: Int)] = []
    /// A turn stopped partway: one of yours pivoted -- a U-turn, a Parting
    /// Shot, an Eject Button -- and the rest of the turn waits on who comes
    /// in. What `conclude` needs once it does.
    struct PausedTurn {
        let before: Board
        let orders: String
        let stepsPlayed: Int
    }
    @Published var pausedTurn: PausedTurn?
    var pivoting: Bool { pausedTurn != nil || remotePivot }
    /// A game between two people: the link carries what the engine and the
    /// model would otherwise do here, and answers with snapshots.
    var link: LANLink?
    /// Waiting on the other player, and for what.
    @Published var waitingOn: String?
    /// The other side's turn stopped for our pivot, over the link.
    @Published var remotePivot = false
    /// How many steps of the current turn the field has already played.
    private var shownSteps = 0
    /// The opening of a game over the link: the arrival steps, for the
    /// battle screen to play as the intro before orders are asked.
    @Published var intro: [Board.Step]?
    private var introAsking: Wire.Asking?
    /// Which of the readings the side panel is showing.
    @Published var panel: Panel = .engine

    /// Seeded, so a snapshot can render a game nobody has clicked into.
    init(rules: Rulebook, playback: TurnPlayback,
         board: Board? = nil, log: [String] = [], command: Command = .menu,
         review: [TurnReview] = [], panel: Panel = .engine,
         thought: BattleEngine.Result? = nil, solved: TurnGame.Solution? = nil) {
        self.rules = rules
        self.playback = playback
        self.board = board
        self.log = log
        self.command = command
        self.review = review
        self.panel = panel
        self.thought = thought
        self.solved = solved
    }

    // MARK: - Thinking

    /// The search, off the main thread. The engine is a value that knows the
    /// rulebook and nothing else, so it runs wherever it is put; the window
    /// keeps drawing and the spinner actually spins.
    static func search(_ engine: BattleEngine, _ board: Board)
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

    func think() {
        guard let board else { return }
        // In a game between two people the engine's advice is the player's
        // to switch on; off, nothing is searched.
        if let link, !link.engineEnabled { thinking = false; return }
        thinking = true
        thinkTicket += 1
        let ticket = thinkTicket
        // Budgeted in positions, so the same board gets the same answer every
        // time it is opened. The patience is for a machine much slower than
        // the one the budget was measured on, and should not fire here.
        let engine = BattleEngine(rules: rules, patience: 1.5)
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

    /// Which of my slots is still waiting for an order, if any: the ring the
    /// field draws, and the deck's cue for whose turn it is to be told.
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
    func awaitingOrders(_ board: Board) -> Int? {
        guard finished == nil, sending.isEmpty, !playing, playback.task == nil else { return nil }
        let living = (0..<board.activeCount).filter {
            board.mine.indices.contains($0) && !board.mine[$0].fainted
        }
        return living.first { pick(for: $0) == nil }
    }

    // MARK: - Playing a turn

    /// The two orders as a play, with an empty or fainted slot passing. Orders
    /// are only required of the Pokémon actually standing there.
    func ordersAsPlay(_ board: Board) -> Play? {
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
    func playTurn() {
        guard let current = board, let mine = ordersAsPlay(current), !playing else { return }
        // Over the link, the orders go to the host and the turn comes back.
        if let link {
            playing = true
            waitingOn = "Waiting for \(link.theirName) to choose..."
            link.chose(play: mine)
            return
        }
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
    func resolve(_ current: Board, mine: Play, solved: TurnGame.Solution) {
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
            pendingReview = (turn: turn,
                             yours: game.describe(mine, mine: true),
                             theirs: game.describe(theirPlay, mine: false),
                             played: played, best: best.expected,
                             bestLine: game.describe(best.play, mine: true),
                             before: current, minePlay: mine, theirPlay: theirPlay)
        } else {
            grade = nil
        }

        // Everything needed to take the turn back.
        history.append((board: current, log: log, turn: turn))

        // A battle rolls. The search does not, which is deliberate: it wants
        // the average and a player wants the dice. A pivot of yours -- a
        // U-turn, a Parting Shot, an Eject Button -- stops the turn for who
        // comes in, and the rest of it plays in `resumeTurn`.
        let orders = "You \(game.describe(mine, mine: true)); they \(game.describe(theirPlay, mine: false))."

        // Showdown's, when it is running the game. It does not need to be
        // asked to stop before a pivot: it asks for the replacement itself,
        // the same way it asks after a faint, so both arrive as one thing to
        // answer rather than two mechanisms.
        if let showdown {
            do {
                let next = try showdown.play(mine: mine, theirs: theirPlay, oursWhenForced: nil)
                if showdown.awaitingSendIn {
                    pausedTurn = PausedTurn(before: current, orders: orders, stepsPlayed: next.steps.count)
                    board = next
                    playback.show(next, steps: next.steps, before: current)
                    sending = Self.fallen(in: next, since: current)
                    chosenSends = []
                    leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
                    thought = nil; self.solved = nil
                    playback.play(next.steps, hitMine: Self.hurt(mine: true, next, since: current),
                                  hitTheirs: Self.hurt(mine: false, next, since: current),
                                  singles: next.activeCount == 1)
                    return
                }
                conclude(next, before: current, orders: orders, stepsPlayed: 0)
            } catch {
                log.append("The engine could not play that turn: \(error.localizedDescription)")
                playing = false
            }
            return
        }

        var asked = current
        asked.asksBeforePivot = true
        let next = TurnModel.resolve(asked, mine: mine, theirs: theirPlay, rolling: true)
        if let pivot = next.pendingPivot {
            pausedTurn = PausedTurn(before: current, orders: orders, stepsPlayed: next.steps.count)
            board = next
            playback.show(next, steps: next.steps, before: current)
            sending = [pivot.slot]
            chosenSends = []
            leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
            thought = nil; self.solved = nil
            playback.play(next.steps, hitMine: Self.hurt(mine: true, next, since: current),
                          hitTheirs: Self.hurt(mine: false, next, since: current),
                          singles: next.activeCount == 1)
            return
        }
        conclude(next, before: current, orders: orders, stepsPlayed: 0)
    }

    /// The active slots of ours with nobody standing in them.
    static func fallen(in board: Board, since before: Board) -> [Int] {
        (0..<Swift.min(board.activeCount, board.mine.count)).filter { board.mine[$0].fainted }
    }

    /// The chosen Pokemon comes in for the one that pivoted, and the turn
    /// finishes: the actions that were waiting, then the end of the turn.
    func resumeTurn(bench: Int) {
        if let showdown {
            let pausedOrders = pausedTurn?.orders
            pausedTurn = nil
            sending = []
            let before = board
            do {
                let next = try showdown.sendIn(bench: bench)
                board = next
                conclude(next, before: before ?? next,
                         orders: pausedOrders ?? "", stepsPlayed: 0)
            } catch {
                log.append("The engine would not send that one in: \(error.localizedDescription)")
                playing = false
            }
            return
        }
        if let link, remotePivot {
            remotePivot = false
            sending = []
            playing = true
            waitingOn = "Waiting for \(link.theirName)..."
            link.chose(pivotBench: bench)
            return
        }
        guard let paused = pausedTurn, let stopped = board, stopped.pendingPivot != nil else { return }
        pausedTurn = nil
        sending = []
        let next = TurnModel.resume(stopped, sendingIn: bench, rolling: true)
        conclude(next, before: paused.before, orders: paused.orders, stepsPlayed: paused.stepsPlayed)
    }

    /// Replacements chosen for the fallen, over the link: they go to the
    /// host, and the arrivals come back with the next snapshot.
    func sendReplacements(_ picks: [(slot: Int, bench: Int)]) {
        guard let link else { return }
        sending = []
        chosenSends = []
        playback.finish()
        playing = true
        waitingOn = "Waiting for \(link.theirName)..."
        link.chose(replacements: picks)
    }

    /// A snapshot from the link: the board as this player may see it, the
    /// turn's steps played from where the field left off, and what is asked.
    func receive(_ snapshot: Wire.Snapshot) {
        let view = Board(wired: snapshot.board)
        let before = board
        // The opening: the leads about to come out. The screen plays it as it
        // plays a local one -- the flash, the leads one by one, each arrival's
        // ability with its line -- and what is asked waits until it has.
        if board == nil, snapshot.turn == 1, snapshot.dealt == 0 {
            board = view
            log = [Self.opener] + view.story
            shownSteps = view.steps.count
            shownStory = view.story.count
            turn = 1
            playing = true
            waitingOn = nil
            introAsking = snapshot.asking
            intro = view.steps
            return
        }
        // The host says how many of these steps it dealt already: nought at
        // the start of a turn, more when a turn stopped partway for a choice
        // or the arrivals for the fallen follow it. The screen plays from there.
        let from = Swift.min(snapshot.dealt, view.steps.count)
        let newTurn = snapshot.dealt == 0 && (board == nil || !view.steps.isEmpty)
        if newTurn {
            log.append(Self.dividerMark + "Turn \(Swift.max(1, snapshot.turn - 1))")
            shownStory = 0
        }
        // Only what has not been said: the story so far this turn less what
        // the log already has of it.
        log.append(contentsOf: view.story.dropFirst(Swift.min(shownStory, view.story.count)))
        shownStory = view.story.count
        turn = snapshot.turn
        board = view
        playing = false
        waitingOn = nil
        remotePivot = false
        pausedTurn = nil
        sending = []
        chosenSends = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        thought = nil; solved = nil
        if !view.steps.isEmpty {
            playback.show(view, steps: view.steps, before: before, revealed: from)
            playback.play(view.steps,
                          hitMine: before.map { Self.hurt(mine: true, view, since: $0) } ?? [],
                          hitTheirs: before.map { Self.hurt(mine: false, view, since: $0) } ?? [],
                          singles: view.activeCount == 1, from: from, leadIn: TurnPlayback.leadInOverLink)
        } else {
            playback.reset()
        }
        shownSteps = view.steps.count
        ask(snapshot.asking)
    }

    /// What the host asks of this player next.
    private func ask(_ asking: Wire.Asking) {
        switch asking {
        case .orders:
            // A fainted Pokemon of mine with somebody to send in is a send-in
            // before it is anything else, whatever was asked.
            if let gaps = board?.gapsOfMine, !gaps.isEmpty {
                sending = gaps
                return
            }
            think()
        case .sendIn(let slots):
            sending = slots
        case .pivot(let slot):
            sending = [slot]
            remotePivot = true
        case .wait:
            playing = true
            waitingOn = "Waiting for \(link?.theirName ?? "the other player")..."
        case .over(let won):
            finished = won ? "You win." : "They win."
        }
    }

    /// The battle screen has played the opening: now what the host asked.
    func introFinished() {
        intro = nil
        playing = false
        if let asking = introAsking { introAsking = nil; ask(asking) }
    }
    private var shownStory = 0

    /// Everything a finished turn does: the review, the log, replacements
    /// for the fallen, and the steps played out on the field -- from the
    /// first, or from where a pivot stopped the turn.
    private func conclude(_ resolved: Board, before current: Board, orders: String, stepsPlayed: Int) {
        var next = resolved
        next.asksBeforePivot = false
        let told = next.story
        // The review needed the turn's own story, which only exists now.
        if let waiting = pendingReview {
            review.append(TurnReview(turn: waiting.turn, yours: waiting.yours,
                                     theirs: waiting.theirs, played: waiting.played,
                                     best: waiting.best, bestLine: waiting.bestLine,
                                     before: waiting.before, minePlay: waiting.minePlay,
                                     theirPlay: waiting.theirPlay, told: told))
            pendingReview = nil
        }
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

        log.append(Self.dividerMark + "Turn \(turn)")
        log.append(orders)
        log.append(contentsOf: told)
        log.append(contentsOf: arrivals)

        let hitMine = Self.hurt(mine: true, next, since: current)
        let hitTheirs = Self.hurt(mine: false, next, since: current)

        board = next
        turn += 1
        playback.show(recorded, steps: told.isEmpty ? [] : recorded.steps, before: current)
        sending = next.gapsOfMine
        chosenSends = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        thought = nil; self.solved = nil
        playback.play(recorded.steps, hitMine: hitMine, hitTheirs: hitTheirs,
                      singles: next.activeCount == 1, from: stepsPlayed)
        if next.isOut(mine: false) { finished = "You win." }
        else if next.isOut(mine: true) { finished = "They win." }
        else { think() }
    }

    /// Whose health is lower than it was: what the field flashes.
    private static func hurt(mine: Bool, _ now: Board, since then: Board) -> Set<Int> {
        let after = mine ? now.mine : now.theirs, before = mine ? then.mine : then.theirs
        return Set(after.indices.filter { $0 < before.count && after[$0].hp < before[$0].hp })
    }

    /// Give both orders from the engine's mix, sampled so a watched game varies.
    func engineOrders(_ board: Board, result: BattleEngine.Result) {
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

    /// The order given for a slot — or the one it has no choice about, when it
    /// is halfway through a two-turn move.
    func pick(for slot: Int) -> Choice? {
        if let board, board.mine.indices.contains(slot), let charging = board.mine[slot].charging {
            return .attack(move: charging, target: board.mine[slot].chargingTarget)
        }
        if let board, board.mine.indices.contains(slot), let encored = board.mine[slot].encored {
            return encored
        }
        return slot == 0 ? leftPick : rightPick
    }

    func set(_ choice: Choice?, slot: Int) {
        if slot == 0 { leftPick = choice } else { rightPick = choice }
    }

    // MARK: - What the field and the deck both ask

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
    func evolving(_ fighter: Fighter, slot: Int,
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
        if let weather = FieldSetters.weather(onArrivalWith: build.ability) { field.weather = weather }
        if let terrain = FieldSetters.terrain(onArrivalWith: build.ability) { field.terrain = terrain }
        return (build, field)
    }

    /// Their Speed as far as anybody could know it: the stat, without the item
    /// nobody has seen yet.
    static func visibleSpeed(_ fighter: Fighter, mine: Bool, field: Field) -> Int {
        guard !mine else { return fighter.build.speed(in: field) }
        var blind = fighter.build
        blind.item = ""
        return blind.speed(in: field)
    }

    /// How a benched Pokémon would do coming in, and why.
    static func sendInReading(_ board: Board, bench: Int) -> (score: Double, why: String) {
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

    // MARK: - Taking one back

    /// Put the last turn back, so a line can be tried a different way.
    /// Whether the game can be taken back.
    ///
    /// The engine only plays forwards, so putting it back a turn means
    /// playing the same battle again from the beginning and stopping early --
    /// the same seed gives the same rolls and the same answers give the same
    /// game. It is the board that has to move with it: restoring a saved one
    /// without moving the engine would leave the picture a turn behind the
    /// game, and every turn after would be resolved against a position nobody
    /// was looking at.
    var canTakeBack: Bool { showdown == nil || showdown?.canRewind == true }

    func undo() {
        guard canTakeBack, let last = history.popLast() else { return }
        review.removeAll { $0.turn >= last.turn }
        restore(engineBoard(at: last.turn) ?? last.board, log: last.log, turn: last.turn)
    }

    /// The engine put back to the start of a turn, and the board it makes of
    /// it. Nil when the app's own model is playing, where the saved board is
    /// the whole of the truth.
    private func engineBoard(at turn: Int) -> Board? {
        guard let showdown else { return nil }
        do { return try showdown.rewind(to: turn) } catch {
            log.append("The engine could not go back to turn \(turn): \(error.localizedDescription)")
            return nil
        }
    }

    /// Take the whole game back to the start of a turn, so it can be played a
    /// different way. This is what the Review panel is for: the engine has
    /// already said which turns were worth the most, and the way to learn one
    /// is to play it again rather than read about it.
    func rewind(to target: Int) {
        guard canTakeBack,
              let index = history.lastIndex(where: { $0.turn == target }) else { return }
        let entry = history[index]
        history.removeSubrange(index...)
        review.removeAll { $0.turn >= target }
        if let engined = engineBoard(at: target) {
            restore(engined, log: entry.log, turn: entry.turn)
            return
        }
        restore(entry.board, log: entry.log, turn: entry.turn)
    }

    /// The game is over, by a result or by choice: everything that was this
    /// game goes, and a search still running for it is dropped when it lands.
    /// The teams and the lobby are the screen's and stay.
    func endGame() {
        // The engine holds one battle at a time, so a game that is over has
        // to let go of it before the next one stands up.
        showdown = nil
        thinkTicket += 1
        playback.reset()
        board = nil; log = []; turn = 1
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        thinking = false; thought = nil; solved = nil; searchNote = ""
        mySide = []; theirSide = []; watching = false
        playing = false; finished = nil; history = []; review = []; grade = nil
        explaining = nil; pendingReview = nil
        sending = []; chosenSends = []; pausedTurn = nil
        remotePivot = false; waitingOn = nil; shownSteps = 0; shownStory = 0
        intro = nil; introAsking = nil
        panel = .engine
    }

    func restore(_ board: Board, log: [String], turn: Int) {
        // Whatever was being played belongs to a turn that no longer happened.
        playback.reset()
        self.board = board
        self.log = log
        self.turn = turn
        finished = nil
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        grade = nil; sending = []
        chosenSends = []; playing = false; pausedTurn = nil
        think()
    }
}
