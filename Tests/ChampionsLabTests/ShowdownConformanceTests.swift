//  ShowdownConformanceTests.swift
//  Our numbers against Showdown's, per Pokemon, on real teams.
//
//      swift test --filter ShowdownConformanceTests
//
//  This is the point of embedding the real engine rather than reading it: the
//  app's own arithmetic can be checked against the thing it was copied from,
//  on every team the app can build, rather than on the handful of cases
//  somebody thought to write down.

import XCTest
@testable import ChampionsLab

@MainActor
final class ShowdownConformanceTests: HarnessCase {
    private func engine() throws -> ShowdownEngine {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        return ShowdownEngine.shared
    }

    /// What the sim says a side is made of, read back off its first request.
    private struct Seen {
        let name: String, hp: Int
        var stats: [String: Int]
    }

    private func readBack(_ request: String) -> [Seen] {
        // The request is JSON; the shape wanted here is small and fixed, so it
        // is picked out rather than modelled.
        var out: [Seen] = []
        let pattern = #""ident":"p1: ([^"]+)","details":"[^"]*","condition":"(\d+)\\?/?\d*","active":[a-z]+,"stats":\{([^}]*)\}"#
        let re = try! NSRegularExpression(pattern: pattern)
        let text = request as NSString
        for m in re.matches(in: request, range: NSRange(location: 0, length: text.length)) {
            var stats: [String: Int] = [:]
            for pair in text.substring(with: m.range(at: 3)).split(separator: ",") {
                let bits = pair.split(separator: ":")
                guard bits.count == 2 else { continue }
                stats[bits[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))] = Int(bits[1]) ?? -1
            }
            out.append(Seen(name: text.substring(with: m.range(at: 1)),
                            hp: Int(text.substring(with: m.range(at: 2))) ?? -1,
                            stats: stats))
        }
        return out
    }

    private static let key: [Stat: String] = [
        .attack: "atk", .defense: "def", .spAttack: "spa", .spDefense: "spd", .speed: "spe",
    ]

    func testOurStatsAreShowdownsStatsOnEveryLadderTeam() throws {
        let ps = try engine()
        var checked = 0
        for ladder in store.ladderTeams(format: "doubles").prefix(4) {
            let team = ladder.team
            let paste = ShowdownTeam.paste(for: team, store: store)
            let packed = try ps.pack(paste: paste)
            check("\(team.name) packed", !packed.isEmpty)
            try ps.start(mine: ("Us", packed), theirs: ("Them", packed), seed: [1, 2, 3, 4])
            guard let request = try ps.request("p1") else {
                check("\(team.name): the sim asked us something", false); continue
            }
            let seen = readBack(request)
            check("\(team.name): the sim has all \(team.slots.count)",
                  seen.count == team.slots.count, "\(seen.count)")
            for (index, slot) in team.slots.enumerated() where index < seen.count {
                guard let form = slot.form(in: store.rulebook) else { continue }
                let ours = ChampionsStats.spread(form: form, sp: slot.sp, alignment: slot.alignment)
                let theirs = seen[index]
                check("  \(form.formLabel) HP: ours \(ours[Stat.hp.rawValue]), theirs \(theirs.hp)",
                      ours[Stat.hp.rawValue] == theirs.hp)
                for (stat, name) in Self.key {
                    let mine = ours[stat.rawValue], sim = theirs.stats[name] ?? -1
                    check("  \(form.formLabel) \(name): ours \(mine), theirs \(sim)", mine == sim)
                }
                checked += 1
            }
        }
        check("it checked a real number of Pokemon", checked >= 12, "\(checked)")
    }

    /// The other half of the bridge: what the sim is handed is what the team
    /// said, down to the ability, the item and the four moves.
    func testTheSimGetsTheSetWeMeant() throws {
        let ps = try engine()
        guard let team = store.ladderTeams(format: "doubles").first?.team else {
            return check("there is a ladder team", false)
        }
        let packed = try ps.pack(paste: ShowdownTeam.paste(for: team, store: store))
        try ps.start(mine: ("Us", packed), theirs: ("Them", packed), seed: [1, 2, 3, 4])
        let request = try ps.request("p1") ?? ""
        for slot in team.slots {
            guard let form = slot.form(in: store.rulebook) else { continue }
            if !slot.ability.isEmpty {
                let id = slot.ability.lowercased().filter { $0.isLetter || $0.isNumber }
                check("\(form.formLabel) kept its \(slot.ability)",
                      request.contains("\"ability\":\"\(id)\"") || request.contains("\"baseAbility\":\"\(id)\""))
            }
            if !slot.item.isEmpty {
                let id = slot.item.lowercased().filter { $0.isLetter || $0.isNumber }
                check("  and its \(slot.item)", request.contains("\"item\":\"\(id)\""))
            }
            for move in slot.moves.prefix(4) {
                guard let named = store.move(move) else { continue }
                let id = named.name.lowercased().filter { $0.isLetter || $0.isNumber }
                check("  and \(named.name)", request.contains("\"\(id)\""), named.name)
            }
        }
    }
}
