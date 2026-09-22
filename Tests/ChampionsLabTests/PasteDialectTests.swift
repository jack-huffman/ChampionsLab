//  PasteDialectTests.swift
//  A spread can be written two ways and they do not look different.
//
//      swift test --filter PasteDialectTests

import XCTest
@testable import ChampionsLab

@MainActor
final class PasteDialectTests: HarnessCase {
    private let championsPaste = """
    Incineroar @ Sitrus Berry
    Ability: Intimidate
    Level: 50
    EVs: 32 HP / 16 Atk / 16 SpD
    Careful Nature
    - Fake Out
    - Knock Off
    - Parting Shot
    - Protect
    """

    private let mainSeriesPaste = """
    Incineroar @ Sitrus Berry
    Ability: Intimidate
    Level: 50
    EVs: 252 HP / 4 Atk / 252 SpD
    IVs: 0 Spe
    Careful Nature
    - Fake Out
    - Knock Off
    - Parting Shot
    - Protect
    """

    func testItTellsTheTwoDialectsApart() {
        check("a Showdown Champions paste is read as points",
              TeamPaste.dialect(of: championsPaste) == .champions)
        check("a main-series paste is read as EVs",
              TeamPaste.dialect(of: mainSeriesPaste) == .mainSeries)
        // Nothing to go on is nothing to get wrong.
        check("a paste with no spread at all does not matter either way",
              TeamPaste.dialect(of: "Incineroar\nAbility: Intimidate") == .champions)
        // The two lines that decide it.
        check("one stat over the cap is enough to say EVs",
              TeamPaste.dialect(of: "EVs: 36 HP") == .mainSeries)
        check("and so is a total over the budget",
              TeamPaste.dialect(of: "EVs: 30 HP / 30 Atk / 30 Spe") == .mainSeries)
        check("a maxed Champions spread is still points",
              TeamPaste.dialect(of: "EVs: 32 HP / 32 Atk / 2 Spe") == .champions)
    }

    func testAShowdownChampionsPasteComesInAtFullValue() {
        let out = TeamPaste.parse(championsPaste, store: store)
        guard let slot = out.team.slots.first else { return check("it imported", false) }
        check("32 HP means 32 points, not four",
              slot.sp[Stat.hp.rawValue] == 32, "\(slot.sp[Stat.hp.rawValue])")
        check("and 16 means 16", slot.sp[Stat.attack.rawValue] == 16, "\(slot.sp[Stat.attack.rawValue])")
        check("which is a legal spread",
              slot.spUsed <= ChampionsStats.spTotal, "\(slot.spUsed) of \(ChampionsStats.spTotal)")
    }

    func testAMainSeriesPasteStillConvertsTheOldWay() {
        let out = TeamPaste.parse(mainSeriesPaste, store: store)
        guard let slot = out.team.slots.first else { return check("it imported", false) }
        check("252 is still the 32 cap", slot.sp[Stat.hp.rawValue] == ChampionsStats.spPerStat,
              "\(slot.sp[Stat.hp.rawValue])")
        check("and 4 is still one point", slot.sp[Stat.attack.rawValue] == 1,
              "\(slot.sp[Stat.attack.rawValue])")
        // IVs are dropped, which is right: Champions has none, and the mod's
        // own formula has no term for them -- every Pokemon is effectively 31
        // across the board.
        check("the IV line changed nothing", slot.sp[Stat.speed.rawValue] == 0)
    }

    /// What the app writes, read back by the app, is what it started with --
    /// and what it writes is the dialect Showdown's Champions formats read.
    func testWhatWeWriteIsWhatShowdownReads() throws {
        guard let team = store.ladderTeams(format: "doubles").first?.team else {
            return check("there is a team to write", false)
        }
        let text = TeamPaste.export(team, store: store)
        check("it writes the Champions dialect", TeamPaste.dialect(of: text) == .champions,
              text.split(separator: "\n").first { $0.hasPrefix("EVs:") }.map(String.init) ?? "no spread")
        let back = TeamPaste.parse(text, store: store)
        check("and reads back the same points",
              back.team.slots.map(\.sp) == team.slots.map(\.sp),
              "\(back.team.slots.first?.sp ?? []) against \(team.slots.first?.sp ?? [])")
        // And the engine agrees it is a team, with the stats we meant.
        if ShowdownEngine.bundleURL() != nil {
            let ps = ShowdownEngine.shared
            let packed = try ps.pack(paste: ShowdownTeam.paste(for: team, store: store))
            try ps.start(mine: ("A", packed), theirs: ("B", packed), seed: [1, 2, 3, 4])
            let request = try ps.request("p1") ?? ""
            if let form = team.slots.first?.form(in: store.rulebook),
               let sp = team.slots.first?.sp, let alignment = team.slots.first?.alignment {
                let hp = ChampionsStats.spread(form: form, sp: sp, alignment: alignment)[Stat.hp.rawValue]
                check("and the engine builds it to \(hp) HP",
                      request.contains("\"condition\":\"\(hp)/\(hp)\""), String(request.prefix(150)))
            }
        }
    }
}
