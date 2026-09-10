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

    func stat(_ stat: Stat) -> Int {
        ChampionsStats.value(base: form.stats[stat.rawValue],
                             sp: sp[stat.rawValue], stat: stat, alignment: alignment)
    }

    func stagedStat(_ stat: Stat) -> Int {
        ChampionsStats.staged(self.stat(stat), stage: boosts[stat.rawValue])
    }

    var effectiveTypes: [PokeType] { form.pokeTypes }

    var maxHP: Int { stat(.hp) }
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

    static func calculate(attacker: Combatant, defender: Combatant,
                          move: Move, field: Field) -> DamageResult {
        var notes: [String] = []
        guard move.isDamaging, move.power > 0 else {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 1, notes: ["Status move"])
        }

        var moveType = PokeType(loose: move.type) ?? .normal
        var power = Double(move.power)

        // -- ability-driven type changes ------------------------------------
        // Aerilate is the reason Mega Salamence clicks Double-Edge: a Normal
        // move becomes Flying and gains 20% before anything else applies.
        if attacker.ability == "Aerilate", moveType == .normal {
            moveType = .flying
            power *= 1.2
            notes.append("Aerilate: Normal → Flying, +20%")
        } else if attacker.ability == "Pixilate", moveType == .normal {
            moveType = .fairy; power *= 1.2
            notes.append("Pixilate: Normal → Fairy, +20%")
        } else if attacker.ability == "Refrigerate", moveType == .normal {
            moveType = .ice; power *= 1.2
            notes.append("Refrigerate: Normal → Ice, +20%")
        } else if attacker.ability == "Galvanize", moveType == .normal {
            moveType = .electric; power *= 1.2
            notes.append("Galvanize: Normal → Electric, +20%")
        } else if attacker.ability == "Normalize" {
            moveType = .normal; power *= 1.2
        }

        // -- power modifiers -------------------------------------------------
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

        // -- attack and defence ---------------------------------------------
        let physical = move.category == "Physical"
        let atkStat: Stat = physical ? .attack : .spAttack
        let defStat: Stat = physical ? .defense : .spDefense

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
        if field.weather == .snow, defender.form.pokeTypes.contains(.ice), physical {
            defense *= 1.5
            notes.append("Snow: Ice Defense ×1.5")
        }
        if field.weather == .sand, defender.form.pokeTypes.contains(.rock), !physical {
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
        var stab = attacker.form.pokeTypes.contains(moveType) ? 1.5 : 1.0
        if attacker.ability == "Adaptability", stab > 1 { stab = 2.0 }
        modifier *= stab

        // -- effectiveness ---------------------------------------------------
        var effectiveness = 1.0
        for type in defender.effectiveTypes {
            effectiveness *= TypeChart.multiplier(moveType, into: type)
        }
        effectiveness = applyDefensiveAbility(effectiveness, moveType: moveType,
                                              defender: defender, notes: &notes)
        modifier *= effectiveness

        if effectiveness == 0 {
            return DamageResult(minDamage: 0, maxDamage: 0, targetHP: defender.maxHP,
                                effectiveness: 0, notes: notes + ["No effect"])
        }

        // Aura Guard is what makes Mega Lucario Z awkward to break: it halves
        // every contact move, and most physical attackers only have those.
        if defender.ability == "Aura Guard", move.makesContact {
            modifier *= 0.5
            notes.append("Aura Guard: contact halved")
        }
        if defender.ability == "Multiscale" || defender.ability == "Shadow Shield" {
            modifier *= 0.5
            notes.append("\(defender.ability) at full HP: ×0.5")
        }
        if defender.ability == "Ice Scales", !physical { modifier *= 0.5 }
        if effectiveness > 1,
           ["Filter", "Solid Rock", "Prism Armor"].contains(defender.ability) {
            modifier *= 0.75
        }
        if effectiveness > 1, defender.item == "Weakness Policy" {
            notes.append("Triggers Weakness Policy (+2 Atk / +2 SpA)")
        }

        if defender.wideOpen {
            modifier *= 2
            notes.append("Glaive Rush: target is Wide Open, damage doubled")
        }

        if field.screen, !field.critical {
            modifier *= field.isDoubles ? 0.667 : 0.5
            notes.append("Screen: ×\(field.isDoubles ? "0.667" : "0.5")")
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

        // -- rolls -----------------------------------------------------------
        let damages = rolls.map { roll -> Int in
            max(1, Int(floor(floor(base * roll) * modifier)))
        }
        return DamageResult(minDamage: damages.first ?? 0,
                            maxDamage: damages.last ?? 0,
                            targetHP: defender.maxHP,
                            effectiveness: effectiveness,
                            notes: notes)
    }

    private static func applyDefensiveAbility(_ effectiveness: Double, moveType: PokeType,
                                              defender: Combatant,
                                              notes: inout [String]) -> Double {
        switch (defender.ability, moveType) {
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
