//  OpeningTests.swift
//  The exchange that happens before anybody attacks.
//
//      swift test --filter OpeningTests

import XCTest
@testable import ChampionsLab

final class OpeningTests: HarnessCase {
    /// A team with the abilities named.
    ///
    /// The shared `fighters` helper takes whichever ability is listed first,
    /// which for an Incineroar is Blaze rather than Intimidate — and an
    /// opening is almost entirely a conversation between abilities, so here
    /// they have to be said out loud.
    @MainActor private func squad(_ rows: [(String, String, [String], String)]) -> Team {
        var out = fighters(rows.map { ($0.0, $0.1, $0.2) })
        for (index, row) in rows.enumerated() where out.slots.indices.contains(index) {
            out.slots[index].ability = row.3
        }
        return out
    }

    /// One side of a field, built by hand so the test says what it means.
    @MainActor private func side(_ rows: [(String, String, [String], String)]) -> Opening.Side {
        let team = squad(rows)
        let pairs = team.slots.compactMap { slot -> (TeamSlot, Form)? in
            guard let form = slot.battleForm(in: store.rulebook) else { return nil }
            return (slot, form)
        }
        return Opening.side(pairs.map(\.1), pairs: pairs, rules: store.rulebook)
    }

    /// Armor Tail answers a Fake Out lead, and the reading knows it
    @MainActor func testTurningPriorityOffAnswersAFakeOutLead() throws {
        print("\n== the Fake Out and the answer to it ==")
        let fakeOutLead = side([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz"], "Intimidate"),
                                ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"], "Grassy Surge")])

        // An ordinary pair, which simply eats it.
        let ordinary = side([("Garchomp", "Life Orb", ["Earthquake", "Protect"], "Rough Skin"),
                             ("Milotic", "Leftovers", ["Surf", "Protect"], "Marvel Scale")])
        let eaten = Opening.read(mine: ordinary, theirs: fakeOutLead)
        for line in eaten.losses { print("    – \(line)") }
        check("an ordinary lead takes the Fake Out", eaten.value < 0,
              String(format: "%.2f", eaten.value))

        // Farigiraf's Armor Tail turns the whole priority bracket off, which is
        // exactly why people lead it into Fake Out teams.
        let armoured = side([("Farigiraf", "Mental Herb", ["Trick Room", "Psychic"], "Armor Tail"),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"], "Rough Skin")])
        let refused = Opening.read(mine: armoured, theirs: fakeOutLead)
        for line in refused.gains { print("    + \(line)") }
        print(String(format: "  ordinary %.2f, Armor Tail %.2f", eaten.value, refused.value))
        check("Armor Tail turns their Fake Out off", refused.value > eaten.value,
              String(format: "%.2f against %.2f", refused.value, eaten.value))
        check("and the reading says so in words",
              refused.gains.contains { $0.contains("priority off") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// An Intimidate is worth what the other side is physical, and a mistake
    /// into the abilities that answer it
    @MainActor func testIntimidateIsWorthWhatItMeetsl() throws {
        print("\n== Intimidate, and what answers it ==")
        let intimidating = side([("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"], "Intimidate"),
                                 ("Garchomp", "Life Orb", ["Earthquake", "Protect"], "Rough Skin")])

        let physical = side([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"], "Grassy Surge"),
                             ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"], "Supreme Overlord")])
        let special = side([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"], "Blaze"),
                            ("Gholdengo", "Leftovers", ["Make It Rain", "Protect"], "Good as Gold")])
        let intoPhysical = Opening.read(mine: intimidating, theirs: physical)
        let intoSpecial = Opening.read(mine: intimidating, theirs: special)
        print(String(format: "  into physical %.2f, into special %.2f",
                     intoPhysical.value, intoSpecial.value))
        check("Intimidate is worth more into physical attackers",
              intoPhysical.value > intoSpecial.value,
              String(format: "%.2f against %.2f", intoPhysical.value, intoSpecial.value))

        // Milotic's Competitive turns a free Intimidate into a gift.
        let punishing = side([("Milotic", "Leftovers", ["Surf", "Protect"], "Competitive"),
                              ("Garchomp", "Life Orb", ["Earthquake", "Protect"], "Rough Skin")])
        let regretted = Opening.read(mine: intimidating, theirs: punishing)
        for line in regretted.losses { print("    – \(line)") }
        check("and a mistake into Competitive",
              regretted.value < intoPhysical.value,
              String(format: "%.2f against %.2f", regretted.value, intoPhysical.value))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// The picker leads differently once it can see the opening
    @MainActor func testThePickerLeadsIntoTheFakeOut() throws {
        print("\n== what the picker leads ==")
        let mine = fighters([("Farigiraf", "Mental Herb", ["Trick Room", "Psychic", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Rock Slide", "Protect"]),
                             ("Milotic", "Leftovers", ["Surf", "Ice Beam", "Protect"]),
                             ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"])])
        var theirs = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                               ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
                               ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                               ("Gholdengo", "Leftovers", ["Make It Rain", "Protect"]),
                               ("Farigiraf", "Leftovers", ["Psychic", "Protect"]),
                               ("Basculegion", "Choice Scarf", ["Wave Crash", "Aqua Jet"])])
        theirs.slots[0].ability = "Intimidate"
        var mine2 = mine
        mine2.slots[0].ability = "Armor Tail"
        let grid = Matchup(mine: mine2, theirs: theirs, rules: store.rulebook,
                           field: Field(isDoubles: true))
        let plans = BringFour(matchup: grid, rules: store.rulebook, bring: 4).plans
        check("it has plans to rank", !plans.isEmpty, "\(plans.count)")
        guard let top = plans.first else { return }
        print("  it leads \(top.leads.map(\.formLabel).joined(separator: " and "))")
        for line in top.opening.gains { print("    + \(line)") }
        for line in top.opening.losses { print("    – \(line)") }
        check("and the opening reading is attached to the plan",
              !(top.opening.gains.isEmpty && top.opening.losses.isEmpty))

        // Against a side with two Fake Out users, a lead that turns priority
        // off should be reading as better than one that does not.
        let armoured = plans.filter { $0.leads.contains { $0.formLabel == "Farigiraf" } }
        let bare = plans.filter { plan in !plan.leads.contains { $0.formLabel == "Farigiraf" } }
        if let withIt = armoured.map(\.opening.value).max(),
           let without = bare.map(\.opening.value).max() {
            print(String(format: "  best opening leading Farigiraf %.2f, without it %.2f",
                         withIt, without))
            check("leading the Armor Tail reads better into two Fake Outs",
                  withIt > without, String(format: "%.2f against %.2f", withIt, without))
        }

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
