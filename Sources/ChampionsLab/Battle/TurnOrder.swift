//  TurnOrder.swift
//  Who acts, in what order, and why — decided in one place.
//
//  This was inline in TurnModel.resolve, and the helpers around it (priority,
//  speed) were single-sourced while the *policy* was not: the bracket, the
//  Trick Room inversion, After You, Quash, the re-read of Speed before every
//  action, and the tie rule all lived inside one while-loop in the middle of a
//  five-thousand-line function. Nothing else could ask "who goes first here"
//  without writing it again.
//
//  Which is exactly what happened. The turn explainer needed the order so it
//  could say why a Fake Out went before a Prankster Tailwind, and it sorted by
//  bracket and then Speed — correct for that case and quietly wrong for After
//  You, for Quash, and for a Tailwind that goes up mid-turn. An explanation
//  that disagrees with the turn is worse than no explanation, because it is
//  believed.
//
//  So the order is a type. `declare` works out what everybody is about to do
//  and what bracket it lands in; `next` picks who goes now, reading the board
//  as it stands rather than as it stood. The turn walks it, and anything that
//  wants to describe the turn walks the same thing.
//
//  The one rule worth restating, because every report about this has turned on
//  it: the bracket is settled before Speed is consulted at all. A Pokémon in a
//  higher bracket moves first however slow it is. Speed only separates things
//  already tied on priority.

import Foundation

enum TurnOrder {
    /// An action waiting its turn. Kept on the Board as `Board.Queued`, so a
    /// turn stopped by a pivot is state and resumes from the Board alone.
    typealias Entry = Board.Queued

    /// A Pokémon halfway through a two-turn move, or held by an Encore, has no
    /// choice this turn — it does what it is held to.
    ///
    /// Read at declaration *and* again when the action comes up, because an
    /// Encore that landed a moment ago already applies.
    static func forced(_ fighter: Fighter, _ choice: Choice) -> Choice {
        if let charging = fighter.charging {
            return .attack(move: charging, target: fighter.chargingTarget)
        }
        if let encored = fighter.encored { return encored }
        return choice
    }

    /// Everybody who is going to act, and the bracket they land in.
    ///
    /// Switches are not here: they resolve before anything is thrown, which is
    /// the whole cost of a pivot. Takes the board as `inout` because a Quick
    /// Claw going off is an event the turn has to say out loud.
    static func declare(_ board: inout Board, mine: [Choice], theirs: [Choice],
                        rolling: Bool) -> [Entry] {
        var out: [Entry] = []
        for (side, given) in [(true, mine), (false, theirs)] {
            let team = side ? board.mine : board.theirs
            let tailwind = (side ? board.myTailwind : board.theirTailwind) > 0
            for (slot, asked) in given.enumerated() {
                guard team.indices.contains(slot), !team[slot].fainted else { continue }
                let choice = forced(team[slot], asked)
                guard !choice.isSwap else { continue }
                var why: [String] = []
                var bracket = priority(of: choice, for: team[slot],
                                                 field: board.field, reasons: &why)
                if quickClawed(team[slot], mine: side, slot: slot, board: board, rolling: rolling) {
                    bracket += 1
                    why.append("a Quick Claw went off")
                    board.note("\(team[slot].build.form.formLabel)'s Quick Claw let it move first.")
                }
                out.append(Entry(mine: side, slot: slot, choice: choice, bracket: bracket,
                                 speed: liveSpeed(side: side, slot: slot, board: board),
                                 becauseOfPriority: why,
                                 becauseOfSpeed: speedNotes(team[slot], tailwind: tailwind,
                                                            board: board)))
            }
        }
        return out
    }

    private static func speedNotes(_ fighter: Fighter, tailwind: Bool, board: Board) -> [String] {
        var out: [String] = []
        if tailwind { out.append("Tailwind doubles it") }
        if board.trickRoom > 0 { out.append("Trick Room, so slower acts first") }
        if fighter.build.item == "Choice Scarf" { out.append("Choice Scarf, +50%") }
        if fighter.status.halvesSpeed { out.append("\(fighter.status.rawValue), halved") }
        return out
    }

    /// Who acts now, out of what is left.
    ///
    /// Chosen one at a time rather than sorted once, because Speed is re-read
    /// before every action and the board moves underneath. A Prankster
    /// Whimsicott putting up Tailwind goes first on priority, and its partner —
    /// who has not acted yet — is twice as fast from that moment, which can
    /// carry it past something it was behind. Sorting the turn up front makes
    /// that impossible to express.
    ///
    /// Removes what it returns, so a caller that does nothing else still
    /// terminates.
    static func next(from pending: inout [Entry], board: Board) -> Entry? {
        guard !pending.isEmpty else { return nil }
        let inverted = board.trickRoom > 0
        func flag(_ e: Entry, _ read: (Fighter) -> Bool) -> Bool {
            let team = e.mine ? board.mine : board.theirs
            return team.indices.contains(e.slot) && read(team[e.slot])
        }
        var choice = 0
        for index in pending.indices.dropFirst() {
            let a = pending[index], b = pending[choice]
            // After You beats priority and Speed both: the whole move is that
            // the target acts next, whatever it was going to do.
            let jumpsA = flag(a, \.goesNext), jumpsB = flag(b, \.goesNext)
            if jumpsA != jumpsB { if jumpsA { choice = index }; continue }
            // Quash is the same in reverse, and loses to everything.
            let backA = flag(a, \.goesLast), backB = flag(b, \.goesLast)
            if backA != backB { if backB { choice = index }; continue }
            if a.bracket != b.bracket {
                if a.bracket > b.bracket { choice = index }
                continue
            }
            let aSpeed = liveSpeed(side: a.mine, slot: a.slot, board: board)
            let bSpeed = liveSpeed(side: b.mine, slot: b.slot, board: board)
            if aSpeed != bSpeed {
                if inverted ? aSpeed < bSpeed : aSpeed > bSpeed { choice = index }
                continue
            }
            // A genuine tie is a coin flip in the game. Resolved the same way
            // every time here, so a search is reproducible.
            if a.mine && !b.mine { choice = index }
        }
        return pending.remove(at: choice)
    }

    /// The whole order, without playing any of it.
    ///
    /// What anything describing a turn should ask. It walks the same `next`
    /// the turn walks, so it cannot drift from it — but it reads a board that
    /// is standing still, so it shows the order as the turn was declared
    /// rather than as it would unfold if a Tailwind went up halfway through.
    static func wholeTurn(from pending: [Entry], board: Board) -> [Entry] {
        var left = pending
        var out: [Entry] = []
        while let entry = next(from: &left, board: board) { out.append(entry) }
        return out
    }

    /// Quick Claw: a fifth of the time the holder goes first regardless.
    /// Rolled once per turn per holder, when the turn is played; the search
    /// never counts on it, the way it never counts on a second Protect.
    static func quickClawed(_ fighter: Fighter, mine: Bool, slot: Int,
                                    board: Board, rolling: Bool) -> Bool {
        // Quick Draw is the ability version, three times in ten rather than
        // two, and it rides the same pre-decided flip.
        let odds = fighter.build.ability == "Quick Draw" ? 0.3
            : (fighter.build.item == "Quick Claw" ? 0.2 : 0)
        guard odds > 0 else { return false }
        if rolling { return Double.random(in: 0..<1, using: &Dice.source) < odds }
        return board.rulings[Board.flip("quickclaw", mine, slot)] ?? false
    }

    static func priority(of choice: Choice, for fighter: Fighter,
                                 field: Field = Field()) -> Int {
        var ignored: [String] = []
        return priority(of: choice, for: fighter, field: field, reasons: &ignored)
    }

    /// The same, saying why.
    ///
    /// The reasons live next to the rules rather than in whatever screen wants
    /// to explain a turn, because an explanation derived separately from the
    /// thing it explains is an explanation that can be wrong — and a wrong one
    /// is worse than none, since it is believed.
    static func priority(of choice: Choice, for fighter: Fighter,
                         field: Field = Field(), reasons: inout [String]) -> Int {
        switch choice {
        case .pass: return -99
        case .swap:
            reasons.append("switching, which happens before anything is thrown")
            return 6
        case .protectSelf(let index), .attack(let index, _):
            guard fighter.moves.indices.contains(index) else { return 0 }
            let move = fighter.moves[index]
            var priority = move.priority
            if move.priority != 0 {
                reasons.append("\(move.name) is priority \(move.priority > 0 ? "+" : "")"
                               + "\(move.priority)")
            }
            // Prankster: a stage on every status move, which is what puts a
            // Whimsicott's Tailwind or Encore ahead of anything without
            // priority of its own — though not ahead of a Fake Out at +3.
            if fighter.build.ability == "Prankster", !move.isDamaging {
                priority += 1
                reasons.append("Prankster adds +1 to a status move")
            }
            // Grassy Glide, which is most of the reason a Rillaboom is worth a
            // slot: under its own terrain it is a priority move, and without
            // that it is a 60 power Grass attack nobody would run.
            //
            // The move data has said so all along — "if the user is under the
            // effect of Grassy Terrain this move's priority becomes +1" — and
            // the analysis screens quote it at you. The turn model never read
            // it, so in an actual battle the Glide has never once gone first.
            if move.id == "grassyglide", field.terrain == .grassy, fighter.isGrounded {
                priority += 1
                reasons.append("Grassy Glide is +1 under its own terrain")
            }
            // Stall always acts last, whatever it is doing.
            if fighter.build.ability == "Stall" {
                priority -= 7
                reasons.append("Stall always acts last")
            }
            // Gale Wings: Flying moves first, while the bar is full.
            if fighter.build.ability == "Gale Wings", move.type == "Flying",
               fighter.hp == fighter.maxHP {
                priority += 1
                reasons.append("Gale Wings adds +1 to a Flying move at full health")
            }
            return priority
        }
    }

    /// One pending action's Speed, as the board stands right now.
    /// Speed as the board has it right now, with everything applied.
    ///
    /// One reader, because the turn re-checks this between actions and
    /// anything explaining the turn has to get the same number back.
    static func liveSpeed(side: Bool, slot: Int, board: Board) -> Int {
        let team = side ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return 0 }
        var value = speed(of: team[slot],
                          tailwind: (side ? board.myTailwind : board.theirTailwind) > 0,
                          board: board)
        if team[slot].status.halvesSpeed { value /= 2 }
        return value
    }

    static func speed(of fighter: Fighter, tailwind: Bool, board: Board) -> Int {
        let base = fighter.build.speed(in: board.field)
        return tailwind ? base * 2 : base
    }

    static func billing(_ board: Board, mine: Play, theirs: Play) -> [Billing] {
        // A throwaway copy, because declaring notices things out loud — a
        // Quick Claw going off is a line in the log — and describing a turn
        // must not write to the turn.
        var scratch = board
        let entries = TurnOrder.declare(&scratch, mine: [mine.left, mine.right],
                                        theirs: [theirs.left, theirs.right],
                                        rolling: false)
        let game = TurnGame(board: board)
        return TurnOrder.wholeTurn(from: entries, board: board).compactMap { entry in
            let team = entry.mine ? board.mine : board.theirs
            guard team.indices.contains(entry.slot) else { return nil }
            return Billing(
                mine: entry.mine, slot: entry.slot,
                who: team[entry.slot].build.form.formLabel,
                what: game.describe(entry.choice, fighter: team[entry.slot],
                                    foes: Array((entry.mine ? board.theirs : board.mine)
                                        .prefix(board.activeCount)),
                                    team: team),
                bracket: entry.bracket, speed: entry.speed,
                becauseOfPriority: entry.becauseOfPriority,
                becauseOfSpeed: entry.becauseOfSpeed)
        }
    }

    /// Who acts when, and why — from the same bracket and Speed the turn uses.
    ///
    /// Reconstructed rather than recorded: the turn itself re-checks Speed
    /// before every action, because a Tailwind that goes up mid-turn changes
    /// the order of what is left. This reads the position as it stood at the
    /// start, which is the question somebody asking "why did that go first" is
    /// actually asking.
    struct Billing: Sendable, Identifiable {
        let mine: Bool
        let slot: Int
        let who: String
        let what: String
        let bracket: Int
        let speed: Int
        /// What moved the bracket off the move's own number.
        let becauseOfPriority: [String]
        /// What moved the Speed off the Pokémon's own number.
        let becauseOfSpeed: [String]
        var id: String { "\(mine)-\(slot)" }
    }
}
