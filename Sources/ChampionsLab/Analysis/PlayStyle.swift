//  PlayStyle.swift
//  The jobs a Pokémon can actually be built to do.
//
//  Base stats say what something is capable of; they do not say what people
//  build it as. Dragapult has 120 Attack and 100 Sp. Atk, and reading only
//  those gets you "physical attacker" — which misses that it owns twenty-six
//  physical moves, seventeen special ones, Will-O-Wisp, Thunder Wave, both
//  screens, U-turn and Dragon Dance at 142 Speed. It is four different Pokémon
//  depending on the set.
//
//  So each job is checked separately against the learnset, the stats and the
//  ability, and where the ladder has measured sets for a Pokémon, how much of
//  the time people actually do it. A style with real usage behind it is
//  reported differently from one that is merely legal, because the difference
//  matters.

import Foundation

struct PlayStyle: Identifiable {
    let name: String
    /// How it does the job — the moves or ability that qualify it.
    let how: [String]
    /// Share of measured sets that look like this, where the ladder has data.
    let measured: Double?
    /// How well its stats suit the job, 0…1, for ordering when nobody has
    /// measured it. A Pokémon that could technically run a special set and has
    /// 60 Sp. Atk should not be listed above what it is actually good at.
    let fit: Double
    var id: String { name }

    /// Is this what people build, or only what it could be built as?
    var isPlayed: Bool { (measured ?? 0) >= 0.12 }
    var evidence: String {
        if let measured, measured > 0 {
            return String(format: "%.0f%% of measured sets", measured * 100)
        }
        return "from its learnset"
    }
}

@MainActor
extension Store {
    /// Every job this Pokémon can credibly be built for, most-played first.
    func playStyles(of form: Form) -> [PlayStyle] {
        let role = statRole(of: form)
        let learnset = moves(for: form)
        let names = Set(learnset.map(\.name))
        let abilities = Set(form.abilities.map(\.name))
        let entry = data.usage.first {
            ($0.name == form.formLabel || $0.name == form.name) && !$0.isProjected
        }
        let shares: [String: Double] = Dictionary(
            (entry?.moveUsage ?? []).map { ($0.name, $0.percent / 100) },
            uniquingKeysWith: { a, _ in a })

        /// How much of the measured sets use any of these moves. Shares are
        /// per-move across four slots, so this is capped rather than summed
        /// into nonsense.
        func share(_ of: Set<String>) -> Double? {
            guard entry?.moveUsage?.isEmpty == false else { return nil }
            let hits = of.compactMap { shares[$0] }
            guard !hits.isEmpty else { return 0 }
            return min(1, hits.reduce(0, +))
        }

        var out: [PlayStyle] = []
        func add(_ name: String, _ qualifying: Set<String>, when: Bool, fit: Double = 0.5) {
            guard when else { return }
            let owned = qualifying.intersection(names)
            guard !owned.isEmpty || qualifying.isEmpty else { return }
            // The examples should be the moves it would actually run. Sorted
            // alphabetically this offered Incineroar "Blaze Kick, Body Slam,
            // Brick Break" for a Pokemon whose case is Flare Blitz.
            let best = owned.compactMap { n in learnset.first { $0.name == n } }
                .sorted { first, second in
                    let a = shares[first.name] ?? 0, b = shares[second.name] ?? 0
                    if a != b { return a > b }
                    return moveValue(first, for: form) > moveValue(second, for: form)
                }
                .prefix(3).map(\.name)
            out.append(PlayStyle(name: name, how: Array(best),
                                 measured: share(qualifying), fit: fit))
        }

        // -- attacking -------------------------------------------------------
        // Worth, not printed power. A raw threshold of 70 excluded Dragon
        // Darts, which reads 50 and hits twice — one of the two moves anybody
        // actually builds Dragapult around.
        let physicalHits = Set(learnset.filter {
            $0.category == "Physical" && $0.isImmediateAttack
                && quality(of: $0).expectedPower >= 70
        }.map(\.name))
        let specialHits = Set(learnset.filter {
            $0.category == "Special" && $0.isImmediateAttack
                && quality(of: $0).expectedPower >= 70
        }.map(\.name))
        add("Physical attacker", physicalHits,
            when: role.canUse("Physical") && !physicalHits.isEmpty,
            fit: role.attackRank)
        add("Special attacker", specialHits,
            when: role.canUse("Special") && !specialHits.isEmpty,
            fit: role.spAttackRank)

        // -- setup -----------------------------------------------------------
        let setup = Set(learnset.filter { move in
            let boosts = move.selfBoosts
            return boosts[.attack] ?? 0 > 0 || boosts[.spAttack] ?? 0 > 0
                || boosts[.speed] ?? 0 > 0
        }.map(\.name))
        add("Setup sweeper", setup, when: !setup.isEmpty && role.offence != .none,
            fit: max(role.attackRank, role.spAttackRank) * 0.8)

        // -- support ---------------------------------------------------------
        let disruption: Set<String> = ["Will-O-Wisp", "Thunder Wave", "Taunt", "Encore",
                                       "Spore", "Hypnosis", "Glare", "Nuzzle", "Snarl",
                                       "Parting Shot", "Haze", "Disable"]
        let screens: Set<String> = ["Reflect", "Light Screen", "Aurora Veil", "Safeguard"]
        let redirect: Set<String> = ["Follow Me", "Rage Powder"]
        let speedControl: Set<String> = ["Tailwind", "Trick Room", "Icy Wind", "Electroweb"]
        let pivot: Set<String> = ["U-turn", "Volt Switch", "Flip Turn", "Parting Shot",
                                  "Teleport", "Baton Pass"]
        let healing: Set<String> = ["Recover", "Roost", "Life Dew", "Strength Sap",
                                    "Wish", "Moonlight", "Synthesis", "Soft-Boiled"]

        // Fast enough to use support before it is attacked, or bulky enough to
        // survive using it. Both are real supporters; they play differently.
        let fast = statRole(of: form).attackRank >= 0 && form.speed >= 95
        let bulky = role.defence != .frail

        add(fast ? "Fast support" : "Bulky support",
            disruption.union(screens), when: !disruption.union(screens).isDisjoint(with: names)
                && (fast || bulky),
            fit: fast ? 0.7 : max(role.physicalBulkRank, role.specialBulkRank))
        add("Redirection", redirect, when: !redirect.isDisjoint(with: names), fit: 0.8)
        add("Speed control", speedControl, when: !speedControl.isDisjoint(with: names), fit: 0.6)
        add("Pivot", pivot, when: !pivot.isDisjoint(with: names), fit: 0.5)
        add("Wall", healing, when: !healing.isDisjoint(with: names) && bulky
                && role.offence == .none,
            fit: max(role.physicalBulkRank, role.specialBulkRank))

        // -- what the ability alone qualifies it for --------------------------
        let fieldAbilities = FieldSetters.arrivalAbilities
        if let owned = fieldAbilities.intersection(abilities).sorted().first {
            out.append(PlayStyle(name: "Field setter", how: [owned], measured: nil, fit: 0.9))
        }
        if abilities.contains("Intimidate") {
            out.append(PlayStyle(name: "Intimidate pivot", how: ["Intimidate"],
                                 measured: nil, fit: 0.85))
        }

        // What people actually build first, then what its stats best support.
        return out.sorted {
            let a = ($0.measured ?? 0), b = ($1.measured ?? 0)
            if abs(a - b) > 0.01 { return a > b }
            return $0.fit > $1.fit
        }
    }
}
