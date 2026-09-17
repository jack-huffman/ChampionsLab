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
//  to eat its berry -- so this is one function walking one list, rather than
//  twenty places each adding a line.

import Foundation

enum Residuals {
    /// Everything that happens after both sides have acted.
    ///
    /// Weather chips, berries and Leftovers fire, burn and poison take their
    /// cut, and the clocks tick. None of it existed: a sandstorm did nothing, a
    /// Sitrus Berry never healed, a Focus Sash worked every turn for ever
    /// because nothing ever marked it as used.
    static func endOfTurn(_ board: inout Board, rolling: Bool) {
        // Written against the board rather than against a borrowed array: the
        // running commentary needs the whole board to snapshot it, and Swift
        // will not lend out one of its arrays while that is happening.
        func settle(mine: Bool) {
            let count = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
            for index in 0..<count {
                guard !(mine ? board.mine[index] : board.theirs[index]).fainted else { continue }
                let who = mine ? board.mine[index] : board.theirs[index]
                let name = who.build.form.formLabel
                let maxHP = who.maxHP
                let types = who.types
                var hp = who.hp

                // Magic Guard takes nothing it was not hit by; Overcoat is
                // the narrower version that only turns away the weather.
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
                    // A sixteenth more each turn it lasts, which is what makes
                    // Toxic a clock rather than chip damage.
                    let stage = Swift.min(15, who.toxicTurns + 1)
                    if mine { board.mine[index].toxicTurns = stage }
                    else { board.theirs[index].toxicTurns = stage }
                    hp -= Swift.max(1, maxHP * stage / 16)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt badly by poison"
                               + (stage > 1 ? ", worse each turn." : "."))
                default: break
                }
                // Speed Boost: a stage every turn it stays in, which is the
                // whole reason a Blaziken is frightening if it is left alone.
                if who.build.ability == "Speed Boost", hp > 0, !who.justArrived,
                   who.build.boosts[Stat.speed.rawValue] < 6 {
                    StatChanges.change([.speed: 1], onMine: mine, slot: index, board: &board,
                           because: "Speed Boost")
                }
                // Shed Skin: one turn in three it shakes a condition off.
                if who.build.ability == "Shed Skin", hp > 0, who.status != .none,
                   rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 1.0 / 3.0 {
                    if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                    else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                    board.note("\(name) shed its skin and shook it off.")
                }
                // Moody: one stat up two stages, another down one, chosen at
                // random. A search cannot price a coin flip with six faces, so
                // it takes nothing.
                if who.build.ability == "Moody", hp > 0, rolling {
                    let stats: [Stat] = [.attack, .defense, .spAttack, .spDefense, .speed]
                    if let up = stats.randomElement(using: &TurnModel.dice),
                       let down = stats.filter({ $0 != up }).randomElement(using: &TurnModel.dice) {
                        StatChanges.change([up: 2], onMine: mine, slot: index, board: &board, because: "Moody")
                        StatChanges.change([down: -1], onMine: mine, slot: index, board: &board, because: "Moody")
                    }
                }
                // Mimicry takes the terrain's type while it stands on it.
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
                // Harvest: in the sun, the berry it ate comes back.
                if who.build.ability == "Harvest", who.build.itemSpent, hp > 0,
                   who.build.item.hasSuffix("Berry"),
                   board.field.weather == .sun
                       || (rolling && Double.random(in: 0..<1, using: &TurnModel.dice) < 0.5) {
                    if mine { board.mine[index].build.itemSpent = false }
                    else { board.theirs[index].build.itemSpent = false }
                    board.note("\(name) harvested another \(who.build.item).")
                }
                // Healer: three in ten that it clears up whatever its partner
                // is carrying.
                if who.build.ability == "Healer", hp > 0, rolling,
                   Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3 {
                    let ally = index == 0 ? 1 : 0
                    let side = mine ? board.mine : board.theirs
                    if side.indices.contains(ally), ally < board.activeCount,
                       !side[ally].fainted, side[ally].status != .none {
                        if mine { board.mine[ally].status = .none; board.mine[ally].asleepFor = 0 }
                        else { board.theirs[ally].status = .none; board.theirs[ally].asleepFor = 0 }
                        board.note("\(name)'s Healer cleared up \(side[ally].build.form.formLabel).")
                    }
                }
                // Hydration does the same, but only in the rain, and always.
                if who.build.ability == "Hydration", hp > 0, who.status != .none,
                   board.field.weather == .rain {
                    if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                    else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                    board.note("\(name)'s Hydration washed it off.")
                }
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
                   // A Sitrus fires at half, which is already the threshold
                   // Gluttony would lower a pinch berry to — and pinch berries
                   // are not modelled separately, so Gluttony has nothing here
                   // to bring forward. It reads as unproven in the audit, which
                   // is the honest answer.
                   hp > 0, hp <= maxHP / 2 {
                    var back = maxHP / 4
                    // Ripen doubles whatever a berry gives.
                    if who.build.ability == "Ripen" { back *= 2 }
                    hp = Swift.min(maxHP, hp + back)
                    // Cheek Pouch is a second helping on top of the berry.
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
                // A Mental Herb clears whatever is stopping it choosing freely.
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
                // A Lum Berry is eaten the moment anything is wrong.
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
                // Cud Chew: a Grass-eater brings its berry back up the turn
                // after eating it.
                // Cud Chew brings a berry back up at the end of the turn after
                // it was eaten. Read fresh from the board rather than from
                // `who`, which was copied before this turn's berry was eaten —
                // so the turn it ate one never counted, and the ability paid
                // out one turn late for its whole life.
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
                if hp <= 0 {
                    if mine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                    board.note("\(name) fainted.")
                }
            }
        }
        settle(mine: true)
        settle(mine: false)

        // A Wish comes down on whoever is standing in the spot now, which is
        // the point of it: the one that made it can be long gone.
        func landWish(mine: Bool) {
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
        landWish(mine: true)
        landWish(mine: false)

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
        // Weather and terrain run out. A clock at zero with something up is
        // an analysis board's field, left alone.
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

        // Symbiosis: a partner hands its own item across the moment this one
        // has nothing left to hold.
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

        // Abilities that take something back from the weather, before the
        // seeds take theirs.
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

        // Seeds drain across the field, to whoever is standing where the seed
        // was thrown from. A seeded Pokémon that has fainted drains nothing.
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
                // Back to whoever is standing in the slot it came from.
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

        clocks(&board)

        for index in board.mine.indices {
            board.mine[index].protectedLast = board.mine[index].isProtected
            if !board.mine[index].isProtected { board.mine[index].protectStreak = 0 }
            // The turn it was used on is the turn it covers. It used to be
            // cleared at the top of the next resolve instead, which blocked
            // nothing — but it left the flag standing on the board handed back,
            // so the shield stayed drawn over a Pokémon that was open again.
            board.mine[index].isProtected = false
            board.mine[index].enduring = false
            if board.mine[index].tauntedFor > 0 {
                board.mine[index].tauntedFor -= 1
                if board.mine[index].tauntedFor == 0 {
                    board.note("\(board.mine[index].build.form.formLabel) shook off the taunt.")
                }
            }
            if board.mine[index].lastMove.map({ board.mine[index].moves.indices.contains($0)
                && board.mine[index].moves[$0].name == "Ally Switch" }) != true {
                board.mine[index].switchStreak = 0
            }
            // Arrived partway through this turn, so its first turn is the
            // next one and the flag has to survive to reach it.
            board.mine[index].justArrived = board.mine[index].arrivedThisTurn
            // A Helping Hand is good for one move, not for the game.
            board.mine[index].helped = false
            if board.mine[index].asleepFor > 0 {
                // Early Bird sleeps through half of it.
                let quick = board.mine[index].build.ability == "Early Bird"
                board.mine[index].asleepFor -= quick ? 2 : 1
                if board.mine[index].asleepFor <= 0 {
                    board.mine[index].asleepFor = 0
                    board.mine[index].status = .none
                }
            }
        }
        for index in board.theirs.indices {
            board.theirs[index].protectedLast = board.theirs[index].isProtected
            if !board.theirs[index].isProtected { board.theirs[index].protectStreak = 0 }
            board.theirs[index].isProtected = false
            board.theirs[index].enduring = false
            if board.theirs[index].tauntedFor > 0 {
                board.theirs[index].tauntedFor -= 1
                if board.theirs[index].tauntedFor == 0 {
                    board.note("\(board.theirs[index].build.form.formLabel) shook off the taunt.")
                }
            }
            if board.theirs[index].lastMove.map({ board.theirs[index].moves.indices.contains($0)
                && board.theirs[index].moves[$0].name == "Ally Switch" }) != true {
                board.theirs[index].switchStreak = 0
            }
            board.theirs[index].justArrived = board.theirs[index].arrivedThisTurn
            // A Helping Hand is good for one move, not for the game.
            board.theirs[index].helped = false
            if board.theirs[index].asleepFor > 0 {
                // Early Bird sleeps through half of it.
                let quick = board.theirs[index].build.ability == "Early Bird"
                board.theirs[index].asleepFor -= quick ? 2 : 1
                if board.theirs[index].asleepFor <= 0 {
                    board.theirs[index].asleepFor = 0
                    board.theirs[index].status = .none
                }
            }
        }
    }

    /// The clocks that run on a Pokémon standing on the field, both sides at
    /// once because they all land together at the end of a turn.
    ///
    /// Order is the order the game takes them in, and it matters: Octolock
    /// grinds first, then Yawn takes hold, and the song is last because a
    /// Pokémon the song takes is not around to be made drowsy.
    private static func clocks(_ board: inout Board) {
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
                            if side { board.mine[index].status = .sleep; board.mine[index].asleepFor = 2 }
                            else { board.theirs[index].status = .sleep; board.theirs[index].asleepFor = 2 }
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
