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
