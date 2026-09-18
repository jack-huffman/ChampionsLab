//  MovePreview.swift
//  What a move would actually do, on the button that would do it.
//
//  This is a simulator, so there is no reason to make somebody guess at
//  arithmetic the app can already do: the range as a share of the target, and
//  how many of them it takes. It is worked out on what the Pokemon *will be*
//  when the move goes off -- a toggled Mega Evolution changes the stats, the
//  typing, the ability and sometimes the weather before the move lands -- and
//  against their side with the item nobody has seen left off. The deck puts it
//  on every move tile and the field puts it on the card, which is why it is a
//  thing of its own rather than a helper on either.

import SwiftUI

@MainActor
struct MovePreview {
    let session: BattleSession
    let store: Store

    /// What a move does to a target, as three pieces rather than one
    /// sentence: the damage, what it becomes against that target's Mega, and
    /// how to colour it.
    ///
    /// Kept apart because the move tiles have to line up. Glued into one
    /// string it read "36–42% · 3HKO · as Mega Salamence 25–30%", which wraps
    /// to three lines on one tile and one on the next, and a grid of four
    /// buttons no two of which are the same height is hard to read at a
    /// glance and harder to click confidently.
    func reading(_ board: Board, fighter: Fighter, slot: Int,
                         choice: Choice, only: Int? = nil)
        -> (text: String, mega: String?, tint: Color, power: Int?)? {
        guard case .attack(let index, let target) = choice,
              fighter.moves.indices.contains(index) else { return nil }
        let move = fighter.moves[index]
        guard move.isDamaging else { return nil }
        let becoming = session.evolving(fighter, slot: slot, board: board)
        // Aimed at your own partner: read against it, item and all, since
        // that one you can see.
        let atAlly = target >= Choice.allyTarget
        let side = atAlly ? board.mine : board.theirs
        // A spread move is read across everything it reaches, unless one of
        // them is asked about on its own.
        let aimed: [Int] = only.map { [$0] }
            ?? (move.isSpread ? Array(0..<min(board.activeCount, board.theirs.count))
                : atAlly ? [slot == 0 ? 1 : 0] : [target])
        var low = 0, high = 0, best = 1.0
        var hp = 1, fullHP = 1
        // The power it actually has against what it is aimed at.
        var power: Int?
        for slot in aimed {
            guard side.indices.contains(slot), !side[slot].fainted
            else { continue }
            var defender = side[slot].build
            if !atAlly { defender.item = "" }            // theirs is not something you can see
            defender.atFullHP = side[slot].hp == side[slot].maxHP
            var field = becoming.field
            field.screen = board.theirScreens.blunt(move)
            var attacker = becoming.build
            attacker.lastMoveFailed = fighter.lastMoveFailed
            attacker.fallenAllies = board.mine.filter(\.fainted).count
            let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                              move: move, field: field)
            if result.power > 0, power == nil { power = Int(result.power.rounded()) }
            if result.maxDamage > high {
                low = result.minDamage; high = result.maxDamage
                best = result.effectiveness
                hp = side[slot].hp
                fullHP = side[slot].maxHP
                if result.power > 0 { power = Int(result.power.rounded()) }
            }
        }
        guard high > 0, hp > 0 else { return nil }
        // Shares of the whole bar, so a Pokémon on three points reads as the
        // knockout it is rather than as two thousand per cent.
        let lowShare = Int((Double(low) / Double(max(1, fullHP)) * 100).rounded())
        let highShare = Int((Double(high) / Double(max(1, fullHP)) * 100).rounded())
        let hits = Int(ceil(Double(hp) / Double(max(1, high))))
        let knockout = low >= hp ? "KO" : (high >= hp ? "may KO" : "\(hits)HKO")
        let tint: Color = best > 1 ? Palette.good
            : (best < 1 && best > 0 ? Palette.dim : Palette.accent)
        let text = "\(lowShare)–\(highShare)% · \(knockout)"
        var megaRead: String?
        // Mega Evolution happens before any move, so a target that could
        // evolve may take this hit as its Mega — with its Mega's defences and
        // ability. Said beside the plain number, because the difference
        // between a knockout and a miss is often exactly that.
        if aimed.count == 1, !atAlly, let slot = aimed.first, side.indices.contains(slot),
           !side[slot].build.form.isMega, !board.theirs.contains(where: \.hasMegaEvolved),
           let mega = MegaGuess(store: store).likelyMega(of: side[slot].build.form) {
            var evolved = side[slot].build
            evolved.form = mega
            evolved.ability = mega.abilities.first?.name ?? evolved.ability
            evolved.item = ""
            evolved.atFullHP = side[slot].hp == side[slot].maxHP
            var field = becoming.field
            field.screen = board.theirScreens.blunt(move)
            var attacker = becoming.build
            attacker.lastMoveFailed = fighter.lastMoveFailed
            attacker.fallenAllies = board.mine.filter(\.fainted).count
            let asMega = DamageCalc.calculate(attacker: attacker, defender: evolved, move: move, field: field)
            if asMega.maxDamage > 0 {
                let l2 = Int((Double(asMega.minDamage) / Double(max(1, fullHP)) * 100).rounded())
                let h2 = Int((Double(asMega.maxDamage) / Double(max(1, fullHP)) * 100).rounded())
                // "Mega 25–30%", not "as Mega Salamence 25–30%". Which Mega it
                // is, is on the card across the field; the tile has room for
                // the number and not the name.
                megaRead = "Mega \(l2)–\(h2)%"
            } else {
                megaRead = "nothing to its Mega"
            }
        }
        return (text, megaRead, tint, power)
    }
}
