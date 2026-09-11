//  Statuses.swift
//  What the statuses in Serebii's effect text actually mean.
//
//  Move descriptions name a status and leave it there — "The user gains the
//  Wide Open status until the next time it takes an action" says nothing about
//  Wide Open doubling the damage you take, which is the entire reason Glaive
//  Rush is a risk. The glossary fills that in underneath the effect.
//
//  Only statuses whose behaviour is certain are listed. Serebii's naming is its
//  own, and a handful ("Def Swapped", "Escape") cannot be mapped to a mechanic
//  with confidence from the text alone; those are left out rather than guessed
//  at, since a wrong explanation is worse than a missing one.

import Foundation

enum Statuses {
    static let glossary: [String: String] = [
        // -- volatile, on the Pokémon itself ---------------------------------
        "Wide Open": "Until it next takes an action, attacks against it cannot miss and deal double damage. This is what Glaive Rush costs you.",
        "Recharging": "It must spend its next turn doing nothing. Hyper Beam and Giga Impact cannot simply be clicked again.",
        "Charging": "It spends this turn charging and attacks on the following one, so the opponent gets a free turn to switch or knock it out.",
        "Rampaging": "Locked into repeating the move for two or three turns, then confused when it ends. In doubles the target it was aimed at is usually long gone.",
        "Bound": "Trapped for four or five turns, losing HP each turn, and it cannot switch out.",
        "Leech Seeded": "Loses HP each turn, and that HP is given to the Pokémon across from it.",
        "Cursed": "Loses a quarter of its maximum HP at the end of every turn.",
        "Salt Cured": "Loses HP each turn, and much faster if it is a Steel or Water type.",
        "Perishing": "Faints in three turns unless it switches out first. Both sides are usually affected.",
        "Infatuated": "Has a chance to do nothing each turn, as long as the Pokémon that caused it is still out.",
        "Taunted": "Cannot use status moves for several turns — no Protect, no Tailwind, no Trick Room.",
        "Encore": "Forced to repeat its last move for the next few turns, which is why it cancels a setup turn.",
        "Move Disabled": "Its last-used move cannot be selected for several turns.",
        "Throat Chopped": "Cannot use sound-based moves for two turns.",
        "Jaw Locked": "Neither it nor the Pokémon that locked it can switch out until one of them faints.",
        "Fairy Locked": "Cannot switch out on the following turn.",
        "Sealing Off": "Neither opponent can use any move that the Pokémon applying it also knows.",
        "Healing Prevented": "Cannot recover HP by any means for several turns.",
        "Locked On": "The next attack against it cannot miss.",
        "Minimized": "Has raised its own evasiveness, but certain moves hit it for double damage instead.",
        "Landed": "Has been forced to the ground: it loses any Flying-type or Levitate immunity to Ground moves.",
        "Stockpiling": "Has stored up charges that raise its defences and power up Spit Up or Swallow.",
        "Syrupy": "Its Speed drops a stage at the end of every turn.",
        "Uproar": "Locked into attacking for several turns, and nothing on the field can fall asleep while it lasts.",
        "No Ability": "Its ability has been suppressed and does nothing.",
        "Electric Boost": "Its next Electric-type move has double power.",
        "Magnet Rise": "Floating, so Ground moves cannot touch it.",
        "Aqua Ring": "Recovers a small amount of HP at the end of every turn.",
        "Ingrained": "Recovers HP each turn but can no longer switch out.",
        "Destiny Bound": "If it faints this turn, whatever knocked it out faints with it.",
        "Forest Cursed": "Has had Grass added to its types, so it now takes Grass-type weaknesses as well.",
        "Trick-or-Treating": "Has had Ghost added to its types, so Normal and Fighting moves no longer touch it.",

        // -- semi-invulnerable ------------------------------------------------
        "Sky-High": "Airborne and out of reach for a turn. Only a few moves, and Thunder or Hurricane, can reach it.",
        "Underground": "Burrowed and out of reach for a turn, though Earthquake hits it for double.",
        "Submerged": "Underwater and out of reach for a turn, though Surf and Whirlpool hit it for double.",
        "Concealed": "Vanished from the field for a turn; almost nothing can reach it until it reappears.",

        // -- side conditions ---------------------------------------------------
        "Tailwind": "Doubles the Speed of everything on that side for four turns.",
        "Light Screen": "Halves special damage against that side — a third off in doubles — for five turns.",
        "Reflect": "Halves physical damage against that side — a third off in doubles — for five turns.",
        "Aurora Veil": "Does the work of both screens at once, but can only be set while snow is up.",
        "Safeguard": "Blocks status conditions on that side for five turns.",
        "Wish": "Heals whatever is in that slot at the end of the following turn.",
        "Future Attack": "Lands on that slot two turns later, whatever is standing in it by then.",

        // -- entry hazards ------------------------------------------------------
        "Spikes": "Damages grounded Pokémon as they switch in, stacking up to three layers.",
        "Toxic Spikes": "Poisons grounded Pokémon as they switch in. A grounded Poison type removes it.",
        "Stealth Rock": "Damages everything that switches in, scaled by its Rock-type weakness.",
        "Sticky Web": "Drops the Speed of grounded Pokémon as they switch in.",

        // -- whole-field --------------------------------------------------------
        "Trick Room": "Reverses the Speed order for five turns, so the slowest Pokémon moves first.",
        "Gravity": "Grounds everything for five turns and makes most moves more accurate. Flying types lose their Ground immunity.",
        "Magic Room": "Held items stop working for five turns.",
        "Wonder Room": "Defense and Sp. Def are swapped for everything on the field for five turns.",
    ]

    /// Statuses named in a move's effect text, in the order they appear.
    ///
    /// Matched longest-first so "Toxic Spikes" is not reported as "Spikes", and
    /// only where the word "status" follows, which is how Serebii writes them.
    static func mentioned(in effect: String) -> [(name: String, meaning: String)] {
        guard effect.contains("status") || effect.contains("Status") else { return [] }
        var found: [(Int, String, String)] = []
        var claimed: [Range<String.Index>] = []
        for name in glossary.keys.sorted(by: { $0.count > $1.count }) {
            guard let range = effect.range(of: name),
                  !claimed.contains(where: { $0.overlaps(range) }) else { continue }
            // Only when it is being used as a status, not in passing.
            let after = effect[range.upperBound...].prefix(40)
            guard after.hasPrefix(" status") || after.hasPrefix(" and ")
                    || after.hasPrefix(" Stealth") || after.hasPrefix(" Spikes")
                    || after.hasPrefix(" Reflect") || after.hasPrefix(" Aurora") else { continue }
            claimed.append(range)
            found.append((effect.distance(from: effect.startIndex, to: range.lowerBound),
                          name, glossary[name]!))
        }
        return found.sorted { $0.0 < $1.0 }.map { (name: $0.1, meaning: $0.2) }
    }
}
