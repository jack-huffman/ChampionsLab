//  Choreography.swift
//  Every move's animation as data: what flies, who leans, and when.
//
//  The Showdown client draws each move as a short script over a handful of
//  primitives -- a sprite flying between two poses, a Pokemon leaning toward a
//  pose and back, a pause, a wash of colour over the field, the ground
//  shaking -- and Scripts/mkanimations.py reads those scripts into
//  data/animations.json. This is that table read back: eight hundred and
//  more moves, the client's own fallbacks for a move without a recipe, and
//  its animations for a condition taking hold. The choreography is theirs,
//  under MIT; the drawing of each primitive is ours.
//
//  A pose is a linear form over the two Pokemon on each axis -- a times the
//  attacker's position, d times the defender's, plus a constant -- with
//  behind(n) and leftof(n) terms signed by which side the Pokemon stands on.
//  MoveTimeline is what places one on the arena.

import Foundation

struct Choreography: Decodable, Sendable {
    let source: String
    let moves: [String: Recipe]
    /// The client's fallbacks and shared pieces: contactattack, dance, shake.
    let other: [String: Recipe]
    /// A condition taking hold: flinch, brn, psn, slp, par, frz, confused.
    let status: [String: Recipe]
    /// The drawn size of each primitive, in the client's scene units.
    let sprites: [String: [Double]]

    struct Recipe: Decodable, Sendable {
        /// "moves:gigaimpact" or "other:clawattack": this move borrows that one whole.
        var alias: String?
        var steps: [Step]?
        /// Written against every target rather than one.
        var spread: Bool?
    }

    enum Kind: String, Decodable, Sendable { case effect, move, delay, wait, background, shake, include }
    enum Part: String, Decodable, Sendable { case attacker, defender }
    enum Easing: String, Decodable, Sendable {
        case linear, swing, accel, decel
        case ballistic, ballisticUp, ballisticUnder, ballistic2, ballistic2Under, ballistic2Back

        /// A name this does not know is linear, rather than a table that will
        /// not load: one odd spelling must not take eight hundred moves down.
        init(from decoder: Decoder) throws {
            self = Easing(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .linear
        }
    }
    enum Ending: String, Decodable, Sendable {
        case fade, explode

        init(from decoder: Decoder) throws {
            self = Ending(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .fade
        }
    }

    struct Step: Decodable, Sendable {
        var kind: Kind
        // effect: a primitive flying from one pose to another
        var sprite: String?
        var from: Pose?
        var to: Pose?
        var easing: Easing?
        var ending: Ending?
        // move and delay: a Pokemon leaning toward a pose, or pausing its queue
        var who: Part?
        var ms: Double?
        // background and shake
        var colour: String?
        var image: String?
        var duration: Double?
        var opacity: Double?
        var delay: Double?
        // include: another recipe, played here with these parts in its roles
        var table: String?
        var name: String?
        var parts: [Part]?
    }

    struct Pose: Decodable, Sendable {
        var x: Coordinate?
        var y: Coordinate?
        var z: Coordinate?
        var scale: Double?
        var xscale: Double?
        var yscale: Double?
        var opacity: Double?
        var time: Double?
    }

    /// One axis of a pose. `a` and `d` weigh the attacker's and the defender's
    /// own coordinate on this axis; the two-letter forms weigh one of their
    /// other axes, which the client does write now and then; `ab`/`db` are
    /// behind(n) and `al`/`dl` leftof(n); `c` is the constant.
    struct Coordinate: Decodable, Sendable {
        var a: Double?, d: Double?
        var ax: Double?, ay: Double?, az: Double?
        var dx: Double?, dy: Double?, dz: Double?
        var ab: Double?, db: Double?, al: Double?, dl: Double?
        var c: Double?

        /// The whole weight on each Pokemon, whichever of its axes was read.
        var onAttacker: Double { (a ?? 0) + (ax ?? 0) + (ay ?? 0) + (az ?? 0) }
        var onDefender: Double { (d ?? 0) + (dx ?? 0) + (dy ?? 0) + (dz ?? 0) }
        var touchesDefender: Bool { onDefender != 0 || (db ?? 0) != 0 || (dl ?? 0) != 0 }

        /// The same coordinate with the roles recast: an included recipe's
        /// attacker and defender become whichever parts it was called with.
        /// Two roles cast onto one part fold together.
        func cast(attacker: Part, defender: Part) -> Coordinate {
            var out = Coordinate(c: c)
            func add(_ weight: Double, _ behind: Double, _ leftof: Double, to part: Part) {
                switch part {
                case .attacker:
                    out.a = (out.a ?? 0) + weight; out.ab = (out.ab ?? 0) + behind; out.al = (out.al ?? 0) + leftof
                case .defender:
                    out.d = (out.d ?? 0) + weight; out.db = (out.db ?? 0) + behind; out.dl = (out.dl ?? 0) + leftof
                }
            }
            add(onAttacker, ab ?? 0, al ?? 0, to: attacker)
            add(onDefender, db ?? 0, dl ?? 0, to: defender)
            return out
        }
    }

    /// A recipe with its aliases followed and its includes inlined.
    struct Resolved: Sendable {
        var steps: [Step]
        var spread: Bool
    }

    // MARK: - Loading

    /// The table shipped with the app, or an empty one when it is missing --
    /// the arena then draws its own beam and burst, as it did before.
    static let shared: Choreography = load()

    static let empty = Choreography(source: "", moves: [:], other: [:], status: [:], sprites: [:])

    static func load() -> Choreography {
        guard let url = Bundle.main.url(forResource: "animations", withExtension: "json")
                ?? developmentURL(named: "animations.json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Choreography.self, from: data) else { return empty }
        return table
    }

    /// Beside Package.swift, for a run from the checkout or a test.
    private static func developmentURL(named name: String) -> URL? {
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Reading it

    /// Showdown's id for a move: lower case, letters and digits only, so
    /// "Double-Edge" and "King's Shield" find their recipes.
    static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }

    var isEmpty: Bool { moves.isEmpty }

    func recipe(forMove name: String) -> Resolved? {
        resolve("moves:" + Self.key(name), seen: [])
    }

    /// What the client plays for a move it has no recipe for: a quick lunge,
    /// a quick shot, or a quick shimmer on the user.
    func fallback(category: String, targetsSelf: Bool) -> Resolved? {
        resolve("other:" + (targetsSelf ? "fastanimself" : category == "Special" ? "fastanimspecial" : "fastanimattack"),
                seen: [])
    }

    func status(_ name: String) -> Resolved? {
        resolve("status:" + name, seen: [])
    }

    private func resolve(_ ref: String, seen: Set<String>) -> Resolved? {
        guard !seen.contains(ref) else { return nil }
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let table = parts[0] == "other" ? other : parts[0] == "status" ? status : moves
        guard let recipe = table[parts[1]] else { return nil }
        if let alias = recipe.alias { return resolve(alias, seen: seen.union([ref])) }
        return flatten(recipe, seen: seen.union([ref]))
    }

    /// Includes inlined where they stand, the included recipe's roles recast
    /// onto the parts it was called with: dance called on [attacker] dances
    /// the attacker; shake called on [defender] shakes the defender.
    private func flatten(_ recipe: Recipe, seen: Set<String>) -> Resolved? {
        var steps: [Step] = []
        for step in recipe.steps ?? [] {
            guard step.kind == .include else { steps.append(step); continue }
            guard let table = step.table, let name = step.name,
                  let inner = resolve(table + ":" + name, seen: seen) else { continue }
            let parts = step.parts ?? [.attacker, .defender]
            let asAttacker = parts.first ?? .attacker
            let asDefender = parts.count > 1 ? parts[1] : asAttacker
            if asAttacker == .attacker && asDefender == .defender {
                steps += inner.steps
            } else {
                steps += inner.steps.map { $0.cast(attacker: asAttacker, defender: asDefender) }
            }
        }
        return Resolved(steps: steps, spread: recipe.spread ?? false)
    }
}

extension Choreography.Step {
    /// Whether this step reads or moves the defender at all -- what a spread
    /// move plays once per target.
    var touchesDefender: Bool {
        if who == .defender { return true }
        for pose in [from, to].compactMap({ $0 }) {
            for coord in [pose.x, pose.y, pose.z].compactMap({ $0 }) where coord.touchesDefender { return true }
        }
        return false
    }

    func cast(attacker: Choreography.Part, defender: Choreography.Part) -> Choreography.Step {
        var out = self
        if let who { out.who = who == .attacker ? attacker : defender }
        func recast(_ pose: Choreography.Pose?) -> Choreography.Pose? {
            guard var pose else { return nil }
            pose.x = pose.x?.cast(attacker: attacker, defender: defender)
            pose.y = pose.y?.cast(attacker: attacker, defender: defender)
            pose.z = pose.z?.cast(attacker: attacker, defender: defender)
            return pose
        }
        out.from = recast(from)
        out.to = recast(to)
        return out
    }
}
