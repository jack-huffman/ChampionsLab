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
}

// MARK: - Combatants

/// One side of a calculation, already resolved to concrete numbers.
struct Combatant {
    var form: Form
    var ability: String = ""
    var item: String = ""
    var sp: [Int] = Array(repeating: 0, count: 6)
    var alignment: Alignment = .neutral
    var boosts: [Int] = Array(repeating: 0, count: 6)
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

    static func calculate(attacker: Combatant, defender: Combatant,
                          move: Move, field: Field) -> DamageResult {
        // Magic Room switches every held item off. Taking them away here means
        // every item rule below is covered by one check, including the ones
        // added after this was written.
        if field.magicRoom, !attacker.item.isEmpty || !defender.item.isEmpty {
            var bare = attacker, bareDefender = defender
            bare.item = ""; bareDefender.item = ""
            var without = field
            without.magicRoom = false
            let result = calculate(attacker: bare, defender: bareDefender,
                                   move: move, field: without)
            return DamageResult(minDamage: result.minDamage, maxDamage: result.maxDamage,
                                targetHP: result.targetHP, effectiveness: result.effectiveness,
                                notes: result.notes + ["Magic Room: held items do nothing"])
        }
        var notes: [String] = []
        guard move.isDamaging, move.power > 0 else {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 1, notes: ["Status move"])
        }

        // -- moves whose type and power come from the field --------------------
        let form = fieldForm(of: move, in: field)
        var moveType = form.type
        var power = Double(form.power)
        if let said = form.note { notes.append(said) }
        // Final Gambit deals the user's remaining health, not a base power of 1.
        // It costs the user its life, which the worth model already charges for.
        if move.id == "finalgambit" {
            let dealt = attacker.stat(.hp)
            return DamageResult(minDamage: dealt, maxDamage: dealt,
                                targetHP: defender.maxHP, effectiveness: 1,
                                notes: ["Final Gambit: deals \(dealt), equal to the user's HP, and the user faints"])
        }

        // -- ability-driven type changes ------------------------------------
        // Aerilate is the reason Mega Salamence clicks Double-Edge: a Normal
        // move becomes Flying and gains 20% before anything else applies.
        let ate = AteAbility.resolve(type: moveType, ability: attacker.ability)
        if ate.boost > 1 {
            if ate.type != moveType {
                notes.append("\(attacker.ability): \(moveType.rawValue) → \(ate.type.rawValue), +20%")
            }
            moveType = ate.type
            power *= ate.boost
        }

        // -- power modifiers -------------------------------------------------
        // The pinch abilities: half again on the matching type once the user is
        // down to a third. Only a battle ever gets there, so only a battle sees
        // it, but a Charizard that has taken a hit hits back harder.
        // Last Respects: 50, and 50 more for every teammate that has gone down.
        // Four moves ignore their listed power and read weight instead. Serebii
        // prints these as 1 base power, so without this they hit for nothing:
        // the audit caught it when Grass Knot dealt 2 damage.
        if move.id == "lowkick" || move.id == "grassknot" {
            let kg = defender.weightKg
            power = kg >= 200 ? 120 : kg >= 100 ? 100 : kg >= 50 ? 80
                  : kg >= 25 ? 60 : kg >= 10 ? 40 : 20
            notes.append(String(format: "%@: %d power against %.1fkg",
                                move.name, Int(power), kg))
        }
        if move.id == "heavyslam" || move.id == "heatcrash" {
            let ratio = attacker.weightKg / defender.weightKg
            power = ratio >= 5 ? 120 : ratio >= 4 ? 100 : ratio >= 3 ? 80
                  : ratio >= 2 ? 60 : 40
            notes.append(String(format: "%@: %d power at %.1fkg against %.1fkg",
                                move.name, Int(power), attacker.weightKg, defender.weightKg))
        }
        // Electro Ball and Gyro Ball read the two Speeds against each other:
        // one rewards outrunning the target, the other rewards being slower,
        // which is why a Gyro Ball user invests nothing in Speed at all.
        if move.id == "electroball" || move.id == "gyroball" {
            let mine = Double(Swift.max(1, attacker.stagedStat(.speed)))
            let theirs = Double(Swift.max(1, defender.stagedStat(.speed)))
            if move.id == "electroball" {
                let ratio = mine / theirs
                power = ratio >= 4 ? 150 : ratio >= 3 ? 120 : ratio >= 2 ? 80
                      : ratio > 1 ? 60 : 40
            } else {
                power = Swift.min(150, Double(Int(25 * theirs / mine)))
                power = Swift.max(1, power)
            }
            notes.append("\(move.name): \(Int(power)) power at \(Int(mine)) Speed against \(Int(theirs))")
        }
        if move.id == "lastrespects" {
            power = Double(50 * (1 + attacker.fallenAllies))
            if attacker.fallenAllies > 0 {
                notes.append("Last Respects: \(Int(power)) power for \(attacker.fallenAllies) fallen")
            }
        }
        if move.doublesAfterFailure, attacker.lastMoveFailed {
            power *= 2
            notes.append("\(move.name): double power after last turn's failed move")
        }
        if attacker.lowHP {
            let pinch: [String: PokeType] = ["Blaze": .fire, "Torrent": .water,
                                             "Overgrow": .grass, "Swarm": .bug]
            if let boosted = pinch[attacker.ability], moveType == boosted {
                power *= 1.5
                notes.append("\(attacker.ability): +50% while low")
            }
        }
        if attacker.ability == "Tough Claws", move.makesContact {
            power *= 1.3
            notes.append("Tough Claws: +30%")
        }
        if attacker.ability == "Sharpness", move.isSlicing {
            power *= 1.5
            notes.append("Sharpness: +50%")
        }
        if attacker.ability == "Iron Fist", move.isPunch { power *= 1.2 }
        if attacker.ability == "Strong Jaw", move.flags["bite"] == true { power *= 1.5 }
        if attacker.ability == "Punk Rock", move.isSound { power *= 1.3 }
        if attacker.ability == "Technician", move.power <= 60 { power *= 1.5 }
        if attacker.ability == "Sheer Force", move.effectRate > 0 { power *= 1.3 }

        switch attacker.item {
        case "Normal Gem" where moveType == .normal:
            // Aerilate converts the type but the Gem still fires, which is why
            // Normal Gem shows up on Mega Salamence sets.
            power *= 1.3
            notes.append("Normal Gem: +30%")
        case "Punching Glove" where move.isPunch: power *= 1.1
        case "Muscle Band" where move.category == "Physical": power *= 1.1
        case "Wise Glasses" where move.category == "Special": power *= 1.1
        default: break
        }

        // Helping Hand is a power modifier, applied before the stats are
        // divided, so it compounds with everything above it.
        if field.helpingHand {
            power *= 1.5
            notes.append("Helping Hand: +50%")
        }

        // Terrain boosts the grounded user's matching type.
        switch (field.terrain, moveType) {
        case (.electric, .electric), (.grassy, .grass), (.psychic, .psychic):
            power *= 1.3
            notes.append("\(field.terrain.rawValue) Terrain: +30%")
        default: break
        }
        if field.terrain == .misty, moveType == .dragon {
            power *= 0.5
            notes.append("Misty Terrain halves Dragon")
        }
        // Grassy Terrain is the structural answer to Earthquake spam.
        if field.terrain == .grassy, ["earthquake", "bulldoze", "magnitude"].contains(move.id) {
            power *= 0.5
            notes.append("Grassy Terrain halves Earthquake")
        }
        // Rising Voltage: twice the power into something standing in the
        // charge, which is the whole reason an Electric Terrain team runs it.
        if move.id == "risingvoltage", field.terrain == .electric, defender.grounded {
            power *= 2
            notes.append("Rising Voltage: double power on Electric Terrain")
        }

        // -- attack and defence ---------------------------------------------
        let physical = move.category == "Physical"
        let atkStat: Stat = physical ? .attack : .spAttack
        // Wonder Room trades the two defences, so a physical attack is worked
        // out against Special Defense and the other way round. It swaps the
        // stat, not the stage, which is why it reads as a stat choice here.
        var defStat: Stat = physical ? .defense : .spDefense
        if field.wonderRoom { defStat = physical ? .spDefense : .defense }

        var attack = Double(attacker.stagedStat(atkStat))
        // Ignore the defender's positive boosts on a crit, and the attacker's
        // negative ones — the usual crit rules.
        if field.critical {
            attack = Double(ChampionsStats.staged(attacker.stat(atkStat),
                                                  stage: max(0, attacker.boosts[atkStat.rawValue])))
        }
        if attacker.ability == "Huge Power" || attacker.ability == "Pure Power", physical {
            attack *= 2
            notes.append("\(attacker.ability): Attack doubled")
        }
        if attacker.ability == "Guts", physical { attack *= 1.5 }
        if attacker.ability == "Solar Power", !physical, field.weather == .sun { attack *= 1.5 }
        switch attacker.item {
        case "Choice Band" where physical: attack *= 1.5
        case "Choice Specs" where !physical: attack *= 1.5
        default: break
        }

        var defense = Double(defender.stagedStat(defStat))
        if field.critical {
            defense = Double(ChampionsStats.staged(defender.stat(defStat),
                                                  stage: min(0, defender.boosts[defStat.rawValue])))
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

        // -- base damage -----------------------------------------------------
        let level = Double(ChampionsStats.level)
        let base = floor(floor(floor(2 * level / 5 + 2) * power * attack / defense) / 50) + 2

        // -- multipliers -----------------------------------------------------
        var modifier = 1.0

        if field.isDoubles, move.isSpread {
            modifier *= 0.75
            notes.append("Spread: ×0.75")
        }

        switch (field.weather, moveType) {
        case (.sun, .fire), (.rain, .water): modifier *= 1.5
        case (.sun, .water), (.rain, .fire): modifier *= 0.5
        default: break
        }

        if field.critical { modifier *= 1.5 }

        // STAB, doubled rather than 1.5x under Adaptability.
        var stab = attacker.effectiveTypes.contains(moveType) ? 1.5 : 1.0
        if attacker.ability == "Adaptability", stab > 1 { stab = 2.0 }
        modifier *= stab

        // -- effectiveness ---------------------------------------------------
        var effectiveness = 1.0
        for type in defender.effectiveTypes {
            effectiveness *= TypeChart.multiplier(moveType, into: type)
        }
        effectiveness = applyDefensiveAbility(effectiveness, moveType: moveType,
                                              defender: defender, ignored: attacker.ignoresAbility, notes: &notes)
        modifier *= effectiveness

        if effectiveness == 0 {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 0, notes: notes + ["No effect"])
        }

        // Aura Guard is what makes Mega Lucario Z awkward to break: it halves
        // every contact move, and most physical attackers only have those.
        if !attacker.ignoresAbility, defender.ability == "Aura Guard", move.makesContact {
            modifier *= 0.5
            notes.append("Aura Guard: contact halved")
        }
        // Only while the bar is full: the first hit is halved, the rest are not.
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

        // Resist berries halve one super-effective hit of their type. Kingambit
        // holds a Chople on 42% of measured sets precisely to survive one
        // Fighting move, and that was not being modelled at all.
        if !defender.itemSpent,
           let berry = Combatant.resistBerries[defender.item],
           berry == moveType, effectiveness > 1 {
            modifier *= 0.5
            notes.append("\(defender.item) halves it, then is consumed")
        }
        // Chilan halves any Normal-type hit, super-effective or not.
        if !defender.itemSpent, defender.item == "Chilan Berry", moveType == .normal {
            modifier *= 0.5
            notes.append("Chilan Berry halves it, then is consumed")
        }

        if defender.wideOpen {
            modifier *= 2
            notes.append("Glaive Rush: target is Wide Open, damage doubled")
        }

        if field.screen, !field.critical {
            modifier *= field.isDoubles ? 0.667 : 0.5
            notes.append("Screen: ×\(field.isDoubles ? "0.667" : "0.5")")
        }

        // The type-boost items: a fifth more of one type, which is what a
        // Charcoal on a Fire attacker is for. Read from a table rather than the
        // text because the text says "increased by 20%" in one place and
        // "increases damage inflicted by 20%" in another.
        if let boosted = Combatant.typeBoostItems[attacker.item], boosted == moveType {
            modifier *= 1.2
            notes.append("\(attacker.item): +20% \(moveType.rawValue)")
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

        // -- multi-hit ---------------------------------------------------------
        //
        // The calculator was reading the printed power and stopping there, so
        // Icicle Spear came out as a single 25 BP hit and Dragon Darts as 50.
        // Each strike is its own calculation in the game; totalling them is
        // close enough and is what the number on screen should mean.
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

        // -- rolls -----------------------------------------------------------
        var damages = rolls.map { roll -> Int in
            max(1, Int(floor(floor(base * roll) * modifier) * strikes))
        }

        // Focus Sash. From full HP it cannot be knocked out in one hit, which
        // makes "guaranteed OHKO" wrong against the 87% of Whimsicott sets
        // holding one. Sturdy behaves the same way.
        // A Sash stops one hit, not a move. Anything that strikes more than
        // once breaks it on the first and knocks out with the second, which is
        // most of the reason those moves are worth running.
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

        return DamageResult(minDamage: damages.first ?? 0,
                            maxDamage: damages.last ?? 0,
                            targetHP: defender.maxHP,
                            effectiveness: effectiveness,
                            notes: notes)
    }

    /// `ignored` is a Mold Breaker on the other side: every type immunity an
    /// ability grants — Levitate, Flash Fire, Water Absorb — is something it
    /// walks straight through.
    private static func applyDefensiveAbility(_ effectiveness: Double, moveType: PokeType,
                                              defender: Combatant, ignored: Bool = false,
                                              notes: inout [String]) -> Double {
        switch (ignored ? "" : defender.ability, moveType) {
        case ("Levitate", .ground):
            notes.append("Levitate: immune to Ground")
            return 0
        case ("Flash Fire", .fire), ("Water Absorb", .water), ("Volt Absorb", .electric),
             ("Sap Sipper", .grass), ("Storm Drain", .water), ("Lightning Rod", .electric),
             ("Motor Drive", .electric), ("Dry Skin", .water):
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
