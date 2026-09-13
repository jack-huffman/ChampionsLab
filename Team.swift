//  Team.swift
//  Saved teams, and the legality checks the format imposes on them.

import Foundation

/// Menu commands, posted by the app's command group and observed by the views.
/// Declared here rather than beside @main so tools/snapshot.sh — which compiles
/// every source except ChampionsLab.swift — still sees them.
extension Notification.Name {
    static let newTeam = Notification.Name("ChampionsLab.newTeam")
    static let importTeam = Notification.Name("ChampionsLab.importTeam")
    static let openCalculator = Notification.Name("ChampionsLab.openCalculator")
}

/// A team slot handed to the calculator, so "check this Pokémon's damage" opens
/// with the build you actually registered rather than a blank attacker.
struct CalculatorPreload: Equatable {
    var formID: String
    var ability: String
    var item: String
    var sp: [Int]
    var alignmentName: String
    var moveID: String
    /// Changes on every request, so asking again for the same Pokémon still
    /// rebuilds the view rather than reusing the old state.
    var token = UUID()

    @MainActor
    init(slot: TeamSlot, store: Store) {
        let form = slot.battleForm(in: store)
        formID = form?.id ?? slot.formID
        // A Mega fights with its own ability, which is the point of evolving.
        ability = slot.megaEvolution(in: store)?.abilities.first?.name
            ?? (slot.ability.isEmpty ? (form?.abilities.first?.name ?? "") : slot.ability)
        item = slot.item
        sp = slot.sp
        alignmentName = slot.alignmentName
        moveID = slot.moves.first { store.move($0)?.isDamaging == true } ?? ""
    }
}

/// One slot on a team: a form plus everything you choose about it.
struct TeamSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var formID: String
    var ability: String = ""
    var item: String = ""
    var moves: [String] = []
    var sp: [Int] = Array(repeating: 0, count: 6)
    var alignmentName: String = "Serious"
    var nickname: String = ""

    var alignment: Alignment { Alignment.named(alignmentName) }
    var spUsed: Int { sp.reduce(0, +) }

    init(formID: String) { self.formID = formID }

    /// Decoded field by field, every one optional.
    ///
    /// The synthesised initialiser requires every key to be present — a default
    /// value on the property does *not* make it optional to decode. So adding
    /// one field to this struct would make every previously saved team fail to
    /// load. That is not hypothetical: it happened, and it silently emptied the
    /// team list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        formID = try c.decodeIfPresent(String.self, forKey: .formID) ?? ""
        ability = try c.decodeIfPresent(String.self, forKey: .ability) ?? ""
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        moves = try c.decodeIfPresent([String].self, forKey: .moves) ?? []
        let saved = try c.decodeIfPresent([Int].self, forKey: .sp) ?? []
        sp = (0..<6).map { saved.indices.contains($0) ? saved[$0] : 0 }
        alignmentName = try c.decodeIfPresent(String.self, forKey: .alignmentName) ?? "Serious"
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
    }

    @MainActor func form(in store: Store) -> Form? { store.formsByID[formID] }

    /// The form this slot fights as: the Mega when it is holding the stone,
    /// otherwise the registered form.
    @MainActor func battleForm(in store: Store) -> Form? {
        guard let base = form(in: store) else { return nil }
        return store.megaForm(for: base, holding: item) ?? base
    }

    /// The Mega this slot will become, if any — for showing "→ Mega Charizard Y".
    @MainActor func megaEvolution(in store: Store) -> Form? {
        guard let base = form(in: store) else { return nil }
        return store.megaForm(for: base, holding: item)
    }

    /// Ready for the calculator.
    @MainActor func combatant(in store: Store) -> Combatant? {
        guard let base = form(in: store) else { return nil }
        // Fight as the Mega when the stone is held; its ability replaces the
        // base one, which is the whole point of Mega Evolving.
        let mega = store.megaForm(for: base, holding: item)
        let form = mega ?? base
        return Combatant(form: form,
                         ability: mega?.abilities.first?.name ?? ability,
                         item: item, sp: sp, alignment: alignment)
    }
}

struct Team: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Team"
    var format: String = "doubles"
    var slots: [TeamSlot] = []
    var notes: String = ""
    /// Champions' in-game Replica Team code. Opaque to us — the game's servers
    /// expand it — so it is stored as a label to copy, not something we resolve.
    var replicaCode: String = ""
    /// Read-only until unlocked. A locked team renders as plain text, which is
    /// also why it opens instantly: the editable form has to build several
    /// hundred picker rows per slot, and a locked one builds none.
    var locked: Bool = true
    var created = Date()
    var modified = Date()

    var isDoubles: Bool { format == "doubles" }

    init(name: String = "New Team", format: String = "doubles") {
        self.name = name
        self.format = format
        self.locked = false   // you just made it; you want to edit it
    }

    /// Lenient for the same reason as `TeamSlot` — see the note there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "doubles"
        slots = try c.decodeIfPresent([TeamSlot].self, forKey: .slots) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        replicaCode = try c.decodeIfPresent(String.self, forKey: .replicaCode) ?? ""
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
    }

    /// Champions requires distinct species and distinct items. Both are easy to
    /// break while iterating, so surface them rather than letting the ladder do it.
    @MainActor func violations(in store: Store) -> [String] {
        var out: [String] = []

        // Species clause is by National Dex number, so Charizard and Mega
        // Charizard Y collide — they are the same Pokémon before and after it
        // Mega Evolves, not two team members.
        var seenSpecies: [Int: [String]] = [:]
        for slot in slots {
            guard let form = slot.form(in: store) else { continue }
            seenSpecies[form.dex, default: []].append(form.formLabel)
        }
        for (dex, labels) in seenSpecies where labels.count > 1 {
            out.append("Species clause: \(labels.joined(separator: " and ")) share National Dex #\(dex)")
        }

        var seenItems: [String: Int] = [:]
        for slot in slots where !slot.item.isEmpty {
            seenItems[slot.item, default: 0] += 1
        }
        for (item, count) in seenItems where count > 1 {
            out.append("Item clause: \(count) Pokémon are holding \(item)")
        }

        // Counted by what each slot *fights* as, not what it is registered as.
        // Champions registers the base Pokémon holding its stone, so reading the
        // registered form found zero Megas on a team carrying two of them and
        // this warning never fired for any normally built team.
        let megas = slots.compactMap { $0.battleForm(in: store) }.filter(\.isMega)
        if megas.count > 1 {
            out.append("Only one Pokémon can Mega Evolve per battle — you have \(megas.count) Megas. That is legal to register, but only one can be used.")
        }

        // Items nobody has been seen holding in Champions. The item list is
        // scraped from the main-series itemdex — Serebii publishes no Champions
        // one — so it carries a good number of things this game does not have.
        // Worded as what it is: absence across 105 registered lists and the
        // measured ladder, which is evidence rather than proof.
        for slot in slots {
            guard let item = store.item(named: slot.item), !item.seenInGame,
                  let form = slot.form(in: store) else { continue }
            out.append("\(form.formLabel) is holding \(item.name), which has not been seen in Champions — it is in the main-series item list but on none of the registered teams or the measured ladder.")
        }

        for slot in slots {
            guard let form = slot.form(in: store) else { continue }
            if slot.spUsed > ChampionsStats.spTotal {
                out.append("\(form.formLabel) spends \(slot.spUsed) SP; the cap is \(ChampionsStats.spTotal)")
            }
            if let over = slot.sp.first(where: { $0 > ChampionsStats.spPerStat }), over > 0 {
                out.append("\(form.formLabel) puts \(over) SP in one stat; the cap is \(ChampionsStats.spPerStat)")
            }
            if slot.moves.count > 4 {
                out.append("\(form.formLabel) has \(slot.moves.count) moves")
            }
        }
        return out
    }

    @MainActor func isComplete(in store: Store) -> Bool {
        let need = store.data.rules.formats.first { $0.id == format }?.teamSize ?? 6
        return slots.count >= need
    }
}

// MARK: - Persistence

enum TeamStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ChampionsLab", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("teams.json") }

    /// Anything that went wrong reading the file, for the UI to show. Losing
    /// saved teams silently is much worse than saying so.
    private(set) static var loadWarning: String?

    static func load() -> [Team] {
        loadWarning = nil
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let raw = try? Data(contentsOf: file) else {
            loadWarning = "Could not read \(file.path)"
            return []
        }
        let decoder = JSONDecoder()
        if let teams = try? decoder.decode([Team].self, from: raw) { return teams }

        // One malformed entry must not cost every other team, so fall back to
        // decoding element by element and keep whatever survives.
        guard let elements = try? decoder.decode([AnyTeam].self, from: raw) else {
            loadWarning = "teams.json is not readable; the file has been left untouched."
            return []
        }
        let teams = elements.compactMap(\.team)
        let lost = elements.count - teams.count
        if lost > 0 {
            loadWarning = "\(lost) saved team\(lost == 1 ? "" : "s") could not be read and \(lost == 1 ? "was" : "were") skipped."
        }
        return teams
    }

    /// Decodes each array element independently so one failure is contained.
    private struct AnyTeam: Decodable {
        let team: Team?
        init(from decoder: Decoder) throws {
            team = try? Team(from: decoder)
        }
    }

    static func save(_ teams: [Team]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // Keep one generation back. A save runs on nearly every edit, so a
            // bad write would otherwise be unrecoverable.
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = directory.appendingPathComponent("teams.backup.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: file, to: backup)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(teams).write(to: file, options: .atomic)
        } catch {
            NSLog("ChampionsLab: could not save teams — \(error)")
        }
    }

    /// Where the teams file lives, for the "Reveal in Finder" menu item.
    static var location: URL { file }
}
