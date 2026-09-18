//  MegaStoneTests.swift
//  Every Mega can be brought, which means every Mega has a stone that names it.
//
//      swift test --filter MegaStoneTests

import XCTest
@testable import ChampionsLab

@MainActor
final class MegaStoneTests: HarnessCase {
    private var megas: [Form] { store.data.forms.filter(\.isMega) }

    func testEveryMegaHasAStoneInTheItemList() {
        check("there are Megas in the dex", !megas.isEmpty, "\(megas.count)")
        for mega in megas {
            let trigger = mega.megaTrigger
            check("\(mega.formLabel) names a stone", !trigger.isEmpty)
            check("  and \(trigger) is an item you can hold",
                  store.item(named: trigger) != nil, trigger)
        }
    }

    /// The failure this was written for: Raichu has two Megas and Serebii
    /// publishes only Raichunite Y, so the generic placeholder could not say
    /// which of the two a Raichu holding "a Mega Stone" was going to become,
    /// and Mega Raichu X could be read about but never built.
    func testAStoneNamesExactlyOneMega() {
        for mega in megas {
            guard let base = store.rulebook.registeredForm(of: mega) else {
                check("\(mega.formLabel) has a base to register", false); continue
            }
            let became = store.rulebook.megaForm(for: base, holding: mega.megaTrigger)
            check("\(base.formLabel) holding \(mega.megaTrigger) becomes \(mega.formLabel)",
                  became?.id == mega.id, became?.formLabel ?? "nothing")
        }
    }

    func testTheTwoSpeciesWithAnUnpublishedSiblingBothWork() {
        for label in ["Mega Raichu X", "Mega Raichu Y", "Mega Absol", "Mega Absol Z"] {
            guard let mega = store.data.forms.first(where: { $0.formLabel == label }) else {
                check("\(label) is in the dex", false); continue
            }
            guard let base = store.rulebook.registeredForm(of: mega) else {
                check("\(label) has a base", false); continue
            }
            let became = store.rulebook.megaForm(for: base, holding: mega.megaTrigger)
            check("\(label) is reachable from \(base.formLabel) and \(mega.megaTrigger)",
                  became?.id == mega.id, became?.formLabel ?? "nothing")
        }
    }

    /// Two Megas of one species must not share a stone, or the pair is a coin
    /// toss again by another name.
    func testNoTwoMegasShareAStone() {
        var byStone: [String: [String]] = [:]
        for mega in megas { byStone[mega.megaTrigger, default: []].append(mega.formLabel) }
        for (stone, holders) in byStone.sorted(by: { $0.key < $1.key }) where holders.count > 1 {
            check("\(stone) names one Mega, not \(holders.count)", false,
                  holders.joined(separator: ", "))
        }
        check("every stone names exactly one Mega",
              byStone.values.allSatisfy { $0.count == 1 }, "\(byStone.count) stones")
    }
}
