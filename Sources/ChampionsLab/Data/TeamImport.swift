//  TeamImport.swift
//  Reading and writing teams in the format the community actually shares.
//
//  Pokepaste / Showdown text is the lingua franca for passing teams around, and
//  Champions' own Replica Team codes are opaque server-side identifiers we can
//  store but not resolve offline. So: parse the paste, keep the code as a label.
//
//  The wrinkle is that a paste carries EVs and Champions has none. The games
//  convert on import at a documented rate — the first Stat Point costs 4 EVs and
//  each one after that costs 8 — which lands 252 EVs exactly on the 32 SP cap.

import Foundation

enum TeamPaste {

    // MARK: - EV/SP conversion

    /// EVs from a Showdown paste -> Champions Stat Points.
    ///
    /// 0 EVs is 0 SP, 4 EVs buys the first point, and every further point costs
    /// 8. So 252 EVs -> 1 + (248 / 8) = 32, which is exactly the per-stat cap.
    static func statPoints(fromEVs evs: Int) -> Int {
        guard evs >= 4 else { return 0 }
        return min(ChampionsStats.spPerStat, 1 + (evs - 4) / 8)
    }

    /// The inverse, for writing a paste a main-series tool can read.
    static func evs(fromStatPoints sp: Int) -> Int {
        guard sp > 0 else { return 0 }
        return min(252, 4 + (sp - 1) * 8)
    }

    // MARK: - Which dialect a paste is written in

    /// A spread can be written two ways and they do not look different.
    ///
    /// A main-series paste spells a Stat Point as the EVs it would have cost
    /// -- four for the first and eight apiece after -- so a maxed stat is 252.
    /// Showdown's own Champions formats spell the points themselves, because
    /// the mod's `statModify` reads the EV field as the points: `base + evs +
    /// 75` for HP and `+ 20` for the rest. A maxed stat is 32.
    ///
    /// Read in the wrong dialect, "EVs: 32 HP / 32 Atk" off Showdown becomes
    /// four points and four points, which is a team nobody built.
    enum Dialect {
        case mainSeries, champions

        /// What one written number is worth in Stat Points.
        func statPoints(_ written: Int) -> Int {
            switch self {
            case .mainSeries: return TeamPaste.statPoints(fromEVs: written)
            case .champions: return Swift.max(0, Swift.min(ChampionsStats.spPerStat, written))
            }
        }
    }

    /// Which dialect a whole paste is in.
    ///
    /// Decided across the paste rather than per Pokémon, because a paste is
    /// written by one tool in one dialect, and a single Pokémon carrying a
    /// small spread says nothing either way.
    ///
    /// The tell is that the two dialects cannot both be true of the same
    /// numbers: a Stat Point spread never exceeds 32 on a stat or 66 across
    /// one Pokémon, and a main-series spread that stayed under both of those
    /// would be a Pokémon with almost nothing invested. So anything above
    /// either line is EVs, and everything else is points.
    static func dialect(of text: String) -> Dialect {
        for amounts in spreads(in: text) {
            if amounts.contains(where: { $0 > ChampionsStats.spPerStat }) { return .mainSeries }
            if amounts.reduce(0, +) > ChampionsStats.spTotal { return .mainSeries }
        }
        return .champions
    }

    /// Every EV line's numbers, one array per Pokémon that has one.
    private static func spreads(in text: String) -> [[Int]] {
        var out: [[Int]] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("evs:") else { continue }
            let numbers = trimmed.dropFirst("evs:".count)
                .components(separatedBy: "/")
                .compactMap { part -> Int? in
                    let bits = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                    guard bits.count >= 2, stat(named: bits[1]) != nil else { return nil }
                    return Int(bits[0])
                }
            if !numbers.isEmpty { out.append(numbers) }
        }
        return out
    }

    // MARK: - Import

    struct Result {
        var team: Team
        /// Lines that could not be matched, reported rather than swallowed.
        var warnings: [String]
    }

    /// Parse one or more Pokémon out of Showdown/Pokepaste text.
    @MainActor
    static func parse(_ text: String, store: Store, name: String? = nil) -> Result {
        var team = Team(name: name ?? "Imported team")
        var warnings: [String] = []
        // Settled once for the whole paste, before anything is read out of it.
        let dialect = Self.dialect(of: text)

        // Blocks are separated by blank lines; a block is one Pokémon.
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let head = lines.first else { continue }

            // "Nickname (Species) (F) @ Item"  /  "Species @ Item"
            var species = head
            var item = ""
            if let at = head.range(of: " @ ") {
                species = String(head[head.startIndex..<at.lowerBound])
                item = String(head[at.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            species = species.trimmingCharacters(in: .whitespaces)
            // A nickname puts the real species in parentheses.
            if let open = species.range(of: "("), let close = species.range(of: ")", options: .backwards),
               open.upperBound < close.lowerBound {
                let inner = String(species[open.upperBound..<close.lowerBound])
                if !["M", "F"].contains(inner) { species = inner }
            }
            species = species.replacingOccurrences(of: " (M)", with: "")
                             .replacingOccurrences(of: " (F)", with: "")
                             .trimmingCharacters(in: .whitespaces)

            guard let form = resolve(species: species, store: store) else {
                warnings.append("Could not find “\(species)” in the Regulation M-C roster")
                continue
            }

            var slot = TeamSlot(formID: form.id)
            slot.ability = form.abilities.first?.name ?? ""
            if !item.isEmpty {
                if let known = store.data.items.first(where: {
                    $0.name.caseInsensitiveCompare(item) == .orderedSame
                }) {
                    slot.item = known.name
                } else if item.lowercased().hasSuffix("ite")
                            || item.lowercased().contains("ite ")
                            || item.lowercased().contains("mega stone") {
                    // A Mega Stone we have no published name for.
                    slot.item = "Mega Stone"
                    warnings.append("\(form.formLabel): “\(item)” is not in the itemdex, using Mega Stone")
                } else {
                    warnings.append("\(form.formLabel): unknown item “\(item)”")
                }
            }

            for line in lines.dropFirst() {
                parse(line: line, into: &slot, form: form, store: store,
                      dialect: dialect, warnings: &warnings)
            }

            // A Mega has to hold its stone, so fill it in if the paste omitted one.
            if form.isMega && slot.item.isEmpty {
                slot.item = megaStone(for: form, store: store)
            }
            team.slots.append(slot)
        }

        if team.slots.isEmpty && warnings.isEmpty {
            warnings.append("No Pokémon found. Paste Showdown or Pokepaste text.")
        }
        return Result(team: team, warnings: warnings)
    }

    @MainActor
    private static func parse(line: String, into slot: inout TeamSlot, form: Form,
                              store: Store, dialect: Dialect, warnings: inout [String]) {
        if line.lowercased().hasPrefix("ability:") {
            let value = line.dropFirst("ability:".count).trimmingCharacters(in: .whitespaces)
            if let match = form.abilities.first(where: {
                $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) {
                slot.ability = match.name
            } else {
                warnings.append("\(form.formLabel): cannot use ability “\(value)”")
            }
            return
        }

        // "Adamant Nature" — Champions calls these Stat Alignments.
        if line.lowercased().hasSuffix("nature") {
            let value = line.replacingOccurrences(of: "Nature", with: "",
                                                  options: .caseInsensitive)
                            .trimmingCharacters(in: .whitespaces)
            if Alignment.all.contains(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
                slot.alignmentName = Alignment.all.first {
                    $0.name.caseInsensitiveCompare(value) == .orderedSame
                }!.name
            } else if !value.isEmpty {
                warnings.append("\(form.formLabel): unknown nature “\(value)”")
            }
            return
        }

        if line.lowercased().hasPrefix("evs:") {
            let body = line.dropFirst("evs:".count)
            for part in body.components(separatedBy: "/") {
                let bits = part.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ")
                guard bits.count >= 2, let amount = Int(bits[0]),
                      let stat = stat(named: bits[1]) else { continue }
                slot.sp[stat.rawValue] = dialect.statPoints(amount)
            }
            return
        }

        // "Shiny: Yes", which every exporter writes and this one used to
        // throw away along with the things the game really has no concept of.
        if line.lowercased().hasPrefix("shiny:") {
            let value = line.dropFirst("shiny:".count).trimmingCharacters(in: .whitespaces)
            slot.shiny = ["yes", "true", "1"].contains(value.lowercased())
            return
        }

        // Lines Champions has no concept of. Tera Type appears in any paste
        // written for Scarlet/Violet; this game has no Terastallization, and IVs
        // do not exist either, so both are dropped without comment.
        if line.lowercased().hasPrefix("tera type:")
            || line.lowercased().hasPrefix("ivs:") || line.lowercased().hasPrefix("level:")
            || line.lowercased().hasPrefix("happiness:")
            || line.lowercased().hasPrefix("gigantamax:") || line.lowercased().hasPrefix("dynamax level:") {
            return
        }

        // "- Move Name"
        if line.hasPrefix("-") {
            let value = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // Hidden Power and friends carry a type in brackets.
            let cleaned = value.components(separatedBy: " [").first ?? value
            guard let move = store.data.moves.values.first(where: {
                $0.name.caseInsensitiveCompare(cleaned) == .orderedSame
            }) else {
                warnings.append("\(form.formLabel): “\(cleaned)” is not a Champions move")
                return
            }
            guard form.moves.contains(move.id) else {
                warnings.append("\(form.formLabel) cannot learn \(move.name)")
                return
            }
            if slot.moves.count < 4 { slot.moves.append(move.id) }
            return
        }
    }

    private static func stat(named text: String) -> Stat? {
        switch text.lowercased() {
        case "hp":  return .hp
        case "atk": return .attack
        case "def": return .defense
        case "spa": return .spAttack
        case "spd": return .spDefense
        case "spe": return .speed
        default:    return nil
        }
    }

    /// Match a paste's species string to a form.
    ///
    /// Showdown writes "Charizard-Mega-Y" and "Indeedee-F"; people write "Mega
    /// Charizard Y". Both have to land on the same row.
    @MainActor
    static func resolve(species raw: String, store: Store) -> Form? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let exact = store.data.forms.first(where: {
            $0.formLabel.caseInsensitiveCompare(text) == .orderedSame
        }) { return exact }
        if let byName = store.form(named: text) { return byName }

        let key = normalise(text)
        if let hit = store.data.forms.first(where: { normalise($0.formLabel) == key }) {
            return hit
        }

        // "Charizard-Mega-Y" -> "megacharizardy"
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "- "))
            .filter { !$0.isEmpty }
        if parts.count > 1 {
            let base = parts[0]
            let rest = parts.dropFirst().map { $0.lowercased() }
            var candidate = base
            if rest.contains("mega") {
                let tag = rest.first { ["x", "y", "z"].contains($0) }
                candidate = "Mega \(base)" + (tag.map { " \($0.uppercased())" } ?? "")
            } else if let region = rest.first(where: {
                ["alola", "alolan", "galar", "galarian", "hisui", "hisuian",
                 "paldea", "paldean"].contains($0)
            }) {
                let word = ["alola": "Alolan", "alolan": "Alolan",
                            "galar": "Galarian", "galarian": "Galarian",
                            "hisui": "Hisuian", "hisuian": "Hisuian",
                            "paldea": "Paldean", "paldean": "Paldean"][region]!
                candidate = "\(word) \(base)"
            } else if rest.contains("f") || rest.contains("female") {
                candidate = "\(base) (Female)"
            } else if rest.contains("m") || rest.contains("male") {
                candidate = "\(base) (Male)"
            }
            let wanted = normalise(candidate)
            if let hit = store.data.forms.first(where: { normalise($0.formLabel) == wanted }) {
                return hit
            }
            // Fall back to the base species so an unknown suffix still imports.
            let baseKey = normalise(base)
            if let hit = store.data.forms.first(where: {
                normalise($0.formLabel) == baseKey && $0.suffix.isEmpty
            }) { return hit }
        }
        return nil
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    @MainActor
    private static func megaStone(for form: Form, store: Store) -> String {
        // Serebii names 47 stones; the Champions-only Megas have none published.
        let guess = form.name + "ite"
        if let hit = store.data.items.first(where: {
            $0.name.replacingOccurrences(of: " ", with: "")
                .caseInsensitiveCompare(guess) == .orderedSame
        }) { return hit.name }
        for item in store.data.items where item.name.hasPrefix(form.name.prefix(5)) {
            if item.name.contains("ite") { return item.name }
        }
        return "Mega Stone"
    }

    // MARK: - Export

    /// Write the team back out as Showdown text, with SP converted to EVs so
    /// other tools can read it.
    @MainActor
    static func export(_ team: Team, store: Store) -> String {
        var out: [String] = []
        for slot in team.slots {
            guard let form = slot.form(in: store.rulebook) else { continue }
            var block: [String] = []

            var head = showdownName(form)
            if !slot.item.isEmpty { head += " @ \(slot.item)" }
            block.append(head)
            if !slot.ability.isEmpty { block.append("Ability: \(slot.ability)") }
            if slot.shiny { block.append("Shiny: Yes") }
            block.append("Level: \(ChampionsStats.level)")

            // The Champions dialect: the points themselves, which is what
            // Showdown's own Champions formats read and write. Written the
            // main-series way instead, a maxed stat says 252 and Showdown
            // makes 422 HP of a Pokemon that should have 202.
            let spread = Stat.allCases.compactMap { stat -> String? in
                let sp = slot.sp[stat.rawValue]
                guard sp > 0 else { return nil }
                return "\(sp) \(showdownStat(stat))"
            }
            if !spread.isEmpty { block.append("EVs: " + spread.joined(separator: " / ")) }
            block.append("\(slot.alignmentName) Nature")
            for id in slot.moves {
                if let move = store.move(id) { block.append("- \(move.name)") }
            }
            out.append(block.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    private static func showdownName(_ form: Form) -> String {
        // Showdown spells forms with hyphens after the species.
        let label = form.formLabel
        if form.isMega {
            var tag = ""
            if label.hasSuffix(" X") { tag = "-X" }
            if label.hasSuffix(" Y") { tag = "-Y" }
            if label.hasSuffix(" Z") { tag = "-Z" }
            return "\(form.name)-Mega\(tag)"
        }
        if label.hasPrefix("Alolan ") { return "\(form.name)-Alola" }
        if label.hasPrefix("Galarian ") { return "\(form.name)-Galar" }
        if label.hasPrefix("Hisuian ") { return "\(form.name)-Hisui" }
        if label.hasPrefix("Paldean ") { return "\(form.name)-Paldea" }
        if label.hasSuffix("(Female)") { return "\(form.name)-F" }
        if label.hasSuffix("(Male)") { return "\(form.name)-M" }
        return form.name
    }

    private static func showdownStat(_ stat: Stat) -> String {
        switch stat {
        case .hp: return "HP"
        case .attack: return "Atk"
        case .defense: return "Def"
        case .spAttack: return "SpA"
        case .spDefense: return "SpD"
        case .speed: return "Spe"
        }
    }

    // MARK: - Meta teams

    /// Turn a bundled archetype into a real Team so it can be analysed or edited.
    @MainActor
    static func team(from meta: MetaTeam, store: Store) -> Team {
        var team = Team(name: meta.name, format: meta.format)
        team.notes = "\(meta.source)\n\n\(meta.note)"
        for member in meta.members {
            guard let form = store.form(named: member.form) else { continue }
            var slot = TeamSlot(formID: form.id)
            slot.ability = member.ability
            slot.item = member.item
            slot.moves = member.moves.compactMap { name in
                store.data.moves.values.first { $0.name == name }?.id
            }
            // Tournament results publish the six, not the sets. Anything with no
            // measured set on the ladder arrives empty, and an empty set scores
            // as harmless — so give it the best four it could plausibly run,
            // priced the same way the builder prices moves.
            if slot.moves.isEmpty {
                let learnable = store.moves(for: form)
                var chosen: [String] = []
                var usedTypes: Set<String> = []
                let physicalAttacker = form.attack >= form.spAttack
                let ranked = store.attackingMoves(for: form)
                    .filter { physicalAttacker ? $0.category == "Physical" : $0.category == "Special" }
                    .sorted {
                        store.moveValue($0, for: form, ability: member.ability)
                            > store.moveValue($1, for: form, ability: member.ability)
                    }
                for move in ranked where chosen.count < 3 {
                    guard usedTypes.insert(move.type).inserted else { continue }
                    chosen.append(move.id)
                }
                if let protect = learnable.first(where: { $0.name == "Protect" }) {
                    chosen.append(protect.id)
                }
                slot.moves = chosen
            }
            // A Mega must be holding its stone; otherwise fall back to something
            // ordinary rather than nothing, which would understate it.
            if slot.item.isEmpty {
                if form.isMega, !form.megaStone.isEmpty {
                    slot.item = form.megaStone
                } else {
                    slot.item = form.attack >= form.spAttack ? "Life Orb" : "Life Orb"
                }
            }
            // Spreads are almost never published with a team list. Giving every
            // member max offence and max Speed was measurably wrong: it is the
            // right shape for an attacker and the wrong one for a bulky support,
            // and it left teams that won real events scoring ten points below
            // untested teams whose spreads had been thought about. They get the
            // same role-aware spread the builder would give them instead.
            let physical = form.attack >= form.spAttack
            let advisor = TeamAdvisor(team: Team(), store: store)
            let roles = advisor.potentialRoles(of: form)
            let support = roles.contains(.redirection) || roles.contains(.tailwind)
                || roles.contains(.trickRoom) || roles.contains(.terrain)
                || max(form.attack, form.spAttack) < 100
            var builder = TeamBuilder(store: store)
            builder.format = meta.format
            let built = builder.spread(for: form, physical: physical,
                                       support: support, plan: .balance,
                                       tailwind: roles.contains(.tailwind))
            slot.sp = built.sp
            // Their alignment where the team list published one, which it now
            // does for every member of a real result. Only the Stat Points are
            // guesswork, and overriding a published nature with a guess threw
            // away the one piece of the spread that is actually known.
            if let nature = member.nature, !nature.isEmpty,
               Alignment.all.contains(where: { $0.name == nature }) {
                slot.alignmentName = nature
            } else {
                slot.alignmentName = built.alignment
            }
            team.slots.append(slot)
        }
        return team
    }
}
