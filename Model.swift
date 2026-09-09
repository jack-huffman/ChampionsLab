//  Model.swift
//  The shapes in data/champions.json, as written by mkdata.py.

import Foundation

// MARK: - Pokémon

/// One legal entry in the roster. Megas are separate forms, not a variant of
/// their base: Mega Golisopod is Bug/Steel with 630 BST while Golisopod is
/// Bug/Water with 530, so they cannot share a record.
struct Form: Codable, Identifiable, Hashable {
    let dex: Int
    let species: String
    let name: String
    let icon: String
    let suffix: String
    let types: [String]
    let stats: [Int]
    let abilities: [Ability]
    let formLabel: String
    let moves: [String]

    var id: String { icon.isEmpty ? "\(species)-\(suffix)" : icon }

    enum CodingKeys: String, CodingKey {
        case dex, species, name, icon, suffix, types, stats, abilities, moves
        case formLabel = "form_label"
    }

    var hp: Int { stats[0] }
    var attack: Int { stats[1] }
    var defense: Int { stats[2] }
    var spAttack: Int { stats[3] }
    var spDefense: Int { stats[4] }
    var speed: Int { stats[5] }
    var bst: Int { stats.reduce(0, +) }

    /// A Mega only when the suffix says so *and* the label agrees — Rotom-Mow
    /// and Lycanroc-Midnight also carry a bare "-m".
    var isMega: Bool {
        ["m", "mx", "my", "mz"].contains(suffix) && formLabel.hasPrefix("Mega")
    }

    /// Z Megas came from Legends: Z-A and are the M-C headliners.
    var isZMega: Bool { isMega && suffix == "mz" }
}

struct Ability: Codable, Hashable {
    let name: String
    let desc: String
}

/// The dex-wide ability table, with everything that can use each one.
struct AbilityEntry: Codable, Identifiable, Hashable {
    let name: String
    let desc: String
    let users: [String]
    var id: String { name }
}

// MARK: - Moves

struct Move: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let category: String
    let power: Int
    let accuracy: Int
    let neverMisses: Bool
    let pp: Int
    let priority: Int
    let target: String
    let critRate: Double
    let flags: [String: Bool]
    let effect: String
    let effectRate: Double
    let learnable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, category, power, accuracy, pp, priority, target
        case flags, effect, learnable
        case neverMisses = "never_misses"
        case critRate = "crit_rate"
        case effectRate = "effect_rate"
    }

    var isDamaging: Bool { category == "Physical" || category == "Special" }
    var makesContact: Bool { flags["contact"] == true }
    var isSound: Bool { flags["sound"] == true }
    var isPunch: Bool { flags["punch"] == true }
    var isSlicing: Bool { flags["slicing"] == true }
    var isBullet: Bool { flags["bullet"] == true }
    var isWind: Bool { flags["wind"] == true }
    var isPowder: Bool { flags["powder"] == true }
    var isProtectable: Bool { flags["protectable"] != false }

    /// Hits more than one Pokémon, so it takes the 0.75x spread penalty and is
    /// the reason Earthquake and Rock Slide define doubles.
    var isSpread: Bool {
        target == "All Adjacent Foes" || target == "All Adjacent Pokémon"
    }

    /// Also hits your own partner. Earthquake does; Rock Slide does not.
    var hitsAlly: Bool { target == "All Adjacent Pokémon" }

    var accuracyLabel: String { neverMisses || accuracy == 0 ? "—" : "\(accuracy)" }
}

// MARK: - Items

struct Item: Codable, Identifiable, Hashable {
    let name: String
    let slug: String
    let effect: String
    let fling: Int
    let isNew: Bool?
    let category: String?
    let note: String?
    let short: String?

    var id: String { slug }
    var addedInMC: Bool { isNew == true }
    var blurb: String { short ?? effect }

    enum CodingKeys: String, CodingKey {
        case name, slug, effect, fling, category, note, short
        case isNew = "new"
    }
}

// MARK: - Regulation and meta

struct Regulation: Codable {
    let id: String
    let name: String
    let start: String
    let end: String
    let startNote: String
    let events: [String]
    let newPokemon: [String]
    let newMegas: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, start, end, events
        case startNote = "start_note"
        case newPokemon = "new_pokemon"
        case newMegas = "new_megas"
    }
}

struct FormatRule: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let teamSize: Int
    let bring: Int
    let note: String

    enum CodingKeys: String, CodingKey {
        case id, name, bring, note
        case teamSize = "team_size"
    }

    var isDoubles: Bool { id == "doubles" }
}

struct Rules: Codable {
    let formats: [FormatRule]
    let level: Int
    let spTotal: Int
    let spPerStat: Int
    let speciesClause: Bool
    let itemClause: Bool
    let gimmick: String
    let timer: Timer

    struct Timer: Codable {
        let matchSeconds: Int
        let playerSeconds: Int
        let teamPreviewSeconds: Int
        let turnSeconds: Int

        enum CodingKeys: String, CodingKey {
            case matchSeconds = "match_seconds"
            case playerSeconds = "player_seconds"
            case teamPreviewSeconds = "team_preview_seconds"
            case turnSeconds = "turn_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case formats, level, gimmick, timer
        case spTotal = "sp_total"
        case spPerStat = "sp_per_stat"
        case speciesClause = "species_clause"
        case itemClause = "item_clause"
    }
}

/// A threat in the usage table. `projected` marks the M-C arrivals that have no
/// ladder history yet — their placement is an argument, not a measurement.
struct UsageEntry: Codable, Identifiable, Hashable {
    let name: String
    let tier: String
    let usage: Double
    let projected: Bool?
    let formats: [String]
    let role: String
    let commonItems: [String]
    let keyMoves: [String]
    let why: String

    var id: String { name }
    var isProjected: Bool { projected == true }

    enum CodingKeys: String, CodingKey {
        case name, tier, usage, projected, formats, role, why
        case commonItems = "common_items"
        case keyMoves = "key_moves"
    }
}

struct MetaNotes: Codable {
    let headline: String
    let threads: [Thread]
    let antiMeta: [Thread]

    struct Thread: Codable, Identifiable, Hashable {
        let title: String
        let body: String
        var id: String { title }
    }

    enum CodingKeys: String, CodingKey {
        case headline, threads
        case antiMeta = "anti_meta"
    }
}

// MARK: - Root

struct Dataset: Codable {
    let regulation: Regulation
    let rules: Rules
    let items: [Item]
    let usage: [UsageEntry]
    let notes: MetaNotes
    let forms: [Form]
    let moves: [String: Move]
    let abilities: [String: AbilityEntry]
    let generated: String
    let sources: [String]
}
