//  MoveDataOwnershipTests.swift
//  A damaging move's rules belong to the move, and the engine may not restate
//  them.
//
//      swift test --filter MoveDataOwnershipTests
//
//  MoveRules already reads a move's effects from the dataset, falls back to
//  parsing the printed text, and drops the parsed copy when the dataset
//  supplies the same kind — so Icy Wind takes one stage of Speed rather than
//  two. That design is right and it is not what goes wrong.
//
//  What goes wrong is the turn model naming a move and doing the same thing
//  again by hand. Fake Out did exactly that: a 100% flinch in the data *and* a
//  special case in the damage path. The duplicate said "flinched" twice, and —
//  the part that mattered — the hand-written copy ran before the check that
//  lets a Covert Cloak refuse a secondary, so the item worn specifically to
//  stand in front of a Fake Out did not.
//
//  The line this draws comes from what the code already does rather than from
//  taste. Of the moves the turn model names, all but one are *status* moves,
//  and that is correct: Leech Seed, Trick Room, Haze and Parting Shot are each
//  a unique rule that no secondary-effect schema is going to carry. Damaging
//  moves are a different matter — power, accuracy, crit rate, secondaries,
//  drops, drain and recoil are all in the data for all nine hundred of them —
//  so a damaging move being named in the turn model is a smell, and every one
//  has to say why.

import XCTest
@testable import ChampionsLab

final class MoveDataOwnershipTests: HarnessCase {
    /// Damaging moves the turn model is allowed to know by name, and why the
    /// dataset cannot carry the rule instead.
    static let damagingExceptions: [String: String] = [
        "Rapid Spin": "clears hazards from its own side — no secondary kind expresses that, "
                    + "and its Speed boost does come from the data",
    ]

    @MainActor func testDamagingMovesAreDataNotCode() throws {
        // Every file of the battle model, not one. The turn model used to be a
        // single file and this read it; the resolver and the status moves have
        // homes of their own now, and a rule restated by hand in any of them
        // is the same fault.
        let battle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChampionsLab/Battle")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: battle.path))?
            .filter { $0.hasSuffix(".swift") }.sorted() ?? []
        check("the battle model is where it is expected to be", files.count > 5,
              "\(files.count) files at \(battle.path)")
        let source = files.compactMap {
            try? String(contentsOf: battle.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        print("  read \(files.count) files: \(files.joined(separator: ", "))")
        let byName = Dictionary(store.data.moves.values.map { ($0.name, $0) },
                                uniquingKeysWith: { a, _ in a })
        var named: Set<String> = []
        for pattern in ["case \"([A-Z][A-Za-z' -]+)\"", "move\\.name == \"([^\"]+)\""] {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: source,
                                       range: NSRange(source.startIndex..., in: source)) {
                guard let at = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[at])
                if byName[name] != nil { named.insert(name) }
            }
        }

print("\n== the surface ==")
        let status = named.filter { byName[$0]?.isDamaging == false }
        let damaging = named.filter { byName[$0]?.isDamaging == true }
        print("  \(named.count) moves named directly: \(status.count) status, "
              + "\(damaging.count) damaging")
        check("status moves are where the hand-written rules live",
              status.count > damaging.count * 10,
              "\(status.count) against \(damaging.count)")

print("\n== and a damaging move has to justify being one ==")
        let undeclared = damaging.subtracting(Self.damagingExceptions.keys).sorted()
        for name in undeclared { print("    undeclared: \(name)") }
        check("every damaging move the engine names is declared, with a reason",
              undeclared.isEmpty, undeclared.joined(separator: ", "))
        let stale = Set(Self.damagingExceptions.keys).subtracting(damaging).sorted()
        check("nothing is declared that the engine no longer names",
              stale.isEmpty, stale.joined(separator: ", "))

print("\n== and nothing carries a rule twice ==")
        // Not by looking for the hand-written copy — proximity in a source file
        // says nothing, and the first version of this flagged Rapid Spin for a
        // generic line that runs for every move. Check the mechanism instead.
        //
        // MoveRules drops the parsed copy of an effect when the dataset
        // supplies the same kind, which is what stops Icy Wind taking two
        // stages of Speed. That is the guarantee everything else leans on, so
        // assert it across all nine hundred moves rather than trusting it.
        var doubled: [String] = []
        for move in store.data.moves.values {
            for effect in move.secondaries {
                switch effect.kind {
                case .drops where !move.targetDrops.isEmpty:
                    doubled.append("\(move.name): drops in data and parsed")
                case .selfBoosts where !move.selfBoosts.isEmpty:
                    doubled.append("\(move.name): selfBoosts in data and parsed")
                case .selfDrops where !move.selfDrops.isEmpty:
                    doubled.append("\(move.name): selfDrops in data and parsed")
                case .confuse where move.confuses:
                    doubled.append("\(move.name): confusion in data and parsed")
                default: break
                }
            }
        }
        for line in doubled.prefix(10) { print("    \(line)") }
        check("no move carries the same effect in the data and in the parsed text",
              doubled.isEmpty, "\(doubled.count) moves")

        // And the other half of it: a move whose text describes an effect the
        // dataset does not carry still has to get it from somewhere, or the
        // effect silently does not happen. Close Combat's own Defence loss is
        // the example — not a secondary in the reference table at all.
        let parsedOnly = store.data.moves.values.filter {
            $0.secondaries.isEmpty && (!$0.selfDrops.isEmpty || !$0.targetDrops.isEmpty)
        }
        print("  \(parsedOnly.count) moves rely on the parsed text alone")
        check("the parser is still doing real work, so it cannot be dropped",
              !parsedOnly.isEmpty, "\(parsedOnly.count)")

print("\n== and the data is carrying its weight ==")
        let all = Array(store.data.moves.values)
        let structured = all.filter { !$0.secondaries.isEmpty }
        print("  \(all.count) moves, \(structured.count) with structured effects")
        check("the dataset supplies the effects rather than the engine",
              structured.count > 150, "\(structured.count)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
