//  StatChanges.swift
//  Stat stages going up and down, and everything that has an opinion about it.
//
//  A stage is a small thing to move and a great deal watches it move: the
//  clamp at six either way, Contrary turning it round, Defiant and Competitive
//  answering a drop with a raise, Clear Body and Mirror Armor refusing it,
//  Opportunist copying the neighbour's gains, a White Herb putting a drop back.
//  Every one of those is a rule about *changing a stat*, whatever caused the
//  change — an Intimidate on arrival, an Icy Wind, a Swords Dance, a Close
//  Combat's own recoil on its defences — so they live with the change rather
//  than with each of the twenty things that can cause one.
//
//  `change` is the only door. Anything that wants a stat moved goes through it,
//  and so gets every rule above for free; the two thin wrappers here for a
//  move's own boosts and its drops on the target are the same door with the
//  sign already applied.

import Foundation

enum StatChanges {
    /// Stat stages a move takes off whatever it hit.
    /// Stat stages taken off a Pokémon by the other side: Icy Wind, Snarl, a
    /// Weakness Policy going off on the wrong one. The abilities that answer
    /// a drop from outside all live here: Clear Body refuses it, Contrary
    /// turns it round, Defiant and Competitive take it and hit back.
    /// `fromOpponent` is what Defiant and Competitive actually watch for:
    /// they answer a stat lowered by the *other side*, and a partner's Charm
    /// on a Contrary sweeper is not that. Everything else about a drop is the
    /// same whoever aimed it.
    static func applyDrops(_ drops: [Stage: Int], toMine: Bool, slot: Int,
                                   board: inout Board, fromOpponent: Bool = true) {
        guard !drops.isEmpty else { return }
        let team = toMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let ability = team[slot].build.ability
        // Big Pecks keeps its Defense where it is, and nothing else.
        if ability == "Big Pecks", drops.keys.contains(.defense), drops.count == 1 {
            board.note("\(name)'s Big Pecks kept its Defense where it was.")
            return
        }
        if ["Clear Body", "White Smoke", "Full Metal Body", "Mirror Armor"].contains(ability) {
            board.note("\(name)'s \(ability) kept its stats where they were.")
            return
        }
        // Flower Veil covers the Grass types on its own side, itself included.
        let partner = slot == 0 ? 1 : 0
        if team[slot].types.contains(.grass),
           team.indices.contains(partner), !team[partner].fainted,
           team[partner].build.ability == "Flower Veil" || ability == "Flower Veil" {
            board.note("\(name) is covered by Flower Veil; its stats stay where they are.")
            return
        }
        let deltas = Dictionary(uniqueKeysWithValues: drops.map { ($0.key, -$0.value) })
        change(deltas, onMine: toMine, slot: slot, board: &board)
        guard fromOpponent else { return }
        if ability == "Defiant" {
            change([.attack: 2], onMine: toMine, slot: slot, board: &board, because: "Defiant")
        } else if ability == "Competitive" {
            change([.spAttack: 2], onMine: toMine, slot: slot, board: &board, because: "Competitive")
        }
    }

    /// Stat stages a Pokémon gives itself, up or down: Swords Dance, Close
    /// Combat's cost, Weakness Policy. Nothing refuses these except Contrary,
    /// which reverses them — the whole reason Contrary Close Combat exists.
    static func applySelf(_ boosts: [Stage: Int], toMine: Bool, slot: Int,
                                  board: inout Board) {
        change(boosts, onMine: toMine, slot: slot, board: &board)
        opportunist(after: boosts, onMine: toMine, board: &board)
    }

    /// White Herb: the moment any of the holder's stats sits below zero, the
    /// herb goes and the drops are undone. It is what turns Unburden on — the
    /// item is gone, so the Speed doubles — which is the whole Sneasler set.
    static func whiteHerb(_ fighter: inout Fighter) -> String? {
        guard fighter.build.item == "White Herb", !fighter.build.itemSpent,
              fighter.build.boosts.contains(where: { $0 < 0 }) else { return nil }
        for index in fighter.build.boosts.indices where fighter.build.boosts[index] < 0 {
            fighter.build.boosts[index] = 0
        }
        fighter.build.itemSpent = true
        let name = fighter.build.form.formLabel
        var said = "\(name)'s White Herb restored its stats."
        if fighter.build.ability == "Unburden" { said += " Its Unburden doubled its Speed." }
        return said
    }

    /// Opportunist: whatever the other side just gained, it gains too.
    ///
    /// Called after a raise lands, and deliberately only for a raise on the
    /// far side — copying its own partner's would be a loop.
    private static func opportunist(after raised: [Stage: Int], onMine: Bool,
                                    board: inout Board) {
        let watchers = onMine ? board.theirs : board.mine
        let positive = raised.filter { $0.value > 0 }
        guard !positive.isEmpty else { return }
        for index in watchers.indices.prefix(board.activeCount)
        where !watchers[index].fainted && watchers[index].build.ability == "Opportunist" {
            change(positive, onMine: !onMine, slot: index, board: &board, because: "Opportunist")
        }
    }

    /// Move a Pokémon's stages, through whatever its ability does to stage
    /// changes, and say what happened in one line.
    static func change(_ deltas: [Stage: Int], onMine: Bool, slot: Int,
                               board: inout Board, because: String? = nil) {
        guard !deltas.isEmpty else { return }
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let ability = team[slot].build.ability
        var applied = deltas
        if ability == "Contrary" { applied = applied.mapValues { -$0 } }
        if ability == "Simple" { applied = applied.mapValues { $0 * 2 } }
        var rose: [String] = [], fell: [String] = []
        for (stage, amount) in applied.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // A Pokemon that arrived from somewhere narrower -- an older peer
            // across the network, a position built before accuracy was a
            // stage -- gets the room rather than a crash.
            if team[slot].build.boosts.count < Stage.width {
                let grown = team[slot].build.boosts
                    + Array(repeating: 0, count: Stage.width - team[slot].build.boosts.count)
                if onMine { board.mine[slot].build.boosts = grown }
                else { board.theirs[slot].build.boosts = grown }
            }
            let side = onMine ? board.mine : board.theirs
            let before = side[slot].build.boosts[stage.rawValue]
            let after = Swift.max(-6, Swift.min(6, before + amount))
            guard after != before else { continue }
            if onMine { board.mine[slot].build.boosts[stage.rawValue] = after }
            else { board.theirs[slot].build.boosts[stage.rawValue] = after }
            board.recordStat(mine: onMine, slot: slot, stat: stage.rawValue, delta: after - before, cause: because)
            let word = abs(amount) >= 2 ? "\(stage.short) sharply" : stage.short
            if amount > 0 { rose.append(word) } else { fell.append(word) }
        }
        guard !rose.isEmpty || !fell.isEmpty else { return }
        var parts: [String] = []
        if !rose.isEmpty { parts.append("\(rose.joined(separator: " and ")) rose") }
        if !fell.isEmpty { parts.append("\(fell.joined(separator: " and ")) fell") }
        var line = "\(name)'s " + parts.joined(separator: "; ") + "."
        if let because { line = "\(name)'s \(because): " + parts.joined(separator: "; ") + "." }
        else if ability == "Contrary" { line = "\(name)'s Contrary turned it round: " + parts.joined(separator: "; ") + "." }
        else if ability == "Simple" { line = "\(name)'s Simple doubled it: " + parts.joined(separator: "; ") + "." }
        board.note(line)
        if !fell.isEmpty {
            let herb = onMine ? whiteHerb(&board.mine[slot]) : whiteHerb(&board.theirs[slot])
            if let herb { board.note(herb) }
        }
    }
}
