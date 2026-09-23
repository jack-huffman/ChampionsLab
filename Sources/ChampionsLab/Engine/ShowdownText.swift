//  ShowdownText.swift
//  Showdown's own sentences for the things a battle does.
//
//  The client does not build its log out of the protocol's tags. It looks the
//  sentence up. `|-start|p2a: Salamence|move: Yawn` is rendered from the Yawn
//  entry's `start`, "{POKEMON} grew drowsy!", and the reader here was doing
//  the other thing -- gluing the tag onto the name and hoping -- which is how
//  "Empoleon used Yawn. Salamence is Yawn." reached the screen. There is no
//  arrangement of that tag that reads as English, because the English is not
//  in the tag; it is in a table, and the table ships with the sim.
//
//  `data/showdown-text.json` is that table, cut down by Scripts/mktext.js to
//  the keys a battle actually says -- the descriptions are three hundred
//  kilobytes of text no log ever prints. Four tables: the sim's `default`,
//  which holds the statuses, the weathers and the terrains, and one each for
//  moves, abilities and items.
//
//  This is deliberately not the whole of the client's BattleTextParser. That
//  is seventeen hundred lines and renders every line of the protocol, which
//  is worth having and is a bigger change than one wrong sentence deserves.
//  It says of itself that it has no dependencies, so the door is open.

import Foundation

enum ShowdownText {
    /// table -> id -> key -> sentence.
    private static let tables: [String: [String: [String: String]]] = {
        let url = Bundle.main.url(forResource: "showdown-text", withExtension: "json")
            ?? developmentURL(named: "showdown-text.json")
        guard let url, let data = try? Data(contentsOf: url),
              let read = try? JSONDecoder().decode([String: [String: [String: String]]].self,
                                                   from: data)
        else { return [:] }
        return read
    }()

    private static func developmentURL(named name: String) -> URL? {
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    /// Whether the table arrived at all, so a test can say so rather than
    /// quietly passing on an empty one.
    static var isLoaded: Bool { !tables.isEmpty }

    /// Showdown's id: lower case, letters and digits only.
    static func id(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter {
            ("a"..."z").contains(String($0)) || ("0"..."9").contains(String($0))
        })
    }

    /// The sentence for one thing happening to one Pokemon, or nil when
    /// Showdown has not written one.
    ///
    /// `effect` is the protocol's own spelling -- "move: Yawn", "confusion",
    /// "ability: Flash Fire", "item: Leftovers" -- and the prefix picks the
    /// table. Without one, the sim's own `default` table is tried first,
    /// because that is where the statuses and the weathers live, and then
    /// moves, because a volatile is usually named after the move that set it.
    static func say(_ key: String, of effect: String,
                    values: [String: String] = [:]) -> String? {
        guard isLoaded else { return nil }
        let (table, name) = split(effect)
        let want = table.map { [$0] } ?? ["default", "moves", "abilities", "items"]
        for table in want {
            if let line = lookup(key, id: id(name), in: table, hops: 0) {
                return render(line, values)
            }
        }
        return nil
    }

    /// "move: Yawn" -> (moves, Yawn). No prefix, no table.
    private static func split(_ effect: String) -> (String?, String) {
        guard let colon = effect.firstIndex(of: ":") else { return (nil, effect) }
        let head = effect[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = String(effect[effect.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        switch head {
        case "move": return ("moves", rest)
        case "ability": return ("abilities", rest)
        case "item": return ("items", rest)
        default: return (nil, effect)
        }
    }

    /// One entry's line, following a cross-reference if it is one.
    ///
    /// The tables say `"end": "#psn"` where an effect ends the way another one
    /// does -- Toxic is cured the way poison is -- so a value beginning with a
    /// hash is the id to read the same key from instead.
    private static func lookup(_ key: String, id: String, in table: String,
                               hops: Int) -> String? {
        guard hops < 4, let line = tables[table]?[id]?[key] else { return nil }
        guard line.hasPrefix("#") else { return line }
        return lookup(key, id: String(line.dropFirst()), in: table, hops: hops + 1)
            ?? lookup(key, id: String(line.dropFirst()), in: "default", hops: hops + 1)
    }

    /// The placeholders filled in, and the client's own indentation dropped.
    ///
    /// A minor line is written with two leading spaces, which is how the
    /// client tells a minor line from a major one. This log does not indent,
    /// so that goes.
    private static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (name, value) in values {
            out = out.replacingOccurrences(of: "{\(name)}", with: value)
        }
        // {INFLECT:STAT:s=was:p=were} -- singular or plural, and everything
        // this log says is about one thing at a time.
        while let start = out.range(of: "{INFLECT:") {
            guard let close = out[start.lowerBound...].firstIndex(of: "}") else { break }
            let whole = out[start.lowerBound...close]
            let singular = whole.split(separator: ":").first { $0.hasPrefix("s=") }
                .map { String($0.dropFirst(2)) } ?? ""
            out = out.replacingOccurrences(of: String(whole),
                                           with: singular.replacingOccurrences(of: "}", with: ""))
        }
        // Anything left unfilled is a placeholder this caller had no value
        // for, and a sentence with a brace in it is worse than one without.
        if out.contains("{") { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
