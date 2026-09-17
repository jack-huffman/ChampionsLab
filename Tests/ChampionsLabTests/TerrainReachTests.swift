//  TerrainReachTests.swift
//  A terrain only reaches what is standing on it.
//
//      swift test --filter TerrainReachTests
//
//  All four terrains are floors. A Flying type, a Levitate and an Air Balloon
//  are all above one, so none of them gets the healing, the protection or the
//  immunity — a Staraptor takes a Fake Out on Psychic Terrain like anywhere
//  else.
//
//  This was written out inline in five places with four different answers. One
//  forgot the balloon, one forgot Levitate as well, one read a Pokémon's
//  printed types rather than the ones it has after a Soak, one had no check at
//  all — and the Psychic Terrain shield was granted if *anything* on that side
//  was grounded, so a Staraptor was protected by its partner's feet. One rule
//  now, on the Pokémon, and these hold it to it.

import XCTest
@testable import ChampionsLab

final class TerrainReachTests: HarnessCase {
    @MainActor private func board(_ mine: Team, _ theirs: Team, _ terrain: Terrain) -> Board {
        var out = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                        field: Field(isDoubles: true), alreadyEvolved: false)
        out.field.terrain = terrain
        out.terrainTurns = 5
        return out
    }

    @MainActor func testTerrainOnlyReachesTheGrounded() throws {
print("\n== Psychic Terrain and a Pokémon in the air ==")
        // Staraptor is Normal/Flying, so the floor is not its problem.
        let airborne = fighters([("Staraptor", "Focus Sash", ["Brave Bird", "Protect"]),
                                 ("Sinistcha", "Sitrus Berry", ["Spore", "Protect"])])
        let fakers = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                               ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])])
        var up = board(airborne, fakers, .psychic)
        check("Staraptor is not standing on it", !up.mine[0].isGrounded)
        check("its partner is", up.mine[1].isGrounded)

        // Aimed at the Staraptor. Its grounded partner must not shield it.
        let hit = TurnModel.resolve(up,
            mine: Play(left: .attack(move: at(up.mine[0], "Brave Bird"), target: 0),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(up.theirs[0], "Fake Out"), target: 0),
                         right: .protectSelf(move: 1)))
        check("a Fake Out reaches it anyway",
              hit.mine[0].hp < hit.mine[0].maxHP,
              "\(hit.mine[0].hp)/\(hit.mine[0].maxHP)")
        for line in hit.story where line.contains("Psychic Terrain") { print("    \(line)") }

        // Aimed at the grounded one, the terrain does its job.
        let refused = TurnModel.resolve(up,
            mine: Play(left: .protectSelf(move: 1),
                       right: .attack(move: at(up.mine[1], "Spore"), target: 0)),
            theirs: Play(left: .attack(move: at(up.theirs[0], "Fake Out"), target: 1),
                         right: .protectSelf(move: 1)))
        check("and is refused when aimed at the one on the floor",
              refused.mine[1].hp == refused.mine[1].maxHP,
              "\(refused.mine[1].hp)/\(refused.mine[1].maxHP)")

print("\n== what counts as being off the ground ==")
        up.mine[1].build.ability = "Levitate"
        check("a Levitate is off it", !up.mine[1].isGrounded)
        up.mine[1].build.ability = "Effect Spore"
        up.mine[1].build.item = "Air Balloon"
        check("and so is an Air Balloon", !up.mine[1].isGrounded)

print("\n== Grassy Terrain tops up only what is on the grass ==")
        var grassy = board(airborne, fakers, .grassy)
        grassy.mine[0].hp = grassy.mine[0].maxHP / 2      // Staraptor, flying
        grassy.mine[1].hp = grassy.mine[1].maxHP / 2      // Amoonguss, grounded
        grassy.mine[1].build.item = "Air Balloon"
        let grown = TurnModel.resolve(grassy,
            mine: Play(left: .protectSelf(move: 1), right: .protectSelf(move: 1)),
            theirs: Play(left: .protectSelf(move: 2), right: .protectSelf(move: 1)))
        check("a Flying type is not healed by it",
              grown.mine[0].hp == grassy.mine[0].hp,
              "\(grown.mine[0].hp) from \(grassy.mine[0].hp)")
        check("nor is a balloon holder",
              grown.mine[1].hp == grassy.mine[1].hp,
              "\(grown.mine[1].hp) from \(grassy.mine[1].hp)")

        var onGrass = board(airborne, fakers, .grassy)
        onGrass.mine[1].hp = onGrass.mine[1].maxHP / 2
        let healed = TurnModel.resolve(onGrass,
            mine: Play(left: .protectSelf(move: 1), right: .protectSelf(move: 1)),
            theirs: Play(left: .protectSelf(move: 2), right: .protectSelf(move: 1)))
        check("but something actually standing on it is",
              healed.mine[1].hp > onGrass.mine[1].hp,
              "\(healed.mine[1].hp) from \(onGrass.mine[1].hp)")

print("\n== Electric Terrain keeps awake only what it can reach ==")
        // Amoonguss Spores the Staraptor, which is in the air and therefore
        // still sleepable however charged the floor is.
        let sleepy = fighters([("Sinistcha", "Sitrus Berry", ["Spore", "Protect"]),
                               ("Rillaboom", "Assault Vest", ["Wood Hammer", "Protect"])])
        let targets = fighters([("Staraptor", "Focus Sash", ["Brave Bird", "Protect"]),
                                ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"])])
        let charged = board(sleepy, targets, .electric)
        // Neither of theirs may Protect: a Protect stops a Spore, and the
        // question here is the terrain rather than the shield.
        let slept = TurnModel.resolve(charged,
            mine: Play(left: .attack(move: at(charged.mine[0], "Spore"), target: 0),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(charged.theirs[0], "Brave Bird"), target: 1),
                         right: .attack(move: at(charged.theirs[1], "Flare Blitz"), target: 1)))
        check("a Flying type still falls asleep on it",
              slept.theirs[0].status == .sleep, "\(slept.theirs[0].status)")

        let grounded = TurnModel.resolve(charged,
            mine: Play(left: .attack(move: at(charged.mine[0], "Spore"), target: 1),
                       right: .protectSelf(move: 1)),
            theirs: Play(left: .attack(move: at(charged.theirs[0], "Brave Bird"), target: 1),
                         right: .attack(move: at(charged.theirs[1], "Flare Blitz"), target: 1)))
        check("and something on the floor does not",
              grounded.theirs[1].status != .sleep, "\(grounded.theirs[1].status)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
