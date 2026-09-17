//  GameRecord.swift
//  A game played to a result, as the lobby remembers it.
//
//  Who played whom, with what four, how it went and how long it took, and
//  what the review said was left on the table. Enough to set the matchup up
//  again with a click, and to see over time whether a team is winning.

import Foundation

struct GameRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let played: Date
    /// "doubles" or "singles".
    let format: String
    let won: Bool
    let turns: Int
    /// Your side: the saved team, and the forms brought, in the order they
    /// stood at the end.
    let myTeamID: String
    let myTeamName: String
    let myForms: [String]
    /// Theirs: a published list's id or another saved team's, and their four.
    let theirID: String
    let theirName: String
    let theirForms: [String]
    /// What the review said the turns left on the table, in the engine's
    /// units, over the turns it could grade.
    let leftOnTable: Double
    let reviewedTurns: Int
}

/// The games on disk, beside the teams.
enum GameStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ChampionsLab", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("games.json") }
    /// How many are kept. A season's worth; the oldest fall off the end.
    static let keep = 300

    static func load() -> [GameRecord] {
        guard let raw = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GameRecord].self, from: raw)) ?? []
    }

    static func save(_ games: [GameRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(games.prefix(keep))) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
