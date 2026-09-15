//  Opening.swift
//  What a lead pair does to the other one before anybody has attacked.
//
//  The picker chose its leads on a damage race: whether the pair could knock
//  something out on turn one, and whether the other pair could do it back. That
//  is a real consideration and it is not the one people actually talk about.
//  What they say is closer to:
//
//      "I'll lead Farigiraf into that, they always open Fake Out."
//      "Lead the Tailwind, I need to be faster before anything else happens."
//      "Careful, both of their leads have Intimidate."
//
//  None of which is damage. It is a game of counters played before a single
//  attack lands: a Fake Out takes a turn off you, an Armor Tail takes the Fake
//  Out off them, an Intimidate makes their physical lead hit softer, and the
//  side that wins that exchange starts the middle game a tempo up.
//
//  This scores that exchange. It is deliberately about turn one only — every
//  one of these things is worth most, or worth only, on the turn the leads meet.

import Foundation

struct Opening {
    /// What this pair does to the other, and what it suffers. Both in the
    /// reader's own words, because the point of them is to be read.
    var gains: [String] = []
    var losses: [String] = []
    /// Roughly −1…1, on the same scale as `TurnOne.value`, which it is added to.
    var value: Double = 0

    /// One side of the field, reduced to the things that matter before anybody
    /// attacks.
    struct Side {
        let forms: [Form]
        let abilities: [String]
        let moves: [Set<String>]

        var hasFakeOut: Bool { moves.contains { $0.contains("Fake Out") } }
        var setsSpeed: Bool {
            moves.contains { $0.contains("Tailwind") || $0.contains("Trick Room") }
        }
        var redirects: Bool {
            moves.contains { $0.contains("Follow Me") || $0.contains("Rage Powder") }
        }
        var intimidators: Int { abilities.filter { $0 == "Intimidate" }.count }

        /// Nothing with priority reaches this side: Armor Tail and its kin turn
        /// off the whole bracket, which is what makes a Farigiraf lead an
        /// answer to a Fake Out lead rather than merely a body.
        var blocksPriority: Bool {
            abilities.contains { ["Armor Tail", "Queenly Majesty", "Dazzling"].contains($0) }
                || abilities.contains("Psychic Surge")
        }

        /// Whether a Fake Out aimed at this side can be relied on to land on
        /// *something*. A Ghost is immune to it outright, and Inner Focus or a
        /// Covert Cloak refuses the flinch.
        var flinchable: Bool {
            guard !blocksPriority else { return false }
            return forms.indices.contains { index in
                let form = forms[index]
                if form.pokeTypes.contains(.ghost) { return false }
                let ability = index < abilities.count ? abilities[index] : ""
                return !["Inner Focus", "Own Tempo", "Oblivious", "Shield Dust"].contains(ability)
            }
        }

        /// How much an Intimidate is worth against this side, from none to one.
        /// A pair of special attackers barely notices it.
        var physicality: Double {
            guard !forms.isEmpty else { return 0 }
            let physical = forms.filter { $0.attack >= $0.spAttack }.count
            return Double(physical) / Double(forms.count)
        }

        /// Abilities that make an Intimidate a mistake rather than a gain.
        var punishesIntimidate: Bool {
            abilities.contains { ["Defiant", "Competitive", "Guard Dog"].contains($0) }
        }
        var shrugsIntimidate: Bool {
            abilities.contains { ["Clear Body", "Hyper Cutter", "White Smoke",
                                  "Full Metal Body", "Inner Focus", "Own Tempo",
                                  "Oblivious", "Scrappy"].contains($0) }
        }
    }

    static func side(_ forms: [Form], pairs: [(TeamSlot, Form)], rules: Rulebook) -> Side {
        var abilities: [String] = []
        var moves: [Set<String>] = []
        for form in forms {
            let slot = pairs.first { $0.1.id == form.id }?.0
            abilities.append(slot?.ability ?? form.abilities.first?.name ?? "")
            moves.append(Set((slot?.moves ?? []).compactMap { rules.move($0)?.name }))
        }
        return Side(forms: forms, abilities: abilities, moves: moves)
    }

    /// Score the exchange from the point of view of `mine`.
    static func read(mine: Side, theirs: Side) -> Opening {
        var out = Opening()

        // -- the flinch, and the answer to it ---------------------------------
        //
        // A Fake Out that lands is a whole action taken off the other side on
        // the turn that decides the most. Blocking one is worth the same thing
        // from the other direction, which is why a Pokemon whose whole job is
        // to turn priority off is a lead rather than a body.
        if mine.hasFakeOut {
            if theirs.blocksPriority {
                out.losses.append("their side turns priority off, so your Fake Out does nothing")
                out.value -= 0.20
            } else if theirs.flinchable {
                out.gains.append("your Fake Out takes a turn off them")
                out.value += 0.35
            }
        }
        if theirs.hasFakeOut {
            if mine.blocksPriority {
                out.gains.append("you turn priority off, so their Fake Out does nothing")
                out.value += 0.30
            } else if mine.flinchable {
                out.losses.append("their Fake Out takes a turn off you")
                out.value -= 0.35
            }
        }

        // -- Intimidate -------------------------------------------------------
        //
        // Worth what the other side is physical, and a mistake into the
        // abilities that answer it: a Defiant lead is *better* off for having
        // been Intimidated.
        if mine.intimidators > 0 {
            if theirs.punishesIntimidate {
                out.losses.append("their lead answers Intimidate, which hands them a stage")
                out.value -= 0.25
            } else if theirs.shrugsIntimidate {
                out.losses.append("their lead shrugs Intimidate off")
            } else if theirs.physicality > 0 {
                let worth = 0.28 * theirs.physicality * Double(min(mine.intimidators, 2))
                out.gains.append("your Intimidate takes the edge off their attackers")
                out.value += worth
            }
        }
        if theirs.intimidators > 0, !mine.punishesIntimidate, !mine.shrugsIntimidate,
           mine.physicality > 0 {
            out.losses.append("their Intimidate takes the edge off yours")
            out.value -= 0.28 * mine.physicality * Double(min(theirs.intimidators, 2))
        }

        // -- getting there first ----------------------------------------------
        //
        // Speed control set on turn one shapes every turn after it. Worth less
        // when they are setting it too, because then it is a race rather than
        // an advantage.
        if mine.setsSpeed {
            out.gains.append("you can have speed control up from turn one")
            out.value += theirs.setsSpeed ? 0.10 : 0.22
        }
        if theirs.setsSpeed, !mine.setsSpeed {
            out.losses.append("they set speed control and you cannot answer it")
            out.value -= 0.18
        }

        // -- redirection ------------------------------------------------------
        if mine.redirects {
            out.gains.append("you can pull their attacks onto the one that can take them")
            out.value += 0.15
        }
        if theirs.redirects {
            out.losses.append("they can pull your attacks off the target you want")
            out.value -= 0.12
        }
        return out
    }
}
