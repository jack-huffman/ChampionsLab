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
    /// One Pokémon's action this turn, with the reasoning behind where it sits.
    struct Entry {
        let mine: Bool
        let slot: Int
        let choice: Choice
        let bracket: Int
        /// Speed as it stood when the turn was declared. `next` re-reads the
        /// live value; this is kept for anything describing the turn later.
        let speed: Int
        /// What moved the bracket off the move's own number.
        let becauseOfPriority: [String]
        /// What moved the Speed off the Pokémon's own number.
        let becauseOfSpeed: [String]
    }

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
                        rolling: Bool,
                        quickClaw: (Fighter, Bool, Int, Board, Bool) -> Bool) -> [Entry] {
        var out: [Entry] = []
        for (side, given) in [(true, mine), (false, theirs)] {
            let team = side ? board.mine : board.theirs
            let tailwind = (side ? board.myTailwind : board.theirTailwind) > 0
            for (slot, asked) in given.enumerated() {
                guard team.indices.contains(slot), !team[slot].fainted else { continue }
                let choice = forced(team[slot], asked)
                guard !choice.isSwap else { continue }
                var why: [String] = []
                var bracket = TurnModel.priority(of: choice, for: team[slot],
                                                 field: board.field, reasons: &why)
                if quickClaw(team[slot], side, slot, board, rolling) {
                    bracket += 1
                    why.append("a Quick Claw went off")
                    board.note("\(team[slot].build.form.formLabel)'s Quick Claw let it move first.")
                }
                out.append(Entry(mine: side, slot: slot, choice: choice, bracket: bracket,
                                 speed: TurnModel.liveSpeed(side: side, slot: slot, board: board),
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
            let aSpeed = TurnModel.liveSpeed(side: a.mine, slot: a.slot, board: board)
            let bSpeed = TurnModel.liveSpeed(side: b.mine, slot: b.slot, board: board)
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
}
