//  UsageFeed.swift
//  Live usage data: fetch, parse, validate, persist.

import Foundation

/// The measured ladder table, fetched at runtime.
///
/// `mkusage.py` does this same job at build time; this is the in-app version so
/// the numbers can be refreshed without a checkout. Pikalytics embeds each
/// Pokémon's figures as JSON-LD FAQ answers, which is far steadier than
/// scraping their rendered tables:
///
///     "The best moves for Rillaboom … are Fake Out 56.51%, Wood Hammer 48.3%"
///
/// Only the ladder table comes from here. The dex itself — forms, learnsets,
/// items, abilities — is roughly 1,200 Serebii requests and stays a build-time
/// job for mkdata.py, which is why the refresh button says so.
///
/// Their data is CC BY-NC 4.0, so the app credits them on screen.
enum UsageFeed {
    static let base = "https://www.pikalytics.com"
    static let license = "CC BY-NC 4.0"

    /// The same header mkusage.py sends. Pikalytics serves a different, much
    /// thinner page to clients it does not recognise.
    private static let agent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    // MARK: - Formats

    struct FormatChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    /// Slugs seen on the site. A regulation that has not shipped yet will not be
    /// in this list, which is why the sheet also takes a typed slug.
    static let formats: [FormatChoice] = [
        .init(id: "gen9championsvgc2026regmc", name: "Regulation M-C",
              detail: "Current ladder"),
        .init(id: "gen9championsvgc2026regmb", name: "Regulation M-B",
              detail: "Previous regulation"),
        .init(id: "battledataregmbs3", name: "M-B Season 3 ranked",
              detail: "In-game ranked battle data"),
        .init(id: "championstournaments", name: "Tournaments",
              detail: "Tournament results"),
    ]

    static func name(ofFormat slug: String) -> String {
        formats.first { $0.id == slug }?.name ?? slug
    }

    // MARK: - What comes back

    struct Snapshot: Codable {
        let format: String
        let formatName: String
        let source: String
        let license: String
        let generated: String
        let fetched: Date
        let entries: [UsageEntry]
        /// References that could not be true and were discarded, kept so the
        /// UI can show what was thrown away rather than hiding it.
        let dropped: [String]
    }

    enum FeedError: LocalizedError {
        case listingUnavailable(String)
        case emptyRoster(String)
        case nothingUsable

        var errorDescription: String? {
            switch self {
            case .listingUnavailable(let slug):
                return "Could not load the listing for “\(slug)”. Check the connection, or the format slug."
            case .emptyRoster(let slug):
                return "The listing for “\(slug)” had no usage rows. That format may not exist."
            case .nothingUsable:
                return "Nothing in the fetched table matched the bundled Champions dex."
            }
        }
    }

    // MARK: - Validation index
    //
    // Snapshotted off the Store on the main actor so the fetch, which runs
    // away from it, never touches a live object.

    struct Index {
        var formsByLabel: [String: Form] = [:]
        var formsByName: [String: Form] = [:]
        var moveIDsByName: [String: String] = [:]
        var itemNames: Set<String> = []
        /// The bundled table, for its hand-written role and analysis prose.
        var curated: [String: UsageEntry] = [:]

        func form(for slug: String) -> Form? {
            let label = pikalyticsLabel(slug)
            return formsByLabel[label] ?? formsByName[label] ?? formsByName[slug]
        }
    }

    /// Map a Pikalytics slug to our form label. Their Megas are suffixed
    /// ("Salamence-Mega", "Charizard-Mega-Y") where ours are prefixed, and their
    /// regional forms hyphenate where ours spell the region out.
    static func pikalyticsLabel(_ slug: String) -> String {
        if let known = knownNames[slug] { return known }
        let parts = slug.split(separator: "-").map(String.init)
        // "Mega" is not always the second part: tournament results carry
        // "Floette-Eternal-Mega", where the form tag comes before it.
        if let index = parts.dropFirst().firstIndex(of: "Mega") {
            var tag = ""
            if parts.count > index + 1, parts[index + 1].count <= 2 {
                tag = " " + parts[index + 1].uppercased()
            }
            return "Mega \(parts[0])\(tag)"
        }
        return slug.replacingOccurrences(of: "-", with: " ")
    }

    private static let knownNames: [String: String] = [
        "Indeedee-F": "Indeedee (Female)",
        "Indeedee-M": "Indeedee",
        "Floette-Eternal": "Floette (Eternal)",
        "Basculegion-F": "Basculegion (Female)",
        "Tauros-Paldea-Aqua": "Paldean Tauros (Aqua)",
        "Tauros-Paldea-Blaze": "Paldean Tauros (Blaze)",
        "Tauros-Paldea-Combat": "Paldean Tauros (Combat)",
        "Ninetales-Alola": "Alolan Ninetales",
        "Raichu-Alola": "Alolan Raichu",
        "Arcanine-Hisui": "Hisuian Arcanine",
        "Rotom-Wash": "Rotom (Wash)",
        "Rotom-Heat": "Rotom (Heat)",
        "Maushold-Four": "Maushold (Family of Four)",
    ]

    // MARK: - Fetching

    private static func get(_ path: String) async throws -> String {
        guard let url = URL(string: base + path) else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole job: listing for the roster, then one page per Pokémon.
    ///
    /// `progress` is called on the main actor after each page so the sheet can
    /// count up; the fetch itself stays off it.
    static func refresh(format: String, index: Index,
                        progress: @escaping @MainActor (Int, Int, String) -> Void)
        async throws -> Snapshot
    {
        await progress(0, 1, "Fetching the \(name(ofFormat: format)) listing…")
        let listing = try await get("/pokedex/\(format)")
        guard !listing.isEmpty else { throw FeedError.listingUnavailable(format) }

        let roster = parseRoster(listing, format: format)
        guard !roster.isEmpty else { throw FeedError.emptyRoster(format) }

        var entries: [UsageEntry] = []
        var dropped: [String] = []

        for (number, row) in roster.enumerated() {
            await progress(number, roster.count, pikalyticsLabel(row.slug))
            try Task.checkCancellation()

            guard let form = index.form(for: row.slug) else {
                dropped.append("\(row.slug): not in the Champions dex")
                continue
            }
            let page = try await get("/pokedex/\(format)/\(row.slug)")
            let detail = page.isEmpty ? Detail() : parseDetail(page)
            let (entry, rejected) = build(row: row, form: form, detail: detail, index: index)
            entries.append(entry)
            dropped.append(contentsOf: rejected)

            // Their pages are cheap but there is no reason to hammer them.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        await progress(roster.count, roster.count, "Done")
        guard !entries.isEmpty else { throw FeedError.nothingUsable }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return Snapshot(format: format, formatName: name(ofFormat: format),
                        source: "\(base)/pokedex/\(format)", license: license,
                        generated: day.string(from: Date()), fetched: Date(),
                        entries: entries.sorted { $0.usage > $1.usage },
                        dropped: dropped)
    }

    // MARK: - Parsing

    struct RosterRow { let slug: String; let usage: Double }

    struct Detail {
        var moves: [UsageShare] = []
        var items: [UsageShare] = []
        var abilities: [UsageShare] = []
        var teammates: [String] = []
        var winrate: Double?
        var wins: Int?
        var losses: Int?
    }

    /// Pokémon in this format with their overall usage, in usage order.
    ///
    /// Rows are an anchor plus a percentage, but the percentage sits a variable
    /// distance away, so the page is sliced on the anchors and each slice
    /// searched forward.
    static func parseRoster(_ page: String, format: String) -> [RosterRow] {
        let text = page as NSString
        let whole = NSRange(location: 0, length: text.length)
        let slug = NSRegularExpression.escapedPattern(for: format)
        let anchors = regex("/pokedex/\(slug)/([A-Za-z0-9\\-'.]+)\"")
            .matches(in: page, range: whole)
        let percent = regex("(\\d{1,3}(?:\\.\\d{1,3})?)\\s*%")

        var rows: [RosterRow] = []
        var seen: Set<String> = []
        for (position, anchor) in anchors.enumerated() {
            let name = text.substring(with: anchor.range(at: 1))
            if seen.contains(name) { continue }
            let start = anchor.range.upperBound
            let end = position + 1 < anchors.count
                ? anchors[position + 1].range.location : text.length
            guard end > start else { continue }
            guard let hit = percent.firstMatch(
                    in: page, range: NSRange(location: start, length: end - start)),
                  let value = Double(text.substring(with: hit.range(at: 1)))
            else { continue }
            seen.insert(name)
            rows.append(RosterRow(slug: name, usage: (value * 100).rounded() / 100))
        }
        return rows
    }

    static func parseDetail(_ page: String) -> Detail {
        var detail = Detail()
        for (question, answer) in faqAnswers(page) {
            let lower = question.lowercased()
            if lower.contains("best moves") {
                detail.moves = shares(in: answer)
            } else if lower.contains("item should i use") {
                detail.items = shares(in: answer)
            } else if lower.contains("ability is best") {
                detail.abilities = shares(in: answer)
            } else if lower.contains("best teammates") {
                // Percentages arrive as "undefined" here, so keep the order only.
                let text = answer as NSString
                detail.teammates = regex("([A-Z][A-Za-z0-9'\\-.]*(?:-[A-Z][A-Za-z]*)?)\\s*\\(")
                    .matches(in: answer, range: NSRange(location: 0, length: text.length))
                    .map { text.substring(with: $0.range(at: 1)) }
            } else if lower.contains("winrate") {
                let text = answer as NSString
                let whole = NSRange(location: 0, length: text.length)
                if let hit = regex("(\\d+(?:\\.\\d+)?)%\\s*winrate")
                    .firstMatch(in: answer, range: whole) {
                    detail.winrate = Double(text.substring(with: hit.range(at: 1)))
                }
                if let hit = regex("(\\d[\\d,]*)\\s*wins and\\s*(\\d[\\d,]*)\\s*losses")
                    .firstMatch(in: answer, range: whole) {
                    detail.wins = Int(text.substring(with: hit.range(at: 1))
                        .replacingOccurrences(of: ",", with: ""))
                    detail.losses = Int(text.substring(with: hit.range(at: 2))
                        .replacingOccurrences(of: ",", with: ""))
                }
            }
        }
        return detail
    }

    /// The FAQPage JSON-LD block, as question to answer.
    static func faqAnswers(_ page: String) -> [String: String] {
        let text = page as NSString
        let blocks = regex("<script type=\"application/ld\\+json\"[^>]*>(.*?)</script>",
                           dotMatchesNewlines: true)
            .matches(in: page, range: NSRange(location: 0, length: text.length))
        for block in blocks {
            let body = text.substring(with: block.range(at: 1))
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any],
                  dict["@type"] as? String == "FAQPage",
                  let entities = dict["mainEntity"] as? [[String: Any]]
            else { continue }
            var out: [String: String] = [:]
            for entity in entities {
                let question = entity["name"] as? String ?? ""
                let answer = (entity["acceptedAnswer"] as? [String: Any])?["text"] as? String
                out[question] = decodeEntities(answer ?? "")
            }
            return out
        }
        return [:]
    }

    /// Name/percentage pairs out of one FAQ sentence.
    ///
    /// Two shapes appear depending on the format — "Dragon Claw (89.4%)" and
    /// "Fake Out 56.51%". The leading clause has to go first, or the first name
    /// comes back as the whole of "The top moves for Rillaboom in … are Fake Out".
    static func shares(in sentence: String) -> [UsageShare] {
        var body = sentence
        if let cut = body.range(of: "\\bare\\b\\s*", options: .regularExpression) {
            body = String(body[cut.upperBound...])
        }
        // Drop the trailing commentary sentence.
        if let stop = body.range(of: "\\.\\s+[A-Z]", options: .regularExpression) {
            body = String(body[..<stop.lowerBound])
        }

        var out: [UsageShare] = []
        for piece in split(body, on: ",|\\band\\b") {
            let chunk = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !chunk.isEmpty else { continue }
            let text = chunk as NSString
            guard let hit = regex("^(.+?)\\s*\\(?(\\d+(?:\\.\\d+)?)%\\)?$")
                    .firstMatch(in: chunk, range: NSRange(location: 0, length: text.length)),
                  let percent = Double(text.substring(with: hit.range(at: 2)))
            else { continue }
            let name = text.substring(with: hit.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "( "))
                .trimmingCharacters(in: .whitespaces)
            guard let initial = name.first, initial.isUppercase else { continue }
            out.append(UsageShare(name: name, percent: (percent * 100).rounded() / 100))
        }
        return out
    }

    // MARK: - Validation
    //
    // Every reference is checked against the scraped dex and dropped if it
    // cannot be true. Their ability figures are noisy on a format this young and
    // claim things like a Basculegion with Trace.

    static func build(row: RosterRow, form: Form, detail: Detail, index: Index)
        -> (UsageEntry, [String])
    {
        var dropped: [String] = []
        let label = form.formLabel

        let learnset = Set(form.moves)
        let moves = detail.moves.filter { share in
            guard let id = index.moveIDsByName[share.name], learnset.contains(id) else {
                dropped.append("\(label): cannot learn \(share.name)")
                return false
            }
            return true
        }

        let own = Set(form.abilities.map(\.name))
        let abilities = detail.abilities.filter { share in
            guard own.contains(share.name) else {
                dropped.append("\(label): cannot have \(share.name)")
                return false
            }
            return true
        }

        let items = detail.items.filter { share in
            guard index.itemNames.contains(share.name) else {
                dropped.append("\(label): unknown item \(share.name)")
                return false
            }
            return true
        }

        let previous = index.curated[label] ?? index.curated[form.name]
        let checked = Detail(moves: moves, items: items, abilities: abilities,
                             teammates: detail.teammates, winrate: detail.winrate,
                             wins: detail.wins, losses: detail.losses)

        let entry = UsageEntry(
            name: label,
            tier: tier(for: row.usage),
            usage: row.usage,
            projected: false,
            formats: previous?.formats ?? ["doubles"],
            // Hand-written analysis wins; otherwise say what the ladder shows.
            role: previous?.role.isEmpty == false ? previous!.role
                                                  : role(of: form, detail: checked),
            commonItems: items.prefix(3).map(\.name),
            keyMoves: moves.prefix(4).map(\.name),
            why: previous?.why.isEmpty == false ? previous!.why
                                                : describe(form, detail: checked),
            winrate: detail.winrate, wins: detail.wins, losses: detail.losses,
            moveUsage: moves, itemUsage: items, abilityUsage: abilities,
            teammates: Array(detail.teammates.prefix(4)))
        return (entry, dropped)
    }

    static func tier(for usage: Double) -> String {
        if usage >= 25 { return "S" }
        if usage >= 12 { return "A" }
        if usage >= 5 { return "B" }
        return "C"
    }

    /// A role label from what the Pokémon actually runs.
    static func role(of form: Form, detail: Detail) -> String {
        let moves = Set(detail.moves.map(\.name))
        let abilities = Set(detail.abilities.map(\.name))
        if !moves.isDisjoint(with: ["Follow Me", "Rage Powder"]) { return "Redirection / support" }
        if moves.contains("Trick Room") { return "Trick Room setter" }
        if moves.contains("Tailwind") { return "Speed control" }
        if !abilities.isDisjoint(with: ["Grassy Surge", "Psychic Surge",
                                        "Electric Surge", "Misty Surge"]) {
            return "Terrain setter"
        }
        if !abilities.isDisjoint(with: ["Drizzle", "Drought", "Sand Stream", "Snow Warning"]) {
            return "Weather setter"
        }
        if abilities.contains("Intimidate")
            || !moves.isDisjoint(with: ["Parting Shot", "U-turn", "Volt Switch"]) {
            return "Pivot / Intimidate"
        }
        return form.attack >= form.spAttack ? "Physical attacker" : "Special attacker"
    }

    /// A factual line for a Pokémon with no hand-written note, so the "Why it
    /// matters" card says something rather than sitting empty.
    static func describe(_ form: Form, detail: Detail) -> String {
        var bits: [String] = []
        if let ability = detail.abilities.first {
            bits.append(String(format: "Runs %@ on %.0f%% of sets",
                               ability.name, ability.percent))
        }
        if !detail.moves.isEmpty {
            bits.append("most common moves are "
                        + detail.moves.prefix(3).map(\.name).joined(separator: ", "))
        }
        if let item = detail.items.first {
            bits.append(String(format: "usually holding %@ (%.0f%%)", item.name, item.percent))
        }
        var text = bits.joined(separator: "; ")
        if let first = text.first {
            text = first.uppercased() + text.dropFirst() + "."
        }
        if let rate = detail.winrate {
            let verdict = rate >= 51 ? "It is winning more than it loses"
                        : (rate >= 49 ? "It is close to even"
                                      : "It loses slightly more than it wins")
            text += String(format: " %@ at %.1f%% across %d recorded games.",
                           verdict, rate, (detail.wins ?? 0) + (detail.losses ?? 0))
        }
        if !detail.teammates.isEmpty {
            text += " Most often seen alongside "
                + detail.teammates.prefix(3).joined(separator: ", ") + "."
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistence
    //
    // The app bundle is signed and must not be written into, so a refresh lands
    // in Application Support and the Store prefers it over the bundled copy.

    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ChampionsLab/usage-live.json")
    }

    static func load() -> Snapshot? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: raw)
    }

    static func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    static func discard() {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Regex plumbing

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String,
                              dotMatchesNewlines: Bool = false) -> NSRegularExpression {
        let key = (dotMatchesNewlines ? "s:" : ":") + pattern
        if let hit = cache[key] { return hit }
        // Every pattern here is a literal, so a failure is a programming error.
        let made = try! NSRegularExpression(
            pattern: pattern, options: dotMatchesNewlines ? [.dotMatchesLineSeparators] : [])
        cache[key] = made
        return made
    }

    private static func split(_ text: String, on pattern: String) -> [String] {
        let source = text as NSString
        var pieces: [String] = []
        var cursor = 0
        for hit in regex(pattern).matches(
                in: text, range: NSRange(location: 0, length: source.length)) {
            pieces.append(source.substring(with: NSRange(
                location: cursor, length: hit.range.location - cursor)))
            cursor = hit.range.upperBound
        }
        pieces.append(source.substring(from: cursor))
        return pieces
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
