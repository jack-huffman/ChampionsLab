//  MegaEvolutionTests.swift
//  One per side, before any move, in Speed order — and the weather war that decides.
//
//      swift test --filter MegaEvolutionTests

import XCTest
@testable import ChampionsLab

final class MegaEvolutionTests: HarnessCase {
    /// who evolves, when, and whose weather stays
    @MainActor func testMegaEvolution() throws {
print("\n== mega evolution ==")
    func sideOf(_ entries: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = entries.map { name, item, moves in
            var slot = TeamSlot(formID: form(name).id)
            slot.item = item
            slot.moves = moves.compactMap { n in
                store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6); sp[Stat.speed.rawValue] = 32
            slot.sp = sp; slot.alignmentName = "Timid"
            return slot
        }
        return out
    }
    let sunSide = sideOf([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                          ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                          ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let snowSide = sideOf([("Froslass", "Froslassite", ["Blizzard", "Protect"]),
                           ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])

    let unevolved = Board(mine: sunSide, theirs: snowSide, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    check("a battle starts with what was registered, not what it becomes",
          unevolved.mine[0].build.form.formLabel == "Charizard",
          unevolved.mine[0].build.form.formLabel)
    check("and with the registered ability",
          unevolved.mine[0].build.ability != "Drought", unevolved.mine[0].build.ability)
    check("but it knows what it turns into",
          unevolved.mine[0].pendingMega?.formLabel == "Mega Charizard Y")
    let analysed = Board(mine: sunSide, theirs: snowSide, store: store,
                         field: Field(isDoubles: true))
    check("while every analysis screen still sees the Mega",
          analysed.mine[0].build.form.formLabel == "Mega Charizard Y",
          analysed.mine[0].build.form.formLabel)

    let mySpeed = unevolved.mine[0].build.speed(in: unevolved.field)
    let theirSpeed = unevolved.theirs[0].build.speed(in: unevolved.field)
    print("  Charizard \(mySpeed) against Froslass \(theirSpeed) — the slower evolves second")
    // Both sides toggle it on for their lead, which is how the game asks.
    let afterMega = TurnModel.resolve(
        unevolved,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                     megaSlot: 0))
    print("  both evolved; the weather is \(afterMega.field.weather.rawValue)")
    check("both sides Mega Evolved",
          afterMega.mine[0].build.form.isMega && afterMega.theirs[0].build.form.isMega)
    // Froslass is faster, so it evolves first and Charizard's Drought lands on
    // top of its Snow Warning.
    check("the slower Mega wins the weather war",
          afterMega.field.weather == (mySpeed < theirSpeed ? .sun : .snow),
          afterMega.field.weather.rawValue)
    check("and evolving spends the side's one Mega Evolution",
          afterMega.mine.allSatisfy(\.hasMegaEvolved))

    // Two stones on one side is legal to register and only one can be used.
    let twoStones = sideOf([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                            ("Froslass", "Froslassite", ["Blizzard", "Protect"]),
                            ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let dual = Board(mine: twoStones, theirs: snowSide, store: store,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    // Asking for the second slot as well changes nothing: a side gets one.
    let afterDual = TurnModel.resolve(
        dual,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                     megaSlot: 0))
    let evolvedNames = afterDual.mine.prefix(2).filter { $0.build.form.isMega }
        .map(\.build.form.formLabel)
    print("  two stones on one side, asked for the first: \(evolvedNames)")
    check("only one of them evolves", evolvedNames.count == 1, "\(evolvedNames)")
    check("and it is the one that was asked for",
          evolvedNames.first == "Mega Charizard Y", "\(evolvedNames)")

    // The other one, if that is the one you ask for.
    let afterOther = TurnModel.resolve(
        dual,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 1),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
    check("asking for the other one evolves the other one",
          afterOther.mine.prefix(2).filter { $0.build.form.isMega }
            .map(\.build.form.formLabel) == ["Mega Froslass"],
          "\(afterOther.mine.prefix(2).map(\.build.form.formLabel))")

    // Not asking leaves it alone, which is a turn people really do take.
    let held = TurnModel.resolve(
        unevolved,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
    check("nothing evolves unless it is asked to",
          !held.mine[0].build.form.isMega && !held.theirs[0].build.form.isMega)
    check("and holding it back leaves the field clear",
          held.field.weather == .none, held.field.weather.rawValue)

    // Holding it back one turn is how you win a weather war you would lose.
    let afterHeld = TurnModel.resolve(
        held,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
    check("evolving a turn later still works",
          afterHeld.mine[0].build.form.isMega && afterHeld.field.weather == .sun,
          afterHeld.field.weather.rawValue)

    // Team lists register the base form; the bundled archetypes now do too.
    let stillMega = store.data.metaTeams.flatMap(\.members)
        .filter { $0.form.hasPrefix("Mega ") }
    check("no bundled team registers a Mega directly", stillMega.isEmpty,
          "\(stillMega.count)")

    // -- the rest of a turn --------------------------------------------------
    //
    // Eleven per cent of the move slots on real team lists used to land in the
    // battle loop and do nothing at all -- Follow Me, Rage Powder, Wide Guard,
    // Swords Dance, Will-O-Wisp, the screens -- and nothing happened between
    // turns either: no weather chip, no burn, no berry, no Leftovers.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
