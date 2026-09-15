//  StatusTests.swift
//  Conditions: the ones a hit leaves behind, the ones that wear off, and the ones that heal.
//
//      swift test --filter StatusTests

import XCTest
@testable import ChampionsLab

final class StatusTests: HarnessCase {
    /// burns, paralysis, flinches and the stages a hit takes off
    @MainActor func testWhatAHitDoesBesidesDamage() throws {
print("\n== what a hit does besides damage ==")
    let icy = fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect"]),
                        ("Milotic", "Leftovers", ["Scald", "Protect"])])
    let chilled = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Protect"]),
                            ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])])
    let icyBoard = Board(mine: icy, theirs: chilled, rules: store.rulebook,
                         field: Field(isDoubles: true), alreadyEvolved: false)
    let windy = TurnModel.resolve(icyBoard,
        mine: Play(left: .attack(move: at(icyBoard.mine[0], "Icy Wind"), target: 0),
                   right: .attack(move: at(icyBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)))
    for line in windy.story where line.contains("Spe") { print("    \(line)") }
    check("Icy Wind takes a stage of Speed off both",
          windy.theirs[0].build.boosts[Stat.speed.rawValue] == -1 && windy.theirs[1].build.boosts[Stat.speed.rawValue] == -1,
          "\(windy.theirs[0].build.boosts[Stat.speed.rawValue]) / \(windy.theirs[1].build.boosts[Stat.speed.rawValue])")
    let scald = store.data.moves.values.first { $0.name == "Scald" }!
    let nuzzle = store.data.moves.values.first { $0.name == "Nuzzle" }!
    let slide = store.data.moves.values.first { $0.name == "Rock Slide" }!
    check("secondary effects are read from the text",
          scald.secondary?.chance == 30 && nuzzle.secondary?.chance == 100 && slide.secondary?.chance == 30)
    var burns = 0
    for _ in 0..<300 {
        let rolled = TurnModel.resolve(icyBoard,
            mine: Play(left: .attack(move: at(icyBoard.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(icyBoard.mine[1], "Scald"), target: 0)),
            theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)), rolling: true)
        if rolled.theirs[0].status == .burn { burns += 1 }
    }
    print("  300 Scalds: \(burns) burns (about 90 expected)")
    check("Scald burns about three times in ten", burns > 55 && burns < 130, "\(burns)")
    let averaged2 = TurnModel.resolve(icyBoard,
        mine: Play(left: .attack(move: at(icyBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(icyBoard.mine[1], "Scald"), target: 0)),
        theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)))
    check("and the search does not count on it", averaged2.theirs[0].status == .none)
    var nuzzleBoard = icyBoard
    nuzzleBoard.mine[0].moves = [nuzzle] + nuzzleBoard.mine[0].moves
    // Into Kingambit: Garchomp is Ground and Nuzzle would not touch it.
    let zapped = TurnModel.resolve(nuzzleBoard,
        mine: Play(left: .attack(move: 0, target: 1),
                   right: .attack(move: at(nuzzleBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(nuzzleBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(nuzzleBoard.theirs[1], "Swords Dance"), target: 0)))
    check("Nuzzle paralyses every time, even for the search", zapped.theirs[1].status == .paralysis,
          "\(zapped.theirs[1].status)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Recover and its kind
    @MainActor func testGettingHealthBack() throws {
print("\n== getting health back ==")
    let recover = store.data.moves.values.first { $0.name == "Recover" }!
    let synthesis = store.data.moves.values.first { $0.name == "Synthesis" }!
    let pulse = store.data.moves.values.first { $0.name == "Heal Pulse" }!
    check("healing moves are read from the text",
          recover.healing?.share == 0.5 && synthesis.healing?.sunlit == true && pulse.healing?.whom == .partner)
    var tired = Board(mine: fighters([("Milotic", "Leftovers", ["Recover", "Protect"]),
                                      ("Whimsicott", "Focus Sash", ["Protect"])]),
                      theirs: chilled, rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    tired.mine[0].hp = tired.mine[0].maxHP / 5
    let recovered = TurnModel.resolve(tired,
        mine: Play(left: .attack(move: at(tired.mine[0], "Recover"), target: 0),
                   right: .attack(move: at(tired.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tired.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(tired.theirs[1], "Swords Dance"), target: 0)))
    for line in recovered.story where line.contains("recovered") { print("    \(line)") }
    let expected = tired.mine[0].hp + tired.mine[0].maxHP / 2
    print("  Milotic \(tired.mine[0].hp) -> \(recovered.mine[0].hp) of \(tired.mine[0].maxHP) (Leftovers adds a sixteenth at the end)")
    check("Recover restores half the bar",
          recovered.mine[0].hp >= expected && recovered.mine[0].hp <= expected + tired.mine[0].maxHP / 16 + 1,
          "\(recovered.mine[0].hp) vs \(expected)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// two to five turns, one action in three into its own face
    @MainActor func testConfusion() throws {
print("\n== confusion ==")
    let confuseRay = store.data.moves.values.first { $0.name == "Confuse Ray" }!
    let swagger = store.data.moves.values.first { $0.name == "Swagger" }!
    check("confusing moves are read from the text",
          confuseRay.confuses && swagger.confuses && swagger.targetBoosts[Stat.attack] == 2
            && store.data.moves.values.first { $0.name == "Water Pulse" }?.secondary?.chance == 20)
    var dazed = Board(mine: fighters([("Whimsicott", "Focus Sash", ["Confuse Ray", "Protect"]),
                                      ("Milotic", "Leftovers", ["Protect"])]),
                      theirs: chilled, rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    dazed.mine[0].moves = [confuseRay] + dazed.mine[0].moves
    let rayed = TurnModel.resolve(dazed,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(dazed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(dazed.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(dazed.theirs[1], "Swords Dance"), target: 0)))
    for line in rayed.story where line.contains("confus") { print("    \(line)") }
    check("Confuse Ray leaves the target confused", rayed.theirs[0].isConfused, "\(rayed.theirs[0].confusedFor)")
    // Over many rolled turns, a confused Pokémon hurts itself about a third of the time.
    var selfHits = 0, turnsConfused = 0
    for _ in 0..<300 {
        var still = rayed
        still.theirs[0].confusedFor = 5
        let rolled = TurnModel.resolve(still,
            mine: Play(left: .attack(move: at(still.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(still.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(still.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(still.theirs[1], "Swords Dance"), target: 0)), rolling: true)
        turnsConfused += 1
        if rolled.story.contains(where: { $0.contains("hurt itself") }) { selfHits += 1 }
    }
    print("  300 confused turns: \(selfHits) went into its own face (about 100 expected)")
    check("a confused Pokémon hurts itself about one time in three", selfHits > 65 && selfHits < 140, "\(selfHits)")
    let averaged3 = TurnModel.resolve(rayed,
        mine: Play(left: .attack(move: at(rayed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(rayed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(rayed.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(rayed.theirs[1], "Swords Dance"), target: 0)))
    check("the search lets it act, and the count runs down",
          averaged3.theirs[0].confusedFor == rayed.theirs[0].confusedFor - 1
            && averaged3.theirs[0].build.boosts[Stat.attack.rawValue] == rayed.theirs[0].build.boosts[Stat.attack.rawValue] + 2)
    var leaving = rayed
    leaving.theirs.append(rayed.theirs[1])
    let switched = TurnModel.resolve(leaving,
        mine: Play(left: .attack(move: at(leaving.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(leaving.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .swap(to: 2),
                     right: .attack(move: at(leaving.theirs[1], "Swords Dance"), target: 0)))
    check("switching out clears it", !switched.theirs[2].isConfused)
    var tempo = dazed
    tempo.theirs[0].build.ability = "Own Tempo"
    let unbothered = TurnModel.resolve(tempo,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(tempo.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tempo.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(tempo.theirs[1], "Swords Dance"), target: 0)))
    check("Own Tempo refuses it", !unbothered.theirs[0].isConfused)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
