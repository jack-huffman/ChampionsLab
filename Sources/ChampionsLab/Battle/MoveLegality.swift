//  MoveLegality.swift
//  Whether a move may be thrown right now, and what happens when none may.
//
//  Four things stop a move, and they had been scattered: Disable held its own
//  check inside the action pipeline, Taunt held another a few lines below it,
//  and the two things that were missing entirely — Power Points, and the moves
//  an Imprison has sealed off — had nowhere to go. They are one question with
//  one answer here, which is what lets the last of them work at all: a Pokémon
//  Struggles when *nothing* is usable, and nothing could tell whether that was
//  true while each rule refused on its own.
//
//  Power Points are the quiet half of this. Every move in the dex carries its
//  count and the battle had never spent one, so Imprison could not be written
//  (it needs Struggle, and Struggle needs an empty Pokémon), Pressure was an
//  ability with no effect, and a Trick Room war was decided by who was willing
//  to keep clicking rather than by who had the turns to spend.

import Foundation

enum MoveLegality {

    // MARK: - Why a move will not go

    /// Why a move cannot be used, or that it can.
    enum Refusal: Equatable {
        case none
        /// No Power Points left on it.
        case spent
        /// Sealed by an Imprison across the field.
        case sealed
        /// Shut off by Disable.
        case disabled
        /// A status move under a Taunt.
        case taunted

        var stops: Bool { self != .none }
    }

    /// What stops one move, in the order the games check it.
    static func refusal(_ index: Int, byMine: Bool, slot: Int, board: Board) -> Refusal {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), team[slot].moves.indices.contains(index) else {
            return .none
        }
        let fighter = team[slot]
        let move = fighter.moves[index]
        if fighter.disabled == index { return .disabled }
        if fighter.pp(at: index) <= 0 { return .spent }
        if sealed(move, byMine: byMine, board: board) { return .sealed }
        if !move.isDamaging, fighter.tauntedFor > 0 { return .taunted }
        return .none
    }

    /// Whether one move may be thrown right now.
    static func usable(_ index: Int, byMine: Bool, slot: Int, board: Board) -> Bool {
        !refusal(index, byMine: byMine, slot: slot, board: board).stops
    }

    /// Whether this Pokémon has anything at all it may throw. When it has not,
    /// it Struggles — which is the only reason this question is worth asking
    /// separately from the one above it.
    static func anyUsable(byMine: Bool, slot: Int, board: Board) -> Bool {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return true }
        return team[slot].moves.indices.contains {
            usable($0, byMine: byMine, slot: slot, board: board)
        }
    }

    /// What to say when a move is refused.
    static func reason(_ refusal: Refusal, who: String, move: String) -> String {
        switch refusal {
        case .none: return ""
        case .spent: return "\(who) has no Power Points left for \(move)."
        case .sealed: return "\(who) cannot use the sealed \(move)."
        case .disabled: return "\(who)'s \(move) is disabled."
        case .taunted: return "\(who) cannot use \(move) — it is still taunted."
        }
    }

    // MARK: - Imprison

    /// Whether anybody across the field has sealed this move off.
    ///
    /// Imprison seals what its user *knows*, not what it uses, so the check is
    /// against the other side's move lists rather than against anything it has
    /// done. Only Pokémon still standing seal anything.
    static func sealed(_ move: Move, byMine: Bool, board: Board) -> Bool {
        let across = byMine ? board.theirs : board.mine
        for index in 0..<Swift.min(board.activeCount, across.count) {
            let other = across[index]
            guard other.imprisoning, !other.fainted else { continue }
            if other.moves.contains(where: { $0.id == move.id }) { return true }
        }
        return false
    }

    /// Whether an Imprison thrown here would seal anything. It fails when the
    /// other side knows none of the user's moves, which is what keeps it from
    /// being a free turn.
    static func imprisonWouldHold(byMine: Bool, slot: Int, board: Board) -> Bool {
        let team = byMine ? board.mine : board.theirs
        let across = byMine ? board.theirs : board.mine
        guard team.indices.contains(slot) else { return false }
        let ours = Set(team[slot].moves.map(\.id))
        for index in 0..<Swift.min(board.activeCount, across.count) where !across[index].fainted {
            if across[index].moves.contains(where: { ours.contains($0.id) }) { return true }
        }
        return false
    }

    // MARK: - Spending

    /// Take the Power Points one use costs.
    ///
    /// One, and two against a Pressure — which is the whole of that ability and
    /// the reason a Pressure wall is a clock rather than a wall. Charged in the
    /// action pipeline once the Pokémon has actually moved, so a turn it never
    /// got costs it nothing.
    static func spend(_ index: Int, byMine: Bool, slot: Int, target: Int, board: inout Board) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), team[slot].moves.indices.contains(index) else { return }
        let move = team[slot].moves[index]
        var cost = 1
        if pressured(move, target: target, byMine: byMine, board: board) { cost = 2 }
        let left = Swift.max(0, team[slot].pp(at: index) - cost)
        // A Fighter that arrived without its counts gets them here rather than
        // silently keeping none.
        if byMine {
            if board.mine[slot].ppLeft.count != board.mine[slot].moves.count {
                board.mine[slot].ppLeft = board.mine[slot].moves.map(\.pp)
            }
            board.mine[slot].ppLeft[index] = left
        } else {
            if board.theirs[slot].ppLeft.count != board.theirs[slot].moves.count {
                board.theirs[slot].ppLeft = board.theirs[slot].moves.map(\.pp)
            }
            board.theirs[slot].ppLeft[index] = left
        }
    }

    /// Whether this use is aimed at somebody with Pressure.
    private static func pressured(_ move: Move, target: Int, byMine: Bool, board: Board) -> Bool {
        let across = byMine ? board.theirs : board.mine
        func has(_ index: Int) -> Bool {
            across.indices.contains(index) && index < board.activeCount
                && !across[index].fainted && across[index].build.ability == "Pressure"
        }
        switch move.aim {
        case .spread: return (0..<Swift.min(board.activeCount, across.count)).contains(where: has)
        case .foe: return has(target)
        default: return false
        }
    }

    // MARK: - Struggle

    /// What a Pokémon throws when it has nothing left to throw.
    ///
    /// Not one of its moves and never in its list: fifty power, physical, and
    /// typeless in every way that matters — a Ghost does not get to be immune
    /// to it and a Normal type gets no bonus for it. Using it costs a quarter
    /// of full health, which is why running a Pokémon dry is a real cost and
    /// not a rounding error.
    ///
    /// Built here rather than read from the dex because the battle model has
    /// no rulebook to ask, and checked against the dex by a test, so the two
    /// cannot drift apart quietly.
    static let struggle: Move = {
        let json = """
        {"id":"struggle","name":"Struggle","type":"Normal","category":"Physical",
         "power":50,"accuracy":0,"never_misses":true,"pp":1,"priority":0,
         "target":"Selected Target","showdown_target":"normal","crit_rate":4.17,
         "flags":{"contact":true,"protectable":true},
         "effect":"Used when the Pokémon has no other move it can use. It takes a quarter of its maximum health as recoil.",
         "effect_rate":0,"learnable":false,"secondaries":[]}
        """
        guard let move = try? JSONDecoder().decode(Move.self, from: Data(json.utf8)) else {
            preconditionFailure("Struggle must always be available to a cornered Pokémon")
        }
        return move
    }()

    /// What Struggle costs its user: a quarter of full health, whatever it
    /// dealt and whether or not it dealt anything. Rock Head does not stop it;
    /// Magic Guard does, and that is handled where every other self-inflicted
    /// cost is.
    static let struggleCost = 0.25

    static func isStruggle(_ move: Move) -> Bool { move.id == struggle.id }
}
