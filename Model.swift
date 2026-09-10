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
    /// For a Mega form, the held item that triggers it. Empty when Serebii has
    /// not published a name for that stone yet.
    let stone: String?

    var id: String { icon.isEmpty ? "\(species)-\(suffix)" : icon }

    enum CodingKeys: String, CodingKey {
        case dex, species, name, icon, suffix, types, stats, abilities, moves, stone
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
        ["m", "mx", "my", "mz"].contains(suffix) && formLabel.hasPrefix("Mega ")
    }

    /// Z Megas came from Legends: Z-A and are the M-C headliners.
    var isZMega: Bool { isMega && suffix == "mz" }

    /// Mega Evolution is spelled "Mega " with a space — "Meganium" is not one.
    var megaStone: String { stone ?? "" }
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

    /// Moves whose base power the calculator should not take at face value when
    /// picking a representative set: they cannot simply be clicked for that
    /// damage on the turn you want it.
    ///
    /// Serebii's effect text identifies most of them — "gains the Recharging
    /// status", "gains the Charging status", "The user faints" — so the test is
    /// mostly data-driven. A handful print no Battle Effect at all, and those are
    /// named explicitly.
    private static let unusableWithoutEffectText: Set<String> = [
        "shadowforce", "prismaticlaser", "eternabeam", "roaroftime",
        "skullbash", "freezeshock", "iceburn", "razorwind", "bide",
        // Conditional on a setup this model does not simulate.
        "belch", "dreameater", "hyperspacefury",
    ]

    /// Stages this move gives its own user, read from the effect text —
    /// "Boosts the user's Attack and Speed stats by 1 stage."
    var selfBoosts: [Stat: Int] {
        guard let match = effect.range(of: #"Boosts the user's .+? stats? by \d+ stage"#,
                                       options: .regularExpression) else { return [:] }
        let phrase = String(effect[match])
        guard let amount = phrase.range(of: #"\d+"#, options: [.regularExpression, .backwards])
            .flatMap({ Int(phrase[$0]) }) else { return [:] }
        let statsPart = phrase
            .replacingOccurrences(of: "Boosts the user's ", with: "")
            .replacingOccurrences(of: #" stats? by \d+ stage"#, with: "",
                                  options: .regularExpression)
        var out: [Stat: Int] = [:]
        for piece in statsPart.components(separatedBy: CharacterSet(charactersIn: ","))
            .flatMap({ $0.components(separatedBy: " and ") }) {
            let name = piece.trimmingCharacters(in: .whitespaces)
            switch name {
            case "Attack":  out[.attack] = amount
            case "Defense": out[.defense] = amount
            case "Sp. Atk": out[.spAttack] = amount
            case "Sp. Def": out[.spDefense] = amount
            case "Speed":   out[.speed] = amount
            default: break
            }
        }
        return out
    }

    var isImmediateAttack: Bool {
        guard isDamaging, power > 0 else { return false }
        if Move.unusableWithoutEffectText.contains(id) { return false }
        let text = effect.lowercased()
        for marker in ["recharging status", "charging status", "sky-high status",
                       "underground status", "submerged status", "concealed status",
                       "future attack status", "the user faints",
                       "fails if the user has already taken damage"] {
            if text.contains(marker) { return false }
        }
        return true
    }
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

// MARK: - Meta teams

/// A known opposing structure to test a team against. `projected` marks the
/// ones built for M-C from the new pieces rather than observed on a ladder.
struct MetaTeam: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let archetype: String
    let format: String
    let projected: Bool
    let source: String
    let note: String
    let members: [Member]

    struct Member: Codable, Hashable {
        let form: String
        let item: String
        let ability: String
        let moves: [String]
    }
}

/// A forward-looking call about the format, with its basis stated so a reader
/// can tell arithmetic from judgement.
struct Prediction: Codable, Identifiable, Hashable {
    let title: String
    let call: String
    let why: String
    let confidence: String
    let basis: String
    var id: String { title }
}

// MARK: - Root

struct Dataset: Codable {
    let regulation: Regulation
    let rules: Rules
    let items: [Item]
    let usage: [UsageEntry]
    let metaTeams: [MetaTeam]
    let predictions: [Prediction]
    let notes: MetaNotes
    let forms: [Form]
    let moves: [String: Move]
    let abilities: [String: AbilityEntry]
    let generated: String
    let sources: [String]

    enum CodingKeys: String, CodingKey {
        case regulation, rules, items, usage, notes, forms, moves, abilities
        case generated, sources
        case metaTeams = "meta_teams"
        case predictions
    }
}
