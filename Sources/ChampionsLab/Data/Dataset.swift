//  Dataset.swift
//  Loads the bundled dataset and the icon sets that go with it.

import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: Dataset
    @Published var teams: [Team] = []
    /// What each team was measured to do, from the Simulate tab, keyed by team
    /// id. Loaded once and kept, so the picker can lean on a few hundred real
    /// games of *this* team rather than only on a scoring function.
    @Published var simulations: [String: LabStore.Entry] = [:]
    @Published var loadError: String?
    /// Set when saved teams could not be read — surfaced rather than swallowed.
    @Published var teamWarning: String?
    /// Set when a team slot asks to be opened in the calculator.
    @Published var pendingCalculation: CalculatorPreload?
    /// The live ladder table currently applied, if any.
    @Published private(set) var liveUsage: UsageFeed.Snapshot?
    /// Bumped whenever the usage table changes, so the views that compute
    /// against it once — Forecast, Builder — know to redo the work.
    @Published private(set) var usageVersion = 0

    /// The table that shipped in champions.json, kept so a refresh always
    /// merges its hand-written prose rather than the last refresh's generated
    /// text, which would go stale as sets move.
    private var bundledUsage: [UsageEntry] = []

    private var spriteCache: [String: NSImage] = [:]
    /// What each form's stats say it is for, worked out once.
    var roleCache: [String: StatRole] = [:]
    /// The viability table, which needs the anti-meta run to be complete.
    var viabilityCache: [Viability]?
    var picksWereUsed = false

    private init() {
        do {
            data = try Store.loadDataset()
        } catch {
            // An empty dataset keeps the app launchable so the window can
            // explain what went wrong instead of dying on start.
            data = Dataset(regulation: .placeholder, rules: .placeholder, items: [],
                           usage: [], metaTeams: [], predictions: [], notes: .placeholder, forms: [], moves: [:],
                           abilities: [:], generated: "—", sources: [], provenance: nil)
            loadError = "\(error)"
        }
        bundledUsage = data.usage
        teams = TeamStore.load()
        simulations = LabStore.load()
        teamWarning = TeamStore.loadWarning
        if let saved = UsageFeed.load() { apply(saved) }
    }

    // MARK: - Live usage

    /// Everything a fetch needs to check its references, as plain values.
    func usageIndex() -> UsageFeed.Index {
        var index = UsageFeed.Index()
        for form in data.forms {
            index.formsByLabel[form.formLabel] = form
            if form.suffix.isEmpty { index.formsByName[form.name] = form }
        }
        index.moveIDsByName = Dictionary(data.moves.values.map { ($0.name, $0.id) },
                                         uniquingKeysWith: { a, _ in a })
        index.itemNames = Set(data.items.map(\.name))
        index.curated = Dictionary(bundledUsage.map { ($0.name, $0) },
                                   uniquingKeysWith: { a, _ in a })
        return index
    }

    func apply(_ snapshot: UsageFeed.Snapshot) {
        data = data.replacingUsage(with: snapshot.entries)
        liveUsage = snapshot
        usageVersion += 1
    }

    /// Back to whatever mkdata.py baked in.
    func revertToBundledUsage() {
        UsageFeed.discard()
        data = data.replacingUsage(with: bundledUsage)
        liveUsage = nil
        usageVersion += 1
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
        // Walk up from this file to the repository root, wherever this file
        // has been filed: the data directory sits beside Package.swift.
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    enum DataError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let text) = self { return text }
            return nil
        }
    }

    // MARK: - Lookups

    /// The engine's frozen view of the data. Rebuilt if the dataset is.
    private(set) lazy var rulebook = Rulebook(dataset: data)

    lazy var formsByID: [String: Form] = {
        Dictionary(data.forms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    func move(_ id: String) -> Move? { rulebook.move(id) }

    func moves(for form: Form) -> [Move] { rulebook.moves(for: form) }

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
        rulebook.megaForm(for: base, holding: item)
    }

    var newMegas: [Form] {
        data.regulation.newMegas.compactMap { form(named: $0) }
    }

    // MARK: - Lookup options
    //
    // Built once and cached. These feed LookupField, which replaced the long
    // Pickers — a macOS Picker materialises every row into an NSMenu as soon as
    // the view appears, and the slot editor was doing that for ~3,400 rows.

    /// Items in the slot picker, the ones people actually hold first.
    ///
    /// Everything stays selectable — the calculator can model an item that is
    /// not in the game yet, and it will be right the day it arrives — but the
    /// ones nobody has been seen holding sort to the bottom and say so, rather
    /// than sitting in the list looking like a normal choice.
    lazy var itemOptions: [LookupOption] = data.items
        .sorted { first, second in
            if first.seenInGame != second.seenInGame { return first.seenInGame }
            return first.name < second.name
        }
        .map {
            LookupOption(id: $0.name, name: $0.name,
                         subtitle: $0.seenInGame ? ($0.category ?? "")
                                                 : "Not seen in Champions yet")
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

    /// The format's speed benchmarks, worked out once.
    ///
    /// Spreads are built against these, and giving meta teams role-aware
    /// spreads meant every one of their members recomputed the whole landscape
    /// — about a hundred and ninety times per team evaluation.
    private var speedCache: [String: [Int]] = [:]

    func speedBenchmarks(format: String) -> [Int] {
        if let hit = speedCache[format] { return hit }
        let made = Forecast(store: self, format: format).speedLandscape.map(\.speed)
        speedCache[format] = made
        return made
    }

    /// Opponent teams built from the meta list, kept rather than rebuilt.
    private var opponentCache: [String: Team] = [:]

    func opponentTeam(_ meta: MetaTeam) -> Team {
        if let hit = opponentCache[meta.id] { return hit }
        let made = TeamPaste.team(from: meta, store: self)
        opponentCache[meta.id] = made
        return made
    }

    /// Whether it is already built. The asynchronous pool warms these a few at
    /// a time and breathes in between, which is worth doing exactly once — after
    /// that the loop is pure sleeping, and the refiner walks it thousands of
    /// times.
    func hasOpponentTeam(_ meta: MetaTeam) -> Bool { opponentCache[meta.id] != nil }

    /// Teams sampled from the usage table, which describe what you will
    /// actually be queued against. Rebuilt inside every evaluation before this.
    private var ladderCache: [String: [(team: Team, weight: Double)]] = [:]

    func ladderTeams(format: String) -> [(team: Team, weight: Double)] {
        if let hit = ladderCache[format] { return hit }
        let made = MetaModel(store: self, format: format).ladderTeams()
        ladderCache[format] = made
        return made
    }

    /// What winning teams carry, worked out once. It depends only on the
    /// dataset, and rebuilding forty-eight teams inside every team evaluation
    /// took a score from 100ms to 390ms.
    private var structureCache: [String: [(group: MetaModel.RoleGroup, share: Double)]] = [:]

    func winningStructure(format: String) -> [(group: MetaModel.RoleGroup, share: Double)] {
        if let hit = structureCache[format] { return hit }
        let made = MetaModel(store: self, format: format).winningStructure()
        structureCache[format] = made
        return made
    }

    /// What a move is worth *to this Pokémon*: its own worth, its same-type
    /// bonus, and any ability that changes its type.
    ///
    /// What a move is worth in this form's hands. One implementation, in the
    /// rulebook, because six places used to rank moves and only three of them
    /// applied the same-type bonus.
    func moveValue(_ move: Move, for form: Form,
                   ability: String = "", item: String = "") -> Double {
        rulebook.moveValue(move, for: form, ability: ability, item: item)
    }

    /// The move this Pokémon is actually best at, by that measure.
    func bestMove(for form: Form, ability: String = "", item: String = "") -> Move? {
        attackingMoves(for: form).max {
            moveValue($0, for: form, ability: ability, item: item)
                < moveValue($1, for: form, ability: ability, item: item)
        }
    }

    func quality(of move: Move, ability: String = "", item: String = "") -> MoveQuality {
        rulebook.quality(of: move, ability: ability, item: item)
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

    /// What this team was measured to do, if it has been simulated and has not
    /// been edited since. A stale report is not offered: measured numbers for a
    /// team that no longer exists look authoritative and are not.
    func measured(for team: Team) -> TeamLab.Report? {
        guard let entry = simulations[team.id.uuidString],
              entry.stamp == LabStore.stamp(of: team) else { return nil }
        return entry.report
    }

    /// The fours this team has actually won with, ready for the picker.
    func measuredFours(for team: Team) -> [String: (wins: Int, games: Int)] {
        measured(for: team)?.measuredFours() ?? [:]
    }

    func remember(_ report: TeamLab.Report, for team: Team) {
        simulations[team.id.uuidString] = LabStore.Entry(
            teamID: team.id.uuidString, stamp: LabStore.stamp(of: team),
            ran: Date(), report: report)
        LabStore.save(simulations)
    }

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
