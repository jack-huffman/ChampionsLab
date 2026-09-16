//  LabStore.swift
//  What a team was measured to do, kept between sessions.
//
//  A simulation costs minutes. Throwing the answer away when the window closes
//  would make it a curiosity rather than something the rest of the app can
//  lean on — and leaning on it is the point: the picker ranks fours by a
//  scoring function, and a few hundred games of that exact team is better
//  evidence than any scoring function.
//
//  Reports are keyed by team id and stamped with what the team looked like
//  when they were made, and every version is kept.
//
//  The first version of this threw the record away when the team changed, on
//  the reasoning that measured numbers for a team that no longer exists look
//  authoritative and are not. True as far as it goes, and it destroyed the only
//  reason to simulate in the first place: you run a team to find out what is
//  wrong with it, change the thing, and run it again. Deleting the first answer
//  at the moment you act on it means never being able to tell whether acting
//  helped.
//
//  So versions accumulate. The current one is the only one offered *as* the
//  team's record — nothing else would be honest — and the rest are history, with
//  what changed between them, which is what turns a number into a decision.

import Foundation

enum LabStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ChampionsLab", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("simulations.json") }

    /// One version of one team, and what it was measured to do.
    struct Entry: Codable, Sendable {
        var teamID: String
        /// What the team was when this was run.
        var stamp: String
        var ran: Date
        var report: TeamLab.Report
        /// The slot descriptions the stamp was built from, kept so a later
        /// version can say what changed rather than only that something did.
        var slots: [String] = []
    }

    /// What changed between two versions, in the words somebody would use.
    ///
    /// Comparing the stamps says only that they differ. Comparing the slots
    /// says "changed Sneasler's item" — which is the difference between a
    /// history you can read and a list of dates.
    ///
    /// Each clause is written to follow "then you", so a caller can join them
    /// into a sentence without knowing which kind of change it has. `naming`
    /// turns a form id into something a person recognises; without it the
    /// history reads "changed 006's item", which is true and no use.
    static func changes(from older: [String], to newer: [String],
                        naming: (String) -> String = { $0 }) -> [String] {
        guard !older.isEmpty, !newer.isEmpty else { return [] }
        func parts(_ line: String) -> [String] { line.components(separatedBy: "|") }
        var out: [String] = []
        let wasByForm = Dictionary(older.map { (parts($0).first ?? "", parts($0)) },
                                   uniquingKeysWith: { a, _ in a })
        for line in newer {
            let now = parts(line)
            guard let form = now.first else { continue }
            guard let was = wasByForm[form] else {
                out.append("added \(naming(form))")
                continue
            }
            let fields = ["item", "ability", "nature", "spread", "moves"]
            for (index, name) in fields.enumerated() where index + 1 < min(was.count, now.count) {
                if was[index + 1] != now[index + 1] {
                    out.append("changed \(naming(form))'s \(name)")
                }
            }
        }
        let nowForms = Set(newer.compactMap { parts($0).first })
        for form in wasByForm.keys where !nowForms.contains(form) {
            out.append("dropped \(naming(form))")
        }
        return out
    }

    /// Everything about a team that would change how it plays, in one string.
    ///
    /// The nickname is deliberately not in it: renaming a Pokémon does not
    /// change a game, and retiring a two-thousand-game report over a nickname
    /// would be its own kind of wrong.
    static func stamp(of team: Team) -> String {
        slotLines(of: team).joined(separator: "//")
    }

    /// One line per Pokémon, which is both the stamp and, split up again, how a
    /// later version says what changed.
    static func slotLines(of team: Team) -> [String] {
        team.slots.map { slot in
            "\(slot.formID)|\(slot.item)|\(slot.ability)|\(slot.alignmentName)"
                + "|\(slot.sp.map(String.init).joined(separator: ","))"
                + "|\(slot.moves.sorted().joined(separator: ","))"
        }
    }

    @MainActor private(set) static var loadWarning: String?

    /// Every version of every team, newest first within each team.
    @MainActor static func load() -> [String: [Entry]] {
        loadWarning = nil
        guard FileManager.default.fileExists(atPath: file.path),
              let raw = try? Data(contentsOf: file) else { return [:] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: raw) else {
            loadWarning = "simulations.json could not be read; it has been left untouched."
            return [:]
        }
        return Dictionary(grouping: entries, by: \.teamID)
            .mapValues { $0.sorted { $0.ran > $1.ran } }
    }

    @MainActor static func save(_ entries: [String: [Entry]]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // Newest first within a team, and only so many versions kept: a
            // team edited fifty times does not need fifty records, and the ones
            // worth comparing against are the recent ones.
            let flat = entries.values.flatMap { $0.sorted { $0.ran > $1.ran }.prefix(8) }
            let blob = try JSONEncoder().encode(Array(flat))
            try blob.write(to: file, options: .atomic)
        } catch {
            loadWarning = "Could not save simulations: \(error.localizedDescription)"
        }
    }
}

/// One Pokémon's record pooled over every team of yours it appears on.
///
/// The thing a per-team report cannot show. A Pokémon can look like an
/// unlucky passenger on one team and be a genuine problem on four — and the
/// second is a fact about the Pokémon rather than about any of the teams,
/// which is a different thing to do about it.
struct RosterEntry: Identifiable, Sendable {
    let form: String
    var teams: [String] = []
    var record = TeamLab.Record()

    var id: String { form }
    var trade: Double { record.trade }
    var netDamage: Int { record.damageDealt - record.damageTaken }
}

extension TeamLab.Report {
    /// The fours this team actually won with, as the picker wants them: keyed
    /// the same way it keys a plan, with the wins and the games behind each.
    ///
    /// Only fours with enough games to carry an opinion. Two games of a four is
    /// not evidence, and letting it overrule a scoring function that has looked
    /// at the whole grid would be worse than ignoring it.
    func measuredFours(least: Int = 8) -> [String: (wins: Int, games: Int)] {
        var out: [String: (wins: Int, games: Int)] = [:]
        for (four, pair) in brings where pair[1] >= least {
            out[four] = (wins: pair[0], games: pair[1])
        }
        return out
    }
}
