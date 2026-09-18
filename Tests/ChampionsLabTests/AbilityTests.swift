//  AbilityTests.swift
//  What an ability does in the middle of a turn, and what arriving does.
//
//      swift test --filter AbilityTests

import XCTest
@testable import ChampionsLab

final class AbilityTests: HarnessCase {
    /// contact, pinch, regeneration and the abilities that answer a hit
    @MainActor func testAbilitiesInTheTurn() throws {
print("\n== abilities in the turn ==")
    // Rough Skin: touching Garchomp costs an eighth.
    let touchers = fighters([("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"]),
                             ("Kingambit", "Chople Berry", ["Protect"])])
    let barbed = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
                           ("Rillaboom", "Life Orb", ["Protect"]),
                           ("Kingambit", "Chople Berry", ["Protect"])])
    var barbBoard = Board(mine: touchers, theirs: barbed, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    barbBoard.theirs[0].build.ability = "Rough Skin"
    let scraped = TurnModel.resolve(
        barbBoard,
        mine: Play(left: .attack(move: at(barbBoard.mine[0], "Flare Blitz"), target: 0),
                   right: .attack(move: at(barbBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(barbBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(barbBoard.theirs[1], "Protect"), target: 0)))
    check("Rough Skin costs a contact attacker health",
          scraped.story.contains { $0.contains("Rough Skin") },
          scraped.story.filter { $0.contains("Incineroar") }.joined(separator: " | "))

    // Emergency Exit: cross half and it leaves.
    let exiting = fighters([("Golisopod", "Sitrus Berry", ["First Impression", "Protect"]),
                            ("Whimsicott", "Focus Sash", ["Protect"]),
                            ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let hitters = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                            ("Incineroar", "Sitrus Berry", ["Protect"])])
    var exitBoard = Board(mine: exiting, theirs: hitters, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    exitBoard.mine[0].build.ability = "Emergency Exit"
    let fled = TurnModel.resolve(
        exitBoard,
        mine: Play(left: .attack(move: at(exitBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(exitBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(exitBoard.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(exitBoard.theirs[1], "Wood Hammer"), target: 0)))
    // Golisopod protected, so it should still be there. Now let it be hit.
    var exposed = exitBoard
    exposed.mine[0].moves = [store.data.moves.values.first { $0.name == "Iron Head" }!]
    let struck = TurnModel.resolve(
        exposed,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(exposed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(exposed.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(exposed.theirs[1], "Wood Hammer"), target: 0)))
    print("  after being hit, slot 0 is \(struck.mine[0].build.form.formLabel)")
    check("Emergency Exit sends Golisopod out when it drops below half",
          struck.story.contains { $0.contains("Emergency Exit") }
            && struck.mine[0].build.form.formLabel != "Golisopod",
          struck.story.filter { $0.contains("Golisopod") }.joined(separator: " | "))
    _ = fled

    // Regenerator heals on the way out.
    var regen = Board(mine: touchers, theirs: barbed, rules: store.rulebook,
                      field: Field(isDoubles: true), alreadyEvolved: false)
    regen.mine[0].build.ability = "Regenerator"
    regen.mine[0].hp = regen.mine[0].maxHP / 3
    let pivoted = TurnModel.resolve(
        regen,
        mine: Play(left: .swap(to: 2), right: .attack(move: at(regen.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(regen.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(regen.theirs[1], "Protect"), target: 0)))
    let benched = pivoted.mine.first { $0.build.form.formLabel == "Incineroar" }!
    print("  Incineroar left on \(regen.mine[0].hp), sits on the bench at \(benched.hp)")
    check("Regenerator heals a third on the way out",
          benched.hp > regen.mine[0].hp, "\(benched.hp) vs \(regen.mine[0].hp)")

    // Crits: over many rolls, some land, and the note says so.
    let blitz = barbBoard.mine[0].moves[at(barbBoard.mine[0], "Flare Blitz")]
    print("  Flare Blitz critical rate in the data: \(blitz.critRate)%")
    var crits = 0
    for _ in 0..<200 {
        let rolled = TurnModel.resolve(
            barbBoard,
            mine: Play(left: .attack(move: at(barbBoard.mine[0], "Flare Blitz"), target: 0),
                       right: .attack(move: at(barbBoard.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(barbBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(barbBoard.theirs[1], "Protect"), target: 0)), rolling: true)
        if rolled.story.contains(where: { $0.contains("critical") }) { crits += 1 }
    }
    print("  200 Flare Blitzes: \(crits) critical hits (about 8 expected at 1 in 24)")
    check("critical hits happen, at roughly the right rate", crits >= 1 && crits <= 30, "\(crits)")

    // And a pinch ability switches on when low.
    var low = Combatant(form: form("Charizard"), ability: "Blaze", item: "",
                        sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let target = Combatant(form: form("Rillaboom"), ability: "Grassy Surge", item: "",
                           sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let flare = store.data.moves.values.first { $0.name == "Flamethrower" }!
    let healthy = DamageCalc.calculate(attacker: low, defender: target, move: flare,
                                       field: Field(isDoubles: true)).maxDamage
    low.lowHP = true
    let desperate = DamageCalc.calculate(attacker: low, defender: target, move: flare,
                                         field: Field(isDoubles: true)).maxDamage
    print("  Blaze Flamethrower: \(healthy) healthy, \(desperate) when low")
    check("Blaze adds half again once the user is low", desperate > healthy,
          "\(desperate) vs \(healthy)")

    // -- what nobody has seen -------------------------------------------------

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// the leads' abilities, in Speed order, and what a move costs in stages
    @MainActor func testArriving() throws {
print("\n== arriving ==")
    let weatherLeads = fighters([("Politoed", "Leftovers", ["Scald", "Protect"]),
                                 ("Staraptor", "Choice Scarf", ["Brave Bird", "Close Combat", "Protect"]),
                                 ("Kingambit", "Chople Berry", ["Iron Head", "Protect"]),
                                 ("Whimsicott", "Focus Sash", ["Tailwind", "Protect"])])
    let sunLeads = fighters([("Torkoal", "Charcoal", ["Eruption", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    var startBoard = Board(mine: weatherLeads, theirs: sunLeads, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    startBoard.mine[0].build.ability = "Drizzle"
    startBoard.mine[1].build.ability = "Intimidate"
    startBoard.theirs[0].build.ability = "Drought"
    startBoard.theirs[1].build.ability = "Defiant"
    startBoard.activeCount = 2
    startBoard.sendOutLeads()
    print("  at the start:")
    for line in startBoard.story { print("    \(line)") }
    let politoedSpeed = startBoard.mine[0].build.speed(in: startBoard.field)
    let torkoalSpeed = startBoard.theirs[0].build.speed(in: startBoard.field)
    print("  Politoed \(politoedSpeed) Speed against Torkoal \(torkoalSpeed)")
    check("the leads' abilities fire when the game starts",
          startBoard.story.contains { $0.contains("Drizzle") } && startBoard.story.contains { $0.contains("Intimidate") })
    check("and the slower weather setter's weather is the one that stays",
          startBoard.field.weather == (politoedSpeed > torkoalSpeed ? .sun : .rain),
          "\(startBoard.field.weather)")
    check("Intimidate into Defiant hands over two stages of Attack",
          startBoard.theirs[1].build.boosts[Stat.attack.rawValue] == 1,
          "\(startBoard.theirs[1].build.boosts[Stat.attack.rawValue])")
    // And into Competitive: the Attack goes, two stages of Special Attack come.
    var competitive = Board(mine: weatherLeads,
                            theirs: fighters([("Milotic", "Leftovers", ["Muddy Water", "Protect"]),
                                              ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])]),
                            rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    competitive.mine[1].build.ability = "Intimidate"
    competitive.theirs[0].build.ability = "Competitive"
    competitive.activeCount = 2
    competitive.sendOutLeads()
    for line in competitive.story where line.contains("Competitive") { print("    \(line)") }
    check("Intimidate into Competitive costs Attack and gives two stages of Special Attack",
          competitive.theirs[0].build.boosts[Stat.attack.rawValue] == -1
            && competitive.theirs[0].build.boosts[Stat.spAttack.rawValue] == 2,
          "\(competitive.theirs[0].build.boosts)")
    print("  a Milotic with nothing registered fights with: \(Board(mine: weatherLeads, theirs: fighters([("Milotic", "Leftovers", ["Protect"])]), rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false).theirs[0].build.ability)")

    // Both sides lose a Pokémon; both send in at once, faster first.
    var fallen = startBoard
    fallen.mine[0].hp = 0
    fallen.theirs[0].hp = 0
    fallen.mine[2].build.ability = "Intimidate"     // Kingambit, slower
    fallen.theirs[2].build.ability = "Intimidate"   // Garchomp, faster
    fallen.story = []
    fallen.replaceFallen(mine: [(slot: 0, bench: 2)])
    print("  after the faints:")
    for line in fallen.story { print("    \(line)") }
    let mineIn = fallen.mine[0].build.form.formLabel, theirsIn = fallen.theirs[0].build.form.formLabel
    check("both sides send in at once", mineIn == "Kingambit" && !fallen.theirs[0].fainted,
          "\(mineIn) and \(theirsIn)")
    let garchompFirst = fallen.story.firstIndex { $0.contains("\(theirsIn) was sent in") }! <
                        fallen.story.firstIndex { $0.contains("\(mineIn) was sent in") }!
    check("the faster one arrives first", garchompFirst)
    // Garchomp arrived first, so its Intimidate never saw Kingambit; Kingambit
    // arrived second and its Intimidate hit Garchomp.
    check("and the faster one's Intimidate never touches the slower arrival",
          fallen.mine[0].build.boosts[Stat.attack.rawValue] == 0
            && fallen.theirs[0].build.boosts[Stat.attack.rawValue] == -1,
          "\(fallen.mine[0].build.boosts[Stat.attack.rawValue]) / \(fallen.theirs[0].build.boosts[Stat.attack.rawValue])")
    check("and the arrival is seen from then on", fallen.theirs[0].seen)

    // Close Combat costs its user, unless it is Contrary.
    let closeCombat = at(startBoard.mine[1], "Close Combat")
    print("  Close Combat lowers: \(startBoard.mine[1].moves[closeCombat].selfDrops)")
    var combat = startBoard
    combat.story = []
    let fought = TurnModel.resolve(
        combat,
        mine: Play(left: .attack(move: at(combat.mine[0], "Protect"), target: 0),
                   right: .attack(move: closeCombat, target: 1)),
        theirs: Play(left: .attack(move: at(combat.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(combat.theirs[1], "Iron Head"), target: 0)))
    for line in fought.story where line.contains("Staraptor") { print("    \(line)") }
    check("Close Combat drops the user's defences",
          fought.mine[1].build.boosts[Stat.defense.rawValue] == -1
            && fought.mine[1].build.boosts[Stat.spDefense.rawValue] == -1,
          "\(fought.mine[1].build.boosts)")
    combat.mine[1].build.ability = "Contrary"
    let contrary = TurnModel.resolve(
        combat,
        mine: Play(left: .attack(move: at(combat.mine[0], "Protect"), target: 0),
                   right: .attack(move: closeCombat, target: 1)),
        theirs: Play(left: .attack(move: at(combat.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(combat.theirs[1], "Iron Head"), target: 0)))
    for line in contrary.story where line.contains("Contrary") { print("    \(line)") }
    check("and Contrary turns the drop into a raise",
          contrary.mine[1].build.boosts[Stat.defense.rawValue] == 1
            && contrary.mine[1].build.boosts[Stat.spDefense.rawValue] == 1,
          "\(contrary.mine[1].build.boosts)")

    // Revival Blessing brings one of your own back, at half.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Thermal Exchange and the abilities that answer the kind of hit
    @MainActor func testAnsweringAHit() throws {
print("\n== answering a hit ==")
    let sunPair = fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
    let dragonPair = fighters([("Baxcalibur", "Loaded Dice", ["Glaive Rush", "Protect"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    var thermal = Board(mine: sunPair, theirs: dragonPair, rules: store.rulebook,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    thermal.theirs[0].build.ability = "Thermal Exchange"
    let warmed = TurnModel.resolve(thermal,
        mine: Play(left: .attack(move: at(thermal.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(thermal.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(thermal.theirs[0], "Glaive Rush"), target: 1),
                     right: .attack(move: at(thermal.theirs[1], "Wood Hammer"), target: 1)))
    for line in warmed.story where line.contains("Thermal") { print("    \(line)") }
    check("Thermal Exchange raises Attack when hit by a Fire move",
          warmed.theirs[0].build.boosts[Stat.attack.rawValue] == 1,
          "\(warmed.theirs[0].build.boosts[Stat.attack.rawValue]) — \(warmed.story.filter { $0.contains("Baxcalibur") })")

    // Hitting your own partner, on purpose.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Multiscale at full health, and the moves that count the fallen
    @MainActor func testTheBarAndTheFallen() throws {
print("\n== the bar and the fallen ==")
    var scaled = Combatant(form: form("Dragonite"), ability: "Multiscale", item: "",
                           sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let striker = Combatant(form: form("Garchomp"), ability: "Rough Skin", item: "",
                            sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let dragonClaw = store.data.moves.values.first { $0.name == "Dragon Claw" }!
    let fresh = DamageCalc.calculate(attacker: striker, defender: scaled, move: dragonClaw, field: Field(isDoubles: true)).maxDamage
    scaled.atFullHP = false
    let dented = DamageCalc.calculate(attacker: striker, defender: scaled, move: dragonClaw, field: Field(isDoubles: true)).maxDamage
    print("  Dragon Claw into Multiscale Dragonite: \(fresh) at full, \(dented) once dented")
    check("Multiscale halves only at full health", dented >= fresh * 2 - 2 && dented <= fresh * 2 + 2, "\(fresh) vs \(dented)")
    var mourner = Combatant(form: form("Basculegion"), ability: "Adaptability", item: "",
                            sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let respects = store.data.moves.values.first { $0.name == "Last Respects" }!
    let alone = DamageCalc.calculate(attacker: mourner, defender: striker, move: respects, field: Field(isDoubles: true)).maxDamage
    mourner.fallenAllies = 2
    let grieving = DamageCalc.calculate(attacker: mourner, defender: striker, move: respects, field: Field(isDoubles: true)).maxDamage
    print("  Last Respects: \(alone) with nobody down, \(grieving) with two down")
    check("Last Respects grows with every fallen teammate", grieving > alone * 2 && grieving <= alone * 3 + 3, "\(alone) vs \(grieving)")
    // And the battle actually counts them.
    var mourning = Board(mine: fighters([("Basculegion", "Choice Scarf", ["Last Respects", "Protect"]),
                                         ("Whimsicott", "Focus Sash", ["Protect"]),
                                         ("Garchomp", "Life Orb", ["Protect"]),
                                         ("Kingambit", "Chople Berry", ["Protect"])]),
                         theirs: soaked, rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    let unbowed = TurnModel.resolve(mourning,
        mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(mourning.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(mourning.theirs[1], "Swords Dance"), target: 0)))
    mourning.mine[2].hp = 0; mourning.mine[3].hp = 0
    let bereaved = TurnModel.resolve(mourning,
        mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(mourning.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(mourning.theirs[1], "Swords Dance"), target: 0)))
    let took1 = unbowed.theirs[0].maxHP - unbowed.theirs[0].hp
    let took2 = bereaved.theirs[0].maxHP - bereaved.theirs[0].hp
    print("  in a turn: \(took1) with the team standing, \(took2) with two down")
    check("and in a played turn the fallen are counted", took2 > took1 * 2, "\(took1) vs \(took2)")
    let pixie = AteAbility.resolve(type: PokeType.normal, ability: "Pixilate")
    check("Pixilate turns a Normal move Fairy", pixie.type == .fairy && pixie.boost > 1)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// White Herb spent, and Unburden picking the Speed up
    @MainActor func testTheHerbAndTheBurden() throws {
print("\n== the herb and the burden ==")
    var herbal = Board(mine: fighters([("Sneasler", "White Herb", ["Close Combat", "Protect"]),
                                       ("Whimsicott", "Focus Sash", ["Protect"])]),
                       theirs: fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect"]),
                                         ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])]),
                       rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    herbal.mine[0].build.ability = "Unburden"
    let quick0 = herbal.mine[0].build.speed(in: herbal.field)
    let chilled2 = TurnModel.resolve(herbal,
        mine: Play(left: .attack(move: at(herbal.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(herbal.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(herbal.theirs[0], "Icy Wind"), target: 0),
                     right: .attack(move: at(herbal.theirs[1], "Swords Dance"), target: 0)))
    _ = chilled2
    // Protect blocks Icy Wind; use a turn where Sneasler attacks instead.
    let dropped = TurnModel.resolve(herbal,
        mine: Play(left: .attack(move: at(herbal.mine[0], "Close Combat"), target: 1),
                   right: .attack(move: at(herbal.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(herbal.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(herbal.theirs[1], "Swords Dance"), target: 0)))
    for line in dropped.story where line.contains("Sneasler") { print("    \(line)") }
    let quick1 = dropped.mine[0].build.speed(in: dropped.field)
    check("White Herb undoes the drop and is used up",
          dropped.mine[0].build.boosts[Stat.defense.rawValue] == 0 && dropped.mine[0].build.itemSpent,
          "\(dropped.mine[0].build.boosts) spent \(dropped.mine[0].build.itemSpent)")
    check("and Unburden then doubles its Speed", quick1 == quick0 * 2, "\(quick0) -> \(quick1)")
    // Intimidate takes the herb too.
    var glared = herbal
    glared.theirs[1].build.ability = "Intimidate"
    glared.activeCount = 2
    glared.sendOutLeads()
    for line in glared.story where line.contains("Intimidate") { print("    \(line)") }
    check("Intimidate into a White Herb spends the herb and leaves no drop",
          glared.mine[0].build.itemSpent && glared.mine[0].build.boosts[Stat.attack.rawValue] == 0
            && glared.mine[0].build.speed(in: glared.field) == quick0 * 2)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
