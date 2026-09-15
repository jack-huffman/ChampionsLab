//  ImportTests.swift
//  Reading and writing a Showdown list, and the EV-to-SP arithmetic it rests on.
//
//      swift test --filter ImportTests

import XCTest
@testable import ChampionsLab

final class ImportTests: HarnessCase {
    /// the conversion, the import, and the round-trip back out
    @MainActor func testConversionAndImport() throws {
print("== EV <-> SP conversion ==")
    // 0 EVs is 0 SP, 4 EVs buys the first point, every point after costs 8,
    // and 252 lands exactly on the 32 SP cap.
    check("0 EVs -> 0 SP", TeamPaste.statPoints(fromEVs: 0) == 0)
    check("4 EVs -> 1 SP", TeamPaste.statPoints(fromEVs: 4) == 1)
    check("12 EVs -> 2 SP", TeamPaste.statPoints(fromEVs: 12) == 2)
    check("252 EVs -> the 32 SP cap",
          TeamPaste.statPoints(fromEVs: 252) == ChampionsStats.spPerStat)
    check("SP 32 -> 252 EVs", TeamPaste.evs(fromStatPoints: 32) == 252)
    let classic = [252, 252, 4, 0, 0, 0].map(TeamPaste.statPoints(fromEVs:))
    check("a 252/252/4 spread fits the 66 SP budget",
          classic.reduce(0, +) <= ChampionsStats.spTotal, "\(classic.reduce(0, +))")

print("\n== import ==")
    let result = TeamPaste.parse(paste, store: store, name: "Paste test")
    print("  parsed \(result.team.slots.count) Pokemon")
    for w in result.warnings { print("  warn: \(w)") }
    // Amoonguss is deliberately not in the Champions roster — Serebii 404s on it
    // — so the parser should skip it with a warning rather than inventing a slot.
    check("imported 4 legal slots", result.team.slots.count == 4, "\(result.team.slots.count)")
    check("warned about the illegal entry",
          result.warnings.contains { $0.contains("Amoonguss") })

    let labels = result.team.slots.compactMap { $0.form(in: store.rulebook)?.formLabel }
    print("  ->", labels.joined(separator: ", "))
    check("Charizard-Mega-Y resolved", labels.contains("Mega Charizard Y"))
    check("Indeedee-F resolved", labels.contains("Indeedee (Female)"))

    if let zard = result.team.slots.first(where: { $0.form(in: store.rulebook)?.formLabel == "Mega Charizard Y" }) {
        check("Timid parsed", zard.alignmentName == "Timid", zard.alignmentName)
        check("252 SpA -> 32 SP", zard.sp[Stat.spAttack.rawValue] == 32, "\(zard.sp)")
        check("4 moves", zard.moves.count == 4, "\(zard.moves.count)")
        check("SP within budget", zard.spUsed <= ChampionsStats.spTotal, "\(zard.spUsed)")
    }
    // Every imported move must be one the form can actually learn.
    check("no unlearnable moves imported", result.team.slots.allSatisfy { slot in
        guard let form = slot.form(in: store.rulebook) else { return false }
        return slot.moves.allSatisfy { form.moves.contains($0) }
    })
    // Charizard holding its stone must be analysed as Mega Charizard Y.
    if let zard = result.team.slots.first(where: { $0.form(in: store.rulebook)?.name == "Charizard" }) {
        check("stone resolves to the Mega",
              zard.battleForm(in: store.rulebook)?.formLabel == "Mega Charizard Y",
              zard.battleForm(in: store.rulebook)?.formLabel ?? "nil")
    }

print("\n== export round-trip ==")
    let text = TeamPaste.export(result.team, store: store)
    let back = TeamPaste.parse(text, store: store)
    check("round-trips to same count", back.team.slots.count == result.team.slots.count,
          "\(back.team.slots.count) vs \(result.team.slots.count)")
    let a = result.team.slots.map { $0.sp }, b = back.team.slots.map { $0.sp }
    check("SP survive the round trip", a == b, "\(a.first ?? []) vs \(b.first ?? [])")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
