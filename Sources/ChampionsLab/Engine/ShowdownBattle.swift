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

@MainActor
final class ShowdownBattle {
    private let engine = ShowdownEngine.shared
    /// Protocol tags the reader does not know yet. Collected rather than
    /// ignored: a tag nobody handled is a thing the board is quietly wrong
    /// about, and the tests read this.
    private(set) var unread: Set<String> = []
    private(set) var board: Board

    /// Which side of the protocol is ours. The sim always calls the first
    /// player p1; the app always calls itself "mine".
    private let mySide = "p1"

    // MARK: - Starting

    init(board: Board) {
        self.board = board
        // `note` is what writes the story and the steps, and it does nothing
        // unless the board is narrating.
        self.board.narrating = true
    }

    /// Stand a battle up from two teams, bringing the four each side chose.
    static func start(mine: Team, theirs: Team, myFour: [Int], theirFour: [Int],
                      store: Store, seed: [Int]? = nil) throws -> ShowdownBattle {
        let engine = ShowdownEngine.shared
        let myPaste = ShowdownTeam.paste(for: mine, bringing: myFour, store: store)
        let theirPaste = ShowdownTeam.paste(for: theirs, bringing: theirFour, store: store)
        try engine.start(mine: (mine.name, engine.pack(paste: myPaste)),
                         theirs: (theirs.name, engine.pack(paste: theirPaste)),
                         seed: seed)
        // Both sides bring everything they packed, in the order they packed it.
        try engine.choose("p1", "team " + (1...myFour.count).map(String.init).joined())
        try engine.choose("p2", "team " + (1...theirFour.count).map(String.init).joined())
        // The board is built from the same four, in the same order, so the
        // sim's positions and the board's indices mean the same thing.
        let battle = ShowdownBattle(board: Board(mine: Self.reduced(mine, to: myFour),
                                                 theirs: Self.reduced(theirs, to: theirFour),
                                                 rules: store.rulebook,
                                                 field: Field(isDoubles: true),
                                                 alreadyEvolved: false))
        battle.read(try engine.since())
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
                      store: Store, seed: [Int]? = nil) throws -> ShowdownBattle {
        func chosen(_ fighters: [Fighter], from team: Team) -> [Int] {
            var taken = Set<Int>(), out: [Int] = []
            for fighter in fighters.prefix(board.activeCount * 2) {
                let wanted = fighter.build.form.dex
                if let index = team.slots.indices.first(where: { index in
                    !taken.contains(index)
                        && team.slots[index].form(in: store.rulebook)?.dex == wanted
                }) {
                    taken.insert(index); out.append(index)
                }
            }
            return out
        }
        let myFour = chosen(board.mine, from: mine)
        let theirFour = chosen(board.theirs, from: theirs)
        let game = try start(mine: mine, theirs: theirs, myFour: myFour, theirFour: theirFour,
                             store: store, seed: seed)
        // The board is the one that was already built and already shown; the
        // engine's job is to resolve what happens to it from here.
        game.board = board
        game.board.narrating = true
        return game
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

    /// A turn, with what our side does if it is made to send somebody in.
    /// Nil stops the turn there and sets `awaitingSendIn`, which is how a
    /// played game asks the player.
    @discardableResult
    func play(mine: String, theirs: String, oursWhenForced ours: String?) throws -> Board {
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
        try settle(answeringOurs: ours)
        return board
    }

    /// Whether our side is being made to send somebody in. The turn is not
    /// over until it has, and it is the player's choice rather than the
    /// engine's, so a played game stops here and asks.
    private(set) var awaitingSendIn = false

    /// Send somebody in for the one that fell, by their place on the board.
    @discardableResult
    func sendIn(bench: Int) throws -> Board {
        try settle(answeringOurs: "switch \(bench + 1)")
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
    private func settle(answeringOurs ours: String?) throws {
        var rounds = 0
        while !engine.ended, rounds < 8 {
            let forced = try (self.forced("p1"), self.forced("p2"))
            guard forced.0 || forced.1 else { break }
            if forced.0 {
                guard let ours else { awaitingSendIn = true; return }
                try answer("p1", ours)
            }
            if forced.1 { try answer("p2", "default") }
            read(try engine.since())
            rounds += 1
        }
        awaitingSendIn = false
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
    private func answer(_ side: String, _ choice: String) throws {
        guard try engine.request(side) != nil else { return }
        guard try engine.choose(side, choice) else {
            throw ShowdownEngine.Trouble.refused("\(side) would not play \(choice)")
        }
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
                parts.append("pass")
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
        // percentages for everyone else. A reader that takes both ends up
        // with whatever the percentage said, which is how every Pokemon on
        // this board came out at 100 HP out of two hundred and seven.
        var skipNext = false
        for line in lines {
            guard line.hasPrefix("|") else { continue }
            if line.hasPrefix("|split|") { skipNext = false; continue }
            if skipNext, line.hasPrefix("|-damage|") || line.hasPrefix("|-heal|")
                || line.hasPrefix("|-sethp|") || line.hasPrefix("|switch|")
                || line.hasPrefix("|drag|") || line.hasPrefix("|replace|") {
                skipNext = false
                continue
            }
            skipNext = false
            let parts = line.dropFirst().components(separatedBy: "|")
            guard let tag = parts.first, !tag.isEmpty else { continue }
            let arg = { (n: Int) -> String in n < parts.count ? parts[n] : "" }
            switch tag {
            case "move":
                board.note("\(name(of: arg(1))) used \(arg(2)).")
            case "-damage", "-heal", "-sethp":
                skipNext = true
                let reading = health(arg(2))
                withFighter(arg(1)) { f in
                    if let hp = reading.hp { f.hp = max(0, min(f.maxHP, hp)) }
                    if let status = reading.status { f.status = status }
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
                skipNext = true
                arrive(arg(1), details: arg(2), health: arg(3))
            case "-ability":
                board.note("\(name(of: arg(1)))'s \(arg(2)).")
            case "-item":
                board.note("\(name(of: arg(1)))'s \(arg(2)).")
            case "-enditem":
                withFighter(arg(1)) { $0.build.item = "" }
                board.note("\(name(of: arg(1)))'s \(arg(2)) was used up.")
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
            case "turn", "upkeep", "", "t:", "player", "teamsize", "gen", "tier",
                 "rule", "start", "gametype", "clearpoke", "poke", "teampreview",
                 "request", "sideupdate", "update", "-hint", "-message", "done",
                 "split", "uhtml", "uhtmlchange", "-anim", "-notarget", "-nothing",
                 "-center", "-combine", "-waiting", "-prepare", "-mustrecharge",
                 "-hitcount", "-singlemove", "-singleturn", "-block", "-ohko",
                 "-zpower", "-zbroken", "-clearnegativeboost", "-copyboost",
                 "-swapboost", "-invertboost", "-endability", "-transform",
                 "-formechange", "-mega", "-primal", "-burst", "-terastallize",
                 "detailschange", "swap", "-fieldactivate", "-candynamax",
                 "-start", "-end", "-activate", "-sidestart", "-sideend",
                 "-cureteam", "-setboost", "-boost2", "inactive", "inactiveoff",
                 "raw", "html", "bigerror", "error", "debug", "seed", "message",
                 "-hidelinebreak", "askreg", "chat", "c", "j", "l", "n", "expire":
                break
            case "win", "tie":
                board.note(tag == "win" ? "\(arg(1)) won." : "It is a tie.")
            default:
                unread.insert(tag)
            }
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
