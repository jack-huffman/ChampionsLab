//  Accuracy.swift
//  Whether a move lands, once everything on both sides has had its say.
//
//  One function, and it is a file of its own for the reason it exists at all:
//  the played roll and the search's average have to read the same number, and
//  when they did not the search priced Zap Cannon at 50 on the one Pokemon in
//  the game that cannot miss with it, and Hurricane at 70 under the rain its
//  team was built around. Three places had read the move's printed accuracy
//  instead of asking. There is one place to ask now, and nothing else in the
//  battle model is allowed to know what a move's accuracy is.

import Foundation

enum Accuracy {
    /// How likely a move is to land, once everything on both sides has had its
    /// say: the move's own accuracy, a Bright Powder, a Sand Veil in the sand,
    /// a Keen Eye refusing to be blinded. Kept in one place so the played roll
    /// and the search's average can never disagree.
    static func chanceToHit(_ move: Move, attacker: Fighter, defender: Fighter,
                            board: Board) -> Double {
        guard !move.neverMisses, move.accuracy > 0 else { return 100 }
        var chance = Double(move.accuracy)
        // The stages, which are the reason Sand Attack and Double Team are
        // moves at all. The game combines the two into one number and reads it
        // off a table based on three rather than two, so a stage of accuracy
        // is a third rather than a half -- which is why stacking them is worth
        // much less than it looks and why nobody runs a Double Team team.
        //
        // A Keen Eye or an Unaware looks straight through the dodging half; a
        // Mold Breaker does too, being a Mold Breaker.
        let blindToEvasion = attacker.build.ability == "Keen Eye"
            || attacker.build.ability == "Unaware"
            || attacker.build.ability == "Mold Breaker"
        func stage(_ which: Stage, of fighter: Fighter) -> Int {
            let held = fighter.build.boosts
            return held.indices.contains(which.rawValue) ? held[which.rawValue] : 0
        }
        let mine = stage(.accuracy, of: attacker)
        let theirs = blindToEvasion ? 0 : stage(.evasion, of: defender)
        let net = Swift.max(-6, Swift.min(6, mine - theirs))
        if net != 0 { chance *= Stage.accuracy.multiplier(net) }
        // What the sky does to a move's accuracy. Hurricane and Thunder are
        // certain in rain and half-blind in sun, and a Blizzard does not miss
        // in snow — which is most of the reason a rain team runs Thunder and a
        // snow team runs Blizzard at all. None of it was here, so a Hurricane
        // under a rain the team had built its whole turn around was still
        // rolling 70.
        switch board.field.weather {
        case .rain where move.id == "hurricane" || move.id == "thunder": return 100
        case .snow where move.id == "blizzard": return 100
        case .sun where move.id == "hurricane" || move.id == "thunder": chance = 50
        default: break
        }
        // No Guard makes everything land, from either side of it.
        if attacker.build.ability == "No Guard" || defender.build.ability == "No Guard" { return 100 }
        if attacker.build.ability == "Compound Eyes" { chance *= 1.3 }
        if attacker.build.ability == "Victory Star" { chance *= 1.1 }
        // A Wide Lens was being read when a set was scored and ignored when
        // the move was actually thrown, so the builder recommended it and the
        // battle pretended it was not there.
        if attacker.build.item == "Wide Lens" { chance *= 1.1 }
        if attacker.build.item == "Zoom Lens", defender.build.item != "" { chance *= 1.2 }
        // Nothing dodges a Keen Eye, and a Mold Breaker ignores the dodging
        // ability entirely.
        let blind = attacker.build.ability == "Keen Eye"
            || attacker.build.ability == "Mold Breaker" || attacker.build.ability == "Unaware"
        if !blind {
            if defender.build.item == "Bright Powder" { chance *= 0.9 }
            if defender.build.ability == "Sand Veil", board.field.weather == .sand { chance *= 0.8 }
            if defender.build.ability == "Snow Cloak", board.field.weather == .snow { chance *= 0.8 }
            if defender.build.ability == "Tangled Feet", defender.isConfused { chance *= 0.8 }
        }
        return Swift.max(1, Swift.min(100, chance))
    }
}
