//  RegisteredFormTests.swift
//  A team registers the Pokemon that holds the stone, never the Mega.

import XCTest
@testable import ChampionsLab

@MainActor
final class RegisteredFormTests: HarnessCase {
    func testAMegaIsRegisteredAsItsBase() {
        let megas = store.data.forms.filter(\.isMega)
        check("there are Megas in the dex", !megas.isEmpty)
        for mega in megas {
            guard let base = store.rulebook.registeredForm(of: mega) else {
                check("\(mega.formLabel) has something to register", false); continue
            }
            check("\(mega.formLabel) registers as \(base.formLabel)",
                  !base.isMega && base.dex == mega.dex)
            // And the pair reads back: that base holding that stone is that Mega.
            let back = store.rulebook.megaForm(for: base, holding: mega.megaTrigger)
            check("  and \(base.formLabel) holding \(mega.megaTrigger) is it again",
                  back?.id == mega.id, back?.formLabel ?? "nothing")
        }
    }

    func testABaseIsNotAMegaAndRegistersAsItself() {
        guard let charizard = store.data.forms.first(where: { $0.formLabel == "Charizard" }) else {
            return check("Charizard is in the dex", false)
        }
        check("a base form has nothing to register", store.rulebook.registeredForm(of: charizard) == nil)
    }

    func testTheLadderRegistersTheBaseAndTheStone() {
        for format in ["doubles", "singles"] {
            for ladder in store.ladderTeams(format: format) {
                for slot in ladder.team.slots {
                    let form = slot.form(in: store.rulebook)
                    check("\(ladder.team.name): \(form?.formLabel ?? slot.formID) is not a Mega",
                          form?.isMega == false, form?.formLabel ?? slot.formID)
                    // What it becomes is still the Mega, through the stone.
                    if let form, let stoned = store.rulebook.megaForm(for: form, holding: slot.item) {
                        check("  and holding \(slot.item) it becomes \(stoned.formLabel)", stoned.isMega)
                    }
                }
            }
        }
    }
}
