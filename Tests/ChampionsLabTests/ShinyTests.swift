//  ShinyTests.swift
//  Registering one shiny, and having a picture to show for it.
//
//      swift test --filter ShinyTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ShinyTests: HarnessCase {

    // MARK: - The art

    func testEveryFormHasOrdinaryArtAndAShiny() {
        var noArt: [String] = [], noShiny: [String] = []
        for entry in store.data.forms {
            if store.sprite(entry) == nil { noArt.append(entry.formLabel) }
            if store.sprite(entry, shiny: true) == nil { noShiny.append(entry.formLabel) }
        }
        check("every form has its art", noArt.isEmpty, noArt.prefix(6).joined(separator: ", "))
        check("and every form has a shiny", noShiny.isEmpty,
              noShiny.prefix(6).joined(separator: ", "))
    }

    /// The pipeline could satisfy the test above by copying the ordinary
    /// render into the shiny slot, and nobody would notice until they looked
    /// at a Charizard. So look at a Charizard.
    func testTheShinyIsADifferentPicture() {
        var same: [String] = [], checked = 0
        for entry in store.data.forms {
            guard let plain = store.sprite(entry)?.tiffRepresentation,
                  let shiny = store.sprite(entry, shiny: true)?.tiffRepresentation
            else { continue }
            checked += 1
            if plain == shiny { same.append(entry.formLabel) }
        }
        check("the shinies were compared against the ordinary art", checked > 300, "\(checked)")
        check("and none of them is the same picture", same.isEmpty,
              "\(same.count): \(same.prefix(6).joined(separator: ", "))")
    }

    /// A slug with a hyphen in it means a species and a forme. Kommo-o has a
    /// hyphen and no forme, and asking Showdown for "kommo-o" got nothing —
    /// so that one form had no pixel sprite in either colour.
    func testASpeciesWithAHyphenInItsNameIsNotSplit() {
        guard store.data.forms.contains(where: { $0.formLabel == "Kommo-o" }) else {
            return check("Kommo-o is in the dex", false)
        }
        check("Kommo-o asks for kommoo", PixelSprites.slug(form("Kommo-o")) == "kommoo",
              PixelSprites.slug(form("Kommo-o")) ?? "nil")
    }

    // MARK: - Registering it

    func testASlotRemembersItAndTheBuildCarriesIt() {
        var slot = TeamSlot(formID: form("Charizard").id)
        check("a new one is not shiny", !slot.shiny)
        check("and neither is its build", slot.combatant(in: store.rulebook)?.shiny == false)
        slot.shiny = true
        check("marked, the build carries it",
              slot.combatant(in: store.rulebook)?.shiny == true)
        // And through a Mega, which is a different form entirely.
        slot.item = "Charizardite Y"
        let mega = slot.combatant(in: store.rulebook)
        check("what it Mega Evolves into is shiny too", mega?.shiny == true)
        check("and it really is the Mega", mega?.form.isMega == true,
              mega?.form.formLabel ?? "nothing")
    }

    /// The one thing that must not happen: a field added to TeamSlot making
    /// every saved team fail to load. The decoder is written by hand for this
    /// reason and the reason is worth a test.
    func testATeamSavedBeforeShinyExistedStillLoads() throws {
        let old = """
        {"id":"\(UUID().uuidString)","name":"Old","format":"doubles","slots":[
          {"id":"\(UUID().uuidString)","formID":"\(form("Garchomp").id)",
           "ability":"Rough Skin","item":"Life Orb","moves":[],
           "sp":[0,32,0,0,0,32],"alignmentName":"Adamant","nickname":""}]}
        """
        let team = try JSONDecoder().decode(Team.self, from: Data(old.utf8))
        check("a team written before shiny existed still loads", team.slots.count == 1)
        check("and its one slot is not shiny", team.slots.first?.shiny == false)
    }

    // MARK: - Through a Mega Evolution

    /// The bug this was written for: a shiny Salamence walked into a battle,
    /// Mega Evolved, and came out of it the ordinary colours. Mega Evolution
    /// built a fresh Combatant and copied two fields onto it.
    func testMegaEvolvingKeepsEverythingItDoesNotChange() {
        var team = fighters([("Salamence", "Salamencite", ["Dragon Claw", "Protect"]),
                             ("Rillaboom", "", ["Wood Hammer", "Protect"])])
        team.slots[0].shiny = true
        var board = Board(mine: team,
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        check("it walks in shiny", board.mine[0].build.shiny)
        check("and has a Mega waiting", board.mine[0].pendingMega != nil,
              board.mine[0].pendingMega?.formLabel ?? "none")
        // Something the battle did to it that the change of form does not undo.
        board.mine[0].build.statOverride = [Stat.speed.rawValue: 123]
        board.mine[0].build.boosts[Stage.attack.rawValue] = 2

        Switching.megaEvolve(&board.mine, slot: 0, opposing: &board.theirs, field: &board.field)
        check("it Mega Evolved", board.mine[0].build.form.isMega,
              board.mine[0].build.form.formLabel)
        check("and is still shiny", board.mine[0].build.shiny)
        check("and still has its stages", board.mine[0].build.boosts[Stage.attack.rawValue] == 2)
        check("and still has what was done to its stats",
              board.mine[0].build.statOverride?[Stat.speed.rawValue] == 123)
        check("but wears the Mega's own typing, not the old form's",
              board.mine[0].build.typeOverride == nil)
    }

    /// Every screen that draws a six holds a form and a flag together now,
    /// rather than a form alone, because holding them apart is what let the
    /// team list and the versus banner go on drawing ordinary colours.
    func testAFormAndItsShinyTravelTogether() {
        var team = Team(name: "Sparkly")
        var slot = TeamSlot(formID: form("Salamence").id)
        slot.item = "Salamencite"
        slot.shiny = true
        team.slots = [slot]
        guard let registered = slot.form(in: store.rulebook),
              let mega = slot.battleForm(in: store.rulebook) else {
            return check("Salamence resolves both ways", false)
        }
        check("asked by what is registered", team.isShiny(registered, in: store.rulebook))
        check("and asked by what it becomes", team.isShiny(mega, in: store.rulebook))
        let other = form("Rillaboom")
        check("and something not on the team is not shiny",
              !team.isShiny(other, in: store.rulebook))
        check("the pair carries the flag", ShownForm(registered, shiny: slot.shiny).shiny)
        check("and defaults to off", !ShownForm(other).shiny)
    }

    // MARK: - Carried in and out

    func testAPasteSaysShinyAndIsBelieved() {
        let paste = """
        Garchomp @ Life Orb
        Ability: Rough Skin
        Shiny: Yes
        EVs: 252 Atk / 252 Spe
        Adamant Nature
        - Earthquake

        Incineroar @ Sitrus Berry
        Ability: Intimidate
        - Fake Out
        """
        let read = TeamPaste.parse(paste, store: store, name: "Shiny test")
        check("both came in", read.team.slots.count == 2, "\(read.team.slots.count)")
        check("the one that said so is shiny", read.team.slots.first?.shiny == true)
        check("and the one that did not is not", read.team.slots.last?.shiny == false)
        // And back out again, so a list written here says what it is.
        let written = TeamPaste.export(read.team, store: store)
        check("a paste written out says Shiny: Yes once",
              written.components(separatedBy: "Shiny: Yes").count == 2, written)
    }
}
