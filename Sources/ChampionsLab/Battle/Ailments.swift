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
    /// How long a sleep lasts. Champions draws two turns a third of the time
    /// and three the rest; the search takes two, so it never counts on the
    /// long one. The one place the number is drawn, so Spore, Yawn and Effect
    /// Spore agree.
    static func sleepTurns(rolling: Bool) -> Int {
        rolling ? (ChampionsRules.sleepTurns.randomElement(using: &Dice.source) ?? ChampionsRules.sleepSearch)
                : ChampionsRules.sleepSearch
    }

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
        let turns = rolling ? Int.random(in: 2...5, using: &Dice.source) : 2
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
            if board.field.terrain == .electric, side[slot].build.grounded { return "\(Terrain.electric.rawValue) Terrain" }
        }
        return nil
    }

    /// Put a status condition on a Pokemon, or say why it did not take.
    ///
    /// The one door. A Thunder Wave and a Nuzzle's hundred per cent both come
    /// through here, which is the point: they used to be two tables in two
    /// files, and the tables had drifted. The status-move one had no Misty
    /// Terrain check at all, so a Will-O-Wisp went straight through the one
    /// terrain that exists to stop it, while a Scald's burn was refused. The
    /// secondary one had Ice types immune to Freeze; the status-move one did
    /// not. Neither was wrong about everything, and a Pokemon on the receiving
    /// end could not have said which one it was facing.
    ///
    /// Order, which is the game's: what the Pokemon *is* refuses first -- its
    /// types, its ability -- then what is on its side of the field, then what is
    /// under its feet. Returns whether it landed.
    ///
    /// `announceImmunity` is off for a secondary: a Scald into a Fire type
    /// happens all game and does not need a line each time. A status move that
    /// does nothing does, because the player clicked it for that.
    @discardableResult
    static func inflict(_ ailment: Ailment, onMine: Bool, slot: Int,
                        byMine: Bool, bySlot: Int,
                        board: inout Board, rolling: Bool,
                        because: String? = nil, announceImmunity: Bool = true) -> Bool {
        let side = onMine ? board.mine : board.theirs
        let attackers = byMine ? board.mine : board.theirs
        guard side.indices.contains(slot), !side[slot].fainted, ailment != .none else { return false }
        let victim = side[slot]
        let name = victim.build.form.formLabel
        guard victim.status == .none else {
            if announceImmunity { board.note("It had no effect on \(name).") }
            return false
        }
        // The types the battle gave it, not the ones the dex printed: a Soaked
        // Garchomp really can be burned like a Water type.
        let types = victim.types
        let ability = victim.build.ability
        let corrodes = attackers.indices.contains(bySlot)
            && attackers[bySlot].build.ability == "Corrosion"
        let immune: Bool
        switch ailment {
        case .burn:
            immune = types.contains(.fire)
                || ["Water Veil", "Water Bubble", "Thermal Exchange"].contains(ability)
        case .paralysis:
            immune = types.contains(.electric) || ability == "Limber"
        case .poison, .badPoison:
            // Corrosion poisons the two types that cannot normally be.
            immune = (!corrodes && types.contains(where: { [.poison, .steel].contains($0) }))
                || ability == "Immunity"
        case .freeze:
            immune = types.contains(.ice) || ability == "Magma Armor"
        case .sleep:
            immune = ["Insomnia", "Vital Spirit"].contains(ability)
                || (board.field.terrain == .electric && victim.isGrounded)
        case .none:
            immune = true
        }
        if immune {
            if announceImmunity { board.note("\(name) is not affected.") }
            return false
        }
        if (onMine ? board.myScreens : board.theirScreens).safeguard > 0 {
            board.note("The veil kept \(name) from being \(ailment.rawValue).")
            return false
        }
        if let refused = refusesStatus(ailment, onMine: onMine, slot: slot, board: board) {
            board.note("\(name)'s \(refused) kept it from being \(ailment.rawValue).")
            return false
        }
        if board.field.terrain == .misty, victim.isGrounded {
            board.note("The mist kept \(name) from being \(ailment.rawValue).")
            return false
        }
        // It takes. Sleep and freeze carry their clocks from here, so every
        // way of inflicting them agrees on how long they last.
        let nap = ailment == .sleep ? sleepTurns(rolling: rolling) : 0
        let frozen = ailment == .freeze ? ChampionsRules.frozenFor : 0
        if onMine {
            board.mine[slot].status = ailment
            board.mine[slot].asleepFor = nap
            board.mine[slot].frozenFor = frozen
        } else {
            board.theirs[slot].status = ailment
            board.theirs[slot].asleepFor = nap
            board.theirs[slot].frozenFor = frozen
        }
        board.note("\(name) was \(ailment.rawValue)" + (because.map { " — \($0)." } ?? "."))
        // Synchronize hands the condition straight back, whoever caused it.
        synchronize(ailment, from: onMine, slot: slot, onto: byMine, slot: bySlot, board: &board)
        return true
    }
}
