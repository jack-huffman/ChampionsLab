//  HarnessCase.swift
//  What every turn-model case needs: the dataset, the assertion, and the teams
//  the cases build their boards out of.
//
//  A case that wants its own version of one of these teams simply declares it;
//  a local declaration shadows the inherited one, and the two are built the
//  same way.

import XCTest
@testable import ChampionsLab

/// The Showdown list the importer is checked against. Deliberately a real one,
/// with an item this format does not have (Assault Vest) and a Mega spelled
/// the way Showdown spells it.
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

class HarnessCase: XCTestCase {
    /// How many checks in this case failed. Printed at the end of the case, so
    /// a run reads like the old harness did.
    var fails = 0

    @MainActor var store: Store { Store.shared }

    /// Assert, and say so either way: the printed line is what makes a failing
    /// run readable — "PASS  Icy Wind takes a stage of Speed off both".
    func check(_ label: String, _ ok: Bool, _ detail: String = "",
               file: StaticString = #filePath, line: UInt = #line) {
        if !ok { fails += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        XCTAssertTrue(ok, "\(label)\(detail.isEmpty ? "" : ": \(detail)")", file: file, line: line)
    }

    // MARK: - Building something to fight with

    @MainActor func form(_ name: String) -> Form { store.data.forms.first { $0.formLabel == name }! }

    @MainActor func fighters(_ rows: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = rows.map { name, item, moveNames in
            var slot = TeamSlot(formID: form(name).id)
            slot.item = item
            slot.ability = form(name).abilities.first?.name ?? ""
            slot.moves = moveNames.compactMap { n in
                store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32
            sp[Stat.hp.rawValue] = 2
            slot.sp = sp; slot.alignmentName = "Adamant"
            return slot
        }
        return out
    }

    func at(_ fighter: Fighter, _ name: String) -> Int {
        fighter.moves.firstIndex { $0.name == name } ?? 0
    }

    // MARK: - The imported list, and what it is lined up against

    /// The Showdown paste, parsed. Several cases start from it: it is the one
    /// team in the suite that came in the way a real one does.
    @MainActor var imported: TeamPaste.Result { TeamPaste.parse(paste, store: store, name: "Paste test") }

    /// The bundled Big Six archetype, as a team.
    @MainActor var bigSixTeam: Team {
        let meta = store.data.metaTeams.first { $0.name == "Big Six" }!
        return TeamPaste.team(from: meta, store: store)
    }

    // MARK: - Teams the cases share

    @MainActor var supporters: Team {
        fighters([
        ("Incineroar", "Sitrus Berry", ["Will-O-Wisp", "Fake Out", "Flare Blitz", "Protect"]),
        ("Indeedee (Female)", "Leftovers", ["Follow Me", "Protect", "Dazzling Gleam"]),
        ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    }
    @MainActor var aggressors: Team {
        fighters([
        ("Garchomp", "Focus Sash", ["Earthquake", "Swords Dance", "Rock Slide", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
        ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    }
    @MainActor var quick: Team {
        fighters([("Garchomp", "Choice Scarf", ["Earthquake", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
        ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    }
    @MainActor var soaked: Team {
        fighters([("Garchomp", "Life Orb", ["Swords Dance", "Protect"]),
        ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])])
    }
    /// The same pair under another name: two cases built it separately and
    /// both names are in use.
    @MainActor var chilled: Team { soaked }
    @MainActor var muddy: Team {
        fighters([("Politoed", "Leftovers", ["Muddy Water", "Protect"]),
        ("Whimsicott", "Focus Sash", ["Protect"])])
    }
    @MainActor var standing: Team {
        fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    }
    @MainActor var sunPair: Team {
        fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
        ("Whimsicott", "Focus Sash", ["Protect"])])
    }
    @MainActor var dragonPair: Team {
        fighters([("Baxcalibur", "Loaded Dice", ["Glaive Rush", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    }
    @MainActor var mySix: Team {
        fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
        ("Indeedee (Female)", "Leftovers", ["Follow Me", "Dazzling Gleam", "Protect"]),
        ("Garchomp", "Life Orb", ["Earthquake", "Rock Slide", "Protect"]),
        ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"]),
        ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
        ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"])])
    }
}
