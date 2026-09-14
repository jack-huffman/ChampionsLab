//  EncoreTests.swift
//  Stat stages in the roll, priority from an ability, and being held to one move.
//
//      swift test --filter EncoreTests

import XCTest
@testable import ChampionsLab

final class EncoreTests: HarnessCase {
    /// a boosted roll, a Prankster's priority, and an Encore
    @MainActor func testBoostedRollsAndEncore() throws {
print("\n== boosted rolls, and Encore ==")
    var boosted = Board(mine: fighters([("Milotic", "Leftovers", ["Moonblast", "Protect"]),
                                        ("Whimsicott", "Focus Sash", ["Encore", "Tailwind", "Protect"])]),
                        theirs: fighters([("Garchomp", "Life Orb", ["Dragon Claw", "Swords Dance", "Protect"]),
                                          ("Kingambit", "Chople Berry", ["Iron Head", "Swords Dance", "Protect"])]),
                        store: store, field: Field(isDoubles: true), alreadyEvolved: false)
    boosted.mine[0].build.boosts[Stat.spAttack.rawValue] = 2
    let moonblast = boosted.mine[0].moves[at(boosted.mine[0], "Moonblast")]
    let plainRange = DamageCalc.calculate(attacker: Combatant(form: boosted.mine[0].build.form, ability: boosted.mine[0].build.ability, item: "", sp: boosted.mine[0].build.sp, alignment: boosted.mine[0].build.alignment),
                                          defender: boosted.theirs[0].build, move: moonblast, field: boosted.field)
    let boostedRange = DamageCalc.calculate(attacker: boosted.mine[0].build, defender: boosted.theirs[0].build,
                                            move: moonblast, field: boosted.field)
    var lowest = Int.max, highest = 0
    for _ in 0..<40 {
        let rolled = TurnModel.resolve(boosted,
            mine: Play(left: .attack(move: at(boosted.mine[0], "Moonblast"), target: 0),
                       right: .attack(move: at(boosted.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(boosted.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(boosted.theirs[1], "Swords Dance"), target: 0)),
            rolling: true)
        // The hit line itself, not the bar: Life Orb and the like chip at the
        // end of the turn and are not the Moonblast.
        if rolled.story.contains(where: { $0.contains("critical") }) { continue }
        if let line = rolled.story.first(where: { $0.contains("Garchomp took") }),
           let took = Int(line.split(separator: " ").first { Int($0) != nil } ?? "") {
            lowest = Swift.min(lowest, took); highest = Swift.max(highest, took)
        }
    }
    print("  +2 Moonblast: calculator \(boostedRange.minDamage)–\(boostedRange.maxDamage) (plain \(plainRange.minDamage)–\(plainRange.maxDamage)); rolled \(lowest)–\(highest)")
    check("a played hit rolls inside the boosted range, not the plain one",
          lowest >= boostedRange.minDamage && highest <= boostedRange.maxDamage && lowest > plainRange.maxDamage,
          "\(lowest)–\(highest)")

    // Prankster: a Whimsicott's Tailwind goes before a plain attack, but not
    // before a Fake Out at +3.
    var prank = boosted
    prank.mine[1].build.ability = "Prankster"
    let gusted = TurnModel.resolve(prank,
        mine: Play(left: .attack(move: at(prank.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(prank.mine[1], "Tailwind"), target: 0)),
        theirs: Play(left: .attack(move: at(prank.theirs[0], "Dragon Claw"), target: 1),
                     right: .attack(move: at(prank.theirs[1], "Swords Dance"), target: 0)))
    let windAt = gusted.story.firstIndex { $0.contains("Whimsicott used Tailwind") } ?? 99
    let clawAt = gusted.story.firstIndex { $0.contains("Garchomp used Dragon Claw") } ?? -1
    let whimSpeed = prank.mine[1].build.speed(in: prank.field), chompSpeed = prank.theirs[0].build.speed(in: prank.field)
    print("  Whimsicott \(whimSpeed) Speed, Garchomp \(chompSpeed): Tailwind at \(windAt), Dragon Claw at \(clawAt)")
    check("a Prankster's Tailwind goes before an ordinary attack", windAt < clawAt)
    // Encore: Garchomp used Dragon Claw; next turn Whimsicott holds it to that,
    // and it applies from the moment it lands.
    let firstTurn2 = TurnModel.resolve(prank,
        mine: Play(left: .attack(move: at(prank.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(prank.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(prank.theirs[0], "Dragon Claw"), target: 0),
                     right: .attack(move: at(prank.theirs[1], "Swords Dance"), target: 0)))
    let encored = TurnModel.resolve(firstTurn2,
        mine: Play(left: .attack(move: at(firstTurn2.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(firstTurn2.mine[1], "Encore"), target: 0)),
        theirs: Play(left: .attack(move: at(firstTurn2.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(firstTurn2.theirs[1], "Swords Dance"), target: 0)))
    for line in encored.story where line.contains("Encore") || line.contains("Garchomp used") { print("    \(line)") }
    check("Encore holds the target to its last move, from the moment it lands",
          encored.theirs[0].encoredFor == 2
            && encored.story.contains { $0.contains("Garchomp used Dragon Claw") }
            && encored.theirs[0].build.boosts[Stat.attack.rawValue] == 0,
          "\(encored.theirs[0].encoredFor) — \(encored.story.filter { $0.contains("Garchomp") })")
    check("and the search knows it has no choice",
          TurnGame(board: encored).choices(forMine: false, slot: 0) == [encored.theirs[0].encored!])
    // A Prankster cannot Encore a Dark type.
    let shrugged = TurnModel.resolve(firstTurn2,
        mine: Play(left: .attack(move: at(firstTurn2.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(firstTurn2.mine[1], "Encore"), target: 1)),
        theirs: Play(left: .attack(move: at(firstTurn2.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(firstTurn2.theirs[1], "Swords Dance"), target: 0)))
    check("a Prankster's Encore does not touch a Dark type",
          shrugged.theirs[1].encoredFor == 0 && shrugged.story.contains { $0.contains("Dark type") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
