//  SmogonFeed.swift
//  The ladder table from Smogon's published usage statistics.
//
//  Smogon publishes, once a month, what was run on the Pokemon Showdown
//  ladder for every format, Champions included: usage, moves, items,
//  abilities, teammates, and the spreads -- in Champions' own Stat Points --
//  as one gzipped JSON file per format and rating floor. One download,
//  where Pikalytics is a page per Pokemon. It publishes usage, not teams;
//  the teams the app plays against are built from it.
//
//  Everything fetched goes through the same validation as the Pikalytics
//  feed, so a reference the dex says cannot be true is dropped and shown.

import Foundation

enum SmogonFeed {
    static let base = "https://www.smogon.com/stats"
    static let credit = "Smogon usage statistics, from Pokemon Showdown ladder games"
    /// The rating floors a table is read at, in the order tried: the ladder
    /// at large first, which is what Pikalytics reads too.
    static let cutoffs = [1500, 0]

    enum FeedError: LocalizedError {
        case noIndex
        case notPublished(String, [String])
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noIndex:
                return "Could not read Smogon's list of months. Check the connection."
            case .notPublished(let slug, let months):
                return "Smogon has not published \u{201C}\(slug)\u{201D} in the last months looked at (\(months.joined(separator: ", "))). The slug may be wrong, or the regulation too new."
            case .unreadable(let why):
                return "Smogon's table could not be read: \(why)."
            }
        }
    }

    // MARK: - Fetching

    /// The latest month with the format, read at the floor asked for or the
    /// next one down, and turned into the app's usage entries.
    static func refresh(format: String, cutoff: Int = 1500, index: UsageFeed.Index,
                        progress: @escaping @MainActor (Int, Int, String) -> Void)
        async throws -> UsageFeed.Snapshot
    {
        await progress(0, 3, "Looking for the latest month...")
        let months = try await months()
        var found: (month: String, cutoff: Int, data: Data)?
        search: for month in months.prefix(8) {
            for floor in [cutoff] + cutoffs.filter({ $0 != cutoff }) {
                try Task.checkCancellation()
                if let raw = try await get("/\(month)/chaos/\(format)-\(floor).json.gz") {
                    found = (month, floor, raw)
                    break search
                }
            }
        }
        guard let found else { throw FeedError.notPublished(format, Array(months.prefix(3))) }
        await progress(1, 3, "Reading \(found.month)...")
        let table = try parse(Gzip.decompress(found.data))
        await progress(2, 3, "Checking against the dex...")
        let (entries, dropped) = convert(table, index: index)
        guard !entries.isEmpty else { throw UsageFeed.FeedError.nothingUsable }
        await progress(3, 3, "Done")
        let floor = found.cutoff == 0 ? "all ratings" : "\(found.cutoff)+"
        return UsageFeed.Snapshot(
            format: format,
            formatName: "\(UsageFeed.name(ofFormat: format)) \u{00B7} Smogon \(found.month), \(floor)",
            source: "\(base)/\(found.month)/chaos/\(format)-\(found.cutoff).json.gz",
            license: credit, generated: found.month, fetched: Date(),
            entries: entries.sorted { $0.usage > $1.usage }, dropped: dropped)
    }

    /// The months published, latest first.
    static func months() async throws -> [String] {
        guard let raw = try await get("/") else { throw FeedError.noIndex }
        let page = String(decoding: raw, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "href=\"(20[0-9]{2}-[0-9]{2})/\"")
        let text = page as NSString
        let hits = pattern.matches(in: page, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
        let months = Array(Set(hits)).sorted(by: >)
        guard !months.isEmpty else { throw FeedError.noIndex }
        return months
    }

    /// A GET, or nil for a 404 -- a month without the format is skipped, not
    /// an error.
    private static func get(_ path: String) async throws -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("ChampionsLab (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw FeedError.unreadable("HTTP \(http.statusCode) for \(path)") }
        return data
    }

    // MARK: - The table

    /// One Pokemon's row of the table: its share of teams, how many sets it
    /// was on (weighted, as Smogon weights them), and what those sets ran.
    struct Species {
        let name: String
        let usage: Double
        let appearances: Double
        let moves: [(String, Double)]
        let items: [(String, Double)]
        let abilities: [(String, Double)]
        let spreads: [(String, Double)]
        let teammates: [(String, Double)]
    }

    static func parse(_ json: Data) throws -> [Species] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            throw FeedError.unreadable("no data table in the file")
        }
        func pairs(_ any: Any?) -> [(String, Double)] {
            ((any as? [String: Any]) ?? [:]).compactMap { key, value in
                (value as? NSNumber).map { (key, $0.doubleValue) }
            }
        }
        return data.compactMap { name, any in
            guard let row = any as? [String: Any] else { return nil }
            let abilities = pairs(row["Abilities"])
            // Every set has one ability, so their weights sum to the sets.
            let appearances = abilities.reduce(0) { $0 + $1.1 }
            return Species(name: name,
                           usage: (row["usage"] as? NSNumber)?.doubleValue ?? 0,
                           appearances: appearances,
                           moves: pairs(row["Moves"]), items: pairs(row["Items"]),
                           abilities: abilities, spreads: pairs(row["Spreads"]),
                           teammates: pairs(row["Teammates"]))
        }
    }

    /// Smogon's names are ids -- "earthquake", "focussash" -- and the app's
    /// are names, so each is read back through the dex, and anything the
    /// dex does not know is dropped with a reason, as the Pikalytics feed
    /// drops what cannot be true.
    static func convert(_ table: [Species], index: UsageFeed.Index) -> ([UsageEntry], [String]) {
        let movesByID = Dictionary(index.moveIDsByName.map { ($0.value, $0.key) },
                                   uniquingKeysWith: { a, _ in a })
        let itemsByID = Dictionary(index.itemNames.map { (toID($0), $0) },
                                   uniquingKeysWith: { a, _ in a })
        var entries: [UsageEntry] = []
        var dropped: [String] = []
        for species in table.sorted(by: { $0.usage > $1.usage }) where species.appearances > 0 {
            guard let form = index.form(for: species.name) else {
                dropped.append("\(species.name): not in the Champions dex")
                continue
            }
            func shares(_ pairs: [(String, Double)], naming: (String) -> String?) -> [UsageShare] {
                pairs.sorted { $0.1 > $1.1 }.compactMap { id, weight in
                    guard let name = naming(id) else { return nil }
                    let percent = (weight / species.appearances * 10_000).rounded() / 100
                    return percent > 0 ? UsageShare(name: name, percent: Swift.min(100, percent)) : nil
                }
            }
            let abilitiesByID = Dictionary(form.abilities.map { (toID($0.name), $0.name) },
                                           uniquingKeysWith: { a, _ in a })
            let detail = UsageFeed.Detail(
                moves: shares(species.moves) { movesByID[$0] },
                items: shares(species.items) { itemsByID[$0] },
                abilities: shares(species.abilities) { abilitiesByID[$0] ?? $0 },
                // Teammates are weighted against expectation, so the top of
                // the list is who it is actually brought with.
                teammates: species.teammates.sorted { $0.1 > $1.1 }.prefix(6)
                    .map { UsageFeed.pikalyticsLabel($0.0) },
                winrate: nil, wins: nil, losses: nil)
            let spreads = Array(shares(species.spreads) { $0.replacingOccurrences(of: ":", with: " ") }.prefix(3))
            let row = UsageFeed.RosterRow(slug: species.name,
                                          usage: (species.usage * 10_000).rounded() / 100)
            let (entry, rejected) = UsageFeed.build(row: row, form: form, detail: detail,
                                                    index: index, spreads: spreads)
            entries.append(entry)
            dropped.append(contentsOf: rejected)
        }
        return (entries, dropped)
    }

    /// Showdown's id for a name: lower case, letters and digits only.
    static func toID(_ name: String) -> String {
        String(name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
}

/// A gzip file opened: the header stepped over, the deflate stream inflated.
enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw SmogonFeed.FeedError.unreadable("not a gzip file")
        }
        let flags = bytes[3]
        var pos = 10
        if flags & 0x04 != 0, pos + 1 < bytes.count {
            let extra = Int(bytes[pos]) | Int(bytes[pos + 1]) << 8
            pos += 2 + extra
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {
            while pos < bytes.count, bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos < bytes.count - 8 else { throw SmogonFeed.FeedError.unreadable("truncated gzip file") }
        let body = Data(bytes[pos..<(bytes.count - 8)])
        do {
            return try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw SmogonFeed.FeedError.unreadable("the compressed stream would not open")
        }
    }
}
