//  SharpnessTests.swift
//  Mega Absol Z's Sharpness, and whether it reaches the move.
//
//      swift test --filter SharpnessTests
//
//  Three things have to line up for an ability like this and only the first is
//  obvious: the form has to carry the ability, the move has to carry the flag,
//  and the Pokémon has to be in its Mega form by the time the damage is worked
//  out. A Mega ability that only exists after evolving is the sort of thing
//  that looks implemented and does nothing.

import XCTest
@testable import ChampionsLab

final class SharpnessTests: HarnessCase {
    @MainActor func testSharpnessBoostsSlicingMoves() throws {
print("\n== the parts ==")
        let absol = form("Mega Absol Z")
        check("Mega Absol Z has Sharpness",
              absol.abilities.contains { $0.name == "Sharpness" },
              absol.abilities.map(\.name).joined(separator: ", "))
        let night = store.data.moves.values.first { $0.name == "Night Slash" }
        check("Night Slash is flagged slicing", night?.isSlicing == true)
        let sucker = store.data.moves.values.first { $0.name == "Sucker Punch" }
        check("Sucker Punch is not", sucker?.isSlicing == false)

print("\n== and what it does to the number ==")
        guard let night, let sucker else { XCTFail("missing moves"); return }
        let target = form("Garchomp")
        var sp = Array(repeating: 0, count: 6)
        sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32
        let defender = Combatant(form: target, ability: "Rough Skin", item: "",
                                 sp: sp, alignment: .neutral)
        func hit(_ ability: String, _ move: Move) -> Int {
            let attacker = Combatant(form: absol, ability: ability, item: "",
                                     sp: sp, alignment: Alignment.named("Adamant"))
            return DamageCalc.calculate(attacker: attacker, defender: defender,
                                        move: move, field: Field(isDoubles: true)).maxDamage
        }
        let sharp = hit("Sharpness", night), blunt = hit("Pressure", night)
        print(String(format: "  Night Slash: %d with Sharpness, %d without", sharp, blunt))
        check("a slicing move hits half again as hard",
              Double(sharp) / Double(Swift.max(1, blunt)) > 1.4,
              String(format: "%.2fx", Double(sharp) / Double(blunt)))

        let punchSharp = hit("Sharpness", sucker), punchBlunt = hit("Pressure", sucker)
        check("a move that does not slice is untouched",
              punchSharp == punchBlunt, "\(punchSharp) against \(punchBlunt)")

print("\n== and it is there in a real battle ==")
        // The way the app actually registers one: the picker writes the Mega
        // form's own id into the slot and fills in the stone, so the slot *is*
        // Mega Absol Z rather than an Absol that might become one.
        var team = Team(); team.format = "doubles"
        var slot = TeamSlot(formID: absol.id)
        slot.item = absol.megaStone.isEmpty ? "Mega Stone" : absol.megaStone
        slot.ability = absol.abilities.first?.name ?? ""
        slot.moves = [night.id, sucker.id]
        slot.sp = sp; slot.alignmentName = "Adamant"
        var second = TeamSlot(formID: form("Whimsicott").id)
        second.ability = "Prankster"
        second.moves = [store.data.moves.values.first { $0.name == "Moonblast" }!.id]
        second.sp = sp; second.alignmentName = "Timid"
        team.slots = [slot, second]
        // Built bulky on purpose. The shared fixture puts two points in health,
        // so Night Slash kills whatever it touches and the damage is capped at
        // the health bar — which measures the bar, not the ability.
        var theirs = fighters([("Garchomp", "Leftovers", ["Earthquake", "Protect"]),
                               ("Milotic", "Leftovers", ["Surf", "Protect"])])
        var bulky = Array(repeating: 0, count: 6)
        bulky[Stat.hp.rawValue] = 32
        bulky[Stat.defense.rawValue] = 32
        for index in theirs.slots.indices {
            theirs.slots[index].sp = bulky
            theirs.slots[index].alignmentName = "Bold"
        }
        var board = Board(mine: team, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        check("it is on the field as the Mega",
              board.mine[0].build.form.formLabel == "Mega Absol Z",
              board.mine[0].build.form.formLabel)
        check("holding Sharpness", board.mine[0].build.ability == "Sharpness",
              board.mine[0].build.ability)

        // And the boost reaches the move in a played turn, not only in the
        // calculator: the same Night Slash with and without the ability.
        var blunted = board
        blunted.mine[0].build.ability = "Pressure"
        func damageDone(_ from: Board) -> Int {
            // Nobody may Protect, or the move lands on nothing and both sides
            // of the comparison are zero.
            // Only Absol attacks, and its partner passes: with both of them on
            // the same target it faints either way and the difference is its
            // whole health bar rather than the move.
            let after = TurnModel.resolve(from,
                mine: Play(left: .attack(move: 0, target: 1), right: .pass),
                theirs: Play(left: .attack(move: at(from.theirs[0], "Earthquake"), target: 0),
                             right: .attack(move: at(from.theirs[1], "Surf"), target: 0)))
            return from.theirs[1].hp - after.theirs[1].hp
        }
        print("  target maxHP \(board.theirs[1].maxHP), attacker ability "
              + "\(board.mine[0].build.ability) vs \(blunted.mine[0].build.ability)")
        print("  move 0 is \(board.mine[0].moves.first?.name ?? "none")")
        let withIt = damageDone(board), withoutIt = damageDone(blunted)
        print("  Night Slash in a turn: \(withIt) with Sharpness, \(withoutIt) without")
        check("the turn applies it too",
              Double(withIt) / Double(Swift.max(1, withoutIt)) > 1.3,
              String(format: "%.2fx", Double(withIt) / Double(Swift.max(1, withoutIt))))

print("\n== and a base Absol can reach either of them ==")
        // Absol has two Megas and Serebii has published a stone for only one,
        // so the other needs a trigger of its own or nothing can ever turn
        // into it.
        let base = form("Absol")
        let plain = store.rulebook.megaForm(for: base, holding: "Absolite")
        check("Absolite still gives the ordinary one",
              plain?.formLabel == "Mega Absol", plain?.formLabel ?? "nothing")
        let zed = store.rulebook.megaForm(for: base, holding: absol.megaTrigger)
        print("  base Absol holding \(absol.megaTrigger) becomes: \(zed?.formLabel ?? "nothing")")
        check("and the Z form has a trigger of its own",
              zed?.formLabel == "Mega Absol Z", zed?.formLabel ?? "nothing")
        check("which is not the published stone", absol.megaTrigger != "Absolite")

        // Every Mega in the game has to be reachable, or it is a Pokémon
        // nobody can play.
        // From *some* form of its species, not from the first one: only
        // Floette (Eternal) may Mega Evolve, and an ordinary Floette correctly
        // cannot, so asking the plain form would call that a fault.
        var unreachable: [String] = []
        for mega in store.data.forms where mega.isMega {
            let roots = store.data.forms.filter { $0.dex == mega.dex && !$0.isMega }
            let reachable = roots.contains {
                store.rulebook.megaForm(for: $0, holding: mega.megaTrigger)?.id == mega.id
            }
            if !reachable { unreachable.append(mega.formLabel) }
        }
        for name in unreachable.prefix(8) { print("    unreachable: \(name)") }
        check("every Mega can be reached from its base form",
              unreachable.isEmpty, "\(unreachable.count) of "
              + "\(store.data.forms.filter(\.isMega).count)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
