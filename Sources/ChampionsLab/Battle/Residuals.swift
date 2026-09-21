//  Residuals.swift
//  What the end of a turn does to everyone, all at once.
//
//  Weather chip and weather healing, a Leftovers, the Grassy Terrain topping
//  up whoever is standing on it, poison and burn, a Leech Seed draining, a
//  Perish Song counting down, a Sitrus Berry going off, the clocks on every
//  field effect ticking. None of it was anybody's action; it is the field
//  acting on everyone who is still on it, and it lands together as one step
//  because that is how the game shows it and how the search should price it.
//
//  Order matters here more than it looks -- a Pokemon has to survive the sand
//  to eat its berry -- so this is one walk in one order, its phases numbered,
//  rather than twenty places each adding a line.

import Foundation

enum Residuals {
    /// Everything that happens after both sides have acted.
    ///
    /// Weather chips, berries and Leftovers fire, burn and poison take their
    /// cut, and the clocks tick. None of it existed: a sandstorm did nothing, a
    /// Sitrus Berry never healed, a Focus Sash worked every turn for ever
    /// because nothing ever marked it as used.
    ///
    /// Each phase below is one thing the end of a turn does, in the order the
    /// game does them. Every one is written against the board rather than a
    /// borrowed array: the running commentary needs the whole board to snapshot
    /// it, and Swift will not lend out one of its arrays while that happens.
    static func endOfTurn(_ board: inout Board, rolling: Bool) {
        settle(onMine: true, board: &board, rolling: rolling)
        settle(onMine: false, board: &board, rolling: rolling)
        landWish(onMine: true, board: &board)
        landWish(onMine: false, board: &board)
        fieldClocks(&board)
        symbiosis(&board)
        weatherHealing(&board)
        leechSeeds(&board)
        clocks(&board, rolling: rolling)
        turnOver(onMine: true, board: &board)
        turnOver(onMine: false, board: &board)
    }

    // MARK: - The phases of an end of turn

    /// 1. Each Pokemon still standing: the field and its own condition act on
    /// it, then its ability, then what it is holding, and only then does it
    /// faint if all of that took it to nothing. Order matters here more than
    /// it looks -- a Pokemon has to survive the sand to eat its berry -- so
    /// this is one walk in one order rather than twenty places each adding a
    /// line. `who` is the Pokemon as it stood when its turn came, and the
    /// phases read it as such; anything that must see the board as it is now
    /// reads the board.
    private static func settle(onMine mine: Bool, board: inout Board, rolling: Bool) {
        let count = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
        for index in 0..<count {
            guard !(mine ? board.mine[index] : board.theirs[index]).fainted else { continue }
            let who = mine ? board.mine[index] : board.theirs[index]
            var hp = who.hp
            weatherAndCondition(&hp, who: who, onMine: mine, slot: index, board: &board)
            ability(hp, who: who, onMine: mine, slot: index, board: &board, rolling: rolling)
            heldAndHealing(&hp, who: who, onMine: mine, slot: index, board: &board)
            if hp <= 0 {
                if mine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                board.note("\(who.build.form.formLabel) fainted.")
            }
        }
    }

    /// The sandstorm, the Grassy Terrain topping up whoever stands on it, and
    /// the condition it carries. Magic Guard takes nothing it was not hit by;
    /// Overcoat is the narrower version that only turns away the weather. A bad
    /// poison is a sixteenth more each turn it lasts, which is what makes Toxic
    /// a clock rather than chip damage.
    private static func weatherAndCondition(_ hp: inout Int, who: Fighter, onMine mine: Bool,
                                            slot index: Int, board: inout Board) {
        let name = who.build.form.formLabel
        let maxHP = who.maxHP
        let types = who.types
        let shielded = who.build.ability == "Magic Guard"
        if board.field.weather == .sand, !shielded,
           who.build.ability != "Overcoat", who.build.item != "Safety Goggles",
           !types.contains(where: { [.rock, .ground, .steel].contains($0) }) {
            hp -= Swift.max(1, maxHP / 16)
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("The sandstorm buffets \(name).")
        }
        if board.field.terrain == .grassy, who.isGrounded, hp < maxHP, hp > 0 {
            hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("Grassy Terrain tops \(name) up.")
        }
        switch who.status {
        case .burn where !shielded:
            hp -= Swift.max(1, maxHP / 16)
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("\(name) is hurt by its burn.")
        case .poison where !shielded:
            hp -= Swift.max(1, maxHP / 8)
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("\(name) is hurt by poison.")
        case .badPoison where !shielded:
            let stage = Swift.min(15, who.toxicTurns + 1)
            if mine { board.mine[index].toxicTurns = stage }
            else { board.theirs[index].toxicTurns = stage }
            hp -= Swift.max(1, maxHP * stage / 16)
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("\(name) is hurt badly by poison"
                       + (stage > 1 ? ", worse each turn." : "."))
        default: break
        }
    }

    /// What its ability does at the end of a turn. Speed Boost is a stage every
    /// turn it stays in, which is the whole reason a Blaziken is frightening if
    /// it is left alone. Shed Skin shakes a condition off one turn in three.
    /// Moody is a coin flip with six faces, which a search cannot price, so it
    /// takes nothing. Mimicry takes the terrain's type while it stands on it.
    /// Harvest brings the berry it ate back in the sun. Healer clears up
    /// whatever its partner is carrying one time in two; Hydration does the
    /// same for itself, only in the rain, and always.
    private static func ability(_ hp: Int, who: Fighter, onMine mine: Bool, slot index: Int,
                                board: inout Board, rolling: Bool) {
        let name = who.build.form.formLabel
        if who.build.ability == "Speed Boost", hp > 0, !who.justArrived,
           who.build.boosts[Stat.speed.rawValue] < 6 {
            StatChanges.change([.speed: 1], onMine: mine, slot: index, board: &board,
                   because: "Speed Boost")
        }
        if who.build.ability == "Shed Skin", hp > 0, who.status != .none,
           rolling, Double.random(in: 0..<1, using: &Dice.source) < 1.0 / 3.0 {
            if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
            else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
            board.note("\(name) shed its skin and shook it off.")
        }
        if who.build.ability == "Moody", hp > 0, rolling {
            // Every stage but health, accuracy and evasion among them, which
            // is what makes a Moody Pokemon the nuisance it is.
            let stats: [Stage] = [.attack, .defense, .spAttack, .spDefense, .speed,
                                  .accuracy, .evasion]
            if let up = stats.randomElement(using: &Dice.source),
               let down = stats.filter({ $0 != up }).randomElement(using: &Dice.source) {
                StatChanges.change([up: 2], onMine: mine, slot: index, board: &board, because: "Moody")
                StatChanges.change([down: -1], onMine: mine, slot: index, board: &board, because: "Moody")
            }
        }
        if who.build.ability == "Mimicry", hp > 0 {
            let became: PokeType? = switch board.field.terrain {
            case .electric: .electric
            case .grassy:   .grass
            case .psychic:  .psychic
            case .misty:    .fairy
            case .none:     nil
            }
            let wanted = became.map { [$0] } ?? []
            let holds = mine ? board.mine[index].build.typeOverride
                             : board.theirs[index].build.typeOverride
            if (holds ?? []) != wanted {
                if mine { board.mine[index].build.typeOverride = wanted.isEmpty ? nil : wanted }
                else { board.theirs[index].build.typeOverride = wanted.isEmpty ? nil : wanted }
                if let became {
                    board.note("\(name)'s Mimicry made it a \(became.rawValue) type.")
                }
            }
        }
        if who.build.ability == "Harvest", who.build.itemSpent, hp > 0,
           who.build.item.hasSuffix("Berry"),
           board.field.weather == .sun
               || (rolling && Double.random(in: 0..<1, using: &Dice.source) < 0.5) {
            if mine { board.mine[index].build.itemSpent = false }
            else { board.theirs[index].build.itemSpent = false }
            board.note("\(name) harvested another \(who.build.item).")
        }
        if who.build.ability == "Healer", hp > 0, rolling,
           Double.random(in: 0..<1, using: &Dice.source) < ChampionsRules.healer {
            let ally = index == 0 ? 1 : 0
            let side = mine ? board.mine : board.theirs
            if side.indices.contains(ally), ally < board.activeCount,
               !side[ally].fainted, side[ally].status != .none {
                if mine { board.mine[ally].status = .none; board.mine[ally].asleepFor = 0 }
                else { board.theirs[ally].status = .none; board.theirs[ally].asleepFor = 0 }
                board.note("\(name)'s Healer cleared up \(side[ally].build.form.formLabel).")
            }
        }
        if who.build.ability == "Hydration", hp > 0, who.status != .none,
           board.field.weather == .rain {
            if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
            else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
            board.note("\(name)'s Hydration washed it off.")
        }
    }

    /// What heals it, and what it is holding. An Aqua Ring and a Leftovers give
    /// a sixteenth back. A Sitrus Berry fires at half, which is already the
    /// threshold Gluttony would lower a pinch berry to -- and pinch berries are
    /// not modelled separately, so Gluttony has nothing here to bring forward;
    /// it reads as unproven in the audit, which is the honest answer. Ripen
    /// doubles whatever a berry gives, and Cheek Pouch is a second helping on
    /// top. A Mental Herb clears whatever is stopping it choosing freely; a Lum
    /// Berry is eaten the moment anything is wrong. Cud Chew brings a berry
    /// back up at the end of the turn after it was eaten, and reads the board
    /// fresh rather than `who`, which was copied before this turn's berry was
    /// eaten -- so the turn it ate one never counted, and the ability paid out
    /// one turn late for its whole life.
    private static func heldAndHealing(_ hp: inout Int, who: Fighter, onMine mine: Bool,
                                       slot index: Int, board: inout Board) {
        let name = who.build.form.formLabel
        let maxHP = who.maxHP
        if who.aquaRing, hp < maxHP, hp > 0 {
            hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("\(name)'s Aqua Ring restores a little.")
        }
        if who.build.item == "Leftovers", hp < maxHP, hp > 0 {
            hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
            if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
            board.note("\(name) restores a little with its Leftovers.")
        }
        if who.build.item == "Sitrus Berry", !who.build.itemSpent,
           Residuals.canEatBerry(mine, slot: index, board: board),
           hp > 0, hp <= maxHP / 2 {
            var back = maxHP / 4
            if who.build.ability == "Ripen" { back *= 2 }
            hp = Swift.min(maxHP, hp + back)
            if who.build.ability == "Cheek Pouch" {
                hp = Swift.min(maxHP, hp + maxHP / 3)
            }
            if mine {
                board.mine[index].hp = hp; board.mine[index].build.itemSpent = true
            } else {
                board.theirs[index].hp = hp; board.theirs[index].build.itemSpent = true
            }
            board.note("\(name) eats its Sitrus Berry."
                       + (who.build.ability == "Cheek Pouch" ? " Its Cheek Pouch gave more back." : ""))
        }
        if who.build.item == "Mental Herb", !who.build.itemSpent, hp > 0,
           who.tauntedFor > 0 || who.encoredFor > 0 {
            if mine {
                board.mine[index].tauntedFor = 0; board.mine[index].encoredFor = 0
                board.mine[index].build.itemSpent = true
            } else {
                board.theirs[index].tauntedFor = 0; board.theirs[index].encoredFor = 0
                board.theirs[index].build.itemSpent = true
            }
            board.note("\(name) used its Mental Herb and can choose freely again.")
        }
        if who.build.item == "Lum Berry", !who.build.itemSpent, hp > 0,
           Residuals.canEatBerry(mine, slot: index, board: board),
           who.status != .none || who.isConfused {
            if mine {
                board.mine[index].status = .none; board.mine[index].asleepFor = 0
                board.mine[index].confusedFor = 0; board.mine[index].build.itemSpent = true
            } else {
                board.theirs[index].status = .none; board.theirs[index].asleepFor = 0
                board.theirs[index].confusedFor = 0; board.theirs[index].build.itemSpent = true
            }
            board.note("\(name) eats its Lum Berry and shakes it off.")
        }
        let now = mine ? board.mine[index] : board.theirs[index]
        if now.build.ability == "Cud Chew", hp > 0 {
            if now.chewedOn {
                if mine { board.mine[index].build.itemSpent = false; board.mine[index].chewedOn = false }
                else { board.theirs[index].build.itemSpent = false; board.theirs[index].chewedOn = false }
                board.note("\(name)'s Cud Chew brought its \(now.build.item) back up.")
            } else if now.build.itemSpent, now.build.item.hasSuffix("Berry") {
                if mine { board.mine[index].chewedOn = true } else { board.theirs[index].chewedOn = true }
            }
        }
    }

    /// 2. A Wish comes down on whoever is standing in the spot now, which is
    /// the point of it: the one that made it can be long gone.
    private static func landWish(onMine mine: Bool, board: inout Board) {
        var side = mine ? board.myScreens : board.theirScreens
        guard side.wishTurns > 0 else { return }
        side.wishTurns -= 1
        if side.wishTurns == 0 {
            let amount = side.wishAmount
            side.wishAmount = 0
            let count = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
            for index in 0..<count {
                let who = mine ? board.mine[index] : board.theirs[index]
                guard !who.fainted, who.hp < who.maxHP else { continue }
                let gained = Swift.min(who.maxHP - who.hp, amount)
                if mine { board.mine[index].hp += gained } else { board.theirs[index].hp += gained }
                board.note("The wish came true and restored \(gained) to \(who.build.form.formLabel).")
            }
        }
        if mine { board.myScreens = side } else { board.theirScreens = side }
    }

    /// 3. The clocks on the field itself: the Tailwinds, Trick Room, the two
    /// Rooms, the weather and the terrain, and the screens. A clock at zero
    /// with something up is an analysis board's field, left alone.
    private static func fieldClocks(_ board: inout Board) {
        board.myTailwind = Swift.max(0, board.myTailwind - 1)
        board.theirTailwind = Swift.max(0, board.theirTailwind - 1)
        board.trickRoom = Swift.max(0, board.trickRoom - 1)
        if board.magicRoom > 0 {
            board.magicRoom -= 1
            if board.magicRoom == 0 { board.note("Magic Room wore off.") }
        }
        if board.wonderRoom > 0 {
            board.wonderRoom -= 1
            if board.wonderRoom == 0 { board.note("Wonder Room wore off.") }
        }
        if board.weatherTurns > 0 {
            board.weatherTurns -= 1
            if board.weatherTurns == 0 {
                let ended = board.field.weather
                board.field.weather = .none
                switch ended {
                case .sun: board.note("The sunlight faded.")
                case .rain: board.note("The rain stopped.")
                case .sand: board.note("The sandstorm subsided.")
                case .snow: board.note("The snow stopped.")
                case .none: break
                }
            }
        }
        if board.terrainTurns > 0 {
            board.terrainTurns -= 1
            if board.terrainTurns == 0 {
                let ended = board.field.terrain
                board.field.terrain = .none
                if ended != .none { board.note("The \(ended.rawValue.lowercased()) terrain disappeared.") }
            }
        }
        board.myScreens.tick()
        board.theirScreens.tick()
    }

    /// 4. Symbiosis: a partner hands its own item across the moment this one
    /// has nothing left to hold.
    private static func symbiosis(_ board: inout Board) {
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let team = side ? board.mine : board.theirs
                let partner = index == 0 ? 1 : 0
                guard team.indices.contains(partner), !team[index].fainted, !team[partner].fainted,
                      team[partner].build.ability == "Symbiosis",
                      team[index].build.itemSpent, !team[partner].build.item.isEmpty,
                      !team[partner].build.itemSpent else { continue }
                let given = team[partner].build.item
                if side {
                    board.mine[index].build.item = given
                    board.mine[index].build.itemSpent = false
                    board.mine[partner].build.item = ""
                } else {
                    board.theirs[index].build.item = given
                    board.theirs[index].build.itemSpent = false
                    board.theirs[partner].build.item = ""
                }
                board.note("\(team[partner].build.form.formLabel)'s Symbiosis passed its \(given) to \(team[index].build.form.formLabel).")
            }
        }
    }

    /// 5. Abilities that take something back from the weather, before the
    /// seeds take theirs.
    private static func weatherHealing(_ board: inout Board) {
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let who = (side ? board.mine : board.theirs)[index]
                guard !who.fainted, who.hp < who.maxHP else { continue }
                let weather = board.field.weather
                let healing = (who.build.ability == "Rain Dish" && weather == .rain)
                    || (who.build.ability == "Ice Body" && weather == .snow)
                    || (who.build.ability == "Dry Skin" && weather == .rain)
                guard healing else { continue }
                let gained = Swift.min(who.maxHP - who.hp, Swift.max(1, who.maxHP / 16))
                if side { board.mine[index].hp += gained } else { board.theirs[index].hp += gained }
                board.note("\(who.build.form.formLabel)'s \(who.build.ability) took \(gained) back from the weather.")
            }
        }
    }

    /// 6. Seeds drain across the field, to whoever is standing where the seed
    /// was thrown from. A seeded Pokemon that has fainted drains nothing.
    private static func leechSeeds(_ board: inout Board) {
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let seeded = (side ? board.mine : board.theirs)[index]
                guard let from = seeded.seededFrom, !seeded.fainted else { continue }
                let taken = Swift.max(1, seeded.maxHP / 8)
                let name = seeded.build.form.formLabel
                if side { board.mine[index].hp = Swift.max(0, board.mine[index].hp - taken) }
                else { board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - taken) }
                var line = "\(name) had \(taken) drained by the seed."
                let other = side ? board.theirs : board.mine
                if other.indices.contains(from), !other[from].fainted {
                    let healed = Swift.min(other[from].maxHP - other[from].hp, taken)
                    if healed > 0 {
                        if side { board.theirs[from].hp += healed } else { board.mine[from].hp += healed }
                        line += " \(other[from].build.form.formLabel) took it back."
                    }
                }
                board.note(line)
                if (side ? board.mine : board.theirs)[index].fainted {
                    board.note("\(name) fainted.")
                }
            }
        }
    }

    /// 8. The turn is over for every Pokemon on a side, bench included: what
    /// Protect covered, the taunt running down, the streaks, whether it counts
    /// as just arrived next turn, a Helping Hand spent, and the sleep counter
    /// -- Early Bird sleeps through half of it. The turn Protect was used on is
    /// the turn it covers; it used to be cleared at the top of the next resolve
    /// instead, which blocked nothing, but left the flag standing on the board
    /// handed back, so the shield stayed drawn over a Pokemon that was open
    /// again. A Pokemon that arrived partway through this turn has its first
    /// turn next, so that flag has to survive to reach it.
    private static func turnOver(onMine mine: Bool, board: inout Board) {
        // Who is actually standing out there. Most of what this loop clears is
        // cleared again by `depart` on the way to the bench, so running it over
        // the whole team costs nothing -- but sleep is the one thing here that
        // deliberately survives leaving the field, so it is the one thing that
        // must not run while benched.
        let onField = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
        for index in (mine ? board.mine : board.theirs).indices {
            var fighter = mine ? board.mine[index] : board.theirs[index]
            fighter.protectedLast = fighter.isProtected
            if !fighter.isProtected { fighter.protectStreak = 0 }
            fighter.isProtected = false
            fighter.enduring = false
            if fighter.tauntedFor > 0 {
                fighter.tauntedFor -= 1
                if fighter.tauntedFor == 0 {
                    if mine { board.mine[index] = fighter } else { board.theirs[index] = fighter }
                    board.note("\(fighter.build.form.formLabel) shook off the taunt.")
                }
            }
            if fighter.lastMove.map({ fighter.moves.indices.contains($0)
                && fighter.moves[$0].name == "Ally Switch" }) != true {
                fighter.switchStreak = 0
            }
            fighter.justArrived = fighter.arrivedThisTurn
            fighter.helped = false
            // Sleep runs down on the field and nowhere else. A Pokemon put to
            // sleep and switched out keeps every turn of it, so sitting on the
            // bench was never a way to wait the sleep off -- and it had been,
            // which let a three-turn sleep expire behind a single pivot.
            if fighter.asleepFor > 0, index < onField {
                let quick = fighter.build.ability == "Early Bird"
                fighter.asleepFor -= quick ? 2 : 1
                if fighter.asleepFor <= 0 {
                    fighter.asleepFor = 0
                    fighter.status = .none
                }
            }
            if mine { board.mine[index] = fighter } else { board.theirs[index] = fighter }
        }
    }

    /// 7. The clocks that run on a Pokemon standing on the field, both sides at
    /// once because they all land together at the end of a turn.
    ///
    /// Order is the order the game takes them in, and it matters: Octolock
    /// grinds first, then Yawn takes hold, and the song is last because a
    /// Pokémon the song takes is not around to be made drowsy.
    private static func clocks(_ board: inout Board, rolling: Bool) {
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                guard !(side ? board.mine : board.theirs)[index].fainted else { continue }
                let name = (side ? board.mine : board.theirs)[index].build.form.formLabel

                // Octolock: a stage off each defence, every turn it stays.
                if (side ? board.mine : board.theirs)[index].octolocked {
                    StatChanges.change([.defense: -1, .spDefense: -1], onMine: side, slot: index,
                           board: &board, because: "Octolock")
                }

                // Disable runs down and lets the move back.
                if (side ? board.mine : board.theirs)[index].disabledFor > 0 {
                    if side { board.mine[index].disabledFor -= 1 } else { board.theirs[index].disabledFor -= 1 }
                    if (side ? board.mine : board.theirs)[index].disabledFor == 0 {
                        if side { board.mine[index].disabled = nil } else { board.theirs[index].disabled = nil }
                        board.note("\(name) can use its move again.")
                    }
                }

                // Yawn comes due: drowsy this turn, asleep at the end of the next.
                if (side ? board.mine : board.theirs)[index].drowsyFor > 0 {
                    if side { board.mine[index].drowsyFor -= 1 } else { board.theirs[index].drowsyFor -= 1 }
                    if (side ? board.mine : board.theirs)[index].drowsyFor == 0 {
                        let who = side ? board.mine[index] : board.theirs[index]
                        if who.status == .none, !Ailments.sleepRefused(who, board: board) {
                            let nap = Ailments.sleepTurns(rolling: rolling)
                            if side { board.mine[index].status = .sleep; board.mine[index].asleepFor = nap }
                            else { board.theirs[index].status = .sleep; board.theirs[index].asleepFor = nap }
                            board.note("\(name) fell asleep.")
                        }
                    }
                }

                // And the song. Three turns from the singing, whatever is
                // still standing goes, however much health it has.
                if (side ? board.mine : board.theirs)[index].perishIn > 0 {
                    if side { board.mine[index].perishIn -= 1 } else { board.theirs[index].perishIn -= 1 }
                    let left = (side ? board.mine : board.theirs)[index].perishIn
                    if left == 0 {
                        if side { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                        board.note("\(name)'s song came due. It fainted.")
                    } else {
                        board.note("\(name)'s song: \(left) turn\(left == 1 ? "" : "s") left.")
                    }
                }

                // Destiny Bond covers the turn it was used on and no longer.
                if side { board.mine[index].destinyBound = false }
                else { board.theirs[index].destinyBound = false }
            }
        }
    }

    /// Whether a Pokémon can use the berry it is holding. An Unnerve on the
    /// other side is the whole of this: nothing eats while it is watching.
    static func canEatBerry(_ side: Bool, slot: Int, board: Board) -> Bool {
        let others = side ? board.theirs : board.mine
        for index in 0..<Swift.min(board.activeCount, others.count)
        where !others[index].fainted
            && ["Unnerve", "As One", "As One (Glastrier)", "As One (Spectrier)"]
                .contains(others[index].build.ability) {
            return false
        }
        return true
    }
}
