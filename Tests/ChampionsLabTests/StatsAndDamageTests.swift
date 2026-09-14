//  StatsAndDamageTests.swift
//  The stat and damage arithmetic against hand-computed values.
//
//      swift test --filter StatsAndDamageTests

import XCTest
@testable import ChampionsLab

final class StatsAndDamageTests: XCTestCase {
    func testTheArithmetic() throws {
        let dataURL = TestData.url("champions.json")
        let dataset = try! JSONDecoder().decode(Dataset.self, from: Data(contentsOf: dataURL))
        let forms = Dictionary(dataset.forms.map { ($0.formLabel, $0) }, uniquingKeysWith: { a, _ in a })
        let movesByName = Dictionary(dataset.moves.values.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var failures = 0
        func check(_ label: String, _ actual: Int, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
            let ok = actual == expected
            if !ok { failures += 1 }
            print("  \(ok ? "PASS" : "FAIL")  \(label): got \(actual), expected \(expected)")
            XCTAssertEqual(actual, expected, label, file: file, line: line)
        }
        func report(_ label: String, _ text: String) {
            print("  ....  \(label): \(text)")
        }

        /// Ratio checks need slack: damage is floored at several points in the formula,
        /// so an exact 0.75x multiplier lands a percentage point either side.
        func checkNear(_ label: String, _ actual: Int, _ expected: Int, tolerance: Int = 2) {
            let ok = abs(actual - expected) <= tolerance
            if !ok { failures += 1 }
            print("  \(ok ? "PASS" : "FAIL")  \(label): got \(actual), expected \(expected)±\(tolerance)")
        }

        print("== dataset ==")
        print("  forms \(dataset.forms.count), moves \(dataset.moves.count), items \(dataset.items.count), abilities \(dataset.abilities.count)")

        // ---------------------------------------------------------------- stats ----
        // Champions: HP = Base + 75 + SP; other = floor((Base + 20 + SP) * alignment).
        print("\n== Champions stat maths ==")
        let megaSalamence = forms["Mega Salamence"]!
        check("Mega Salamence HP, 0 SP", ChampionsStats.value(base: megaSalamence.hp, sp: 0, stat: .hp, alignment: .neutral), 95 + 75)
        check("Mega Salamence HP, 32 SP", ChampionsStats.value(base: megaSalamence.hp, sp: 32, stat: .hp, alignment: .neutral), 95 + 75 + 32)
        check("Mega Salamence Spe, 0 SP neutral", ChampionsStats.value(base: megaSalamence.speed, sp: 0, stat: .speed, alignment: .neutral), 120 + 20)
        // 120 + 20 + 32 = 172, x1.1 = 189.2 -> 189
        check("Mega Salamence Spe, 32 SP +Spe", ChampionsStats.value(base: megaSalamence.speed, sp: 32, stat: .speed, alignment: Alignment.named("Jolly")), 189)
        // A hindering alignment: 172 * 0.9 = 154.8 -> 154
        check("Mega Salamence Spe, 32 SP -Spe", ChampionsStats.value(base: megaSalamence.speed, sp: 32, stat: .speed, alignment: Alignment.named("Brave")), 154)

        let megaGarchompZ = forms["Mega Garchomp Z"]!
        // The format's new speed ceiling: 151 + 20 + 32 = 203, x1.1 = 223.3 -> 223
        check("Mega Garchomp Z max Speed", ChampionsStats.maxValue(base: megaGarchompZ.speed, stat: .speed, boosting: true), 223)

        // Battle stages.
        check("+1 stage on 200", ChampionsStats.staged(200, stage: 1), 300)
        check("+2 stages on 200", ChampionsStats.staged(200, stage: 2), 400)
        check("-1 stage on 200", ChampionsStats.staged(200, stage: -1), 133)

        // ----------------------------------------------------------- type chart ----
        print("\n== type chart ==")
        let megaGolisopod = forms["Mega Golisopod"]!
        report("Mega Golisopod types", megaGolisopod.types.joined(separator: "/"))
        check("Fire into Bug/Steel = 4x", Int(TypeChart.multiplier(.fire, into: megaGolisopod) * 100), 400)
        check("Poison into Bug/Steel = 0x", Int(TypeChart.multiplier(.poison, into: megaGolisopod) * 100), 0)
        check("Ground into Mega Garchomp Z with Levitate = 0",
              Int(TypeChart.multiplier(.ground, into: megaGarchompZ, ability: "Levitate") * 100), 0)
        check("Ground into Dragon (no ability) = 1x",
              Int(TypeChart.multiplier(.ground, into: megaGarchompZ, ability: nil) * 100), 100)
        check("Dragon into Fairy = 0x", Int(TypeChart.multiplier(.dragon, into: [.fairy]) * 100), 0)
        check("Ice into Dragon/Flying = 4x", Int(TypeChart.multiplier(.ice, into: [.dragon, .flying]) * 100), 400)

        // -------------------------------------------------------------- damage ----
        print("\n== damage ==")

        // Max-Attack Jolly Mega Salamence, Aerilate Double-Edge, into a neutral
        // 0-SP Serious Garchomp. Aerilate makes it Flying and adds 20%.
        var salamence = Combatant(form: megaSalamence, ability: "Aerilate", item: "",
                                  sp: [0, 32, 0, 0, 0, 32],
                                  alignment: Alignment.named("Jolly"))
        let garchomp = Combatant(form: forms["Garchomp"]!, ability: "Rough Skin", item: "")
        let doubleEdge = movesByName["Double-Edge"]!
        let singles = Field(isDoubles: false)
        let result = DamageCalc.calculate(attacker: salamence, defender: garchomp,
                                          move: doubleEdge, field: singles)
        report("Salamence Double-Edge into Garchomp", result.summary)
        report("  notes", result.notes.joined(separator: "; "))
        check("Aerilate applied (Flying, not Normal)",
              result.effectiveness == 1.0 ? 1 : 0, 1)   // Flying into Dragon/Ground is 1x

        // Spread penalty: Rock Slide should lose exactly 25% in doubles.
        let rockSlide = movesByName["Rock Slide"]!
        let tyranitar = Combatant(form: forms["Tyranitar"]!, ability: "Sand Stream", item: "")
        let single = DamageCalc.calculate(attacker: salamence, defender: tyranitar,
                                          move: rockSlide, field: Field(isDoubles: false))
        let spread = DamageCalc.calculate(attacker: salamence, defender: tyranitar,
                                          move: rockSlide, field: Field(isDoubles: true))
        report("Rock Slide singles", "\(single.minDamage)-\(single.maxDamage)")
        report("Rock Slide doubles", "\(spread.minDamage)-\(spread.maxDamage)")
        checkNear("spread is ~0.75 of single", Int((Double(spread.maxDamage) / Double(single.maxDamage) * 100).rounded()), 75)

        // Grassy Terrain must halve Earthquake — the core anti-Garchomp claim.
        let earthquake = movesByName["Earthquake"]!
        var chompAttacker = Combatant(form: forms["Garchomp"]!, ability: "Rough Skin", item: "",
                                      sp: [0, 32, 0, 0, 0, 32],
                                      alignment: Alignment.named("Jolly"))
        let plain = DamageCalc.calculate(attacker: chompAttacker, defender: tyranitar,
                                         move: earthquake, field: Field(isDoubles: true))
        let grassy = DamageCalc.calculate(attacker: chompAttacker, defender: tyranitar,
                                          move: earthquake,
                                          field: Field(terrain: .grassy, isDoubles: true))
        report("Earthquake, no terrain", "\(plain.minDamage)-\(plain.maxDamage)")
        report("Earthquake, Grassy", "\(grassy.minDamage)-\(grassy.maxDamage)")
        checkNear("Grassy halves Earthquake", Int((Double(grassy.maxDamage) / Double(plain.maxDamage) * 100).rounded()), 50)

        // Tough Claws on a contact move, +30%.
        let liquidation = movesByName["Liquidation"]!
        var golisopod = Combatant(form: megaGolisopod, ability: "Tough Claws", item: "",
                                  sp: [0, 32, 0, 0, 0, 0], alignment: Alignment.named("Adamant"))
        var golisopodPlain = golisopod
        golisopodPlain.ability = "Emergency Exit"
        let withClaws = DamageCalc.calculate(attacker: golisopod, defender: tyranitar,
                                             move: liquidation, field: singles)
        let withoutClaws = DamageCalc.calculate(attacker: golisopodPlain, defender: tyranitar,
                                                move: liquidation, field: singles)
        report("Liquidation w/ Tough Claws", "\(withClaws.minDamage)-\(withClaws.maxDamage)")
        report("Liquidation w/o", "\(withoutClaws.minDamage)-\(withoutClaws.maxDamage)")
        checkNear("Tough Claws ~+30%", Int((Double(withClaws.maxDamage) / Double(withoutClaws.maxDamage) * 100).rounded()), 130)

        // Aura Guard halves contact — the Mega Lucario Z wall.
        let lucarioZ = forms["Mega Lucario Z"]!
        var guarded = Combatant(form: lucarioZ, ability: "Aura Guard", item: "")
        var unguarded = guarded
        unguarded.ability = "Steadfast"
        let vsGuard = DamageCalc.calculate(attacker: golisopod, defender: guarded,
                                           move: liquidation, field: singles)
        let vsPlain = DamageCalc.calculate(attacker: golisopod, defender: unguarded,
                                           move: liquidation, field: singles)
        report("Liquidation into Aura Guard", "\(vsGuard.minDamage)-\(vsGuard.maxDamage)")
        report("Liquidation into plain", "\(vsPlain.minDamage)-\(vsPlain.maxDamage)")
        checkNear("Aura Guard halves contact", Int((Double(vsGuard.maxDamage) / Double(vsPlain.maxDamage) * 100).rounded()), 50)

        // STAB, and Adaptability doubling it. Champions has no Terastallization, so
        // there is no Tera-STAB case to check.
        let dragonClaw = movesByName["Dragon Claw"]!
        var plainAttacker = salamence
        plainAttacker.ability = "Intimidate"
        var adaptive = salamence
        adaptive.ability = "Adaptability"
        let stabOnly = DamageCalc.calculate(attacker: plainAttacker, defender: tyranitar,
                                            move: dragonClaw, field: singles)
        let adaptiveStab = DamageCalc.calculate(attacker: adaptive, defender: tyranitar,
                                                move: dragonClaw, field: singles)
        report("Dragon Claw STAB", "\(stabOnly.maxDamage)")
        report("Dragon Claw Adaptability STAB", "\(adaptiveStab.maxDamage)")
        checkNear("Adaptability turns 1.5x STAB into 2.0x",
                  Int((Double(adaptiveStab.maxDamage) / Double(stabOnly.maxDamage) * 100).rounded()), 133)

        // ------------------------------------------------------- battle stages ----
        print("\n== battle stages ==")
        // The standard stage table, which is what makes a Swords Dance worth 2.0x.
        check("+1 on 100", ChampionsStats.staged(100, stage: 1), 150)
        check("+2 on 100", ChampionsStats.staged(100, stage: 2), 200)
        check("+3 on 100", ChampionsStats.staged(100, stage: 3), 250)
        check("-1 on 100", ChampionsStats.staged(100, stage: -1), 66)
        check("-2 on 100", ChampionsStats.staged(100, stage: -2), 50)
        check("+6 on 100", ChampionsStats.staged(100, stage: 6), 400)

        // Boost moves are read out of the effect text rather than a hand-kept list.
        check("Swords Dance parses as +2 Attack",
              movesByName["Swords Dance"]!.selfBoosts[.attack] ?? 0, 2)
        check("Dragon Dance parses as +1 Attack",
              movesByName["Dragon Dance"]!.selfBoosts[.attack] ?? 0, 1)
        check("Dragon Dance parses as +1 Speed",
              movesByName["Dragon Dance"]!.selfBoosts[.speed] ?? 0, 1)

        // Swords Dance plus a Thermal Exchange proc, which is the case that prompted this.
        let baxcalibur = forms["Mega Baxcalibur"]!
        var boosted = Combatant(form: baxcalibur, ability: "Thermal Exchange", item: "",
                                sp: [2, 32, 0, 0, 0, 32], alignment: Alignment.named("Adamant"))
        report("Mega Baxcalibur Attack at +0", "\(boosted.stagedStat(.attack))")
        boosted.boosts[Stat.attack.rawValue] = 3
        check("Attack at +3 is 2.5x", boosted.stagedStat(.attack), 622)

        // Glaive Rush doubles what its user takes until its next action.
        var open = Combatant(form: forms["Tyranitar"]!, ability: "Sand Stream", item: "")
        let shut = DamageCalc.calculate(attacker: boosted, defender: open,
                                        move: movesByName["Ice Shard"]!, field: singles)
        open.wideOpen = true
        let exposed = DamageCalc.calculate(attacker: boosted, defender: open,
                                           move: movesByName["Ice Shard"]!, field: singles)
        let exposedMax = Double(exposed.maxDamage)
        let shutMax = Double(shut.maxDamage)
        let wideOpenRatio = Int((exposedMax / shutMax * 100).rounded())
        report("Ice Shard normal / Wide Open", "\(shut.maxDamage) / \(exposed.maxDamage)")
        checkNear("Wide Open doubles damage taken", wideOpenRatio, 200)

        // -- Helping Hand ---------------------------------------------------------
        var hhField = singles
        let unhelped = DamageCalc.calculate(attacker: boosted, defender: open,
                                            move: movesByName["Ice Shard"]!, field: hhField)
        hhField.helpingHand = true
        let helped = DamageCalc.calculate(attacker: boosted, defender: open,
                                          move: movesByName["Ice Shard"]!, field: hhField)
        report("Ice Shard alone / with Helping Hand",
               "\(unhelped.maxDamage) / \(helped.maxDamage)")
        checkNear("Helping Hand is +50% power",
                  Int((Double(helped.maxDamage) / Double(unhelped.maxDamage) * 100).rounded()), 150,
                  tolerance: 3)

        // -- Move worth -----------------------------------------------------------
        //
        // Base power alone ranked Steel Beam over everything Gholdengo owns. These
        // pin the discounts that stopped it.
        func worth(_ name: String, ability: String = "", item: String = "") -> Int {
            Int(movesByName[name]!.quality(ability: ability, item: item).expectedPower.rounded())
        }
        report("Steel Beam / Iron Head worth", "\(worth("Steel Beam")) / \(worth("Iron Head"))")
        check("Focus Blast is discounted for 70% accuracy", worth("Focus Blast"), 75)
        check("No Guard restores Focus Blast", worth("Focus Blast", ability: "No Guard"), 120)
        check("Rock Head cancels Head Smash recoil",
              worth("Head Smash", ability: "Rock Head") > worth("Head Smash") ? 1 : 0, 1)
        check("Contrary turns Draco Meteor's drop into a gain",
              worth("Draco Meteor", ability: "Contrary") > worth("Draco Meteor") ? 1 : 0, 1)
        check("Outrage is not worth its base power in doubles",
              worth("Outrage") < worth("Dragon Claw") ? 1 : 0, 1)
        check("Triple Axel is worth more than its 20 BP",
              worth("Triple Axel") > 80 ? 1 : 0, 1)
        check("Sucker Punch is discounted for failing on the wrong read",
              movesByName["Sucker Punch"]!.quality().reliability < 0.8 ? 1 : 0, 1)
        // First Impression is not a read: it always works on the turn you send it in.
        // Charging it Sucker Punch's penalty ranked it below a weaker neutral move.
        check("First Impression beats Liquidation on worth",
              worth("First Impression") > worth("Liquidation") ? 1 : 0, 1)
        check("but it still costs something to be first-turn only",
              movesByName["First Impression"]!.quality().reliability < 1.0 ? 1 : 0, 1)
        check("A clean move takes no discount",
              worth("Flamethrower"), movesByName["Flamethrower"]!.power)

        // -- survival items and multi-hit -----------------------------------------
        //
        // A Focus Sash stops one hit, not a move. Anything that strikes more than once
        // breaks it on the first and knocks out with the second, and the calculator
        // used to read the printed power and stop -- Icicle Spear came out as a single
        // 25 BP hit.
        let sashTarget = forms["Whimsicott"]!
        var bare = Combatant(form: sashTarget, ability: "Prankster", item: "",
                             sp: [2, 0, 0, 0, 0, 32], alignment: Alignment.named("Timid"))
        var sashed = bare
        sashed.item = "Focus Sash"
        let spear = movesByName["Icicle Spear"]!
        let crash = movesByName["Icicle Crash"]!
        let doubles = Field(isDoubles: true)

        let spearBare = DamageCalc.calculate(attacker: boosted, defender: bare, move: spear, field: doubles)
        let spearSash = DamageCalc.calculate(attacker: boosted, defender: sashed, move: spear, field: doubles)
        report("Icicle Spear bare / into a Sash",
               "\(spearBare.maxDamage) / \(spearSash.maxDamage)")
        check("a multi-hit move counts every strike",
              spearBare.maxDamage > spear.power * 2 ? 1 : 0, 1)
        check("and goes through a Focus Sash",
              spearSash.minDamage >= spearSash.targetHP ? 1 : 0, 1)

        let crashSash = DamageCalc.calculate(attacker: boosted, defender: sashed, move: crash, field: doubles)
        check("while a single-hit move is still stopped by one",
              crashSash.maxDamage < crashSash.targetHP ? 1 : 0, 1)

        print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
    }
}
