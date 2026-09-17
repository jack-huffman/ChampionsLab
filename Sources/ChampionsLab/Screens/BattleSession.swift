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
    /// Every board so far, so a turn can be taken back and tried again.
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
        thinking = true
        thinkTicket += 1
        let ticket = thinkTicket
        let engine = BattleEngine(rules: rules, budget: 0.5)
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
        // the average and a player wants the dice.
        var next = TurnModel.resolve(current, mine: mine, theirs: theirPlay, rolling: true)
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
        playback.show(recorded, steps: told.isEmpty ? [] : recorded.steps)
        sending = next.gapsOfMine
        chosenSends = []
        leftPick = nil; rightPick = nil; megaSlot = nil; command = .menu
        thought = nil; self.solved = nil
        playback.play(recorded.steps, hitMine: hitMine, hitTheirs: hitTheirs,
                      singles: next.activeCount == 1)
        if next.isOut(mine: false) { finished = "They have nothing left. You win." }
        else if next.isOut(mine: true) { finished = "You have nothing left. They win." }
        else { think() }
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

    // MARK: - Taking one back

    /// Put the last turn back, so a line can be tried a different way.
    func undo() {
        guard let last = history.popLast() else { return }
        review.removeAll { $0.turn >= last.turn }
        restore(last.board, log: last.log, turn: last.turn)
    }

    /// Take the whole game back to the start of a turn, so it can be played a
    /// different way. This is what the Review panel is for: the engine has
    /// already said which turns were worth the most, and the way to learn one
    /// is to play it again rather than read about it.
    func rewind(to target: Int) {
        guard let index = history.lastIndex(where: { $0.turn == target }) else { return }
        let entry = history[index]
        history.removeSubrange(index...)
        review.removeAll { $0.turn >= target }
        restore(entry.board, log: entry.log, turn: entry.turn)
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
        chosenSends = []; playing = false
        think()
    }
}
