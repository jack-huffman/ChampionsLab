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
//  when they were made. Change a move, an item, a Pokémon, and the stamp stops
//  matching and the report is no longer offered — measured numbers for a team
//  that no longer exists are worse than none, because they look authoritative.

import Foundation

enum LabStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ChampionsLab", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("simulations.json") }

    /// One team's measured record, and the team it was measured on.
    struct Entry: Codable, Sendable {
        var teamID: String
        /// What the team was when this was run. A mismatch retires the entry.
        var stamp: String
        var ran: Date
        var report: TeamLab.Report
    }

    /// Everything about a team that would change how it plays, in one string.
    ///
    /// The nickname is deliberately not in it: renaming a Pokémon does not
    /// change a game, and retiring a two-thousand-game report over a nickname
    /// would be its own kind of wrong.
    static func stamp(of team: Team) -> String {
        team.slots.map { slot in
            "\(slot.formID)|\(slot.item)|\(slot.ability)|\(slot.alignmentName)"
                + "|\(slot.sp.map(String.init).joined(separator: ","))"
                + "|\(slot.moves.sorted().joined(separator: ","))"
        }.joined(separator: "//")
    }

    @MainActor private(set) static var loadWarning: String?

    @MainActor static func load() -> [String: Entry] {
        loadWarning = nil
        guard FileManager.default.fileExists(atPath: file.path),
              let raw = try? Data(contentsOf: file) else { return [:] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: raw) else {
            loadWarning = "simulations.json could not be read; it has been left untouched."
            return [:]
        }
        return Dictionary(entries.map { ($0.teamID, $0) }, uniquingKeysWith: { $1 })
    }

    @MainActor static func save(_ entries: [String: Entry]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let blob = try JSONEncoder().encode(Array(entries.values))
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
