//  MoveHistory.swift
//  What a Pokemon just did, for the moves that ask.
//
//  A handful of moves read the recent past rather than the present: Encore
//  holds a Pokemon to whatever it used last, Stomping Tantrum doubles after a
//  failure, a two-turn move remembers that it is halfway through. That memory
//  is written in one place, so every action records itself the same way and
//  no move can be surprised by a gap in the record.

import Foundation

enum MoveHistory {
    /// Note what a Pokémon used and where, for Encore; and if it is under an
    /// Encore, count that down.
    static func remember(byMine: Bool, slot: Int, move: Int, target: Int, board: inout Board) {
        if byMine {
            board.mine[slot].lastMove = move; board.mine[slot].lastTarget = target
            if board.mine[slot].encoredFor > 0 {
                board.mine[slot].encoredFor -= 1
                if board.mine[slot].encoredFor == 0 { board.note("\(board.mine[slot].build.form.formLabel)'s Encore ended.") }
            }
        } else {
            board.theirs[slot].lastMove = move; board.theirs[slot].lastTarget = target
            if board.theirs[slot].encoredFor > 0 {
                board.theirs[slot].encoredFor -= 1
                if board.theirs[slot].encoredFor == 0 { board.note("\(board.theirs[slot].build.form.formLabel)'s Encore ended.") }
            }
        }
    }

    /// Whether a Pokémon's last move came off, for Stomping Tantrum.
    static func markFailed(byMine: Bool, slot: Int, board: inout Board, failed: Bool) {
        if byMine, board.mine.indices.contains(slot) { board.mine[slot].lastMoveFailed = failed }
        if !byMine, board.theirs.indices.contains(slot) { board.theirs[slot].lastMoveFailed = failed }
    }

    /// A charge that will not be finished: the Pokémon was stopped, or the
    /// move is landing now.
    static func dropCharge(byMine: Bool, slot: Int, board: inout Board, quietly: Bool = false) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), let charging = team[slot].charging else { return }
        if !quietly, team[slot].moves.indices.contains(charging) {
            board.note("\(team[slot].build.form.formLabel) lost its \(team[slot].moves[charging].name).")
        }
        if byMine { board.mine[slot].charging = nil; board.mine[slot].hidden = false }
        else { board.theirs[slot].charging = nil; board.theirs[slot].hidden = false }
    }
}
