//  Damage.swift
//  The Gen 9 damage formula as Champions runs it.
//
//  Standard shape, with the Champions-specific parts wired in: stats come from
//  Stat Points rather than EVs, Mega Evolution is the only battle gimmick — there
//  is no Terastallization in this game — and spread moves take the doubles 0.75x.

import Foundation

// MARK: - Field

enum Weather: String, CaseIterable, Identifiable {
    case none = "None", sun = "Sun", rain = "Rain", sand = "Sandstorm", snow = "Snow"
    var id: String { rawValue }
}

enum Terrain: String, CaseIterable, Identifiable {
    case none = "None", electric = "Electric", grassy = "Grassy"
    case misty = "Misty", psychic = "Psychic"
    var id: String { rawValue }
}

struct Field {
    var weather: Weather = .none
    var terrain: Terrain = .none
    var isDoubles = true
    /// Reflect / Light Screen on the defending side.
    var screen = false
    var critical = false
    /// The attacker's partner used Helping Hand on it this turn: +50% power,
    /// and the single biggest reason a doubles support slot earns its place.
    var helpingHand = false
    /// Magic Room is up: no held item does anything for anybody.
    var magicRoom = false
    /// Wonder Room is up: every Pokémon's Defense and Special Defense have
    /// traded places, so a physical wall is suddenly the special one.
    var wonderRoom = false
    /// The attacker is moving after the target has already gone, which is what
    /// Analytic is paid for.
    var movingLast = false
    /// The attacker's partner is covering it with Friend Guard.
    var friendGuarded = false
    /// The target walked in this turn, which is what Stakeout is watching for.
    /// Carried on the field rather than on the Pokémon, because it is a fact
    /// about this turn and `Combatant` is what the parity audit fingerprints.
    var targetJustArrived = false
    /// A Fairy Aura is standing somewhere on the field. It powers up Fairy
    /// moves for *everybody*, which is why it is a property of the field
    /// rather than of whoever is holding it.
    var fairyAura = false
    /// The attacker's partner has Steely Spirit, which pays for its Steel
    /// moves as well as its own.
    var alliedSteelySpirit = false
    /// The attacker stored a charge and is spending it on this Electric move.
    var charged = false
    /// The attacker's partner has Plus or Minus and so does it.
    var paired = false
    /// Cloud Nine or Air Lock is on the field, so the weather is decoration.
    /// Kept separate from clearing the weather outright, because the weather
    /// is still *there* — it comes back the moment the ability leaves.
    var weatherSuppressed = false
}

// MARK: - Combatants

/// One side of a calculation, already resolved to concrete numbers.
struct Combatant {
    var form: Form
    var ability: String = ""
    var item: String = ""
    var sp: [Int] = Array(repeating: 0, count: 6)
    var alignment: Alignment = .neutral
    var boosts: [Int] = Array(repeating: 0, count: Stage.width)
    /// Drawn shiny. Nothing in this file reads it -- no stat, no roll, no
    /// type -- it rides along so the scene can draw the right colours for
    /// whatever is standing there, including a Mega it turned into.
    var shiny: Bool = false
    /// Fainted allies, for Supreme Overlord and Last Respects.
    var fallenAllies = 0
    /// Left itself open by using Glaive Rush: until its next action, attacks
    /// against it cannot miss and deal double damage.
    var wideOpen = false
    /// Untouched so far. Focus Sash only works from full HP, and every
    /// evaluation in this app opens from full, so it defaults to true.
    var atFullHP = true
    /// Whether its berry or Sash has already been used this battle.
    var itemSpent = false
    /// At a third of its health or less, which is when Blaze and its family
    /// switch on. A build on paper is never low; a battle sets this.
    var lowHP = false
    /// A condition it is carrying. Set at the point of use the way `lowHP`
    /// and `atFullHP` are, because a build on paper has no status and only a
    /// battle knows: Marvel Scale and Quick Feet are both paid for being ill.
    var status: Ailment = .none
    /// Its last move missed, failed or never happened, which is what
    /// Stomping Tantrum is waiting for.
    var lastMoveFailed = false
    /// The attacker ignores the defender's ability, which is the whole of
    /// Mold Breaker, Turboblaze and Teravolt.
    var ignoresAbility = false

    /// Weight in kilograms as the battle sees it, not as the dex prints it:
    /// Heavy Metal doubles it, Light Metal and a Float Stone halve it. Four
    /// moves read this instead of their own power.
    var weightKg: Double {
        var kg = form.weightKg
        switch ability {
        case "Heavy Metal": kg *= 2
        case "Light Metal": kg *= 0.5
        default: break
        }
        if item == "Float Stone" { kg *= 0.5 }
        return max(0.1, kg)
    }

    /// A stat the battle overwrote, by index, replacing what the build works
    /// out. Guard Split and Power Split average two Pokémon's raw stats, which
    /// is not a stage change and cannot be expressed as one.
    var statOverride: [Int: Int]?

    func stat(_ stat: Stat) -> Int {
        if let forced = statOverride?[stat.rawValue] { return forced }
        return ChampionsStats.value(base: form.stats[stat.rawValue],
                                    sp: sp[stat.rawValue], stat: stat, alignment: alignment)
    }

    func stagedStat(_ stat: Stat) -> Int {
        ChampionsStats.staged(self.stat(stat), stage: boosts[stat.rawValue])
    }

    /// Speed as it actually is on the field, which is not the stat.
    ///
    /// None of this was applied anywhere. Every screen that asked who moves
    /// first read the raw number, so the grid raced a Choice Scarf Garchomp at
    /// its base Speed — the most common speed item in the format, worth half
    /// again — and raced a rain team's Swift Swim sweeper at half the Speed it
    /// actually moves at. Swift Swim, Chlorophyll, Sand Rush and Slush Rush are
    /// the entire point of a weather team, and they were read as team-building
    /// labels and never as Speed.
    ///
    /// Paralysis is not here: it is applied where it is worked out, because
    /// whether it lands is a fact about the duel rather than about the Pokémon.
    func speed(in field: Field) -> Int {
        var speed = Double(stagedStat(.speed))
        switch item {
        case "Choice Scarf":                    speed *= 1.5
        case "Iron Ball", "Macho Brace":        speed *= 0.5
        default: break
        }
        // Quick Feet is half again as fast while ill, and it ignores the
        // paralysis that would otherwise be halving it.
        if ability == "Quick Feet", status != .none { speed *= 1.5 }
        switch ability {
        case "Swift Swim"   where field.weather == .rain:      speed *= 2
        case "Chlorophyll"  where field.weather == .sun:       speed *= 2
        case "Sand Rush"    where field.weather == .sand:      speed *= 2
        case "Slush Rush"   where field.weather == .snow:      speed *= 2
        case "Surge Surfer" where field.terrain == .electric:  speed *= 2
        case "Unburden" where itemSpent && !item.isEmpty:      speed *= 2
        default: break
        }
        return Int(speed)
    }

    /// A type the battle gave it, replacing what the dex says. Soak makes its
    /// target a pure Water type; Terastallisation and the -ate abilities would
    /// live here too.
    ///
    /// Optional rather than an empty array, and the stat override below the
    /// same, because this struct is copied millions of times while a team is
    /// being built. Two empty heap-backed collections on it cost the builder
    /// 13 ms of unbroken main thread; nil costs nothing to copy.
    var typeOverride: [PokeType]?

    /// The types it actually has right now. Every rule that asks about type
    /// reads this, so a Soaked Garchomp really does take a Thunderbolt.
    var effectiveTypes: [PokeType] { typeOverride ?? form.pokeTypes }

    /// Items that add a fifth to one type of move.
    static let typeBoostItems: [String: PokeType] = [
        "Black Glasses": .dark, "Charcoal": .fire, "Fairy Feather": .fairy,
        "Metal Coat": .steel, "Miracle Seed": .grass, "Mystic Water": .water,
        "Never-Melt Ice": .ice, "Sharp Beak": .flying, "Spell Tag": .ghost,
        "Twisted Spoon": .psychic, "Magnet": .electric, "Poison Barb": .poison,
        "Silk Scarf": .normal, "Hard Stone": .rock, "Soft Sand": .ground,
        "Dragon Fang": .dragon, "Black Belt": .fighting, "Silver Powder": .bug,
    ]

    /// Standing on the ground, which is what every terrain asks about: it does
    /// nothing for a Flying type or a Levitate, and neither does a Spikes.
    var grounded: Bool {
        !effectiveTypes.contains(.flying) && ability != "Levitate" && item != "Air Balloon"
    }

    var maxHP: Int { stat(.hp) }

    /// Health it effectively has across a fight, which is what a damage race
    /// should be run against. Sitrus is worth a quarter of its maximum the
    /// first time it drops below half, and that is often the difference
    /// between a two- and a three-hit knockout.
    var effectiveHP: Int {
        guard !itemSpent else { return maxHP }
        switch item {
        case "Sitrus Berry":   return maxHP + maxHP / 4
        case "Oran Berry":     return maxHP + 10
        case "Leftovers":      return maxHP + maxHP / 16
        default:               return maxHP
        }
    }

    /// The resist berries, which halve one super-effective hit of their type.
    static let resistBerries: [String: PokeType] = [
        "Occa Berry": .fire, "Passho Berry": .water, "Wacan Berry": .electric,
        "Rindo Berry": .grass, "Yache Berry": .ice, "Chople Berry": .fighting,
        "Kebia Berry": .poison, "Shuca Berry": .ground, "Coba Berry": .flying,
        "Payapa Berry": .psychic, "Tanga Berry": .bug, "Charti Berry": .rock,
        "Kasib Berry": .ghost, "Haban Berry": .dragon, "Colbur Berry": .dark,
        "Babiri Berry": .steel, "Roseli Berry": .fairy,
    ]
}

// MARK: - Result

struct DamageResult {
    let minDamage: Int
    let maxDamage: Int
    let targetHP: Int
    let effectiveness: Double
    let notes: [String]
    /// The power the move actually had, read off the board rather than the
    /// page: Last Respects counting the fallen, Grass Knot the weight, Gyro
    /// Ball the two Speeds. Nought when nothing was worked out -- a status
    /// move, an immunity -- and the page's number is the one to show.
    var power: Double = 0
    /// How many strikes are already included in the totals above.
    ///
    /// One for an ordinary move. For a multi-hit move the numbers here are the
    /// whole flurry, because that is what a calculator should show — and that
    /// is a trap for anything that wants one blow. Divide by this to get one.
    var strikes: Double = 1

    var minPercent: Double { Double(minDamage) / Double(targetHP) * 100 }
    var maxPercent: Double { Double(maxDamage) / Double(targetHP) * 100 }

    /// How many unresisted hits it takes, using the low roll — the number that
    /// matters when you are deciding whether a KO is guaranteed.
    var hitsToKO: Int {
        guard minDamage > 0 else { return 0 }
        return Int(ceil(Double(targetHP) / Double(minDamage)))
    }

    var isGuaranteedOHKO: Bool { minDamage >= targetHP }
    var isPossibleOHKO: Bool { maxDamage >= targetHP }

    var summary: String {
        guard maxDamage > 0 else { return "No damage" }
        let range = String(format: "%.1f – %.1f%%", minPercent, maxPercent)
        if isGuaranteedOHKO { return "\(range) · guaranteed OHKO" }
        if isPossibleOHKO { return "\(range) · possible OHKO" }
        return "\(range) · \(hitsToKO)HKO"
    }
}

// MARK: - Calculator

enum DamageCalc {
    /// The 16 damage rolls, as percentages of the maximum.
    private static let rolls: [Double] = (85...100).map { Double($0) / 100.0 }

    /// What a move is under the field it is used on. Weather Ball is 50 base
    /// Normal on paper and 100 base Fire under sun, which is the entire reason
    /// a Drought team runs it; reading the printed number undervalued it by
    /// half and gave it the wrong type. Read at the moment the move resolves,
    /// so a switch-in that changes the weather earlier in the turn changes
    /// what this move is before it lands.
    static func fieldForm(of move: Move, in field: Field) -> (type: PokeType, power: Int, note: String?) {
        let printed = PokeType(loose: move.type) ?? .normal
        if move.id == "weatherball", field.weather != .none {
            let type: PokeType
            switch field.weather {
            case .sun:  type = .fire
            case .rain: type = .water
            case .snow: type = .ice
            case .sand: type = .rock
            case .none: type = printed
            }
            return (type, move.power * 2,
                    "Weather Ball: \(type.rawValue) and double power in \(field.weather.rawValue)")
        }
        if move.id == "terrainpulse", field.terrain != .none {
            let type: PokeType
            switch field.terrain {
            case .electric: type = .electric
            case .grassy:   type = .grass
            case .misty:    type = .fairy
            case .psychic:  type = .psychic
            case .none:     type = printed
            }
            return (type, move.power * 2, "Terrain Pulse: \(type.rawValue) and double power")
        }
        // Solar Beam and Solar Blade are half power in any weather but sun.
        if move.id == "solarbeam" || move.id == "solarblade",
           field.weather != .none, field.weather != .sun {
            return (printed, move.power / 2, "\(move.name): half power in \(field.weather.rawValue)")
        }
        return (printed, move.power, nil)
    }

    /// One calculation in flight: the move as the field and the user's ability
    /// make it, the power as everything else makes it, and the working written
    /// down as it goes. The notes are what the calculator screen and the turn
    /// explainer show, in the order the game applies them.
    struct Working {
        var type: PokeType
        var power: Double
        var notes: [String] = []
    }

    /// The damage one move does to one target, low roll to high, with the
    /// working. Each phase below owns one part of the formula and they read in
    /// the order the game applies them: what the move is, what its power
    /// becomes, the two stats, the base, what multiplies the hit, the type
    /// chart, what the defender takes off and the attacker adds, the strikes,
    /// and the rolls. The multipliers are applied in place and in that order
    /// on purpose -- floating-point products are not associative, and a
    /// factor gathered up and applied later could move a roll across a
    /// knock-out by one point.
    static func calculate(attacker: Combatant, defender: Combatant,
                          move: Move, field: Field) -> DamageResult {
        if let bare = withoutItems(attacker: attacker, defender: defender, move: move, field: field) {
            return bare
        }
        guard move.isDamaging, move.power > 0 else {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 1, notes: ["Status move"])
        }
        // Final Gambit deals the user's remaining health, not a base power of 1.
        // It costs the user its life, which the worth model already charges for.
        if move.id == "finalgambit" {
            let dealt = attacker.stat(.hp)
            return DamageResult(minDamage: dealt, maxDamage: dealt,
                                targetHP: defender.maxHP, effectiveness: 1,
                                notes: ["Final Gambit: deals \(dealt), equal to the user's HP, and the user faints"])
        }

        var working = theMove(move, by: attacker, in: field)
        variablePower(&working, move: move, attacker: attacker, defender: defender)
        // What the move is worth off the board, before anything the attacker
        // is holding or born with adds to it: the number a player means when
        // they ask what this move's power is right now.
        let boardPower = working.power
        abilityPower(&working, move: move, attacker: attacker, field: field)
        itemAndFieldPower(&working, move: move, attacker: attacker, defender: defender, field: field)
        let type = working.type

        let physical = move.category == "Physical"
        let attackStat = attack(of: attacker, physical: physical, field: field, notes: &working.notes)
        let defenceStat = defence(of: defender, physical: physical, field: field, notes: &working.notes)

        // -- base damage -----------------------------------------------------
        let level = Double(ChampionsStats.level)
        let base = floor(floor(floor(2 * level / 5 + 2) * working.power * attackStat / defenceStat) / 50) + 2

        // -- multipliers -----------------------------------------------------
        var modifier = 1.0
        hitModifier(&modifier, move: move, type: type, attacker: attacker, field: field,
                    notes: &working.notes)
        // Struggle is typeless: it is what is left when a Pokemon has nothing
        // to throw, and a Ghost standing in front of it does not get to be
        // immune to it. Printed Normal so it has something to draw, read as
        // neither strong nor weak against anything.
        let effective = MoveLegality.isStruggle(move) ? 1
            : effectiveness(of: type, into: defender, ignored: attacker.ignoresAbility,
                            notes: &working.notes)
        modifier *= effective
        if effective == 0 {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 0, notes: working.notes + ["No effect"])
        }
        defensiveModifier(&modifier, move: move, type: type, physical: physical,
                          effectiveness: effective, attacker: attacker, defender: defender,
                          field: field, notes: &working.notes)
        offensiveModifier(&modifier, type: type, effectiveness: effective, attacker: attacker,
                          notes: &working.notes)

        let hits = strikes(of: move, by: attacker, notes: &working.notes)
        let damages = rolled(base: base, modifier: modifier, strikes: hits.count,
                             multiHit: hits.multiHit, attacker: attacker, defender: defender,
                             notes: &working.notes)
        return DamageResult(minDamage: damages.first ?? 0,
                            maxDamage: damages.last ?? 0,
                            targetHP: defender.maxHP,
                            effectiveness: effective,
                            notes: working.notes,
                            power: boardPower,
                            strikes: hits.count)
    }

    // MARK: - The phases of a calculation

    /// Magic Room switches every held item off, and Klutz does the same to one
    /// Pokemon. Taking them away here means every item rule below is covered
    /// by one check, including the ones added after this was written. Nil when
    /// every item is where it should be.
    private static func withoutItems(attacker: Combatant, defender: Combatant,
                                     move: Move, field: Field) -> DamageResult? {
        let klutzed = attacker.ability == "Klutz" && !attacker.item.isEmpty
        let theirKlutz = defender.ability == "Klutz" && !defender.item.isEmpty
        guard field.magicRoom || klutzed || theirKlutz,
              !attacker.item.isEmpty || !defender.item.isEmpty else { return nil }
        var bare = attacker, bareDefender = defender
        if field.magicRoom || klutzed { bare.item = "" }
        if field.magicRoom || theirKlutz { bareDefender.item = "" }
        var without = field
        without.magicRoom = false
        let result = calculate(attacker: bare, defender: bareDefender,
                               move: move, field: without)
        let why = field.magicRoom ? "Magic Room: held items do nothing"
                                  : "Klutz: the item does nothing"
        return DamageResult(minDamage: result.minDamage, maxDamage: result.maxDamage,
                            targetHP: result.targetHP, effectiveness: result.effectiveness,
                            notes: result.notes + [why], power: result.power)
    }

    /// 1. What the move is: its type and power under this field, and after the
    /// user's ability has had its say. Aerilate is the reason Mega Salamence
    /// clicks Double-Edge: a Normal move becomes Flying and gains 20% before
    /// anything else applies.
    private static func theMove(_ move: Move, by attacker: Combatant, in field: Field) -> Working {
        let form = fieldForm(of: move, in: field)
        var working = Working(type: form.type, power: Double(form.power))
        if let said = form.note { working.notes.append(said) }
        let ate = AteAbility.resolve(type: working.type, ability: attacker.ability)
        if ate.boost > 1 {
            if ate.type != working.type {
                working.notes.append("\(attacker.ability): \(working.type.rawValue) → \(ate.type.rawValue), +20%")
            }
            working.type = ate.type
            working.power *= ate.boost
        }
        return working
    }

    /// 2. Moves whose power is read off the board rather than the page. Serebii
    /// prints the weight moves as 1 base power, so without this they hit for
    /// nothing: the audit caught it when Grass Knot dealt 2 damage. Electro
    /// Ball and Gyro Ball read the two Speeds against each other -- one rewards
    /// outrunning the target, the other rewards being slower, which is why a
    /// Gyro Ball user invests nothing in Speed at all. Last Respects is 50, and
    /// 50 more for every teammate that has gone down.
    private static func variablePower(_ working: inout Working, move: Move,
                                      attacker: Combatant, defender: Combatant) {
        if move.id == "lowkick" || move.id == "grassknot" {
            let kg = defender.weightKg
            working.power = kg >= 200 ? 120 : kg >= 100 ? 100 : kg >= 50 ? 80
                          : kg >= 25 ? 60 : kg >= 10 ? 40 : 20
            working.notes.append(String(format: "%@: %d power against %.1fkg",
                                        move.name, Int(working.power), kg))
        }
        if move.id == "heavyslam" || move.id == "heatcrash" {
            let ratio = attacker.weightKg / defender.weightKg
            working.power = ratio >= 5 ? 120 : ratio >= 4 ? 100 : ratio >= 3 ? 80
                          : ratio >= 2 ? 60 : 40
            working.notes.append(String(format: "%@: %d power at %.1fkg against %.1fkg",
                                        move.name, Int(working.power), attacker.weightKg, defender.weightKg))
        }
        if move.id == "electroball" || move.id == "gyroball" {
            let mine = Double(Swift.max(1, attacker.stagedStat(.speed)))
            let theirs = Double(Swift.max(1, defender.stagedStat(.speed)))
            if move.id == "electroball" {
                let ratio = mine / theirs
                working.power = ratio >= 4 ? 150 : ratio >= 3 ? 120 : ratio >= 2 ? 80
                              : ratio > 1 ? 60 : 40
            } else {
                working.power = Swift.min(150, Double(Int(25 * theirs / mine)))
                working.power = Swift.max(1, working.power)
            }
            working.notes.append("\(move.name): \(Int(working.power)) power at \(Int(mine)) Speed against \(Int(theirs))")
        }
        if move.id == "lastrespects" {
            working.power = Double(50 * (1 + attacker.fallenAllies))
            if attacker.fallenAllies > 0 {
                working.notes.append("Last Respects: \(Int(working.power)) power for \(attacker.fallenAllies) fallen")
            }
        }
        if move.doublesAfterFailure, attacker.lastMoveFailed {
            working.power *= 2
            working.notes.append("\(move.name): double power after last turn's failed move")
        }
    }

    /// 3. The user's ability, and the allies' abilities the field carries as
    /// flags -- an Electromorphosis charge, a partner's Steely Spirit, a Fairy
    /// Aura. The pinch abilities pay half again on the matching type once the
    /// user is down to a third; only a battle ever gets there, so only a battle
    /// sees it, but a Charizard that has taken a hit hits back harder. Two of
    /// Champions' Mega abilities rewrite the move's type on the way out, done
    /// here before anything reads it, so the same-type bonus and the type
    /// chart both see the new one. Analytic pays for going second, which is
    /// the one thing a slow attacker has going for it; Stakeout doubles on
    /// anything that has just walked in, which is what makes switching against
    /// one so expensive.
    private static func abilityPower(_ working: inout Working, move: Move,
                                     attacker: Combatant, field: Field) {
        if attacker.lowHP {
            let pinch: [String: PokeType] = ["Blaze": .fire, "Torrent": .water,
                                             "Overgrow": .grass, "Swarm": .bug]
            if let boosted = pinch[attacker.ability], working.type == boosted {
                working.power *= 1.5
                working.notes.append("\(attacker.ability): +50% while low")
            }
        }
        if attacker.ability == "Tough Claws", move.makesContact {
            working.power *= 1.3
            working.notes.append("Tough Claws: +30%")
        }
        if attacker.ability == "Sharpness", move.isSlicing {
            working.power *= 1.5
            working.notes.append("Sharpness: +50%")
        }
        switch attacker.ability {
        case "Dragonize" where working.type == .normal:
            working.type = .dragon
            working.power *= 1.2
            working.notes.append("Dragonize: Normal becomes Dragon, +20%")
        case "Liquid Voice" where move.isSound:
            working.type = .water
            working.notes.append("Liquid Voice: the sound becomes Water")
        default: break
        }
        if field.charged, working.type == .electric {
            working.power *= 2
            working.notes.append("Electromorphosis: the stored charge doubles it")
        }
        if attacker.ability == "Mega Launcher", move.isPulse {
            working.power *= 1.5
            working.notes.append("Mega Launcher: +50%")
        }
        if attacker.ability == "Fire Mane", working.type == .fire {
            working.power *= 1.5
            working.notes.append("Fire Mane: +50%")
        }
        if working.type == .steel, attacker.ability == "Steely Spirit" || field.alliedSteelySpirit {
            working.power *= 1.5
            working.notes.append("Steely Spirit: +50%")
        }
        if working.type == .fairy, field.fairyAura {
            working.power *= 1.33
            working.notes.append("Fairy Aura: +33%")
        }
        if attacker.ability == "Analytic", field.movingLast {
            working.power *= 1.3
            working.notes.append("Analytic: +30% for moving last")
        }
        if attacker.ability == "Stakeout", field.targetJustArrived {
            working.power *= 2
            working.notes.append("Stakeout: doubled against something that just came in")
        }
        if attacker.ability == "Iron Fist", move.isPunch { working.power *= 1.2 }
        if attacker.ability == "Strong Jaw", move.flags["bite"] == true { working.power *= 1.5 }
        if attacker.ability == "Punk Rock", move.isSound { working.power *= 1.3 }
        if attacker.ability == "Technician", move.power <= 60 { working.power *= 1.5 }
        if attacker.ability == "Sheer Force", move.effectRate > 0 { working.power *= 1.3 }
    }

    /// 4. The user's item, Helping Hand, and the terrain. Aerilate converts the
    /// type but a Normal Gem still fires, which is why it shows up on Mega
    /// Salamence sets. Helping Hand is a power modifier, applied before the
    /// stats are divided, so it compounds with everything above it. Terrain
    /// boosts the grounded user's matching type; Grassy Terrain is the
    /// structural answer to Earthquake spam; and Rising Voltage is twice the
    /// power into something standing in the charge, which is the whole reason
    /// an Electric Terrain team runs it.
    private static func itemAndFieldPower(_ working: inout Working, move: Move, attacker: Combatant,
                                          defender: Combatant, field: Field) {
        switch attacker.item {
        case "Normal Gem" where working.type == .normal:
            working.power *= 1.3
            working.notes.append("Normal Gem: +30%")
        case "Punching Glove" where move.isPunch: working.power *= 1.1
        case "Muscle Band" where move.category == "Physical": working.power *= 1.1
        case "Wise Glasses" where move.category == "Special": working.power *= 1.1
        default: break
        }
        if field.helpingHand {
            working.power *= 1.5
            working.notes.append("Helping Hand: +50%")
        }
        switch (field.terrain, working.type) {
        case (.electric, .electric), (.grassy, .grass), (.psychic, .psychic):
            working.power *= 1.3
            working.notes.append("\(field.terrain.rawValue) Terrain: +30%")
        default: break
        }
        if field.terrain == .misty, working.type == .dragon {
            working.power *= 0.5
            working.notes.append("Misty Terrain halves Dragon")
        }
        if field.terrain == .grassy, ["earthquake", "bulldoze", "magnitude"].contains(move.id) {
            working.power *= 0.5
            working.notes.append("Grassy Terrain halves Earthquake")
        }
        if move.id == "risingvoltage", field.terrain == .electric, defender.grounded {
            working.power *= 2
            working.notes.append("Rising Voltage: double power on Electric Terrain")
        }
    }

    /// 5. The attacking stat with its stage, and everything that multiplies it.
    /// A critical hit ignores the attacker's negative stages -- the usual crit
    /// rule. Plus and Minus pay each other, and only each other: half again the
    /// Special Attack when the partner carries the matching one. A burn halves
    /// what a physical attacker does; it was applied as a stage off Attack once,
    /// which is a third rather than a half, and being a stage it compounded
    /// with whatever stages were already there, so a burned Pokemon at +6 lost
    /// an eighth of its damage instead of half. Guts ignores the burn and is
    /// paid for the condition instead, which is why the two are decided
    /// together.
    private static func attack(of attacker: Combatant, physical: Bool, field: Field,
                               notes: inout [String]) -> Double {
        let atkStat: Stat = physical ? .attack : .spAttack
        var attack = Double(attacker.stagedStat(atkStat))
        if field.critical {
            attack = Double(ChampionsStats.staged(attacker.stat(atkStat),
                                                  stage: max(0, attacker.boosts[atkStat.rawValue])))
        }
        if field.paired, !physical { attack *= 1.5 }
        if attacker.ability == "Huge Power" || attacker.ability == "Pure Power", physical {
            attack *= 2
            notes.append("\(attacker.ability): Attack doubled")
        }
        if attacker.status != .none, physical {
            if attacker.ability == "Guts" { attack *= 1.5 }
            else if attacker.status == .burn { attack *= 0.5 }
        }
        if attacker.ability == "Solar Power", !physical, field.weather == .sun { attack *= 1.5 }
        switch attacker.item {
        case "Choice Band" where physical: attack *= 1.5
        case "Choice Specs" where !physical: attack *= 1.5
        default: break
        }
        return attack
    }

    /// 6. The defending stat. Wonder Room trades the two defences, so a physical
    /// attack is worked out against Special Defense and the other way round --
    /// it swaps the stat, not the stage, which is why it reads as a stat choice
    /// here. A critical hit ignores the defender's positive stages. Fur Coat is
    /// a second Defense, and the reason a Furfrou wall exists; Marvel Scale is
    /// paid for being ill, Grass Pelt for standing on grass.
    private static func defence(of defender: Combatant, physical: Bool, field: Field,
                                notes: inout [String]) -> Double {
        var defStat: Stat = physical ? .defense : .spDefense
        if field.wonderRoom { defStat = physical ? .spDefense : .defense }
        var defense = Double(defender.stagedStat(defStat))
        if field.critical {
            defense = Double(ChampionsStats.staged(defender.stat(defStat),
                                                  stage: min(0, defender.boosts[defStat.rawValue])))
        }
        if defender.ability == "Fur Coat", physical { defense *= 2 }
        if defender.ability == "Marvel Scale", defender.status != .none, physical {
            defense *= 1.5
        }
        if defender.ability == "Grass Pelt", field.terrain == .grassy, physical {
            defense *= 1.5
        }
        if defender.item == "Assault Vest", !physical { defense *= 1.5 }
        if defender.item == "Eviolite" { defense *= 1.5 }
        if field.weather == .snow, defender.effectiveTypes.contains(.ice), physical {
            defense *= 1.5
            notes.append("Snow: Ice Defense ×1.5")
        }
        if field.weather == .sand, defender.effectiveTypes.contains(.rock), !physical {
            defense *= 1.5
        }
        return defense
    }

    /// 7. What multiplies the hit before the type chart: a spread move in
    /// doubles, the weather, a critical hit, and the same-type bonus -- doubled
    /// rather than half again under Adaptability. Sniper makes a critical hit
    /// worth half again as much as it already is, which is the entire ability.
    private static func hitModifier(_ modifier: inout Double, move: Move, type: PokeType,
                                    attacker: Combatant, field: Field, notes: inout [String]) {
        if field.isDoubles, move.isSpread {
            modifier *= 0.75
            notes.append("Spread: ×0.75")
        }
        switch (field.weather, type) {
        case (.sun, .fire), (.rain, .water): modifier *= 1.5
        case (.sun, .water), (.rain, .fire): modifier *= 0.5
        default: break
        }
        if field.critical {
            modifier *= attacker.ability == "Sniper" ? 2.25 : 1.5
        }
        // The same-type bonus, which Struggle never gets: a Normal type is
        // not throwing a Normal move, it is out of moves.
        var stab = attacker.effectiveTypes.contains(type)
            && !MoveLegality.isStruggle(move) ? 1.5 : 1.0
        if attacker.ability == "Adaptability", stab > 1 { stab = 2.0 }
        modifier *= stab
    }

    /// 8. The type chart, and the defender's ability where it changes the
    /// answer: an immunity, an absorption, a Thick Fat.
    private static func effectiveness(of type: PokeType, into defender: Combatant, ignored: Bool,
                                      notes: inout [String]) -> Double {
        var effectiveness = 1.0
        for defending in defender.effectiveTypes {
            effectiveness *= TypeChart.multiplier(type, into: defending)
        }
        return applyDefensiveAbility(effectiveness, moveType: type, defender: defender,
                                     ignored: ignored, notes: &notes)
    }

    /// 9. What the defender takes off the hit. Aura Guard is what makes Mega
    /// Lucario Z awkward to break: it halves every contact move, and most
    /// physical attackers only have those. Multiscale only while the bar is
    /// full -- the first hit is halved, the rest are not. The resist berries
    /// halve one super-effective hit of their type; Kingambit holds a Chople
    /// on 42% of measured sets precisely to survive one Fighting move, and
    /// that was not being modelled at all. Chilan halves any Normal-type hit,
    /// super-effective or not. Friend Guard is a quarter off everything aimed
    /// at its partner, which is the whole of a support slot that does nothing
    /// else.
    private static func defensiveModifier(_ modifier: inout Double, move: Move, type: PokeType,
                                          physical: Bool, effectiveness: Double,
                                          attacker: Combatant, defender: Combatant, field: Field,
                                          notes: inout [String]) {
        if !attacker.ignoresAbility, defender.ability == "Aura Guard", move.makesContact {
            modifier *= 0.5
            notes.append("Aura Guard: contact halved")
        }
        if !attacker.ignoresAbility, defender.ability == "Multiscale" || defender.ability == "Shadow Shield", defender.atFullHP {
            modifier *= 0.5
            notes.append("\(defender.ability) at full HP: ×0.5")
        }
        if !attacker.ignoresAbility, defender.ability == "Ice Scales", !physical { modifier *= 0.5 }
        if effectiveness > 1,
           !attacker.ignoresAbility,
           ["Filter", "Solid Rock", "Prism Armor"].contains(defender.ability) {
            modifier *= 0.75
        }
        if effectiveness > 1, defender.item == "Weakness Policy" {
            notes.append("Triggers Weakness Policy (+2 Atk / +2 SpA)")
        }
        if !defender.itemSpent,
           let berry = Combatant.resistBerries[defender.item],
           berry == type, effectiveness > 1 {
            modifier *= 0.5
            notes.append("\(defender.item) halves it, then is consumed")
        }
        if !defender.itemSpent, defender.item == "Chilan Berry", type == .normal {
            modifier *= 0.5
            notes.append("Chilan Berry halves it, then is consumed")
        }
        if defender.wideOpen {
            modifier *= 2
            notes.append("Glaive Rush: target is Wide Open, damage doubled")
        }
        if field.friendGuarded { modifier *= 0.75 }
        if field.screen, !field.critical {
            modifier *= field.isDoubles ? 0.667 : 0.5
            notes.append("Screen: ×\(field.isDoubles ? "0.667" : "0.5")")
        }
    }

    /// 10. What the attacker's item adds, and Supreme Overlord for the fallen.
    /// The type-boost items are a fifth more of one type, which is what a
    /// Charcoal on a Fire attacker is for -- read from a table rather than the
    /// text, because the text says "increased by 20%" in one place and
    /// "increases damage inflicted by 20%" in another.
    private static func offensiveModifier(_ modifier: inout Double, type: PokeType,
                                          effectiveness: Double, attacker: Combatant,
                                          notes: inout [String]) {
        if let boosted = Combatant.typeBoostItems[attacker.item], boosted == type {
            modifier *= 1.2
            notes.append("\(attacker.item): +20% \(type.rawValue)")
        }
        if attacker.item == "Life Orb" {
            modifier *= 1.3
            notes.append("Life Orb: +30% (10% recoil)")
        }
        if attacker.item == "Expert Belt", effectiveness > 1 { modifier *= 1.2 }
        if attacker.ability == "Supreme Overlord", attacker.fallenAllies > 0 {
            let boost = 1.0 + 0.1 * Double(min(5, attacker.fallenAllies))
            modifier *= boost
            notes.append("Supreme Overlord ×\(String(format: "%.1f", boost))")
        }
    }

    /// 11. How many times it strikes. The calculator was reading the printed
    /// power and stopping there, so Icicle Spear came out as a single 25 BP hit
    /// and Dragon Darts as 50. Each strike is its own calculation in the game;
    /// totalling them is close enough and is what the number on screen should
    /// mean.
    private static func strikes(of move: Move, by attacker: Combatant,
                                notes: inout [String]) -> (count: Double, multiHit: Bool) {
        var strikes = 1.0
        var multiHit = false
        if let hits = move.drawbacks.hits {
            multiHit = hits.max > 1
            if attacker.ability == "Skill Link" {
                strikes = Double(hits.max)
            } else if hits.min == hits.max {
                strikes = Double(hits.min)
            } else if attacker.item == "Loaded Dice" {
                strikes = Double(hits.max) - 0.5
            } else {
                // The Gen 5+ 2-5 distribution averages 3.
                strikes = hits.max == 5 && hits.min == 2 ? 3.0
                        : Double(hits.min + hits.max) / 2
            }
            if strikes > 1 {
                notes.append(String(format: "%@ hits %.1f times on average",
                                    move.name, strikes))
            }
        }
        return (strikes, multiHit)
    }

    /// 12. The sixteen rolls, and the one thing that caps them. From full HP a
    /// Focus Sash cannot be knocked out in one hit, which makes "guaranteed
    /// OHKO" wrong against the 87% of Whimsicott sets holding one; Sturdy
    /// behaves the same way. A Sash stops one hit, not a move: anything that
    /// strikes more than once breaks it on the first and knocks out with the
    /// second, which is most of the reason those moves are worth running.
    private static func rolled(base: Double, modifier: Double, strikes: Double, multiHit: Bool,
                               attacker: Combatant, defender: Combatant,
                               notes: inout [String]) -> [Int] {
        var damages = rolls.map { roll -> Int in
            max(1, Int(floor(floor(base * roll) * modifier) * strikes))
        }
        let survivesAnything = ((defender.item == "Focus Sash" && !defender.itemSpent)
            || (defender.ability == "Sturdy" && !attacker.ignoresAbility)) && !multiHit
        if multiHit, defender.atFullHP,
           (defender.item == "Focus Sash" && !defender.itemSpent)
            || (defender.ability == "Sturdy" && !attacker.ignoresAbility) {
            notes.append("Hits more than once, so it goes through a Focus Sash or Sturdy")
        }
        if survivesAnything, defender.atFullHP {
            let cap = max(1, defender.maxHP - 1)
            if damages.contains(where: { $0 >= defender.maxHP }) {
                notes.append(defender.ability == "Sturdy"
                             ? "Sturdy: survives on 1 HP from full"
                             : "Focus Sash: survives on 1 HP from full")
            }
            damages = damages.map { min($0, cap) }
        }
        return damages
    }

    /// `ignored` is a Mold Breaker on the other side: every type immunity an
    /// ability grants — Levitate, Flash Fire, Water Absorb — is something it
    /// walks straight through.
    private static func applyDefensiveAbility(_ effectiveness: Double, moveType: PokeType,
                                              defender: Combatant, ignored: Bool = false,
                                              notes: inout [String]) -> Double {
        switch (ignored ? "" : defender.ability, moveType) {
        case ("Levitate", .ground), ("Eelevate", .ground):
            notes.append("\(defender.ability): immune to Ground")
            return 0
        case ("Flash Fire", .fire), ("Water Absorb", .water), ("Volt Absorb", .electric),
             ("Sap Sipper", .grass), ("Storm Drain", .water), ("Lightning Rod", .electric),
             ("Motor Drive", .electric), ("Dry Skin", .water),
             ("Earth Eater", .ground), ("Well-Baked Body", .fire):
            notes.append("\(defender.ability): absorbed")
            return 0
        case ("Thick Fat", .fire), ("Thick Fat", .ice):
            notes.append("Thick Fat: ×0.5")
            return effectiveness * 0.5
        case ("Heatproof", .fire):
            return effectiveness * 0.5
        case ("Thermal Exchange", .fire):
            // Not an immunity — it still takes the hit, but converts it into a
            // +1 Attack, which is the point of Mega Baxcalibur.
            notes.append("Thermal Exchange: +1 Attack on Fire hits")
            return effectiveness
        default:
            return effectiveness
        }
    }
}

// A game between two people sends a side's state across the wire.
extension Weather: Codable {}
extension Terrain: Codable {}
extension Field: Codable {}
extension Combatant: Codable {}
