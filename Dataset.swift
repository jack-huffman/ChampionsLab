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
    /// Set when saved teams could not be read — surfaced rather than swallowed.
    @Published var teamWarning: String?
    /// Set when a team slot asks to be opened in the calculator.
    @Published var pendingCalculation: CalculatorPreload?

    private var spriteCache: [String: NSImage] = [:]

    private init() {
        do {
            data = try Store.loadDataset()
        } catch {
            // An empty dataset keeps the app launchable so the window can
            // explain what went wrong instead of dying on start.
            data = Dataset(regulation: .placeholder, rules: .placeholder, items: [],
                           usage: [], metaTeams: [], predictions: [], notes: .placeholder, forms: [], moves: [:],
                           abilities: [:], generated: "—", sources: [])
            loadError = "\(error)"
        }
        teams = TeamStore.load()
        teamWarning = TeamStore.loadWarning
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

    /// The Mega a base form turns into while holding `item`.
    ///
    /// Champions registers the base Pokémon holding its stone — a team lists
    /// "Charizard @ Charizardite Y" — so this is what tells the analysis that
    /// the slot fights as Mega Charizard Y with 159 Sp. Atk and Drought, not as
    /// a base Charizard with 109 and Solar Power.
    func megaForm(for base: Form, holding item: String) -> Form? {
        guard !item.isEmpty, !base.isMega else { return nil }
        let candidates = data.forms.filter { $0.dex == base.dex && $0.isMega }
        if let exact = candidates.first(where: { $0.megaStone == item }) { return exact }
        // Only one Mega for this species and the item is some stone: take it.
        if candidates.count == 1, item == "Mega Stone" { return candidates.first }
        return nil
    }

    var newMegas: [Form] {
        data.regulation.newMegas.compactMap { form(named: $0) }
    }

    // MARK: - Lookup options
    //
    // Built once and cached. These feed LookupField, which replaced the long
    // Pickers — a macOS Picker materialises every row into an NSMenu as soon as
    // the view appears, and the slot editor was doing that for ~3,400 rows.

    lazy var itemOptions: [LookupOption] = data.items.map {
        LookupOption(id: $0.name, name: $0.name, subtitle: $0.category)
    }

    lazy var formOptions: [LookupOption] = data.forms.map {
        LookupOption(id: $0.id, name: $0.formLabel,
                     subtitle: $0.types.joined(separator: "/"), form: $0)
    }

    /// Move ids that can be clicked for their damage on the turn you want it.
    /// Precomputed because Forecast tests it for every move of every form, and
    /// the check reads the effect text.
    lazy var immediateAttackIDs: Set<String> = Set(
        data.moves.values.filter(\.isImmediateAttack).map(\.id))

    /// The subset of a form's learnset worth ranking as an attack.
    private var attackCache: [String: [Move]] = [:]

    func attackingMoves(for form: Form) -> [Move] {
        if let cached = attackCache[form.id] { return cached }
        let moves = form.moves.compactMap { data.moves[$0] }
            .filter { immediateAttackIDs.contains($0.id) }
        attackCache[form.id] = moves
        return moves
    }

    private var moveOptionCache: [String: [LookupOption]] = [:]

    func moveOptions(for form: Form) -> [LookupOption] {
        if let cached = moveOptionCache[form.id] { return cached }
        let options = moves(for: form).map {
            LookupOption(id: $0.id, name: $0.name,
                         subtitle: "\($0.category) · \($0.power > 0 ? "\($0.power) BP" : "status")",
                         type: PokeType(loose: $0.type))
        }
        moveOptionCache[form.id] = options
        return options
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
