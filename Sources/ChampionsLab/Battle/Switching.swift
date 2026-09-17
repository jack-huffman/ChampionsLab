//  Switching.swift
//  Everything that happens when a Pokemon enters or leaves the field.
//
//  Switching is most of competitive doubles and it is not merely a way out.
//  The Pokemon coming in takes a free hit, because it does not act on the turn
//  it arrives; that cost is paid by resolving switches before anything is
//  thrown. And arriving is itself an action: an Intimidate takes an Attack
//  stage off both opponents, a Drizzle takes the weather back, a Psychic Surge
//  turns off the other side's Fake Out. Leaving has its own rules too -- a
//  Regenerator heals a third on the way out, a Natural Cure drops its status,
//  an Emergency Exit leaves whether it meant to or not.
//
//  Mega Evolution is here as well, because it is an entrance the Pokemon makes
//  without moving: the new form's ability fires exactly as it would on
//  arrival, which is why a Salamence evolving mid-turn changes the weather
//  war the same way a Pelipper switching in does.

import Foundation

enum Switching {
    /// Turn one Pokémon into its Mega, with whatever that brings with it.
    ///
    /// Only one per side per battle, which is the rule the whole format is
    /// built around, so evolving marks the rest of the team as having spent it.
    static func megaEvolve(_ team: inout [Fighter], slot: Int,
                                   opposing: inout [Fighter], field: inout Field) {
        guard team.indices.contains(slot), let mega = team[slot].pendingMega,
              !team[slot].hasMegaEvolved,
              !team.contains(where: { $0.hasMegaEvolved }) else { return }
        let before = team[slot].build
        team[slot].build = Combatant(form: mega,
                                     ability: mega.abilities.first?.name ?? before.ability,
                                     item: before.item, sp: before.sp,
                                     alignment: before.alignment)
        team[slot].build.boosts = before.boosts
        team[slot].build.itemSpent = before.itemSpent
        team[slot].pendingMega = nil
        for index in team.indices { team[index].hasMegaEvolved = true }
        entryAbility(of: team[slot].build.ability, team: &team, slot: slot,
                     opposing: &opposing, field: &field)
    }

    /// What arriving — or evolving — does to the field and to the other side.
    /// What arriving does, and a line saying so — nil when the ability does
    /// nothing on the way in. Weather and terrain simply take the field, which
    /// is why the order two setters arrive in decides whose stays.
    @discardableResult
    static func entryAbility(of ability: String, team: inout [Fighter], slot: Int,
                                         opposing: inout [Fighter], field: inout Field) -> String? {
        let name = team.indices.contains(slot) ? team[slot].build.form.formLabel : "It"
        switch ability {
        case "Curious Medicine":
            // Wipes its own side's stat changes on the way in, which is a cost
            // as often as it is a cure.
            var cleared: [String] = []
            for index in team.indices.prefix(2)
            where !team[index].fainted && team[index].build.boosts.contains(where: { $0 != 0 }) {
                team[index].build.boosts = Array(repeating: 0, count: 6)
                cleared.append(team[index].build.form.formLabel)
            }
            guard !cleared.isEmpty else { return nil }
            return "\(name)'s Curious Medicine reset \(cleared.joined(separator: " and "))."
        case "Trace":
            // Takes an ability from across the field, which is why a Gardevoir
            // can walk in and suddenly have Intimidate. Not everything can be
            // copied; the ones that cannot are the ones tied to a particular
            // Pokémon being that Pokémon.
            let untraceable: Set<String> = [
                "Trace", "Illusion", "Multitype", "Stance Change", "Zen Mode",
                "Battle Bond", "Power Construct", "Schooling", "Disguise",
                "Zero to Hero", "Hunger Switch", "Comatose", "Imposter",
                "Neutralizing Gas", "Forecast", "Flower Gift", "Receiver",
            ]
            guard team.indices.contains(slot) else { return nil }
            let taken = opposing.prefix(2).first {
                !$0.fainted && !$0.build.ability.isEmpty
                    && !untraceable.contains($0.build.ability)
            }
            guard let taken else { return nil }
            team[slot].build.ability = taken.build.ability
            return "\(name)'s Trace copied \(taken.build.form.formLabel)'s \(taken.build.ability)."
        case "Intimidate":
            var cut: [String] = [], shrugged: [String] = [], rallied: [String] = []
            for index in opposing.indices.prefix(2) where !opposing[index].fainted {
                let other = opposing[index].build.form.formLabel
                switch opposing[index].build.ability {
                case "Clear Body", "Hyper Cutter", "Inner Focus", "White Smoke",
                     "Full Metal Body", "Own Tempo", "Oblivious", "Scrappy":
                    shrugged.append(other)
                case "Guard Dog", "Contrary":
                    // Turns the drop into a raise.
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.attack.rawValue] + 1)
                    rallied.append("\(other)'s \(opposing[index].build.ability) turned it into a raise")
                case "Defiant":
                    // The drop lands, then Defiant answers with two stages.
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.attack.rawValue] + 1)
                    rallied.append("\(other)'s Defiant answered with two stages of Attack")
                case "Competitive":
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.max(-6, opposing[index].build.boosts[Stat.attack.rawValue] - 1)
                    opposing[index].build.boosts[Stat.spAttack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.spAttack.rawValue] + 2)
                    cut.append(other)
                    rallied.append("\(other)'s Competitive answered with two stages of Special Attack")
                default:
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.max(-6, opposing[index].build.boosts[Stat.attack.rawValue] - 1)
                    cut.append(other)
                }
            }
            var parts: [String] = []
            if !cut.isEmpty { parts.append("cut \(cut.joined(separator: " and "))'s Attack") }
            if !shrugged.isEmpty { parts.append("\(shrugged.joined(separator: " and ")) shrugged it off") }
            parts += rallied
            var herbs: [String] = []
            for index in opposing.indices.prefix(2) {
                if let herb = StatChanges.whiteHerb(&opposing[index]) { herbs.append(herb) }
            }
            guard !parts.isEmpty else { return nil }
            return "\(name)'s Intimidate " + parts.joined(separator: "; ") + "."
                + (herbs.isEmpty ? "" : " " + herbs.joined(separator: " "))
        case "Hospitality":
            // A quarter of the partner's health, the moment it walks in.
            let partner = slot == 0 ? 1 : 0
            guard team.indices.contains(partner), !team[partner].fainted else { return nil }
            let healed = Swift.min(team[partner].maxHP - team[partner].hp, team[partner].maxHP / 4)
            guard healed > 0 else { return nil }
            team[partner].hp += healed
            return "\(name) brought \(team[partner].build.form.formLabel) \(healed) health."
        default:
            // Weather and terrain on arrival, from the one table that says who
            // sets what. The words are the sim's own.
            if let weather = FieldSetters.weather(onArrivalWith: ability) {
                let same = field.weather == weather
                field.weather = weather
                return "\(name)'s \(ability) " + announced(weather, kept: same)
            }
            if let terrain = FieldSetters.terrain(onArrivalWith: ability) {
                field.terrain = terrain
                return "\(name)'s \(ability) \(announced(terrain))"
            }
            return nil
        }
    }

    /// What a weather arriving says, and what one already up says.
    private static func announced(_ weather: Weather, kept: Bool) -> String {
        switch weather {
        case .sun:  return kept ? "kept the sunlight harsh." : "made the sunlight harsh."
        case .rain: return kept ? "kept the rain falling." : "made it rain."
        case .sand: return kept ? "kept the sandstorm up." : "whipped up a sandstorm."
        case .snow: return kept ? "kept the snow falling." : "made it snow."
        case .none: return ""
        }
    }

    /// What a terrain arriving says.
    private static func announced(_ terrain: Terrain) -> String {
        switch terrain {
        case .electric: return "charged the field."
        case .grassy:   return "grew grass across the field."
        case .misty:    return "covered the field in mist."
        case .psychic:  return "made the field feel strange."
        case .none:     return ""
        }
    }

    /// Bring a benched Pokémon in, with whatever its entry does.
    ///
    /// Switching is most of competitive doubles and it is not merely a way out.
    /// The Pokémon coming in takes a free hit, because it does not act on the
    /// turn it arrives — that cost is paid by resolving switches first and then
    /// letting the attacks land on whoever is now standing there. And arriving
    /// is itself an action: Intimidate takes an Attack stage off both of them,
    /// and a weather or terrain setter takes the field back, which is why
    /// pivoting a Pelipper back in is a play rather than a retreat.
    /// Written against the board rather than against a borrowed array, because
    /// what walks in has to be charged for the hazards lying on its side of the
    /// field, and those live on the board.
    @discardableResult
    static func swapIn(mine side: Bool, active: Int, bench: Int,
                               board: inout Board) -> String? {
        var team = side ? board.mine : board.theirs
        var opposing = side ? board.theirs : board.mine
        var field = board.field
        defer {
            if side { board.mine = team; board.theirs = opposing }
            else { board.theirs = team; board.mine = opposing }
            board.field = field
        }
        guard team.indices.contains(active), team.indices.contains(bench),
              !team[bench].fainted else { return nil }
        // Natural Cure: whatever it was carrying is left on the field.
        if team[active].build.ability == "Natural Cure", !team[active].fainted,
           team[active].status != .none {
            team[active].status = .none
            team[active].asleepFor = 0
        }
        // Regenerator heals a third on the way out, which is what makes a
        // Regenerator pivot free where another Pokémon's costs it the chip.
        if team[active].build.ability == "Regenerator", !team[active].fainted {
            team[active].hp = Swift.min(team[active].maxHP,
                                        team[active].hp + team[active].maxHP / 3)
        }
        // Everything the field did to it is left on the field. Stat stages
        // especially: they were surviving a switch, so a Pokémon could set up,
        // pivot out and come back later still at +2.
        team[active].charging = nil
        team[active].hidden = false
        team[active].protectStreak = 0
        team[active].confusedFor = 0
        team[active].encoredFor = 0
        team[active].tauntedFor = 0
        team[active].seededFrom = nil
        team[active].critStage = 0
        team[active].lastMove = nil
        team[active].build.boosts = Array(repeating: 0, count: 6)
        team[active].substitute = 0
        team[active].infatuatedWith = nil
        team[active].tormented = false
        team[active].cannotEscape = false
        team[active].aquaRing = false
        team[active].stockpile = 0
        // The song does not follow to the bench, which is the whole counter to
        // Perish Song and the reason it is not simply a win button. The rest
        // go the same way: they were done to the Pokémon standing there.
        team[active].perishIn = 0
        team[active].drowsyFor = 0
        team[active].disabled = nil
        team[active].disabledFor = 0
        team[active].destinyBound = false
        team[active].octolocked = false
        team[active].build.typeOverride = nil
        team[active].build.statOverride = nil
        team.swapAt(active, bench)
        team[active].justArrived = true
        team[active].arrivedThisTurn = true
        team[active].seen = true
        team[active].isProtected = false

        let said = entryAbility(of: team[active].build.ability, team: &team, slot: active,
                                opposing: &opposing, field: &field)
        // Hazards bite before the ability speaks, so write the board back now.
        if side { board.mine = team; board.theirs = opposing } else { board.theirs = team; board.mine = opposing }
        board.field = field
        board.takeHazards(mine: side, slot: active)
        team = side ? board.mine : board.theirs
        opposing = side ? board.theirs : board.mine
        field = board.field
        return said
    }

    /// Emergency Exit and Wimp Out: dropping below half health sends the
    /// Pokémon out to whoever is waiting, mid-turn, without asking.
    ///
    /// Golisopod runs it, which is most of why anyone in this format meets it,
    /// and it changes what a turn against one is worth: hit it hard and it
    /// leaves, hit it for less than half and it stays and hits back.
    static func flee(ifNeeded slot: Int, ofMine mine: Bool, wasAt before: Int,
                             board: inout Board) {
        let team = mine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted,
              ["Emergency Exit", "Wimp Out"].contains(team[slot].build.ability) else { return }
        let now = team[slot].hp, maxHP = team[slot].maxHP
        // Crossed the line this hit, from at-or-above half to below it.
        guard before * 2 >= maxHP, now * 2 < maxHP else { return }
        guard let next = (board.activeCount..<team.count).first(where: { !team[$0].fainted })
        else { return }
        let name = team[slot].build.form.formLabel
        if mine { board.mine.swapAt(slot, next) } else { board.theirs.swapAt(slot, next) }
        let arrival = (mine ? board.mine : board.theirs)[slot].build.form.formLabel
        board.note("\(name)'s \(team[slot].build.ability) sent it out. \(arrival) came in.")
        board.landed(mine: mine, slot: slot)
    }

    /// A Pokémon leaving the field under its own move — Parting Shot, and
    /// whatever else pivots. Whoever is waiting comes in and does what
    /// arriving does.
    static func leave(byMine: Bool, slot: Int, board: inout Board) {
        let team = byMine ? board.mine : board.theirs
        guard let next = (board.activeCount..<team.count).first(where: { !team[$0].fainted }) else {
            board.note("\(team[slot].build.form.formLabel) had nowhere to go.")
            return
        }
        let leaving = team[slot].build.form.formLabel
        if byMine { board.mine.swapAt(slot, next) } else { board.theirs.swapAt(slot, next) }
        let arriving = (byMine ? board.mine : board.theirs)[slot].build.form.formLabel
        board.note("\(leaving) went out; \(arriving) came in.")
        board.landed(mine: byMine, slot: slot)
    }
}

// MARK: - Arriving on the field, as the Board does it

/// The Board's own arrival methods, kept here rather than in Board.swift.
///
/// `fillGaps`, `sendIn`, `replaceFallen` and `landed` are how a Pokemon reaches
/// the field, and everything a Pokemon does on reaching it -- taking the
/// hazards, its entry ability going off, being marked as seen and as able to
/// Fake Out -- is Switching's business. They stay methods on Board because
/// eighteen places already say `board.fillGaps()` and that reads correctly; but
/// the file they are written in is the one that owns what they do, so Board.swift
/// is state alone and names no aspect.
extension Board {
    /// Bring the next healthy Pokémon forward into an empty slot. Replacing a
    /// fainted Pokémon is not a turn, it happens at the end of one.
    /// `sides` says whose gaps to fill. A battle asks the player who comes in
    /// rather than choosing for them, so the interface fills only the opponent
    /// and then asks; a search fills both, because it has to keep going.
    mutating func fillGaps(mine fillMine: Bool = true, theirs fillTheirs: Bool = true) {
        for side in [true, false] where side ? fillMine : fillTheirs {
            let count = side ? mine.count : theirs.count
            for slot in 0..<min(activeCount, count) where (side ? mine : theirs)[slot].fainted {
                let team = side ? mine : theirs
                guard let next = (activeCount..<team.count).first(where: { !team[$0].fainted })
                else { continue }
                if side { mine.swapAt(slot, next) } else { theirs.swapAt(slot, next) }
                landed(mine: side, slot: slot)
            }
        }
    }

    /// A Pokémon has just reached the field: it is seen, it can Fake Out, and
    /// whatever it does on arrival happens now.
    mutating func landed(mine side: Bool, slot: Int) {
        let before = field
        takeHazards(mine: side, slot: slot)
        if (side ? mine[slot] : theirs[slot]).fainted { return }
        // Screen Cleaner takes down both sides' screens on the way in. Done
        // here rather than in `entryAbility`, which is handed two teams and a
        // field but never the screens.
        if (side ? mine[slot] : theirs[slot]).build.ability == "Screen Cleaner",
           myScreens.any || theirScreens.any {
            myScreens.reflect = 0; myScreens.lightScreen = 0; myScreens.auroraVeil = 0
            theirScreens.reflect = 0; theirScreens.lightScreen = 0; theirScreens.auroraVeil = 0
            note("\((side ? mine[slot] : theirs[slot]).build.form.formLabel)'s Screen Cleaner swept the screens away.")
        }
        if side {
            mine[slot].justArrived = true
            mine[slot].arrivedThisTurn = true
            mine[slot].seen = true
            mine[slot].isProtected = false
            mine[slot].lastMoveFailed = false
            if let said = Switching.entryAbility(of: mine[slot].build.ability, team: &mine,
                                                 slot: slot, opposing: &theirs, field: &field) {
                note(said)
            }
        } else {
            theirs[slot].justArrived = true
            theirs[slot].arrivedThisTurn = true
            theirs[slot].seen = true
            theirs[slot].isProtected = false
            theirs[slot].lastMoveFailed = false
            if let said = Switching.entryAbility(of: theirs[slot].build.ability, team: &theirs,
                                                 slot: slot, opposing: &mine, field: &field) {
                note(said)
            }
        }
        fieldSettled(from: before)
        terrainSeeds()
    }

    /// Their pick for a gap: the benched one that takes least from whatever
    /// of yours is standing, which is how the choice is made in `choices`.
    func theirBestReplacement(for slot: Int, excluding taken: Set<Int>) -> Int? {
        var best: (index: Int, worst: Double)?
        for index in activeCount..<theirs.count where !theirs[index].fainted && !taken.contains(index) {
            var worst = 0.0
            for foe in mine.prefix(activeCount) where !foe.fainted {
                for move in foe.moves where move.isDamaging {
                    let result = DamageCalc.calculate(attacker: foe.build, defender: theirs[index].build,
                                                      move: move, field: field)
                    worst = Swift.max(worst, Double(result.maxDamage) / Double(theirs[index].maxHP))
                }
            }
            if best == nil || worst < best!.worst { best = (index, worst) }
        }
        return best?.index
    }

    /// The end of a turn with something down on either side: both players
    /// send in at once, and the arrivals happen in Speed order — so the faster
    /// one's Intimidate never touches the slower one, and the slower one's
    /// weather is the weather. Yours are what you chose; theirs choose for
    /// themselves.
    mutating func replaceFallen(mine picks: [(slot: Int, bench: Int)]) {
        var arrivals: [(mine: Bool, slot: Int, bench: Int, speed: Int)] = []
        for pick in picks where mine.indices.contains(pick.bench) && !mine[pick.bench].fainted {
            arrivals.append((true, pick.slot, pick.bench, mine[pick.bench].build.speed(in: field)))
        }
        var taken: Set<Int> = []
        for slot in 0..<min(activeCount, theirs.count) where theirs[slot].fainted {
            guard let pick = theirBestReplacement(for: slot, excluding: taken)
            else { continue }
            taken.insert(pick)
            arrivals.append((false, slot, pick, theirs[pick].build.speed(in: field)))
        }
        arrivals.sort { $0.speed > $1.speed || ($0.speed == $1.speed && $0.mine && !$1.mine) }
        for arrival in arrivals {
            if arrival.mine {
                guard mine[arrival.slot].fainted else { continue }
                mine.swapAt(arrival.slot, arrival.bench)
                note("You sent in \(mine[arrival.slot].build.form.formLabel).")
            } else {
                guard theirs[arrival.slot].fainted else { continue }
                theirs.swapAt(arrival.slot, arrival.bench)
                note("They sent in \(theirs[arrival.slot].build.form.formLabel).")
            }
            landed(mine: arrival.mine, slot: arrival.slot)
        }
    }

    /// Bring one specific Pokémon in, which is the choice the game gives you.
    mutating func sendIn(_ bench: Int, to slot: Int) {
        guard mine.indices.contains(bench), mine.indices.contains(slot),
              !mine[bench].fainted, mine[slot].fainted else { return }
        mine.swapAt(slot, bench)
        landed(mine: true, slot: slot)
    }
}
