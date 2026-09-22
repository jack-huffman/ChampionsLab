//  ShowdownBattle.swift
//  A game played by Showdown, shown on this app's board.
//
//  The engine is the authority: it owns the turn, the order, the rolls and
//  every interaction. What it hands back is the client protocol -- the same
//  lines Showdown's own client reads -- and this turns those into the Board
//  the battle screen already knows how to draw.
//
//  Keeping Board as the projection rather than replacing it is deliberate.
//  Every screen, the playback, the choreography and the callouts are written
//  against it, and none of that has anything to learn from a new engine; what
//  had to change is who decides what happens, not who draws it.

import Foundation

final class ShowdownBattle {
    private let engine: ShowdownEngine
    /// Protocol tags the reader does not know yet. Collected rather than
    /// ignored: a tag nobody handled is a thing the board is quietly wrong
    /// about, and the tests read this.
    private(set) var unread: Set<String> = []
    private(set) var board: Board
    /// What a move is and what a form is called: the two things the reader
    /// looks up. The dataset rather than the Store, because the lab and the
    /// duel run off any actor and a plain table travels where a Store cannot.
    private var data: Dataset?

    /// Which side of the protocol is ours. The sim always calls the first
    /// player p1; the app always calls itself "mine".
    private let mySide = "p1"

    // MARK: - Starting

    /// Everything needed to stand this exact battle up again.
    ///
    /// The engine plays forwards and has no way to be put back a turn, so a
    /// take-back is the same battle played again from the beginning with the
    /// same choices: the same seed gives the same rolls, and the same answers
    /// in the same order give the same game. It costs about two milliseconds
    /// plus four a turn, which is nothing next to being unable to take a move
    /// back at all.
    private struct Origin {
        let format: String
        let mine: (name: String, team: String)
        let theirs: (name: String, team: String)
        let seed: [Int]
        /// The team order each side gave at preview. Not part of the script,
        /// because it is answered before the script starts -- and leaving it
        /// out meant a replay sat at team preview refusing every move it was
        /// then handed.
        let ordering: (mine: String, theirs: String)
        let board: Board
    }
    private var origin: Origin?
    /// Every answer given to the engine, in the order it was given.
    private var script: [(side: String, choice: String)] = []
    /// Where each turn began in that script.
    private var turnMarks: [Int: Int] = [:]
    /// The turn the engine last announced.
    private(set) var turn = 1

    init(board: Board, data: Dataset? = nil, engine: ShowdownEngine = .shared) {
        self.board = board
        self.data = data
        self.engine = engine
        // `note` is what writes the story and the steps, and it does nothing
        // unless the board is narrating.
        self.board.narrating = true
    }

    /// Stand a battle up from two teams, bringing the four each side chose.
    static func start(mine: Team, theirs: Team, myFour: [Int], theirFour: [Int],
                      rules: Rulebook, data: Dataset, seed: [Int]? = nil,
                      onto prebuilt: Board? = nil,
                      engine: ShowdownEngine = .shared) throws -> ShowdownBattle {
        let myPaste = ShowdownTeam.paste(for: mine, bringing: myFour, rules: rules, data: data)
        let theirPaste = ShowdownTeam.paste(for: theirs, bringing: theirFour, rules: rules, data: data)
        // A seed of its own when none was given, so the game is repeatable
        // even when nobody asked for a particular one -- which is what makes
        // a take-back possible at all.
        let rolled = seed ?? (0..<4).map { _ in Int.random(in: 0..<65536) }
        let packed = (mine: (name: mine.name, team: try engine.pack(paste: myPaste)),
                      theirs: (name: theirs.name, team: try engine.pack(paste: theirPaste)))
        try engine.start(mine: packed.mine, theirs: packed.theirs, seed: rolled)
        // Both sides bring everything they packed, in the order they packed it.
        let ordering = (mine: "team " + (1...myFour.count).map(String.init).joined(),
                        theirs: "team " + (1...theirFour.count).map(String.init).joined())
        try engine.choose("p1", ordering.mine)
        try engine.choose("p2", ordering.theirs)
        // The board is built from the same four, in the same order, so the
        // sim's positions and the board's indices mean the same thing.
        // The board the opening is read onto. A game the screen is about to
        // show hands its own in, with the leads not yet out, so that the
        // switches and the abilities that open the battle come off the
        // protocol like everything else does.
        let blank = Board(mine: Self.reduced(mine, to: myFour),
                          theirs: Self.reduced(theirs, to: theirFour),
                          rules: rules, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        let battle = ShowdownBattle(board: prebuilt ?? blank, data: data, engine: engine)
        // What a replay starts from: the board before a word of the protocol
        // has been read onto it.
        let beginning = battle.board
        battle.read(try engine.since())
        battle.origin = Origin(format: ShowdownEngine.regMC, mine: packed.mine,
                               theirs: packed.theirs, seed: rolled,
                               ordering: ordering, board: beginning)
        return battle
    }

    /// The team as only the four that were brought, in the order chosen.
    /// The same game, started from a board that has already been built.
    ///
    /// `Board.opening` chooses the opponent's four itself -- it searches for
    /// what they would bring -- so the four are not known until it has run.
    /// Reading them back off the board is what keeps the sim and the board
    /// holding the same eight Pokemon rather than two guesses at them.
    static func start(from board: Board, mine: Team, theirs: Team,
                      rules: Rulebook, data: Dataset, seed: [Int]? = nil,
                      engine: ShowdownEngine = .shared) throws -> ShowdownBattle {
        func chosen(_ fighters: [Fighter], from team: Team) -> [Int] {
            var taken = Set<Int>(), out: [Int] = []
            for fighter in fighters.prefix(board.activeCount * 2) {
                let wanted = fighter.build.form.dex
                if let index = team.slots.indices.first(where: { index in
                    !taken.contains(index)
                        && team.slots[index].form(in: rules)?.dex == wanted
                }) {
                    taken.insert(index); out.append(index)
                }
            }
            return out
        }
        let myFour = chosen(board.mine, from: mine)
        let theirFour = chosen(board.theirs, from: theirs)
        // Read onto the board rather than over it: the leads walking on and
        // the abilities that fire as they land are the engine's to decide,
        // the same as every turn after. The opening used to be the app's own
        // and only the turns were Showdown's, which left one Intimidate in
        // the game decided by the old model.
        var opening = board
        opening.narrating = true
        return try start(mine: mine, theirs: theirs, myFour: myFour, theirFour: theirFour,
                         rules: rules, data: data, seed: seed, onto: opening, engine: engine)
    }

    // MARK: - The app's way in

    @MainActor
    static func start(mine: Team, theirs: Team, myFour: [Int], theirFour: [Int],
                      store: Store, seed: [Int]? = nil) throws -> ShowdownBattle {
        try start(mine: mine, theirs: theirs, myFour: myFour, theirFour: theirFour,
                  rules: store.rulebook, data: store.data, seed: seed)
    }

    @MainActor
    static func start(from board: Board, mine: Team, theirs: Team,
                      store: Store, seed: [Int]? = nil) throws -> ShowdownBattle {
        try start(from: board, mine: mine, theirs: theirs,
                  rules: store.rulebook, data: store.data, seed: seed)
    }

    private static func reduced(_ team: Team, to bringing: [Int]) -> Team {
        var out = team
        out.slots = bringing.compactMap { team.slots[safe: $0] }
        return out
    }

    // MARK: - A turn

    /// Both sides' choices, handed to the engine, and the board as it stands
    /// after it has resolved them.
    @discardableResult
    func play(mine: Play, theirs: Play) throws -> Board {
        try play(mine: mine, theirs: theirs, oursWhenForced: "default")
    }

    @discardableResult
    func play(mine: Play, theirs: Play, oursWhenForced ours: String?) throws -> Board {
        try play(mine: request(mine, side: true), theirs: request(theirs, side: false),
                 oursWhenForced: ours)
    }

    /// Both sides' choices in the sim's own words. "default" is the sim
    /// picking the first legal thing, which is what a self-playing game wants.
    @discardableResult
    func play(mine: String, theirs: String) throws -> Board {
        try play(mine: mine, theirs: theirs, oursWhenForced: "default")
    }

    /// A turn in a game between two people: neither side's replacement is
    /// answered for it.
    @discardableResult
    func play(bothChoosing mine: String, theirs: String) throws -> Board {
        try play(mine: mine, theirs: theirs, oursWhenForced: nil, theirsWhenForced: nil)
    }

    @discardableResult
    func play(bothChoosing mine: Play, theirs: Play) throws -> Board {
        try play(bothChoosing: request(mine, side: true), theirs: request(theirs, side: false))
    }

    // MARK: - What might happen

    /// One way a turn could go, and the odds of its going that way.
    struct Outcome {
        let chance: Double
        let board: Board
    }

    /// Every way a turn could go, weighed.
    ///
    /// Not sampling. Showdown puts every coin flip through
    /// `battle.randomChance`, and `battle.prng` is a property the sim itself
    /// documents as an override -- so a run can be made to answer yes to the
    /// third flip and no to the fourth, and what comes out is exactly the
    /// turn where the Protect held and the secondary missed. The odds are the
    /// ones it was asked for.
    ///
    /// `branching` is how many of the turn's coin flips to split on, chosen
    /// nearest-to-even first because those are the ones worth pricing. Two of
    /// them is four turns to resolve, three is eight.
    func outcomes(mine: Play, theirs: Play, branching: Int = 1) throws -> [Outcome] {
        let rows = try engine.outcomes(request(mine, side: true),
                                       request(theirs, side: false), branching: branching)
        // Asking what might happen must leave no mark on what has. The
        // engine puts its own position back; these are the board's records of
        // the game so far, which reading a hypothetical turn would otherwise
        // advance -- the turn counter most visibly.
        let before = board
        let wasTurn = turn, wasMarks = turnMarks, wasUnread = unread
        defer { board = before; turn = wasTurn; turnMarks = wasMarks; unread = wasUnread }
        var out: [Outcome] = []
        for row in rows {
            guard let chance = row["chance"] as? Double else { continue }
            // Each branch is read onto a copy of where the turn started, so
            // the outcomes are boards that can be compared with each other.
            board = before
            board.steps = []
            board.story = []
            read(row["log"] as? [String] ?? [])
            out.append(Outcome(chance: chance, board: board))
        }
        return out
    }

    /// Which of a side's active slots are empty and waiting to be filled.
    func gaps(mine: Bool) -> [Int] {
        let team = mine ? board.mine : board.theirs
        return (0..<Swift.min(board.activeCount, team.count)).filter { team[$0].fainted }
    }

    /// A turn, with what our side does if it is made to send somebody in.
    /// Nil stops the turn there and sets `awaitingSendIn`, which is how a
    /// played game asks the player.
    @discardableResult
    func play(mine: String, theirs: String, oursWhenForced ours: String?,
              theirsWhenForced: String? = "default") throws -> Board {
        board.steps = []
        board.story = []
        try answer("p1", mine)
        try answer("p2", theirs)
        read(try engine.since())
        // A faint asks the side that lost somebody who comes in next, and the
        // turn is not over until it has answered. The other side is asked
        // nothing at all, which is why both are only ever answered when they
        // have actually been asked -- choosing for a side with no question is
        // refused, and looks exactly like an illegal move.
        try settle(ours: ours, theirs: theirsWhenForced)
        return board
    }

    /// Which sides are being made to send somebody in.
    ///
    /// Both, because a game between two people has two players: the far side
    /// is the opponent's choice there and the engine's in a game against the
    /// app. Only which of them is answered automatically differs.
    private(set) var awaiting: (mine: Bool, theirs: Bool) = (false, false)
    var awaitingSendIn: Bool { awaiting.mine || awaiting.theirs }

    /// Send somebody in for the one that fell, by their place on the board.
    @discardableResult
    func sendIn(bench: Int) throws -> Board {
        try sendIn(mine: bench, theirs: nil, autoTheirs: true)
    }

    /// Both sides' replacements, for a game where both are chosen. Nil for a
    /// side means it is not being asked, or is not ready to say.
    @discardableResult
    func sendIn(mine: Int?, theirs: Int?, autoTheirs: Bool = false) throws -> Board {
        try settle(ours: mine.map { "switch \($0 + 1)" },
                   theirs: autoTheirs ? "default" : theirs.map { "switch \($0 + 1)" })
        return board
    }

    /// Answer whatever forced questions are outstanding.
    ///
    /// Only forced ones. A side that fainted is asked who comes in next and
    /// the turn is not finished until it says; a side asked for an ordinary
    /// move is being asked about the *next* turn, and answering that here
    /// would play the game by itself -- which it did, four turns deep, inside
    /// what was meant to be one.
    ///
    /// Theirs is answered for them and ours is handed back, which is the only
    /// asymmetry: their replacement is a decision the opponent makes and ours
    /// is one the player does.
    private func settle(ours: String?, theirs: String?) throws {
        var rounds = 0
        while !engine.ended, rounds < 8 {
            let forced = try (self.forced("p1"), self.forced("p2"))
            guard forced.0 || forced.1 else { break }
            // Neither is answered until both can be: the engine wants the
            // round together, and answering one and stopping would leave the
            // turn half taken.
            if forced.0 && ours == nil || forced.1 && theirs == nil {
                awaiting = (forced.0, forced.1)
                return
            }
            if forced.0, let ours { try answer("p1", ours) }
            if forced.1, let theirs { try answer("p2", theirs) }
            read(try engine.since())
            rounds += 1
        }
        awaiting = (false, false)
    }

    /// Whether a side is being made to send somebody in rather than asked
    /// what it would like to do.
    private func forced(_ side: String) throws -> Bool {
        guard let request = try engine.request(side) else { return false }
        return request.contains("\"forceSwitch\"")
    }

    /// One side's answer, and only when it was asked something.
    ///
    /// A refused choice is otherwise silence: the engine declines it, no turn
    /// resolves, and the board simply does not move. Saying so is the
    /// difference between a bug and a mystery.
    /// Choices the engine would not take, and what was played instead.
    ///
    /// The app's idea of a turn and the sim's do not line up everywhere --
    /// the board has a `pass` for a Pokemon that simply does nothing, and the
    /// sim has no such move, because a Pokemon standing there always acts.
    /// Where a choice cannot be honoured the sim picks the first legal thing
    /// and it is written down here, because a turn that quietly became a
    /// different turn is worse than one that says so.
    private(set) var substituted: [String] = []

    private func answer(_ side: String, _ choice: String) throws {
        guard try engine.request(side) != nil else { return }
        var played = choice
        if try !engine.choose(side, choice) {
            // The engine's own reading of what is legal, rather than another
            // guess at it from here.
            guard try engine.choose(side, "default") else {
                throw ShowdownEngine.Trouble.refused("\(side) would not play \(choice)")
            }
            played = "default"
            substituted.append("\(side): \(choice)")
        }
        if !replaying { script.append((side, played)) }
    }

    /// True while the battle is being played again from the start, so the
    /// script records itself once rather than once per replay.
    private var replaying = false

    // MARK: - Taking it back

    /// Whether the game can be put back to the start of a turn.
    var canRewind: Bool { origin != nil }

    /// The same battle, replayed from the beginning up to the start of a
    /// turn, which is the only way to move an engine that only plays forwards.
    @discardableResult
    func rewind(to target: Int) throws -> Board {
        guard let origin, let mark = turnMarks[target] else {
            throw ShowdownEngine.Trouble.refused("turn \(target) is not one this game passed through")
        }
        let keeping = Array(script.prefix(mark))
        try engine.start(format: origin.format, mine: origin.mine, theirs: origin.theirs,
                         seed: origin.seed)
        board = origin.board
        board.narrating = true
        unread = []
        turn = 1
        replaying = true
        defer { replaying = false }
        _ = try engine.since()
        try engine.choose("p1", origin.ordering.mine)
        try engine.choose("p2", origin.ordering.theirs)
        _ = try engine.since()
        for step in keeping {
            guard try engine.request(step.side) != nil else { continue }
            _ = try engine.choose(step.side, step.choice)
            read(try engine.since())
        }
        script = keeping
        turnMarks = turnMarks.filter { $0.key <= target }
        board.steps = []
        board.story = []
        awaiting = (false, false)
        return board
    }

    /// One side's turn, in the sim's own words.
    private func request(_ play: Play, side mine: Bool) -> String {
        let team = mine ? board.mine : board.theirs
        let slots = [play.left, play.right]
        var parts: [String] = []
        for (index, choice) in slots.enumerated() {
            guard index < board.activeCount else { break }
            switch choice {
            case .pass:
                // The board says `pass` for a slot with nobody in it, and the
                // sim agrees -- but the app also uses it to mean a Pokemon
                // that simply does nothing, and there is no such move. A
                // Pokemon standing there has to act, so it takes the first
                // thing it can: the sim refuses the whole turn otherwise, and
                // a refused turn is a turn that silently did not happen.
                let standing = index < team.count && !team[index].fainted
                    && index < board.activeCount
                // `default` is a whole request's worth of shortcut, not one
                // slot's, so the slot names a move instead.
                parts.append(standing ? "move 1" : "pass")
            case .swap(let to):
                // The sim counts a party position, one-based, over what is
                // left standing; the board counts an index into its own array.
                parts.append("switch \(to + 1)")
            case .protectSelf(let move), .attack(let move, _):
                let number = move + 1
                var text = "move \(number)"
                if case .attack(_, let target) = choice,
                   index < team.count, move < team[index].moves.count,
                   !team[index].moves[move].isSpread,
                   !team[index].moves[move].aimsAtUser,
                   !team[index].moves[move].aimsAtAlly {
                    // Opponents are +1 and +2 from whoever is choosing.
                    text += " \(target + 1)"
                }
                // Mega Evolution is part of the order, not a thing that
                // happens to you: the sim is told on the move that triggers
                // it. Left off, the stone never goes off and the Pokemon
                // plays the whole game as its base form.
                if play.megaSlot == index { text += " mega" }
                parts.append(text)
            }
        }
        return parts.isEmpty ? "default" : parts.joined(separator: ", ")
    }

    // MARK: - Reading the protocol

    /// Where a protocol position sits on this board.
    private func seat(_ ident: String) -> (mine: Bool, slot: Int)? {
        // "p1a: Incineroar" -- the side, the position, then the name.
        guard ident.count >= 3 else { return nil }
        let side = ident.hasPrefix(mySide)
        let letter = Array(ident)[2]
        guard let slot = "abc".firstIndex(of: letter).map({ "abc".distance(from: "abc".startIndex, to: $0) })
        else { return nil }
        return (side, slot)
    }

    private func name(of ident: String) -> String {
        ident.contains(": ") ? String(ident.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) : ident
    }

    private func withFighter(_ ident: String, _ change: (inout Fighter) -> Void) {
        guard let at = seat(ident) else { return }
        if at.mine, board.mine.indices.contains(at.slot) { change(&board.mine[at.slot]) }
        else if !at.mine, board.theirs.indices.contains(at.slot) { change(&board.theirs[at.slot]) }
    }

    /// `186/202` and `0 fnt` and `92/100 brn`.
    private func health(_ text: String) -> (hp: Int?, status: Ailment?) {
        let bits = text.split(separator: " ")
        guard let first = bits.first else { return (nil, nil) }
        var hp: Int?
        if first == "0" || first.hasPrefix("0 ") { hp = 0 }
        else if let slash = first.firstIndex(of: "/") { hp = Int(first[first.startIndex..<slash]) }
        var status: Ailment?
        if bits.count > 1 {
            switch bits[1] {
            case "brn": status = .burn
            case "psn": status = .poison
            case "tox": status = .badPoison
            case "par": status = .paralysis
            case "slp": status = .sleep
            case "frz": status = .freeze
            case "fnt": hp = 0
            default: break
            }
        }
        return (hp, status)
    }

    func read(_ lines: [String]) {
        // `|split|<side>` says the next two lines are the same event told
        // twice: the exact numbers for the side named, then the same thing in
        // percentages for everyone else. Counted rather than guessed at -- it
        // used to skip the next line that *looked* like a repeat, which threw
        // away the second of two residuals when a burn and a Leftovers landed
        // one after the other with no split between them.
        var afterSplit = 0
        for line in lines {
            guard line.hasPrefix("|") else { continue }
            if line.hasPrefix("|split|") { afterSplit = 2; continue }
            if afterSplit == 2 {
                afterSplit = 1          // the exact one, for the side that owns it
            } else if afterSplit == 1 {
                afterSplit = 0          // the same thing in percentages
                continue
            }
            let parts = line.dropFirst().components(separatedBy: "|")
            guard let tag = parts.first else { continue }
            // The empty line: Showdown writes one to mark the end of the
            // acting and the start of the residuals.
            if tag.isEmpty { board.closeStep(); continue }
            let arg = { (n: Int) -> String in n < parts.count ? parts[n] : "" }
            switch tag {
            case "move":
                // The step is what the screen animates, and a step with no
                // action behind it is a line of text with nothing to play:
                // the turn arrives already over. Each move opens its own, so
                // the damage, the crit and the effectiveness that follow are
                // all part of the same beat.
                if let at = seat(arg(1)) {
                    let move = data?.moves.values.first { $0.name == arg(2) }
                    board.beginStep(Board.Action(byMine: at.mine, slot: at.slot,
                                                 move: arg(2),
                                                 category: move?.category ?? "Physical",
                                                 type: move?.type ?? "Normal"))
                    // Used in the open, so the other side has seen it. A game
                    // between two people sends only what has been shown, and
                    // a move nobody recorded as shown is a move the opponent's
                    // screen never learns about.
                    if let id = move?.id {
                        withFighter(arg(1)) { $0.revealedMoves.insert(id) }
                    }
                }
                board.note("\(name(of: arg(1))) used \(arg(2)).")
            case "-damage", "-heal", "-sethp":
                let reading = health(arg(2))
                withFighter(arg(1)) { f in
                    if let hp = reading.hp { f.hp = max(0, min(f.maxHP, hp)) }
                    if let status = reading.status { f.status = status }
                }
                // Health that moved for a reason of its own rather than
                // because somebody hit it. Said out loud, because a step with
                // nothing in it is no step at all: the end of a turn was
                // changing everyone's health without a word and without a
                // beat to draw it on, so the bars simply jumped.
                if let why = parts.first(where: { $0.hasPrefix("[from]") }) {
                    board.note(Self.because(String(why.dropFirst("[from]".count))
                                                .trimmingCharacters(in: .whitespaces),
                                            to: name(of: arg(1)), healing: tag == "-heal"))
                }
            case "faint":
                withFighter(arg(1)) { $0.hp = 0 }
                board.note("\(name(of: arg(1))) fainted.")
            case "-status":
                withFighter(arg(1)) { $0.status = Self.ailment(arg(2)) ?? $0.status }
                board.note("\(name(of: arg(1))) was \(arg(2)).")
            case "-curestatus":
                withFighter(arg(1)) { $0.status = .none; $0.asleepFor = 0 }
            case "-boost", "-unboost":
                let by = (Int(arg(3)) ?? 0) * (tag == "-boost" ? 1 : -1)
                if let at = seat(arg(1)), let stage = Self.stage(arg(2)) {
                    board.recordStat(mine: at.mine, slot: at.slot, stat: stage.rawValue,
                                     delta: by, cause: nil)
                    withFighter(arg(1)) { f in
                        let now = f.build.boosts[stage.rawValue] + by
                        f.build.boosts[stage.rawValue] = max(-6, min(6, now))
                    }
                }
            case "-setboost":
                if let at = seat(arg(1)), let stage = Self.stage(arg(2)) {
                    withFighter(arg(1)) { $0.build.boosts[stage.rawValue] = Int(arg(3)) ?? 0 }
                    _ = at
                }
            case "-clearboost", "-clearallboost":
                withFighter(arg(1)) { $0.build.boosts = Array(repeating: 0, count: Stage.width) }
            case "switch", "drag", "replace":
                // A step of its own, marked as an arrival: it is what both
                // screens play the opening from, one Pokemon at a time.
                if let at = seat(arg(1)) {
                    board.beginStep(Board.Action(byMine: at.mine, slot: at.slot,
                                                 move: "", category: "Switch", type: ""))
                }
                arrive(arg(1), details: arg(2), health: arg(3))
            case "-ability":
                board.note("\(name(of: arg(1)))'s \(arg(2)).")
            case "-item":
                board.note("\(name(of: arg(1)))'s \(arg(2)).")
            case "-enditem":
                withFighter(arg(1)) { $0.build.item = "" }
                board.note("\(name(of: arg(1)))'s \(arg(2)) was used up.")
            case "-mega":
                // The stone going off. The form itself arrives on the
                // detailschange that follows; this is the line that says so.
                board.beginStep(seat(arg(1)).map {
                    Board.Action(byMine: $0.mine, slot: $0.slot, move: "", category: "Mega", type: "")
                })
                board.note("\(name(of: arg(1))) Mega Evolved!")
            case "detailschange", "-formechange":
                // It is something else now: a Mega, a Primal, an Ogerpon that
                // changed masks. Without this the board plays the whole game
                // as whatever walked on, and the sprite never changes.
                becomes(arg(1), details: arg(2))
            case "-sidestart", "-sideend":
                side(arg(1), condition: arg(2), starting: tag == "-sidestart")
            case "-start", "-end":
                volatile(arg(1), effect: arg(2), starting: tag == "-start")
            case "-singleturn":
                // Protect and its family last the turn. The board has a flag
                // for it and the scene draws a shield from it; without this
                // nothing on screen ever looks protected.
                let what = bare(arg(2))
                if what == "Protect" || what == "Endure" || what.hasSuffix("Shield")
                    || what.hasSuffix("Bunker") || what == "Obstruct" || what == "Burning Bulwark"
                    || what == "Silk Trap" || what == "Detect" {
                    withFighter(arg(1)) { $0.isProtected = true; $0.protectStreak += 1 }
                } else if what == "Wide Guard" || what == "Quick Guard" {
                    guarding(arg(1), wide: what == "Wide Guard")
                }
                board.note("\(name(of: arg(1))) used \(what).")
            case "-singlemove":
                if bare(arg(2)) == "Destiny Bond" { withFighter(arg(1)) { $0.destinyBound = true } }
            case "-setboost":
                if let stage = Self.stage(arg(2)) {
                    withFighter(arg(1)) { $0.build.boosts[stage.rawValue] = Int(arg(3)) ?? 0 }
                }
            case "-clearnegativeboost":
                withFighter(arg(1)) { f in
                    for index in f.build.boosts.indices where f.build.boosts[index] < 0 {
                        f.build.boosts[index] = 0
                    }
                }
            case "-clearpositiveboost":
                withFighter(arg(1)) { f in
                    for index in f.build.boosts.indices where f.build.boosts[index] > 0 {
                        f.build.boosts[index] = 0
                    }
                }
            case "-invertboost":
                withFighter(arg(1)) { f in
                    f.build.boosts = f.build.boosts.map { -$0 }
                }
            case "-copyboost", "-swapboost":
                // Between two Pokemon: one takes the other's stages, or they
                // trade them.
                if let to = seat(arg(1)), let from = seat(arg(2)) {
                    let source = (from.mine ? board.mine : board.theirs)[safe: from.slot]?.build.boosts
                    let target = (to.mine ? board.mine : board.theirs)[safe: to.slot]?.build.boosts
                    if let source { withFighter(arg(1)) { $0.build.boosts = source } }
                    if tag == "-swapboost", let target { withFighter(arg(2)) { $0.build.boosts = target } }
                }
            case "swap":
                // Ally Switch: the two of them change places, and the board
                // keeps its actives by position.
                if let at = seat(arg(1)), let with = Int(arg(2)), with != at.slot {
                    if at.mine, board.mine.indices.contains(with) { board.mine.swapAt(at.slot, with) }
                    else if !at.mine, board.theirs.indices.contains(with) { board.theirs.swapAt(at.slot, with) }
                }
            case "-terastallize":
                if let type = PokeType(loose: arg(2)) {
                    withFighter(arg(1)) { $0.build.typeOverride = [type] }
                }
                board.note("\(name(of: arg(1))) Terastallized into \(arg(2)).")
            case "-transform":
                board.note("\(name(of: arg(1))) transformed into \(name(of: arg(2)))!")
            case "-endability":
                withFighter(arg(1)) { $0.build.ability = "" }
            case "-activate":
                // The client's catch-all for "this did something" -- a Focus
                // Sash holding, a Sturdy, an Ability Shield. Said rather than
                // modelled: whatever it did shows up as its own line.
                if !arg(2).isEmpty { board.note("\(name(of: arg(1)))'s \(bare(arg(2)))." ) }
            case "-mustrecharge":
                board.note("\(name(of: arg(1))) must recharge.")
            case "-crit":
                board.note("A critical hit!")
            case "-supereffective":
                board.note("It's super effective!")
            case "-resisted":
                board.note("It's not very effective...")
            case "-immune":
                board.note("\(name(of: arg(1))) is immune.")
            case "-miss":
                board.note("\(name(of: arg(2).isEmpty ? arg(1) : arg(2))) avoided the attack.")
            case "-fail":
                board.note("But it failed.")
            case "cant":
                board.note("\(name(of: arg(1))) could not move.")
            case "-weather":
                board.field.weather = FieldSetters.weather(named: arg(1)) ?? .none
            case "-fieldstart":
                board.field.terrain = FieldSetters.terrain(named: arg(1)) ?? board.field.terrain
            case "-fieldend":
                if FieldSetters.terrain(named: arg(1)) != nil { board.field.terrain = .none }
            case "turn":
                // Whatever was being gathered belongs to the turn that just
                // finished, not the one starting.
                board.closeStep()
                ranDown()
                turn = Int(arg(1)) ?? turn
                if turnMarks[turn] == nil { turnMarks[turn] = script.count }
            case "-prepare":
                // A two-turn move winding up. The field draws the glow from
                // this; without it a Sky Attack looks like a turn where
                // nothing happened.
                withFighter(arg(1)) { $0.charging = 0 }
            case "win", "tie":
                board.note(tag == "win" ? "\(arg(1)) won." : "It is a tie.")
            default:
                if Self.chrome.contains(tag) { break }
                unread.insert(tag)
            }
        }
        board.closeStep()
    }

    /// Tags that say nothing about the board.
    ///
    /// Named rather than skipped, and checked against the simulator's own
    /// source by a test: every tag it can emit has to be read here or listed
    /// here. Mega Evolution was dropped for a fortnight because a hand-written
    /// list of things to step over is a list nobody ever reads again.
    ///
    /// The groups, and why each is chrome: the room and the match around the
    /// battle; the client's own presentation, which this app draws its own
    /// way; the two halves of a split message, handled before the switch; and
    /// a handful of effects whose consequence arrives as its own line -- a
    /// `-block` is followed by the move failing, a `-hitcount` by the damage
    /// it counted.
    nonisolated static let chrome: Set<String> = [
        // The room, the match, the players.
        "player", "teamsize", "gametype", "gen", "tier", "rule", "rated", "start",
        "clearpoke", "poke", "teampreview", "showteam", "upkeep", "t:",
        "request", "sideupdate", "update", "done", "inactive", "inactiveoff", "expire",
        "askreg", "1ET",
        // Chat and the client's own chrome.
        "chat", "c", "j", "l", "n", "raw", "html", "uhtml", "uhtmlchange", "bigerror",
        "error", "debug", "seed", "message", "-message", "-hint", "-hidelinebreak",
        // Presentation this app does its own way.
        "-anim", "-center", "-combine", "-waiting", "-notarget", "-nothing",
        "-fieldactivate", "-candynamax", "-zpower", "-zbroken", "-swapsideconditions",
        // Split messages: read before the switch, never reaching it.
        "split",
        // Said by the line that follows them.
        "-block", "-ohko", "-hitcount", "-primal", "-burst",
    ]


    /// What a line of health moving says for itself.
    ///
    /// The client gives the cause and leaves the sentence to whoever is
    /// drawing it. Written the way the model wrote them, so the same callouts
    /// light up: `note` reads an item or an ability out of its own text, and
    /// a Leftovers that says nothing is a Leftovers nobody sees work.
    static func because(_ source: String, to who: String, healing: Bool) -> String {
        switch source {
        case "psn": return "\(who) is hurt by poison."
        case "tox": return "\(who) is hurt badly by poison."
        case "brn": return "\(who) is hurt by its burn."
        case "Leech Seed": return "\(who)'s health was sapped by Leech Seed."
        case "Recoil": return "\(who) is hit by the recoil."
        case "drain": return "\(who) had its energy drained."
        default: break
        }
        // The weather and the terrain are named by the file that owns their
        // names, rather than spelled out again here: one place knows what a
        // weather is called, and a second copy is the drift that rule exists
        // to stop.
        if FieldSetters.weather(named: source) != nil {
            return healing ? "\(who) is healed by the \(source.lowercased())."
                           : "The \(source.lowercased()) buffets \(who)."
        }
        if FieldSetters.terrain(named: source) != nil {
            return healing ? "\(source) tops \(who) up." : "\(source) hurts \(who)."
        }
        // "item: Leftovers", "ability: Poison Heal", "move: Aqua Ring".
        if source.hasPrefix("item: ") || source.hasPrefix("ability: ") {
            let named = source.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            return healing ? "\(who)'s \(named) restored a little health."
                           : "\(who) is hurt by its \(named)."
        }
        let named = source.contains(":")
            ? source.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            : source
        return healing ? "\(who) was healed by \(named)." : "\(who) was hurt by \(named)."
    }

    /// The clocks, wound down a turn.
    ///
    /// The engine owns how long a screen or a Taunt lasts and says only when
    /// one starts and when it ends, so nothing here would ever move: a
    /// Reflect put up on turn one still read "5" on turn six, right up to the
    /// moment it vanished. Counting them down is what the game does and lands
    /// on zero the same turn the engine says it is over -- and the engine
    /// stays the authority, because it is `-sideend` and `-end` that clear
    /// them, not this reaching zero.
    ///
    /// Perish is not counted here: the client sends the number itself, once a
    /// turn, and counting it as well would halve the song.
    private func ranDown() {
        func wind(_ screens: inout Screens) {
            screens.reflect = Swift.max(0, screens.reflect - 1)
            screens.lightScreen = Swift.max(0, screens.lightScreen - 1)
            screens.auroraVeil = Swift.max(0, screens.auroraVeil - 1)
            screens.safeguard = Swift.max(0, screens.safeguard - 1)
            // These last the turn they were used on and no longer.
            screens.wideGuard = false
            screens.quickGuard = false
        }
        wind(&board.myScreens)
        wind(&board.theirScreens)
        board.myTailwind = Swift.max(0, board.myTailwind - 1)
        board.theirTailwind = Swift.max(0, board.theirTailwind - 1)
        board.trickRoom = Swift.max(0, board.trickRoom - 1)
        for index in board.mine.indices {
            board.mine[index].isProtected = false
            board.mine[index].tauntedFor = Swift.max(0, board.mine[index].tauntedFor - 1)
            board.mine[index].encoredFor = Swift.max(0, board.mine[index].encoredFor - 1)
            board.mine[index].disabledFor = Swift.max(0, board.mine[index].disabledFor - 1)
        }
        for index in board.theirs.indices {
            board.theirs[index].isProtected = false
            board.theirs[index].tauntedFor = Swift.max(0, board.theirs[index].tauntedFor - 1)
            board.theirs[index].encoredFor = Swift.max(0, board.theirs[index].encoredFor - 1)
            board.theirs[index].disabledFor = Swift.max(0, board.theirs[index].disabledFor - 1)
        }
    }

    /// `move: Reflect`, `ability: Intimidate`, `item: Leftovers` -- the
    /// client prefixes an effect with where it came from.
    private func bare(_ effect: String) -> String {
        guard let colon = effect.firstIndex(of: ":") else { return effect }
        return String(effect[effect.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// A screen, a Tailwind, a layer of hazards: everything that belongs to a
    /// side of the field rather than to a Pokemon standing on it.
    private func side(_ ident: String, condition: String, starting: Bool) {
        let mine = ident.hasPrefix(mySide)
        var screens = mine ? board.myScreens : board.theirScreens
        var tailwind = mine ? board.myTailwind : board.theirTailwind
        switch bare(condition) {
        case "Reflect": screens.reflect = starting ? 5 : 0
        case "Light Screen": screens.lightScreen = starting ? 5 : 0
        case "Aurora Veil": screens.auroraVeil = starting ? 5 : 0
        case "Safeguard": screens.safeguard = starting ? 5 : 0
        case "Tailwind": tailwind = starting ? 4 : 0
        case "Spikes": screens.spikes = starting ? Swift.min(3, screens.spikes + 1) : 0
        case "Toxic Spikes": screens.toxicSpikes = starting ? Swift.min(2, screens.toxicSpikes + 1) : 0
        case "Stealth Rock": screens.stealthRock = starting
        case "Sticky Web": screens.stickyWeb = starting
        case "Wide Guard": screens.wideGuard = starting
        case "Quick Guard": screens.quickGuard = starting
        default: break
        }
        if mine { board.myScreens = screens; board.myTailwind = tailwind }
        else { board.theirScreens = screens; board.theirTailwind = tailwind }
        board.note("\(bare(condition)) \(starting ? "went up" : "ended").")
    }

    private func guarding(_ ident: String, wide: Bool) {
        let mine = ident.hasPrefix(mySide)
        if mine { if wide { board.myScreens.wideGuard = true } else { board.myScreens.quickGuard = true } }
        else { if wide { board.theirScreens.wideGuard = true } else { board.theirScreens.quickGuard = true } }
    }

    /// What is on one Pokemon: a Substitute, a Leech Seed, a Taunt, the
    /// confusion it is under. The board carries each of these as its own
    /// field, and the scene draws several of them.
    private func volatile(_ ident: String, effect: String, starting: Bool) {
        let what = bare(effect)
        withFighter(ident) { fighter in
            switch what {
            case "Substitute": fighter.substitute = starting ? Swift.max(1, fighter.maxHP / 4) : 0
            case "confusion": fighter.confusedFor = starting ? 3 : 0
            case "Taunt": fighter.tauntedFor = starting ? 3 : 0
            case "Encore": fighter.encoredFor = starting ? 3 : 0
            case "Disable": fighter.disabledFor = starting ? 4 : 0
            case "Yawn": fighter.drowsyFor = starting ? 1 : 0
            case "Aqua Ring": fighter.aquaRing = starting
            case "Octolock": fighter.octolocked = starting
            case "Torment": fighter.tormented = starting
            case "Attract": fighter.infatuatedWith = starting ? 0 : nil
            case "Ingrain", "No Retreat": fighter.cannotEscape = starting
            case "Perish3": fighter.perishIn = 3
            case "Perish2": fighter.perishIn = 2
            case "Perish1": fighter.perishIn = 1
            case "Perish0": fighter.perishIn = 0
            default: break
            }
        }
        if what == "Leech Seed", let at = seat(ident) {
            withFighter(ident) { $0.seededFrom = starting ? (at.slot) : nil }
        }
        board.note("\(name(of: ident))\(starting ? " is " : " is no longer ")\(what).")
    }

    /// It turned into something else. The Pokemon is the same one -- same
    /// slot, same health, same stages -- wearing a different form.
    private func becomes(_ ident: String, details: String) {
        let species = details.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? details
        guard let form = data?.forms.first(where: {
            $0.showdown == species || $0.formLabel == species
        }) else { return }
        withFighter(ident) { fighter in
            fighter.build.form = form
            // A Mega brings its own ability with it.
            if let its = form.abilities.first?.name, form.isMega { fighter.build.ability = its }
        }
    }

    /// Somebody walked on. The board keeps actives at the front of its array,
    /// so whoever it is has to be brought to the front.
    private func arrive(_ ident: String, details: String, health: String) {
        guard let at = seat(ident) else { return }
        let who = name(of: ident)
        let species = details.split(separator: ",").first.map(String.init) ?? who
        var team = at.mine ? board.mine : board.theirs
        guard let found = team.firstIndex(where: {
            $0.build.form.showdown == species || $0.build.form.formLabel == species
                || $0.build.form.name == species
        }) else { return }
        if found != at.slot, team.indices.contains(at.slot) { team.swapAt(found, at.slot) }
        let reading = self.health(health)
        if let hp = reading.hp, team.indices.contains(at.slot) {
            team[at.slot].hp = max(0, min(team[at.slot].maxHP, hp))
        }
        if at.mine { board.mine = team } else { board.theirs = team }
        board.note("\(who) came in.")
    }

    // MARK: - The protocol's words for things

    private static func ailment(_ text: String) -> Ailment? {
        switch text {
        case "brn": return .burn
        case "psn": return .poison
        case "tox": return .badPoison
        case "par": return .paralysis
        case "slp": return .sleep
        case "frz": return .freeze
        default: return nil
        }
    }

    private static func stage(_ text: String) -> Stage? {
        switch text {
        case "atk": return .attack
        case "def": return .defense
        case "spa": return .spAttack
        case "spd": return .spDefense
        case "spe": return .speed
        case "accuracy": return .accuracy
        case "evasion": return .evasion
        default: return nil
        }
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
