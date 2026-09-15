//  Model.swift
//  The shapes in data/champions.json, as written by mkdata.py.

import Foundation

// MARK: - Pokémon

/// One legal entry in the roster. Megas are separate forms, not a variant of
/// their base: Mega Golisopod is Bug/Steel with 630 BST while Golisopod is
/// Bug/Water with 530, so they cannot share a record.
struct Form: Codable, Identifiable, Hashable, Sendable {
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

/// A lasting condition. Burn halves what a physical attacker does and chips
/// it every turn; paralysis halves Speed and costs a turn now and then.
enum Ailment: String {
    case none = "", burn = "burned", paralysis = "paralysed", poison = "poisoned"
    case badPoison = "badly poisoned", sleep = "asleep", freeze = "frozen"

    /// Whether it stops a physical attacker being one.
    var halvesPhysical: Bool { self == .burn }
    var halvesSpeed: Bool { self == .paralysis }
}

struct Move: Codable, Identifiable, Hashable, Sendable {
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

    /// Feint, Phantom Force, Shadow Force: goes through Protect and takes it
    /// down, so everything else aimed there this turn lands too.
    internal var computedBreaksProtect: Bool {
        effect.lowercased().contains("removes the effects of those moves")
    }

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
    /// Who a move is pointed at, and therefore whether you get to choose.
    ///
    /// The dex's own target field is too coarse to use on its own: "Selected
    /// Target" covers Protect, Swords Dance, Helping Hand and Thunder Wave,
    /// which are aimed at four different things. Spread moves it does get
    /// right, and the rest is read from what the move does.
    enum Aim: Sendable {
        /// One opponent, and you pick which.
        case foe
        /// Everything it can reach; no choice to make.
        case spread
        /// Itself.
        case user
        /// Its partner.
        case ally
        /// The side, or the field.
        case side
        /// A fainted member of the user's own party, and you pick which.
        case party
    }

    internal var computedAim: Aim {
        if isSpread { return .spread }
        if Move.partyMoves.contains(name) { return .party }
        if Move.sideMoves.contains(name) { return .side }
        if Move.allyMoves.contains(name) { return .ally }
        if Move.selfMoves.contains(name) { return .user }
        // The computed forms, not the memoised ones: this *is* the parse, and
        // asking the memo for a move it is still parsing never returns.
        if !isDamaging, !computedSelfBoosts.isEmpty, computedTargetDrops.isEmpty { return .user }
        return .foe
    }

    /// Aimed at somebody on the bench: the one move that brings a Pokémon back.
    static let partyMoves: Set<String> = ["Revival Blessing"]

    /// Protect and its family. Named rather than read from the text because
    /// the family is small, closed and easy to get wrong: Wide Guard and Quick
    /// Guard read almost identically and do something else entirely, and Endure
    /// leaves you on one health point rather than untouched.
    static let protectMoves: Set<String> = [
        "Protect", "Detect", "Spiky Shield", "Baneful Bunker",
        "Burning Bulwark", "Silk Trap", "Obstruct", "King's Shield",
    ]

    /// Aimed at the user's own side or the whole field.
    static let sideMoves: Set<String> = [
        "Tailwind", "Trick Room", "Reflect", "Light Screen", "Aurora Veil",
        "Wide Guard", "Quick Guard", "Safeguard", "Mist", "Lucky Chant",
        "Sunny Day", "Rain Dance", "Sandstorm", "Snowscape", "Hail",
        "Grassy Terrain", "Electric Terrain", "Misty Terrain", "Psychic Terrain",
        "Gravity", "Magic Room", "Wonder Room", "Perish Song", "Haze",
    ]

    /// Aimed at the partner.
    static let allyMoves: Set<String> = [
        "Helping Hand", "Coaching", "Decorate", "Life Dew", "Aromatic Mist",
        "Heal Pulse", "After You", "Ally Switch", "Instruct", "Floral Healing",
    ]

    /// Aimed at itself, beyond anything the boost text already implies.
    static let selfMoves: Set<String> = [
        "Protect", "Detect", "Spiky Shield", "Baneful Bunker", "Burning Bulwark",
        "Silk Trap", "Obstruct", "King's Shield", "Endure", "Substitute",
        "Rest", "Recover", "Roost", "Soft-Boiled", "Synthesis", "Moonlight",
        "Morning Sun", "Slack Off", "Shore Up", "Milk Drink", "Follow Me",
        "Rage Powder", "Baton Pass", "Belly Drum", "Focus Energy", "Stockpile",
        "Charge", "Ingrain", "Aqua Ring", "Curse", "Destiny Bond",
    ]

    /// Stages this move takes off whatever it is aimed at.
    ///
    /// "Lowers targets' Speed stats by 1 stage" is Icy Wind, which is most of
    /// what speed control looks like outside Tailwind, and "Lowers the target's
    /// Attack and Sp. Atk stats by 1 stage" is Parting Shot. Read from the same
    /// sentence the boosts are, because it is written the same way.
    internal var computedTargetDrops: [Stat: Int] {
        guard let match = effect.range(
            // "targets'" and "the target's" both appear, and the apostrophe
            // falls in different places: a spread move lowers *targets'*
            // Speed, a single-target one lowers *the target's*. Missing the
            // second spelling quietly silenced Screech, Scary Face, Noble Roar
            // and every other single-target drop in the game.
            of: #"Lowers (?:the )?targets?'?s? .+? stats? by \d+ stage"#,
            options: .regularExpression) else { return [:] }
        let phrase = String(effect[match])
        guard let amount = phrase.range(of: #"\d+"#, options: [.regularExpression, .backwards])
            .flatMap({ Int(phrase[$0]) }) else { return [:] }
        let statsPart = phrase
            .replacingOccurrences(of: #"^Lowers (?:the )?targets?'?s? "#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #" stats? by \d+ stage"#, with: "",
                                  options: .regularExpression)
        var out: [Stat: Int] = [:]
        for piece in statsPart.components(separatedBy: CharacterSet(charactersIn: ","))
            .flatMap({ $0.components(separatedBy: " and ") }) {
            switch piece.trimmingCharacters(in: .whitespaces) {
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

    /// A move that takes a turn to wind up: what the user does on the first
    /// turn, whether it is out of reach while doing it, and the weather that
    /// lets it skip the wait. Read from the text, which is regular about it.
    struct Charge: Sendable {
        /// Fly, Dig, Dive, Bounce, Phantom Force: nothing reaches it meanwhile.
        let hides: Bool
        /// Solar Beam fires at once in sun, Electro Shot in rain.
        let skipsIn: Weather?
        /// Stages gained on the charging turn: Electro Shot and Meteor Beam
        /// raise Special Attack while they wind up.
        let boosts: [Stat: Int]
    }

    internal var computedCharge: Charge? {
        let lower = effect.lowercased()
        guard lower.contains("status on the turn this move is used then attacks on the following turn")
        else { return nil }
        let hides = ["sky-high", "underground", "submerged", "concealed"]
            .contains { lower.contains("gains the \($0) status") }
        var skipsIn: Weather?
        if lower.contains("in rain the user does not gain") { skipsIn = .rain }
        if lower.contains("in harsh sunlight the user does not gain") { skipsIn = .sun }
        var boosts: [Stat: Int] = [:]
        if let match = effect.range(of: #"The user's (.+?) stat is boosted by (\d+) stage"#,
                                    options: .regularExpression) {
            let phrase = String(effect[match])
            let amount = phrase.range(of: #"\d+"#, options: .regularExpression)
                .flatMap { Int(phrase[$0]) } ?? 1
            let statName = phrase
                .replacingOccurrences(of: "The user's ", with: "")
                .replacingOccurrences(of: #" stat is boosted by \d+ stage"#, with: "",
                                      options: .regularExpression)
            switch statName {
            case "Attack":  boosts[.attack] = amount
            case "Defense": boosts[.defense] = amount
            case "Sp. Atk": boosts[.spAttack] = amount
            case "Sp. Def": boosts[.spDefense] = amount
            case "Speed":   boosts[.speed] = amount
            default: break
            }
        }
        return Charge(hides: hides, skipsIn: skipsIn, boosts: boosts)
    }

    /// The share of the damage dealt that comes back to the user: Leech Life,
    /// Drain Punch, Giga Drain and Horn Leech at half, Draining Kiss at three
    /// quarters. Read from the text.
    internal var computedDrainShare: Double? {
        guard let match = effect.range(of: #"restored by (\d+)/(\d+) of the damage dealt"#,
                                       options: .regularExpression) else { return nil }
        let numbers = effect[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2, numbers[1] > 0 else { return nil }
        return Double(numbers[0]) / Double(numbers[1])
    }

    /// What a hit does besides damage, and how often: Scald's burn three times
    /// in ten, Nuzzle's paralysis every time, Rock Slide's flinch, a chance of
    /// a stage off the target. Read from the text, which is regular about it.
    struct Secondary: Sendable {
        enum Kind: Sendable {
            case status(Ailment)
            case flinch
            case drops([Stat: Int])
            case confuse
        }
        let chance: Int
        let kind: Kind
    }

    internal var computedSecondary: Secondary? {
        let text = effect
        func ailment(_ verb: String) -> Ailment? {
            switch verb {
            case "burning", "burns": return .burn
            case "paralyzing", "paralyzes": return .paralysis
            case "poisoning", "poisons": return .poison
            case "badly poisoning", "badly poisons": return .badPoison
            case "freezing", "freezes": return .freeze
            default: return nil
            }
        }
        if let match = text.range(of: #"Has a (\d+)% chance of (badly poisoning|burning|paralyzing|poisoning|freezing) the target"#,
                                  options: .regularExpression) {
            let phrase = String(text[match])
            let chance = Int(phrase.split(separator: " ")[2].dropLast()) ?? 0
            let verb = phrase.replacingOccurrences(of: #"^Has a \d+% chance of "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " the target", with: "")
            if let ailment = ailment(verb) { return Secondary(chance: chance, kind: .status(ailment)) }
        }
        if let match = text.range(of: #"Has a (\d+)% chance of confusing the target"#,
                                  options: .regularExpression) {
            let chance = Int(String(text[match]).split(separator: " ")[2].dropLast()) ?? 0
            return Secondary(chance: chance, kind: .confuse)
        }
        if let match = text.range(of: #"Has a (\d+)% chance of making (?:the )?targets? flinch"#,
                                  options: .regularExpression) {
            let chance = Int(String(text[match]).split(separator: " ")[2].dropLast()) ?? 0
            return Secondary(chance: chance, kind: .flinch)
        }
        if let match = text.range(of: #"Has a (\d+)% chance of lowering (?:the )?targets?'? (.+?) stats? by (\d+) stage"#,
                                  options: .regularExpression) {
            let phrase = String(text[match])
            let chance = Int(phrase.split(separator: " ")[2].dropLast()) ?? 0
            let amount = phrase.range(of: #"\d+ stage"#, options: .regularExpression)
                .flatMap { Int(phrase[$0].split(separator: " ")[0]) } ?? 1
            let statName = phrase
                .replacingOccurrences(of: #"^Has a \d+% chance of lowering (?:the )?targets?'? "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" stats? by \d+ stage"#, with: "", options: .regularExpression)
            let stat: Stat? = ["Attack": .attack, "Defense": .defense, "Sp. Atk": .spAttack,
                               "Sp. Def": .spDefense, "Speed": .speed][statName]
            if let stat { return Secondary(chance: chance, kind: .drops([stat: amount])) }
            return nil   // accuracy and evasion are not stats this model keeps
        }
        // The certain ones: "Paralyzes the target." — but not Fake Out's
        // flinch, which the turn handles itself.
        for (verb, ailment) in [("Paralyzes the target", Ailment.paralysis), ("Burns the target", .burn),
                                ("Poisons the target", .poison), ("Badly poisons the target", .badPoison)]
        where text.hasPrefix(verb) || text.contains(". \(verb)") {
            return Secondary(chance: 100, kind: .status(ailment))
        }
        return nil
    }

    /// What a healing move gives back, as a share of the bar, and to whom.
    /// Recover's half to the user, Heal Pulse's half to the partner, Life
    /// Dew's quarter to both; Synthesis and its kind read the weather.
    struct Healing: Sendable {
        enum Whom: Sendable { case user, partner, both }
        let share: Double
        let whom: Whom
        /// Two thirds in sun, a quarter in any other weather.
        let sunlit: Bool
    }

    internal var computedHealing: Healing? {
        let text = effect
        if text.hasPrefix("Fully restores the user's HP") { return Healing(share: 1, whom: .user, sunlit: false) }
        guard let match = text.range(of: #"Restores (\d+)/(\d+) of (the user's|the target's|the max HP of the user and its allies|the max HP of the user or an ally|its) max HP|Restores (\d+)/(\d+) of the max HP of the user (and its allies|or an ally)"#,
                                     options: .regularExpression) else { return nil }
        let phrase = String(text[match])
        let numbers = phrase.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2, numbers[1] > 0 else { return nil }
        let share = Double(numbers[0]) / Double(numbers[1])
        let whom: Healing.Whom = phrase.contains("and its allies") ? .both
            : phrase.contains("target's") ? .partner : .user
        return Healing(share: share, whom: whom, sunlit: text.contains("In harsh sunlight 2/3"))
    }

    /// Confuse Ray, Swagger, Flatter, Dynamic Punch: the target ends up
    /// confused whatever else the move does.
    internal var computedConfuses: Bool {
        let lower = effect.lowercased()
        return lower.hasPrefix("confuses the target") || lower.contains("and confuses it")
            || lower.contains("confuses all other")
    }

    /// Swagger's two stages of Attack, Flatter's one of Special Attack: a
    /// raise handed to the target, which only makes sense with the confusion.
    internal var computedTargetBoosts: [Stat: Int] {
        guard let match = effect.range(of: #"Boosts the target's (.+?) stats? by (\d+) stage"#,
                                       options: .regularExpression) else { return [:] }
        let phrase = String(effect[match])
        let amount = phrase.range(of: #"\d+"#, options: [.regularExpression, .backwards])
            .flatMap { Int(phrase[$0]) } ?? 1
        let statName = phrase
            .replacingOccurrences(of: "Boosts the target's ", with: "")
            .replacingOccurrences(of: #" stats? by \d+ stage"#, with: "", options: .regularExpression)
        let stat: Stat? = ["Attack": .attack, "Defense": .defense, "Sp. Atk": .spAttack,
                           "Sp. Def": .spDefense, "Speed": .speed][statName]
        return stat.map { [$0: amount] } ?? [:]
    }

    /// Stomping Tantrum: twice the power after a turn the user's move missed,
    /// failed, or never happened.
    internal var computedDoublesAfterFailure: Bool {
        effect.lowercased().contains("doubled if the user couldn't act or its move missed or failed")
    }

    internal var computedSelfBoosts: [Stat: Int] { ownChanges(verb: "Boosts") }

    /// What a move costs the user in stages: Close Combat's Defence and
    /// Special Defence, Overheat's two stages of Special Attack. Positive
    /// numbers, the way the drops on a target are.
    internal var computedSelfDrops: [Stat: Int] { ownChanges(verb: "Lowers") }

    internal func ownChanges(verb: String) -> [Stat: Int] {
        guard let match = effect.range(of: "\(verb) the user's .+? stats? by \\d+ stage",
                                       options: .regularExpression) else { return [:] }
        let phrase = String(effect[match])
        guard let amount = phrase.range(of: #"\d+"#, options: [.regularExpression, .backwards])
            .flatMap({ Int(phrase[$0]) }) else { return [:] }
        let statsPart = phrase
            .replacingOccurrences(of: "\(verb) the user's ", with: "")
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
    /// Whether anybody has actually been seen holding it in Champions.
    ///
    /// The item list is scraped from Serebii's main-series itemdex, because
    /// Serebii has no Champions one — its Champions hub links straight to the
    /// general list. A good number of those items are not in this game: Assault
    /// Vest appears on none of the 105 registered team lists while Choice Scarf
    /// appears on twenty-two, and Choice Band, Choice Specs, Covert Cloak,
    /// Eviolite and Weakness Policy are all absent too.
    ///
    /// Optional so that a dataset built before this existed still decodes. A
    /// non-optional field added here once took the whole file down.
    let attested: Bool?
    /// Where it was seen, for the tooltip that explains the gate.
    let attestation: String?

    var id: String { slug }
    var addedInMC: Bool { isNew == true }
    var blurb: String { short ?? effect }

    /// Absence of evidence, stated as such. A legal but unpopular item looks
    /// exactly like one that is not in the game, so nothing here claims an item
    /// is illegal — only that nobody has been seen holding it. The calculator
    /// still supports it; the builder will not reach for it.
    var seenInGame: Bool { attested ?? true }

    enum CodingKeys: String, CodingKey {
        case name, slug, effect, fling, category, note, short, attested, attestation
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

struct FormatRule: Codable, Identifiable, Hashable, Sendable {
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
struct UsageEntry: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let tier: String
    let usage: Double
    let projected: Bool?
    let formats: [String]
    let role: String
    let commonItems: [String]
    let keyMoves: [String]
    let why: String
    /// Measured ladder figures, present when data/usage.json has been built.
    let winrate: Double?
    let wins: Int?
    let losses: Int?
    let moveUsage: [UsageShare]?
    let itemUsage: [UsageShare]?
    let abilityUsage: [UsageShare]?
    let teammates: [String]?

    var hasLiveData: Bool { winrate != nil || (moveUsage?.isEmpty == false) }
    var record: String? {
        guard let wins, let losses else { return nil }
        return "\(wins)W / \(losses)L"
    }

    var id: String { name }
    var isProjected: Bool { projected == true }

    enum CodingKeys: String, CodingKey {
        case name, tier, usage, projected, formats, role, why
        case commonItems = "common_items"
        case keyMoves = "key_moves"
        case winrate, wins, losses, teammates
        case moveUsage = "move_usage"
        case itemUsage = "item_usage"
        case abilityUsage = "ability_usage"
    }
}

/// One line of a usage breakdown: a name and the share of sets running it.
struct UsageShare: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let percent: Double
    var id: String { name }
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
    /// "7-0" for a team taken from a real event; nil for a written archetype.
    let record: String?
    let placement: String?

    /// Games won as a share, where a real record exists. This is the only
    /// outside evidence in the whole dataset about whether a team is any good,
    /// so it is what the scoring weights get calibrated against.
    var winRate: Double? {
        guard let record else { return nil }
        let parts = record.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] + parts[1] > 0 else { return nil }
        return Double(parts[0]) / Double(parts[0] + parts[1])
    }
    var gamesPlayed: Int {
        guard let record else { return 0 }
        return record.split(separator: "-").compactMap { Int($0) }.prefix(2).reduce(0, +)
    }

    struct Member: Codable, Hashable {
        let form: String
        let item: String
        let ability: String
        let moves: [String]
        /// The Stat Alignment they registered, where the team list published
        /// one. Spreads are never published; this is.
        let nature: String?
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

    /// A copy carrying a different usage table — how a live refresh lands.
    func replacingUsage(with table: [UsageEntry]) -> Dataset {
        Dataset(regulation: regulation, rules: rules, items: items, usage: table,
                metaTeams: metaTeams, predictions: predictions, notes: notes,
                forms: forms, moves: moves, abilities: abilities,
                generated: generated, sources: sources)
    }
}
