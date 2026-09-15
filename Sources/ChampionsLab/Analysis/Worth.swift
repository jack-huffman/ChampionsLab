//  Worth.swift
//  What a Pokémon is worth against the team in front of it.
//
//  The battle engine priced every Pokémon the same: alive was 0.35 and health
//  was the other 0.65, summed and subtracted. A perfectly even trade of your
//  win condition for their least useful body came out as nothing gained and
//  nothing lost, so the engine would take it — and then have nothing left that
//  could actually win the game.
//
//  This gives the engine the one thing it was missing: some of your Pokémon
//  matter more than others, and which ones depends entirely on who you are
//  playing against. A Rillaboom is a different asset into rain than into sun.
//
//  It is built out of the duel grid the app already computes for the versus
//  screen, rather than a second opinion invented for the purpose: each cell
//  already knows how many turns each side needs to knock the other out, and
//  who moves first. Beating a cell is winning the race in it.
//
//  What it is worth, measured rather than assumed:
//
//    * The grid was checked first. `make lab ARGS="--calibrate"` plays fours
//      from all the way down the bring-four ranking. Over 2,400 games the
//      picker's favourite won 60% and a four from the bottom half 42%, and
//      the score bands climb in order — so the grid this is built on is
//      carrying real information, not noise wearing a number.
//
//    * `make lab ARGS="--ab"` then plays one weighted engine against one flat
//      one, same teams, same dice, both chairs. Over 2,000 games the weighted
//      side took 57.3%, give or take 2.2.
//
//  Re-run both if this file changes. A weighting that cannot beat a flat one
//  is a weighting that should come out.

import Foundation

enum Worth {
    /// Around one on average, so the numbers the rest of the engine is tuned
    /// against — the 0.12 a Tailwind is worth, the 0.25 that separates a draw
    /// from a win on time — keep meaning what they meant.
    static let neutral = 1.0

    /// How one side's Pokémon fare against each of the other side's, cell by
    /// cell: my form id, then theirs, then how the race goes.
    ///
    /// This is the durable half — it depends only on the two teams, so it is
    /// worked out once. Which of those cells still matter is the part that
    /// changes as Pokémon faint, and that is `weights(from:against:)`.
    static func table(for team: Team, against foe: Team,
                      rules: Rulebook, field: Field) -> [String: [String: Double]] {
        let grid = Matchup(mine: team, theirs: foe, rules: rules, field: field)
        var out: [String: [String: Double]] = [:]
        for mine in grid.myForms {
            var row: [String: Double] = [:]
            for theirs in grid.theirForms {
                guard let cell = grid.cell(mine: mine, theirs: theirs) else { continue }
                if cell.myTurnsToKO < cell.theirTurnsToKO { row[theirs.id] = 1 }
                else if cell.myTurnsToKO > cell.theirTurnsToKO { row[theirs.id] = 0 }
                // A tie goes to whoever moves first, because they land the last
                // hit. Worth something either way: a race this close is decided
                // by a roll as often as by the plan.
                else { row[theirs.id] = cell.iAmFaster ? 0.75 : 0.25 }
            }
            out[mine.id] = row
            // The Mega is the same Pokémon as the thing that becomes it.
            if let pair = grid.myPairs.first(where: { $0.1.id == mine.id }) {
                if let registered = pair.0.form(in: rules) { out[registered.id] = row }
                if let mega = pair.0.megaEvolution(in: rules) { out[mega.id] = row }
            }
        }
        return out
    }

    /// What each Pokémon is worth *right now*, given who is still standing.
    ///
    /// This is the half that moves. A Basculegion is worth keeping while the
    /// Swampert it drowns is still on the field; once the Swampert has gone it
    /// is one more body, and the engine should be willing to spend it. The
    /// static version of this could not tell those two positions apart —
    /// Basculegion had one number for the whole game.
    ///
    /// `against` is the opposing forms that are both alive and *seen*. Seen,
    /// because a weight worked out against a Pokémon the other side has not
    /// revealed would be reasoning from something this side cannot know; and
    /// because the same table is read from both chairs, it has to be the
    /// visible part in either direction.
    static func weights(from table: [String: [String: Double]],
                        against living: [String]) -> [String: Double] {
        guard !living.isEmpty, !table.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        for (form, row) in table {
            var beats = 0.0, counted = 0.0
            for id in living {
                guard let cell = row[id] else { continue }
                beats += cell
                counted += 1
            }
            guard counted > 0 else { continue }
            out[form] = 0.72 + 0.56 * (beats / counted)
        }
        guard !out.isEmpty else { return [:] }
        // Around one on average, so the numbers the rest of the engine is tuned
        // against keep meaning what they meant, and so a side's total worth
        // does not move with who is left — only the distribution does.
        let mean = out.values.reduce(0, +) / Double(out.count)
        if mean > 0 { for key in out.keys { out[key]! /= mean } }
        return out
    }

}
