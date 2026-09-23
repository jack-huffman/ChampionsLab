//  ElectroShotTests.swift
//  A two-turn move the rain lets fire at once, into a Protect.
//
//      swift test --filter ElectroShotTests
//
//  Reported as: Electro Shot from an Archaludon in the rain, into a Pokemon
//  that is protecting -- the boost and the shot should both happen on the one
//  turn, and it "goes into Protect and does no damage".
//
//  The rules part is right: the simulator raises Special Attack during the
//  charge, lets the rain skip the wait, fires, and the Protect stops the shot.
//  No damage is correct. What was wrong was the reading of it. The move line
//  for a move fired that way carries no target -- `|move|X|Electro Shot||[still]`
//  -- and the only line naming one is the `-anim` after the boost, which the
//  reader ignored. A step with no aim is played over its own user, so the shot
//  went off over the Archaludon instead of into the shield that stopped it.

import XCTest
@testable import ChampionsLab

@MainActor
final class ElectroShotTests: HarnessCase {
    private func slot(_ name: String, ability: String, _ moves: [String]) -> TeamSlot? {
        guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
        var s = TeamSlot(formID: form.id)
        s.ability = form.abilities.first { $0.name == ability }?.name ?? form.abilities.first?.name ?? ""
        s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
        s.sp = [32, 0, 0, 32, 0, 0]; s.id = UUID()
        return s
    }

    private func game(rain: Bool) throws -> ShowdownBattle? {
        guard let archaludon = slot("Archaludon", ability: "Stamina", ["Electro Shot", "Protect"]),
              let partner = slot(rain ? "Pelipper" : "Milotic", ability: rain ? "Drizzle" : "Marvel Scale",
                                 rain ? ["Protect", "Hurricane"] : ["Protect", "Scald"]),
              let milotic = slot("Milotic", ability: "Marvel Scale", ["Protect", "Scald"]),
              let incineroar = slot("Incineroar", ability: "Blaze", ["Protect", "Flare Blitz"]),
              archaludon.moves.count == 2, partner.moves.count == 2
        else { return nil }
        var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [archaludon, partner]
        var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [milotic, incineroar]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        return try ShowdownBattle.start(mine: mine, theirs: theirs, myFour: [0, 1], theirFour: [0, 1],
                                        store: store, seed: [5, 5, 5, 5])
    }

    func testInTheRainItChargesAndFiresOnOneTurnIntoTheShield() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let game = try game(rain: true) else { throw XCTSkip("the cast is not in this dex") }
        check("it is raining", game.board.field.weather == .rain, game.board.field.weather.rawValue)
        let before = game.board.theirs[0].hp
        try game.play(mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
                      theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)))
        for line in game.board.story { print("    | \(line)") }

        guard let shot = game.board.steps.first(where: { $0.action?.move == "Electro Shot" }) else {
            return check("there was an Electro Shot step", false)
        }
        check("the shot is aimed at the Pokemon it was thrown at",
              shot.action?.target == 0, "\(String(describing: shot.action?.target))")
        check("the charge raised Special Attack",
              game.board.mine[0].build.boosts[Stat.spAttack.rawValue] == 1,
              "\(game.board.mine[0].build.boosts)")
        check("the shield that stopped it flares",
              shot.blocked.contains { !$0.mine && $0.slot == 0 }, "\(shot.blocked)")
        check("and no damage, which is right: Protect stops it",
              game.board.theirs[0].hp == before)
        check("the charge says what it did",
              game.board.story.contains { $0.contains("absorbed electricity") })
        check("  and says the boost landed",
              game.board.story.contains("Archaludon's Sp. Atk rose!"),
              game.board.story.joined(separator: " | "))
        check("and it is not left winding anything next turn",
              game.board.mine[0].charging == nil)
    }

    func testWithoutRainItChargesOneTurnAndFiresTheNext() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        guard let game = try game(rain: false) else { throw XCTSkip("the cast is not in this dex") }
        let before = game.board.theirs[1].hp
        try game.play(mine: Play(left: .attack(move: 0, target: 1), right: .attack(move: 0, target: 0)),
                      theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
        check("turn one: it winds up", game.board.mine[0].charging != nil)
        check("  and the order for it is taken as read", game.board.mine[0].unusable.count >= 1
              || game.board.mine[0].charging != nil)
        let charging = game.board.mine[0].charging ?? 0
        try game.play(mine: Play(left: .attack(move: charging, target: game.board.mine[0].chargingTarget),
                                 right: .attack(move: 0, target: 0)),
                      theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)))
        check("turn two: it fires", game.board.story.contains { $0.contains("Electro Shot") })
        check("  and it is free again afterwards", game.board.mine[0].charging == nil)
        check("  and the blow landed on its target",
              game.board.theirs[1].hp < before, "\(before) -> \(game.board.theirs[1].hp)")
    }
}
