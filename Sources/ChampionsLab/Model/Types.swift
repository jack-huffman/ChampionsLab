//  Types.swift
//  The type chart, and the colours everything in the UI is keyed to.

import SwiftUI

enum PokeType: String, CaseIterable, Identifiable, Codable {
    case normal = "Normal", fire = "Fire", water = "Water", electric = "Electric"
    case grass = "Grass", ice = "Ice", fighting = "Fighting", poison = "Poison"
    case ground = "Ground", flying = "Flying", psychic = "Psychic", bug = "Bug"
    case rock = "Rock", ghost = "Ghost", dragon = "Dragon", dark = "Dark"
    case steel = "Steel", fairy = "Fairy"

    var id: String { rawValue }

    init?(loose name: String) {
        self.init(rawValue: name.capitalized)
    }

    /// Sampled from the type badges so chips and icons agree.
    var color: Color {
        switch self {
        case .normal:   return Color(red: 0.66, green: 0.66, blue: 0.59)
        case .fire:     return Color(red: 0.93, green: 0.51, blue: 0.19)
        case .water:    return Color(red: 0.39, green: 0.56, blue: 0.94)
        case .electric: return Color(red: 0.97, green: 0.82, blue: 0.17)
        case .grass:    return Color(red: 0.48, green: 0.78, blue: 0.30)
        case .ice:      return Color(red: 0.60, green: 0.85, blue: 0.84)
        case .fighting: return Color(red: 0.76, green: 0.18, blue: 0.16)
        case .poison:   return Color(red: 0.64, green: 0.24, blue: 0.63)
        case .ground:   return Color(red: 0.88, green: 0.75, blue: 0.41)
        case .flying:   return Color(red: 0.66, green: 0.56, blue: 0.95)
        case .psychic:  return Color(red: 0.98, green: 0.34, blue: 0.53)
        case .bug:      return Color(red: 0.65, green: 0.73, blue: 0.10)
        case .rock:     return Color(red: 0.72, green: 0.63, blue: 0.22)
        case .ghost:    return Color(red: 0.45, green: 0.34, blue: 0.59)
        case .dragon:   return Color(red: 0.44, green: 0.21, blue: 0.98)
        case .dark:     return Color(red: 0.44, green: 0.34, blue: 0.28)
        case .steel:    return Color(red: 0.72, green: 0.72, blue: 0.81)
        case .fairy:    return Color(red: 0.85, green: 0.52, blue: 0.68)
        }
    }

    /// Text that stays readable on `color`.
    var onColor: Color {
        switch self {
        case .electric, .ice, .ground, .steel, .normal, .bug, .rock, .fairy:
            return Color.black.opacity(0.82)
        default:
            return .white
        }
    }
}

enum TypeChart {
    /// Attacker -> defender multipliers. Only the non-1.0 entries are listed.
    private static let table: [PokeType: [PokeType: Double]] = [
        .normal:   [.rock: 0.5, .ghost: 0, .steel: 0.5],
        .fire:     [.fire: 0.5, .water: 0.5, .grass: 2, .ice: 2, .bug: 2,
                    .rock: 0.5, .dragon: 0.5, .steel: 2],
        .water:    [.fire: 2, .water: 0.5, .grass: 0.5, .ground: 2, .rock: 2,
                    .dragon: 0.5],
        .electric: [.water: 2, .electric: 0.5, .grass: 0.5, .ground: 0,
                    .flying: 2, .dragon: 0.5],
        .grass:    [.fire: 0.5, .water: 2, .grass: 0.5, .poison: 0.5, .ground: 2,
                    .flying: 0.5, .bug: 0.5, .rock: 2, .dragon: 0.5, .steel: 0.5],
        .ice:      [.fire: 0.5, .water: 0.5, .grass: 2, .ice: 0.5, .ground: 2,
                    .flying: 2, .dragon: 2, .steel: 0.5],
        .fighting: [.normal: 2, .ice: 2, .poison: 0.5, .flying: 0.5,
                    .psychic: 0.5, .bug: 0.5, .rock: 2, .ghost: 0, .dark: 2,
                    .steel: 2, .fairy: 0.5],
        .poison:   [.grass: 2, .poison: 0.5, .ground: 0.5, .rock: 0.5,
                    .ghost: 0.5, .steel: 0, .fairy: 2],
        .ground:   [.fire: 2, .electric: 2, .grass: 0.5, .poison: 2, .flying: 0,
                    .bug: 0.5, .rock: 2, .steel: 2],
        .flying:   [.electric: 0.5, .grass: 2, .fighting: 2, .bug: 2, .rock: 0.5,
                    .steel: 0.5],
        .psychic:  [.fighting: 2, .poison: 2, .psychic: 0.5, .dark: 0, .steel: 0.5],
        .bug:      [.fire: 0.5, .grass: 2, .fighting: 0.5, .poison: 0.5,
                    .flying: 0.5, .psychic: 2, .ghost: 0.5, .dark: 2,
                    .steel: 0.5, .fairy: 0.5],
        .rock:     [.fire: 2, .ice: 2, .fighting: 0.5, .ground: 0.5, .flying: 2,
                    .bug: 2, .steel: 0.5],
        .ghost:    [.normal: 0, .psychic: 2, .ghost: 2, .dark: 0.5],
        .dragon:   [.dragon: 2, .steel: 0.5, .fairy: 0],
        .dark:     [.fighting: 0.5, .psychic: 2, .ghost: 2, .dark: 0.5, .fairy: 0.5],
        .steel:    [.fire: 0.5, .water: 0.5, .electric: 0.5, .ice: 2, .rock: 2,
                    .steel: 0.5, .fairy: 2],
        .fairy:    [.fire: 0.5, .fighting: 2, .poison: 0.5, .dragon: 2,
                    .dark: 2, .steel: 0.5],
    ]

    static func multiplier(_ attack: PokeType, into defender: PokeType) -> Double {
        table[attack]?[defender] ?? 1
    }

    /// Effectiveness against a defending type combination.
    static func multiplier(_ attack: PokeType, into defenders: [PokeType]) -> Double {
        defenders.reduce(1) { $0 * multiplier(attack, into: $1) }
    }

    static func multiplier(_ attack: PokeType, into form: Form) -> Double {
        multiplier(attack, into: form.pokeTypes)
    }

    /// Damage taken accounting for the ability, which the raw chart cannot see:
    /// Levitate is the whole point of Mega Garchomp Z, and Mega Baxcalibur's
    /// Thermal Exchange changes how you think about Fire coverage.
    static func multiplier(_ attack: PokeType, into form: Form, ability: String?) -> Double {
        let base = multiplier(attack, into: form.pokeTypes)
        guard let ability, !ability.isEmpty else { return base }
        switch (ability, attack) {
        case ("Levitate", .ground):                       return 0
        case ("Flash Fire", .fire):                       return 0
        case ("Water Absorb", .water), ("Storm Drain", .water),
             ("Dry Skin", .water):                        return 0
        case ("Volt Absorb", .electric), ("Lightning Rod", .electric),
             ("Motor Drive", .electric):                  return 0
        case ("Sap Sipper", .grass):                      return 0
        case ("Thick Fat", .fire), ("Thick Fat", .ice):   return base * 0.5
        case ("Heatproof", .fire), ("Water Bubble", .fire): return base * 0.5
        case ("Fluffy", .fire):                           return base * 2
        case ("Purifying Salt", .ghost):                  return base * 0.5
        default:
            if ability == "Filter" || ability == "Solid Rock" || ability == "Prism Armor" {
                return base > 1 ? base * 0.75 : base
            }
            if ability == "Wonder Guard" { return base > 1 ? base : 0 }
            return base
        }
    }

    static func label(_ multiplier: Double) -> String {
        switch multiplier {
        case 0:     return "0"
        case 0.25:  return "¼"
        case 0.5:   return "½"
        case 1:     return "1"
        case 2:     return "2"
        case 4:     return "4"
        default:    return String(format: "%g", multiplier)
        }
    }

    /// Red where it hurts, green where it is resisted.
    static func color(_ multiplier: Double) -> Color {
        switch multiplier {
        case 0:            return Color(red: 0.30, green: 0.62, blue: 0.42)
        case ..<0.5:       return Color(red: 0.35, green: 0.68, blue: 0.47)
        case ..<1:         return Color(red: 0.48, green: 0.73, blue: 0.52)
        case 1:            return Color.secondary.opacity(0.30)
        case ..<4:         return Color(red: 0.87, green: 0.45, blue: 0.30)
        default:           return Color(red: 0.80, green: 0.25, blue: 0.25)
        }
    }
}

extension Form {
    /// Parsed once per form and kept.
    ///
    /// This was `types.compactMap { PokeType(loose: $0) }` on every read, which
    /// capitalises two strings and allocates an array. It is read for every
    /// damage roll, every status check and every hazard, several times each, so
    /// it was one of the hottest things in the app: doing it once per form
    /// takes 13 ms off the longest unbroken stretch of a build.
    private static let parsedTypes = Memo<String, [PokeType]>()

    var pokeTypes: [PokeType] {
        Form.parsedTypes.value(id) { types.compactMap { PokeType(loose: $0) } }
    }

    /// Incoming multipliers for all 18 types.
    func weaknesses(ability: String? = nil) -> [PokeType: Double] {
        var out: [PokeType: Double] = [:]
        for attack in PokeType.allCases {
            out[attack] = TypeChart.multiplier(attack, into: self, ability: ability)
        }
        return out
    }
}
