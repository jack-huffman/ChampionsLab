//  Stats.swift
//  Champions' stat system, which is not the one the rest of the series uses.
//
//  Champions dropped IVs and EVs entirely. Every Pokémon is treated as having
//  31 IVs, and customisation happens through Stat Points: 66 to spend, at most
//  32 in any one stat, each worth exactly +1 at Level 50. Natures survive under
//  the name "Stat Alignment" with the usual ±10%.
//
//  At Level 50 that collapses to:
//
//      HP    = Base + 75 + SP
//      other = floor((Base + 20 + SP) * alignment)
//
//  A calculator built on 252 EVs would be wrong here, which is why this file
//  exists rather than reusing a standard VGC formula.

import Foundation

enum Stat: Int, CaseIterable, Identifiable, Codable {
    case hp, attack, defense, spAttack, spDefense, speed

    var id: Int { rawValue }

    /// By the name the dataset uses.
    ///
    /// Returns nil for "accuracy" and "evasion", which are real stages in the
    /// game and are not modelled here: stat stages are a six-slot array
    /// throughout. Muddy Water, Night Daze, Mud-Slap and Sand Attack lose that
    /// part of their effect, and the parity audit reports them.
    static func named(_ name: String) -> Stat? {
        switch name {
        case "hp":        return .hp
        case "attack":    return .attack
        case "defense":   return .defense
        case "spAttack":  return .spAttack
        case "spDefense": return .spDefense
        case "speed":     return .speed
        default:          return nil
        }
    }

    var short: String {
        switch self {
        case .hp:        return "HP"
        case .attack:    return "Atk"
        case .defense:   return "Def"
        case .spAttack:  return "SpA"
        case .spDefense: return "SpD"
        case .speed:     return "Spe"
        }
    }

    var long: String {
        switch self {
        case .hp:        return "HP"
        case .attack:    return "Attack"
        case .defense:   return "Defense"
        case .spAttack:  return "Sp. Attack"
        case .spDefense: return "Sp. Defense"
        case .speed:     return "Speed"
        }
    }
}

/// A nature by its Champions name. Serious is the only neutral one the game
/// still offers, so it is the default here.
struct Alignment: Identifiable, Hashable, Codable {
    let name: String
    let up: Stat?
    let down: Stat?

    var id: String { name }

    var label: String {
        guard let up, let down else { return "\(name) (neutral)" }
        return "\(name) (+\(up.short) / −\(down.short))"
    }

    func multiplier(for stat: Stat) -> Double {
        if stat == .hp { return 1 }
        if stat == up { return 1.1 }
        if stat == down { return 0.9 }
        return 1
    }

    static let neutral = Alignment(name: "Serious", up: nil, down: nil)

    /// The 21 alignments Champions offers: every up/down pair plus Serious.
    static let all: [Alignment] = {
        let pairs: [(String, Stat, Stat)] = [
            ("Lonely", .attack, .defense), ("Brave", .attack, .speed),
            ("Adamant", .attack, .spAttack), ("Naughty", .attack, .spDefense),
            ("Bold", .defense, .attack), ("Relaxed", .defense, .speed),
            ("Impish", .defense, .spAttack), ("Lax", .defense, .spDefense),
            ("Timid", .speed, .attack), ("Hasty", .speed, .defense),
            ("Jolly", .speed, .spAttack), ("Naive", .speed, .spDefense),
            ("Modest", .spAttack, .attack), ("Mild", .spAttack, .defense),
            ("Quiet", .spAttack, .speed), ("Rash", .spAttack, .spDefense),
            ("Calm", .spDefense, .attack), ("Gentle", .spDefense, .defense),
            ("Sassy", .spDefense, .speed), ("Careful", .spDefense, .spAttack),
        ]
        return [neutral] + pairs.map { Alignment(name: $0.0, up: $0.1, down: $0.2) }
    }()

    static func named(_ name: String) -> Alignment {
        all.first { $0.name == name } ?? neutral
    }
}

enum ChampionsStats {
    static let level = 50
    static let spTotal = 66
    static let spPerStat = 32

    /// The Level 50 value of one stat.
    static func value(base: Int, sp: Int, stat: Stat, alignment: Alignment) -> Int {
        if stat == .hp { return base + 75 + sp }
        let raw = Double(base + 20 + sp) * alignment.multiplier(for: stat)
        return Int(raw.rounded(.down))
    }

    /// All six, in `Stat.allCases` order.
    static func spread(form: Form, sp: [Int], alignment: Alignment) -> [Int] {
        Stat.allCases.map { stat in
            value(base: form.stats[stat.rawValue],
                  sp: sp.indices.contains(stat.rawValue) ? sp[stat.rawValue] : 0,
                  stat: stat, alignment: alignment)
        }
    }

    /// What a stat reaches with everything poured into it — the number to beat
    /// when you are checking whether you outrun something.
    static func maxValue(base: Int, stat: Stat, boosting: Bool) -> Int {
        value(base: base, sp: spPerStat, stat: stat,
              alignment: boosting ? Alignment(name: "x", up: stat, down: .hp) : .neutral)
    }

    /// Applies a −6...+6 battle stage to a computed stat.
    static func staged(_ value: Int, stage: Int) -> Int {
        let clamped = max(-6, min(6, stage))
        let factor: Double = clamped >= 0
            ? Double(2 + clamped) / 2.0
            : 2.0 / Double(2 - clamped)
        return max(1, Int((Double(value) * factor).rounded(.down)))
    }
}
