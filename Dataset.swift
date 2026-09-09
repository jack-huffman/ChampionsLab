//  Dataset.swift
//  Loads the bundled dataset and the icon sets that go with it.

import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: Dataset
    @Published var teams: [Team] = []
    @Published var loadError: String?

    private var spriteCache: [String: NSImage] = [:]

    private init() {
        do {
            data = try Store.loadDataset()
        } catch {
            // An empty dataset keeps the app launchable so the window can
            // explain what went wrong instead of dying on start.
            data = Dataset(regulation: .placeholder, rules: .placeholder, items: [],
                           usage: [], metaTeams: [], notes: .placeholder, forms: [], moves: [:],
                           abilities: [:], generated: "—", sources: [])
            loadError = "\(error)"
        }
        teams = TeamStore.load()
    }

    private static func loadDataset() throws -> Dataset {
        guard let url = Bundle.main.url(forResource: "champions", withExtension: "json")
                ?? developmentURL(named: "champions.json") else {
            throw DataError.missing("champions.json not found in the app bundle")
        }
        let raw = try Data(contentsOf: url)
        return try JSONDecoder().decode(Dataset.self, from: raw)
    }

    /// Running straight out of the source tree during development.
    private static func developmentURL(named name: String) -> URL? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidate = here.appendingPathComponent("data/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    enum DataError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let text) = self { return text }
            return nil
        }
    }

    // MARK: - Lookups

    lazy var formsByID: [String: Form] = {
        Dictionary(data.forms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    func move(_ id: String) -> Move? { data.moves[id] }

    func moves(for form: Form) -> [Move] {
        form.moves.compactMap { data.moves[$0] }.sorted { $0.name < $1.name }
    }

    func item(named name: String) -> Item? {
        data.items.first { $0.name == name }
    }

    /// Resolve a usage-table name ("Mega Salamence", "Indeedee-F") to a form.
    func form(named name: String) -> Form? {
        if let hit = data.forms.first(where: { $0.formLabel == name }) { return hit }
        if let hit = data.forms.first(where: { $0.name == name && $0.suffix.isEmpty }) {
            return hit
        }
        // "Indeedee-F" and "Indeedee (Female)" refer to the same row.
        let normalized = name.replacingOccurrences(of: "-F", with: " (Female)")
                             .replacingOccurrences(of: "-M", with: " (Male)")
        return data.forms.first { $0.formLabel == normalized }
    }

    var megas: [Form] { data.forms.filter(\.isMega) }

    var newMegas: [Form] {
        data.regulation.newMegas.compactMap { form(named: $0) }
    }

    // MARK: - Images

    func sprite(_ form: Form) -> NSImage? { image(subdirectory: "sprites", name: form.icon) }
    func typeIcon(_ type: PokeType) -> NSImage? {
        image(subdirectory: "types", name: type.rawValue)
    }
    func itemIcon(_ item: Item) -> NSImage? {
        image(subdirectory: "items", name: item.slug)
    }
    func itemIcon(named name: String) -> NSImage? {
        guard let item = item(named: name) else { return nil }
        return itemIcon(item)
    }

    private func image(subdirectory: String, name: String) -> NSImage? {
        let key = "\(subdirectory)/\(name)"
        if let cached = spriteCache[key] { return cached }
        let url = Bundle.main.url(forResource: name, withExtension: "png",
                                  subdirectory: subdirectory)
            ?? Store.developmentURL(named: "\(subdirectory)/\(name).png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        spriteCache[key] = image
        return image
    }

    // MARK: - Teams

    func save(_ team: Team) {
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            teams[index] = team
        } else {
            teams.append(team)
        }
        TeamStore.save(teams)
    }

    func delete(_ team: Team) {
        teams.removeAll { $0.id == team.id }
        TeamStore.save(teams)
    }
}

// MARK: - Placeholders for the failed-load path

extension Regulation {
    static let placeholder = Regulation(
        id: "—", name: "Dataset unavailable", start: "", end: "", startNote: "",
        events: [], newPokemon: [], newMegas: [])
}

extension Rules {
    static let placeholder = Rules(
        formats: [FormatRule(id: "doubles", name: "Doubles", teamSize: 6, bring: 4, note: "")],
        level: 50, spTotal: 66, spPerStat: 32, speciesClause: true, itemClause: true,
        gimmick: "", timer: Rules.Timer(matchSeconds: 0, playerSeconds: 0,
                                        teamPreviewSeconds: 0, turnSeconds: 0))
}

extension MetaNotes {
    static let placeholder = MetaNotes(headline: "", threads: [], antiMeta: [])
}
