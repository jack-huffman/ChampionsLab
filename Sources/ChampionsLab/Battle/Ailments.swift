//  Ailments.swift
//  Status conditions, and what refuses them.
//
//  Confusion, flinching, and the things that stand between a Pokemon and a
//  status: a Safeguard, a Misty Terrain under a grounded target, an ability
//  like Inner Focus or Own Tempo, an Electric Terrain keeping the grounded
//  awake, a Synchronize handing the condition straight back. None of these
//  cares which move was responsible. A Fake Out and a Rock Slide's thirty
//  per cent both end in `flinch`; a Spore and a Sleep Powder and a Yawn all
//  end up asking `sleepRefused` the same question. So the rules about the
//  condition live with the condition, and the moves that cause one only have
//  to know its name.
//
//  Flinching is idempotent here on purpose. Two sources once announced the
//  same flinch twice and would have handed out two Steadfast boosts.

import Foundation

enum Ailments {
    /// Whether something cannot be put to sleep — the same rules Spore is held
    /// to, which is what Yawn has to ask before it comes due.
    static func sleepRefused(_ who: Fighter, board: Board) -> Bool {
        if who.build.ability == "Insomnia" || who.build.ability == "Vital Spirit" { return true }
        if who.build.ability == "Sweet Veil" || who.build.ability == "Comatose" { return true }
        if board.field.terrain == .electric && who.isGrounded { return true }
        if who.build.ability == "Leaf Guard" && board.field.weather == .sun { return true }
        return false
    }

    /// Leave a Pokémon confused for two to five turns, unless something on it
    /// or under it says no.
    static func confuse(onMine: Bool, slot: Int, board: inout Board, rolling: Bool, chance: Int) {
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let target = team[slot]
        let name = target.build.form.formLabel
        if target.isConfused { return }
        if target.build.ability == "Own Tempo" {
            board.note("\(name)'s Own Tempo kept it clear-headed.")
            return
        }
        if board.field.terrain == .misty, target.isGrounded {
            board.note("The mist kept \(name) from being confused.")
            return
        }
        // Two to five turns of it. The search takes the shortest, so it never
        // counts on more than the game guarantees.
        let turns = rolling ? Int.random(in: 2...5, using: &TurnModel.dice) : 2
        if onMine { board.mine[slot].confusedFor = turns } else { board.theirs[slot].confusedFor = turns }
        board.note("\(name) became confused" + (chance < 100 ? " — the \(chance)% came up." : "."))
    }

    /// Synchronize: a burn, a poison or a paralysis goes straight back to
    /// whoever handed it over.
    static func synchronize(_ ailment: Ailment, from side: Bool, slot victim: Int,
                                    onto other: Bool, slot giver: Int, board: inout Board) {
        let team = side ? board.mine : board.theirs
        guard team.indices.contains(victim),
              team[victim].build.ability == "Synchronize",
              [.burn, .poison, .badPoison, .paralysis].contains(ailment) else { return }
        let givers = other ? board.mine : board.theirs
        guard givers.indices.contains(giver), !givers[giver].fainted,
              givers[giver].status == .none else { return }
        if other { board.mine[giver].status = ailment } else { board.theirs[giver].status = ailment }
        board.note("\(team[victim].build.form.formLabel)'s Synchronize passed it back: "
                   + "\(givers[giver].build.form.formLabel) is \(ailment.rawValue).")
    }

    /// Make something flinch, and let a Steadfast take the Speed it is owed
    /// for the trouble.
    /// Make something flinch, if anything can.
    ///
    /// Inner Focus is checked here rather than at the call sites. It was
    /// guarded on the secondary-effect path only, so a Fake Out — the one move
    /// whose whole purpose is the flinch — went straight through the ability
    /// that exists to stop it.
    static func flinch(onMine: Bool, slot: Int, board: inout Board, because: String? = nil) {
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        // Already flinching. Nothing to add, and saying so twice reads as two
        // separate things having happened.
        guard !team[slot].flinched else { return }
        if team[slot].build.ability == "Inner Focus" {
            board.note("\(team[slot].build.form.formLabel)'s Inner Focus kept it going.")
            return
        }
        if onMine { board.mine[slot].flinched = true } else { board.theirs[slot].flinched = true }
        let name = team[slot].build.form.formLabel
        // Only say it here when there is something to explain — which roll came
        // up, whose ability did it. A flinch that simply happened is announced
        // where the game announces it, at the moment the Pokémon would have
        // moved and does not; saying it twice reads as two separate events.
        if let because { board.note("\(name) flinched — \(because).") }
        if team[slot].build.ability == "Steadfast" {
            StatChanges.change([.speed: 1], onMine: onMine, slot: slot, board: &board, because: "Steadfast")
        }
    }

    /// An ability on that side that turns a condition away, and its name.
    ///
    /// Leaf Guard covers everything but only in the sun. Sweet Veil and Flower
    /// Veil cover the whole side, and only against sleep — a Pokémon does not
    /// have to be the one carrying it.
    static func refusesStatus(_ ailment: Ailment, onMine: Bool, slot: Int,
                                      board: Board) -> String? {
        let side = onMine ? board.mine : board.theirs
        guard side.indices.contains(slot) else { return nil }
        if side[slot].build.ability == "Leaf Guard", board.field.weather == .sun {
            return "Leaf Guard"
        }
        if ailment == .sleep {
            // Sweet Veil covers the whole side; the other two are personal.
            for who in side.prefix(board.activeCount) where !who.fainted {
                if who.build.ability == "Sweet Veil" { return "Sweet Veil" }
            }
            if ["Vital Spirit", "Insomnia"].contains(side[slot].build.ability) {
                return side[slot].build.ability
            }
            if board.field.terrain == .electric, side[slot].build.grounded { return "Electric Terrain" }
        }
        return nil
    }
}
