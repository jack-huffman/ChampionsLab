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

    /// By the name the dataset uses. Accuracy and evasion are not stats and
    /// are not here; they are stages, and `Stage.named` knows them.
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

/// Something a battle can move up and down.
///
/// The six stats, and the two things that are stages without being stats.
/// Accuracy and evasion have no base value, nothing is spent on them, nothing
/// outside a battle has one and no card shows one — so they are not `Stat`,
/// which is the type the builder, the spread planner and every readout are
/// written in. But a Haze clears them, a Psych Up copies them, a Topsy-Turvy
/// turns them over and a switch leaves them behind, exactly like the six. So
/// they live in the same array, past the end of it, and the first six raw
/// values are `Stat`'s own so that everything already indexing by a stat goes
/// on working.
///
/// They were missing entirely before this. Twenty-three moves in the dex, five
/// items and a handful of abilities had the part of them that touches accuracy
/// quietly dropped on the floor: a Sand Attack did nothing at all, a Double
/// Team did nothing at all, and Hone Claws was half a move.
enum Stage: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case hp, attack, defense, spAttack, spDefense, speed, accuracy, evasion

    var id: Int { rawValue }

    init(_ stat: Stat) { self = Stage(rawValue: stat.rawValue) ?? .hp }

    /// The stat this stage belongs to, or nil for the two that are only ever
    /// stages.
    var stat: Stat? { Stat(rawValue: rawValue) }

    /// True for accuracy and evasion, whose stages are worth a third each
    /// rather than a half.
    var isAim: Bool { self == .accuracy || self == .evasion }

    static func named(_ name: String) -> Stage? {
        if let stat = Stat.named(name) { return Stage(stat) }
        switch name {
        case "accuracy": return .accuracy
        case "evasion":  return .evasion
        default:         return nil
        }
    }

    var short: String {
        switch self {
        case .accuracy: return "Acc"
        case .evasion:  return "Eva"
        default:        return stat?.short ?? ""
        }
    }

    var long: String {
        switch self {
        case .accuracy: return "accuracy"
        case .evasion:  return "evasiveness"
        default:        return stat?.long ?? ""
        }
    }

    /// What a stage is worth as a multiplier. The six stats move in halves
    /// from a base of two; accuracy and evasion move in thirds from a base of
    /// three, which is why a −1 to accuracy is a smaller thing than a −1 to
    /// Attack and why stacking them is worth so much less than it looks.
    func multiplier(_ stage: Int) -> Double {
        let base = isAim ? 3.0 : 2.0
        let steps = Double(Swift.max(-6, Swift.min(6, stage)))
        return steps >= 0 ? (base + steps) / base : base / (base - steps)
    }

    /// Every stage a battle keeps, which is the width of the array.
    static let width = Stage.allCases.count
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
