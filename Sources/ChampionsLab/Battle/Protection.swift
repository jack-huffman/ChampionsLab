//  Protection.swift
//  Protect, with the odds the game actually gives it.
//
//  Certain the first time, a third the next, a ninth after that, and back to
//  certain the moment one fails or a turn goes by without one. A played turn
//  rolls it. The search asks for one branch at a time and weighs them itself,
//  so a second Protect in a row is worth exactly a third of a first one — which
//  is what it is worth, and is why a Gholdengo that has already protected is
//  still not a free Sucker Punch. The streak itself lives on the Fighter; this
//  is the one place that reads it and rolls against it.

import Foundation

enum Protection {
    @discardableResult
    static func tryProtect(_ label: String?, byMine: Bool, slot: Int,
                                   board: inout Board, rolling: Bool) -> Bool {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return false }
        let fighter = team[slot]
        let name = fighter.build.form.formLabel
        let word = label ?? "Protect"
        let chance = fighter.protectChance
        // A played turn rolls it. The search asks for one branch at a time
        // and weighs them itself, so a 33% Protect is worth a third of a
        // Protect to it rather than nothing — which is what it is worth, and
        // is why a Gholdengo that has already protected is still not a free
        // Sucker Punch.
        let ruling = board.rulings[Board.flip("protect", byMine, slot)]
        let works = rolling ? Double.random(in: 0..<1, using: &Dice.source) < chance : (ruling ?? (chance >= 0.5))
        if works {
            if byMine { board.mine[slot].isProtected = true; board.mine[slot].protectStreak += 1 }
            else { board.theirs[slot].isProtected = true; board.theirs[slot].protectStreak += 1 }
            board.note(chance < 1
                ? "\(name) used \(word) and braced — a \(Int((chance * 100).rounded()))% chance, and it held."
                : "\(name) used \(word) and braced.")
            return true
        } else {
            if byMine { board.mine[slot].protectStreak = 0 } else { board.theirs[slot].protectStreak = 0 }
            board.note("\(name) used \(word), but it failed — \(Int((chance * 100).rounded()))% after using it last turn.")
            return false
        }
    }
}
