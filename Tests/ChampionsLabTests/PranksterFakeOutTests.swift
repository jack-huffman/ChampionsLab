//  PranksterFakeOutTests.swift
//  What Prankster does and does not beat.
//
//      swift test --filter PranksterFakeOutTests
//
//  Prankster adds one stage of priority to a status move. Fake Out is +3. So a
//  Prankster Tailwind at +1 does not go first, and a Whimsicott that leads into
//  an Incineroar gets flinched — which is the whole reason Fake Out leads are
//  played. It is not a bug and this says so in a way that stays said.
//
//  The things that do beat it are also here, because "your setup is stopped" is
//  only useful next to "and this is what stops it being stopped".

import XCTest
@testable import ChampionsLab

final class PranksterFakeOutTests: HarnessCase {
    @MainActor private func board(mine: Team, theirs: Team,
                                  terrain: Terrain = .none) -> Board {
        var out = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                        field: Field(isDoubles: true), alreadyEvolved: false)
        out.field.terrain = terrain
        if terrain != .none { out.terrainTurns = 5 }
        return out
    }

    @MainActor func testPranksterDoesNotOutrunFakeOut() throws {
print("\n== the arithmetic ==")
        let mine = fighters([("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
        let theirs = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                               ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])])
        var start = board(mine: mine, theirs: theirs)
        check("Whimsicott actually has Prankster",
              start.mine[0].build.ability == "Prankster", start.mine[0].build.ability)

        let tail = at(start.mine[0], "Tailwind")
        let fake = at(start.theirs[0], "Fake Out")
        check("Tailwind is priority 0 before the ability",
              start.mine[0].moves[tail].priority == 0,
              "\(start.mine[0].moves[tail].priority)")
        check("Fake Out is priority 3", start.theirs[0].moves[fake].priority == 3,
              "\(start.theirs[0].moves[fake].priority)")

print("\n== so the Fake Out lands ==")
        let flinched = TurnModel.resolve(start,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("no Tailwind went up", flinched.myTailwind == 0,
              "\(flinched.myTailwind)")
        check("and Whimsicott took the hit", flinched.mine[0].hp < flinched.mine[0].maxHP,
              "\(flinched.mine[0].hp)/\(flinched.mine[0].maxHP)")
        for line in flinched.story where line.contains("Whimsicott") || line.contains("flinch") {
            print("    \(line)")
        }

print("\n== but only on the turn it arrives ==")
        // Second turn out: Fake Out is spent, and the Tailwind goes up.
        var later = start
        later.theirs[0].justArrived = false
        later.theirs[0].arrivedThisTurn = false
        let settled = TurnModel.resolve(later,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("Fake Out does nothing once it has been out a turn",
              settled.myTailwind > 0, "\(settled.myTailwind)")

print("\n== and Prankster does beat anything without priority ==")
        let plain = TurnModel.resolve(start,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Flare Blitz"), target: 0),
                         right: .protectSelf(move: 1)))
        check("Tailwind goes up ahead of a Flare Blitz", plain.myTailwind > 0,
              "\(plain.myTailwind)")

print("\n== what actually stops a Fake Out ==")
        // Psychic Terrain: nothing with priority reaches a grounded target.
        var psychic = board(mine: mine, theirs: theirs, terrain: .psychic)
        psychic.mine[0].build.ability = "Prankster"
        let refused = TurnModel.resolve(psychic,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("Psychic Terrain refuses it and the Tailwind goes up",
              refused.myTailwind > 0, "\(refused.myTailwind)")

        // A priority-blocking ability on the partner does the same.
        var guarded = board(mine: mine, theirs: theirs)
        guarded.mine[1].build.ability = "Armor Tail"
        let blocked = TurnModel.resolve(guarded,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("a priority blocker on the partner does it too",
              blocked.myTailwind > 0, "\(blocked.myTailwind)")

print("\n== and the things that refuse the flinch ==")
        // Covert Cloak stops secondary effects, and Fake Out's flinch is one —
        // a 100% secondary rather than part of the damage. Blocking it is most
        // of why the item is worn.
        var cloaked = board(mine: mine, theirs: theirs)
        cloaked.mine[0].build.item = "Covert Cloak"
        let shrugged = TurnModel.resolve(cloaked,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("a Covert Cloak takes the hit and still sets the Tailwind",
              shrugged.myTailwind > 0, "\(shrugged.myTailwind)")
        check("and it did take the damage", shrugged.mine[0].hp < shrugged.mine[0].maxHP,
              "\(shrugged.mine[0].hp)/\(shrugged.mine[0].maxHP)")

        var focused = board(mine: mine, theirs: theirs)
        focused.mine[0].build.ability = "Inner Focus"
        let unmoved = TurnModel.resolve(focused,
            mine: Play(left: .attack(move: tail, target: 0), right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: fake, target: 0), right: .protectSelf(move: 1)))
        check("Inner Focus does too", unmoved.myTailwind > 0, "\(unmoved.myTailwind)")

print("\n== and it is announced once ==")
        let said = flinched.story.filter { $0.contains("flinched") }
        for line in said { print("    \(line)") }
        check("the flinch is said once, not three times", said.count == 1,
              "\(said.count) lines")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
