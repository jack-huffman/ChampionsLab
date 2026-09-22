//  ShowdownEngine.swift
//  Showdown's own battle engine, running inside the app.
//
//  Not a translation of it and not a reading of it: the simulator itself, the
//  same code that resolves every game on Pokémon Showdown, bundled by
//  Scripts/mkengine.sh and run in JavaScriptCore -- which every Mac already
//  has, so nothing extra ships and nothing extra is signed.
//
//  It plays this game rather than the main series because Showdown has a
//  champions mod and that mod is the real thing: `[Gen 9 Champions] VGC 2026
//  Reg M-C` is a format it runs, and the mod's `statModify` is the Stat Point
//  formula -- base + points + 75 for HP, + 20 for the rest -- which is where
//  this app's own numbers were reverse-engineered to.
//
//  Tracked against master rather than a release. The tags lag well behind:
//  Reg M-C reached master months before any tag carried it.

import Foundation
import JavaScriptCore

/// The engine, and a battle in progress.
///
/// One context, loaded once. Standing a battle up costs about two
/// milliseconds and a turn about four, so a played game never notices it and
/// a search can afford a few hundred positions a second.
@MainActor
final class ShowdownEngine {
    static let shared = ShowdownEngine()

    enum Trouble: LocalizedError {
        case noBundle, didNotLoad(String), refused(String)
        var errorDescription: String? {
            switch self {
            case .noBundle:
                return "showdown-engine.js is missing. Run ./Scripts/mkengine.sh."
            case .didNotLoad(let why): return "the engine did not load: \(why)"
            case .refused(let why): return "the engine refused: \(why)"
            }
        }
    }

    private var context: JSContext?
    private var lastException: String?

    /// What the bundle was built from, so a battle can say which Showdown it is.
    private(set) var commit = "unknown"

    // MARK: - Loading

    /// The context, built on first use. Loading nine megabytes of JavaScript
    /// takes about a fifth of a second, which is why it is not done at launch.
    @discardableResult
    func load() throws -> JSContext {
        if let context { return context }
        guard let url = Self.bundleURL() else { throw Trouble.noBundle }
        guard let made = JSContext() else { throw Trouble.didNotLoad("no JavaScript context") }
        made.exceptionHandler = { [weak self] _, value in
            self?.lastException = value?.toString() ?? "unknown"
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        made.evaluateScript(source)
        if let trouble = lastException { throw Trouble.didNotLoad(trouble) }
        guard let ps = made.objectForKeyedSubscript("PS"), !ps.isUndefined else {
            throw Trouble.didNotLoad("the bundle did not install its API")
        }
        context = made
        return made
    }

    static func bundleURL() -> URL? {
        if let inApp = Bundle.main.url(forResource: "showdown-engine", withExtension: "js") {
            return inApp
        }
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/showdown-engine.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    private func call(_ name: String, _ arguments: [Any] = []) throws -> JSValue {
        let ctx = try load()
        lastException = nil
        guard let ps = ctx.objectForKeyedSubscript("PS"),
              let out = ps.invokeMethod(name, withArguments: arguments) else {
            throw Trouble.refused("\(name) returned nothing")
        }
        if let trouble = lastException { throw Trouble.refused(trouble) }
        return out
    }

    // MARK: - What it can play

    struct Format: Equatable {
        let id: String, name: String, mod: String, gameType: String
        var isDoubles: Bool { gameType == "doubles" }
    }

    /// Every Champions format the bundle carries.
    func formats() throws -> [Format] {
        let raw = try call("formats").toArray() as? [[String: Any]] ?? []
        return raw.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String,
                  let mod = row["mod"] as? String, let type = row["gameType"] as? String
            else { return nil }
            return Format(id: id, name: name, mod: mod, gameType: type)
        }
    }

    /// The format this app plays.
    static let regMC = "gen9championsvgc2026regmc"

    // MARK: - A battle

    /// A team written as a Showdown paste, packed the way the sim wants it.
    func pack(paste: String) throws -> String {
        try call("pack", [paste]).toString() ?? ""
    }

    /// Stand a battle up. The seed makes it repeatable; without one the sim
    /// picks its own and the same game never happens twice.
    func start(format: String = ShowdownEngine.regMC,
               mine: (name: String, team: String),
               theirs: (name: String, team: String),
               seed: [Int]? = nil) throws {
        _ = try call("start", [format,
                               ["name": mine.name, "team": mine.team],
                               ["name": theirs.name, "team": theirs.team],
                               seed?.map(String.init).joined(separator: ",") ?? ""])
    }

    /// A side's choice, in the sim's own words: "team 1234", "move fakeout 1,
    /// move woodhammer 1", "switch 3", "default".
    @discardableResult
    func choose(_ side: String, _ choice: String) throws -> Bool {
        try call("choose", [side, choice]).toBool()
    }

    /// Everything the battle has said since this was last asked, as protocol
    /// lines -- the same lines Showdown's own client reads.
    func since() throws -> [String] {
        let chunks = try call("since").toArray() as? [String] ?? []
        return chunks.joined(separator: "\n").split(separator: "\n").map(String.init)
    }

    /// What a side is being asked for, as the client would see it.
    func request(_ side: String) throws -> String? {
        let out = try call("request", [side])
        return out.isNull || out.isUndefined ? nil : out.toString()
    }

    /// Every way a turn could go, each with the odds of going that way, as
    /// the engine reports them: a chance and the protocol lines for it.
    func outcomes(_ mine: String, _ theirs: String, branching: Int) throws -> [[String: Any]] {
        try call("outcomes", [mine, theirs, branching]).toArray() as? [[String: Any]] ?? []
    }

    var turn: Int { (try? call("turn").toInt32()).map(Int.init) ?? 0 }
    var ended: Bool { (try? call("ended").toBool()) ?? false }
    var winner: String? {
        guard let out = try? call("winner"), !out.isNull, !out.isUndefined else { return nil }
        return out.toString()
    }
}
