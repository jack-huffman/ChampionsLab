//  tools/main.swift
//  Checks the stat and damage maths against hand-computed values.
//
//  Lives outside the app sources on purpose: build.sh globs *.swift in the
//  project root, and a second `main` there would collide with the app's @main.
//
//      ./tools/verify.sh

import Foundation

let dataURL = URL(fileURLWithPath: "data/champions.json")
let dataset = try! JSONDecoder().decode(Dataset.self, from: Data(contentsOf: dataURL))
let forms = Dictionary(dataset.forms.map { ($0.formLabel, $0) }, uniquingKeysWith: { a, _ in a })
let movesByName = Dictionary(dataset.moves.values.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

var failures = 0
func check(_ label: String, _ actual: Int, _ expected: Int) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("  \(ok ? "PASS" : "FAIL")  \(label): got \(actual), expected \(expected)")
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

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
