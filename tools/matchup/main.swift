//  tools/matchup/main.swift
//  Checks the paste importer, the EV<->SP conversion and the versus engine
//  against a real Showdown list and a bundled meta archetype.
//
//      ./tools/matchup.sh

import AppKit
import SwiftUI

let paste = """
Incineroar @ Assault Vest
Ability: Intimidate
Level: 50
EVs: 252 HP / 4 Atk / 252 SpD
Careful Nature
- Fake Out
- Parting Shot
- Darkest Lariat
- Flare Blitz

Charizard-Mega-Y @ Charizardite Y
Ability: Drought
EVs: 4 HP / 252 SpA / 252 Spe
Timid Nature
- Heat Wave
- Solar Beam
- Air Slash
- Protect

Garchomp @ Choice Scarf
Ability: Rough Skin
EVs: 252 Atk / 4 HP / 252 Spe
Jolly Nature
- Earthquake
- Rock Slide
- Dragon Claw
- Protect

Indeedee-F @ Psychic Seed
Ability: Psychic Surge
- Follow Me
- Trick Room
- Dazzling Gleam
- Helping Hand

Amoonguss @ Leftovers
Ability: Regenerator
- Spore
- Rage Powder
"""

@MainActor func run() {
    let store = Store.shared
    var fails = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if !ok { fails += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }

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

    let labels = result.team.slots.compactMap { $0.form(in: store)?.formLabel }
    print("  ->", labels.joined(separator: ", "))
    check("Charizard-Mega-Y resolved", labels.contains("Mega Charizard Y"))
    check("Indeedee-F resolved", labels.contains("Indeedee (Female)"))

    if let zard = result.team.slots.first(where: { $0.form(in: store)?.formLabel == "Mega Charizard Y" }) {
        check("Timid parsed", zard.alignmentName == "Timid", zard.alignmentName)
        check("252 SpA -> 32 SP", zard.sp[Stat.spAttack.rawValue] == 32, "\(zard.sp)")
        check("4 moves", zard.moves.count == 4, "\(zard.moves.count)")
        check("SP within budget", zard.spUsed <= ChampionsStats.spTotal, "\(zard.spUsed)")
    }
    // Every imported move must be one the form can actually learn.
    check("no unlearnable moves imported", result.team.slots.allSatisfy { slot in
        guard let form = slot.form(in: store) else { return false }
        return slot.moves.allSatisfy { form.moves.contains($0) }
    })
    // Charizard holding its stone must be analysed as Mega Charizard Y.
    if let zard = result.team.slots.first(where: { $0.form(in: store)?.name == "Charizard" }) {
        check("stone resolves to the Mega",
              zard.battleForm(in: store)?.formLabel == "Mega Charizard Y",
              zard.battleForm(in: store)?.formLabel ?? "nil")
    }

    print("\n== export round-trip ==")
    let text = TeamPaste.export(result.team, store: store)
    let back = TeamPaste.parse(text, store: store)
    check("round-trips to same count", back.team.slots.count == result.team.slots.count,
          "\(back.team.slots.count) vs \(result.team.slots.count)")
    let a = result.team.slots.map { $0.sp }, b = back.team.slots.map { $0.sp }
    check("SP survive the round trip", a == b, "\(a.first ?? []) vs \(b.first ?? [])")

    print("\n== matchup ==")
    guard let bigSix = store.data.metaTeams.first(where: { $0.id == "big-six" }) else {
        print("  FAIL no big-six"); exit(1)
    }
    let theirs = TeamPaste.team(from: bigSix, store: store)
    check("meta team built", theirs.slots.count == 6, "\(theirs.slots.count)")

    let m = Matchup(mine: result.team, theirs: theirs, store: store,
                    field: Field(isDoubles: true))
    let v = m.verdict
    print("  cells \(v.totalCells)  wins \(v.winCount)  losses \(v.lossCount)  edge \(v.score)  faster \(v.speedEdge)%")
    check("grid is mine x theirs", v.totalCells == result.team.slots.count * theirs.slots.count, "\(v.totalCells)")
    check("score in range", (-100...100).contains(v.score), "\(v.score)")
    for line in v.advice { print("  advice: \(line)") }
    print("  unanswered:", v.unanswered.map(\.formLabel))
    print("  dead weight:", v.deadWeight.map(\.formLabel))

    let mirror = Matchup(mine: theirs, theirs: theirs, store: store, field: Field(isDoubles: true))
    print("  mirror edge: \(mirror.verdict.score)")
    check("mirror is even", abs(mirror.verdict.score) <= 5, "\(mirror.verdict.score)")

    // -- same-type bonus in move ranking ---------------------------------
    //
    // Six places ranked moves and three of them ignored STAB, which reported a
    // Dragon/Ice Pokemon's best move as Normal-type Double-Edge. One function
    // does it now; these keep it honest.
    print("\n== move valuation ==")
    func form(_ name: String) -> Form { store.data.forms.first { $0.formLabel == name }! }
    let bax = form("Mega Baxcalibur")
    let baxBest = store.bestMove(for: bax)?.name ?? "-"
    print("  Mega Baxcalibur's best move: \(baxBest)")
    check("STAB decides Baxcalibur's best move", baxBest == "Glaive Rush", baxBest)

    let goli = form("Mega Golisopod")
    let goliBest = store.bestMove(for: goli)?.name ?? "-"
    print("  Mega Golisopod's best move: \(goliBest)")
    check("a physical attacker is not handed a special move",
          store.data.moves.values.first { $0.name == goliBest }?.category == "Physical", goliBest)

    // Aerilate makes a Normal move STAB Flying, which must survive the fix.
    let mence = form("Mega Salamence")
    let edge = store.data.moves.values.first { $0.name == "Double-Edge" }!
    let claw = store.data.moves.values.first { $0.name == "Dragon Claw" }!
    check("Aerilate keeps Double-Edge above a Dragon move",
          store.moveValue(edge, for: mence, ability: "Aerilate")
            > store.moveValue(claw, for: mence, ability: "Aerilate"), "no")

    // And a move it gets no bonus for must rank below one it does.
    let glaive = store.data.moves.values.first { $0.name == "Glaive Rush" }!
    check("STAB Glaive Rush beats neutral Double-Edge on Baxcalibur",
          store.moveValue(glaive, for: bax) > store.moveValue(edge, for: bax), "no")

    // -- what a Pokemon's stats say it is for -----------------------------
    print("\n== stat roles ==")
    let pult = form("Dragapult")
    let pultRole = store.statRole(of: pult)
    print("  Dragapult: \(pultRole.summary)")
    check("Dragapult is physical", pultRole.offence == .physical, pultRole.offence.rawValue)
    check("and special is recognised as a real second set",
          pultRole.alsoViable == .special, "\(String(describing: pultRole.alsoViable))")

    let goliRole = store.statRole(of: goli)
    print("  Mega Golisopod: \(goliRole.summary)")
    check("175 Def against 120 SpD is physically bulky",
          goliRole.defence == .physicalWall, goliRole.defence.rawValue)

    let milo = store.statRole(of: form("Milotic"))
    check("Milotic is specially bulky", milo.defence == .specialWall, milo.defence.rawValue)
    let gengar = store.statRole(of: form("Mega Gengar"))
    check("Mega Gengar is a special attacker", gengar.offence == .special, gengar.offence.rawValue)
    check("and frail", gengar.defence == .frail, gengar.defence.rawValue)
    let whim = store.statRole(of: form("Whimsicott"))
    check("Whimsicott is not an attacker", whim.offence == .none, whim.offence.rawValue)

    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }
