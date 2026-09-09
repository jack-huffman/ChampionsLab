//  Team.swift
//  Saved teams, and the legality checks the format imposes on them.

import Foundation

/// One slot on a team: a form plus everything you choose about it.
struct TeamSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var formID: String
    var ability: String = ""
    var item: String = ""
    var moves: [String] = []
    var sp: [Int] = Array(repeating: 0, count: 6)
    var alignmentName: String = "Serious"
    var teraType: String = ""
    var nickname: String = ""

    var alignment: Alignment { Alignment.named(alignmentName) }
    var tera: PokeType? { PokeType(loose: teraType) }
    var spUsed: Int { sp.reduce(0, +) }

    @MainActor func form(in store: Store) -> Form? { store.formsByID[formID] }

    /// Ready for the calculator.
    @MainActor func combatant(in store: Store) -> Combatant? {
        guard let form = form(in: store) else { return nil }
        return Combatant(form: form, ability: ability, item: item, sp: sp,
                         alignment: alignment, teraType: tera)
    }
}

struct Team: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Team"
    var format: String = "doubles"
    var slots: [TeamSlot] = []
    var notes: String = ""
    var created = Date()
    var modified = Date()

    var isDoubles: Bool { format == "doubles" }

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

        let megas = slots.compactMap { $0.form(in: store) }.filter(\.isMega)
        if megas.count > 1 {
            out.append("Only one Pokémon can Mega Evolve per battle — you have \(megas.count) Megas. That is legal to register, but only one can be used.")
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

    static func load() -> [Team] {
        guard let raw = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Team].self, from: raw)) ?? []
    }

    static func save(_ teams: [Team]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
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
