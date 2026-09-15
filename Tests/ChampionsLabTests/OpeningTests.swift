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

extension OpeningTests {
    /// Whether to draw the fire or hide behind Protect is a question about
    /// what the partner is worth
    ///
    /// The claim, from the Sandover annotation, is that a Protect on a Follow
    /// Me or Rage Powder Pokémon usually backfires: the other side simply
    /// double-targets the one that is not protected.
    ///
    /// It turns out not to be a rule the engine should be given, because it is
    /// not unconditional. Drawing the fire trades the redirector's health for
    /// the partner's, and which way that trade goes depends entirely on which
    /// of the two is worth more. What decides it is exactly the matchup
    /// weighting — and with no weights on the board, the engine can only
    /// compare health, so it shelters the frail redirector and lets the Mega
    /// take two hits.
    ///
    /// So this checks the mechanism rather than the maxim: told what its
    /// Pokémon are worth, the engine changes its mind.
    @MainActor func testDrawingFireDependsOnWhatThePartnerIsWorth() throws {
        print("\n== protecting the redirection ==")
        // Indeedee rather than Farigiraf, which learns neither redirection move;
        // Follow Me rather than Rage Powder, which a Grass type ignores
        // outright; and two attackers with no priority, since priority would be
        // answered by the ability rather than by the redirection.
        let mine = fighters([("Indeedee", "Leftovers", ["Follow Me", "Protect", "Psychic"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Garchomp", "Leftovers", ["Earthquake", "Protect"]),
                             ("Milotic", "Leftovers", ["Surf", "Protect"])])
        let theirs = fighters([("Kingambit", "Life Orb", ["Iron Head", "Protect"]),
                               ("Gholdengo", "Life Orb", ["Make It Rain", "Protect"]),
                               ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                               ("Milotic", "Leftovers", ["Surf", "Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.sendOutLeads()

        let bare = TurnGame(board: board)
        let powder = at(board.mine[0], "Follow Me")
        let guard0 = at(board.mine[0], "Protect")
        let wave = at(board.mine[1], "Heat Wave")

        // Both sides attacking the fragile partner, with the redirector either
        // pulling the fire or hiding behind a Protect.
        let theirBest = Play(left: .attack(move: at(board.theirs[0], "Iron Head"), target: 1),
                             right: .attack(move: at(board.theirs[1], "Make It Rain"), target: 1))
        let draw = Play(left: .attack(move: powder, target: 0),
                        right: .attack(move: wave, target: 0))
        let hide = Play(left: .protectSelf(move: guard0),
                        right: .attack(move: wave, target: 0))
        let flatDraw = bare.settle(draw, theirBest).expected
        let flatHide = bare.settle(hide, theirBest).expected
        print(String(format: "  worth nothing to it: drawing %.3f, hiding %.3f",
                     flatDraw, flatHide))
        check("with no weights it shelters the frail one and lets the Mega take both",
              flatHide > flatDraw, String(format: "%.3f against %.3f", flatHide, flatDraw))

        // Now tell it what the two are actually worth to this team.
        var weighted = board
        weighted.myBeats = Worth.table(for: mine, against: theirs,
                                       rules: store.rulebook, field: Field(isDoubles: true))
        weighted.myRoster = mine.slots.compactMap { $0.battleForm(in: store.rulebook)?.id }
        // Both rosters: the weights are counted against who is standing on the
        // *other* side, so leaving theirs empty leaves nothing to count.
        weighted.theirRoster = theirs.slots.compactMap { $0.battleForm(in: store.rulebook)?.id }
        weighted.refreshWorth()
        let zard = weighted.mine[1].build.form.id
        let helper = weighted.mine[0].build.form.id
        print(String(format: "  it is told: %@ %.2f, %@ %.2f",
                     weighted.mine[1].build.form.formLabel, weighted.myWorth[zard] ?? 1,
                     weighted.mine[0].build.form.formLabel, weighted.myWorth[helper] ?? 1))
        check("the Mega is worth more than the redirector",
              (weighted.myWorth[zard] ?? 1) > (weighted.myWorth[helper] ?? 1))

        let told = TurnGame(board: weighted)
        let toldDraw = told.settle(draw, theirBest).expected
        let toldHide = told.settle(hide, theirBest).expected
        print(String(format: "  told what they are worth: drawing %.3f, hiding %.3f",
                     toldDraw, toldHide))
        check("knowing that narrows the gap, or closes it",
              (toldDraw - toldHide) > (flatDraw - flatHide),
              String(format: "%.3f against %.3f", toldDraw - toldHide, flatDraw - flatHide))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
