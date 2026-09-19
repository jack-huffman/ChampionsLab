//  MoveRuleTests.swift
//  Rules that belong to particular moves: the field, the wind-up, and the targets.
//
//      swift test --filter MoveRuleTests

import XCTest
@testable import ChampionsLab

final class MoveRuleTests: HarnessCase {
    /// Weather Ball and the moves the field rewrites
    @MainActor func testTheFieldDecidesTheMove() throws {
print("\n== the field decides the move ==")
    let weatherBall = store.data.moves.values.first { $0.name == "Weather Ball" }!
    let inSun = DamageCalc.fieldForm(of: weatherBall, in: Field(weather: .sun, isDoubles: true))
    let inRain = DamageCalc.fieldForm(of: weatherBall, in: Field(weather: .rain, isDoubles: true))
    let clear = DamageCalc.fieldForm(of: weatherBall, in: Field(isDoubles: true))
    print("  Weather Ball: clear \(clear.type) \(clear.power), sun \(inSun.type) \(inSun.power), rain \(inRain.type) \(inRain.power)")
    check("Weather Ball is Fire and 100 under sun", inSun.type == .fire && inSun.power == 100)
    check("Water and 100 under rain, Normal and 50 with nothing up",
          inRain.type == .water && inRain.power == 100 && clear.type == .normal && clear.power == 50)

    // -- two turns for one move, and Protect wearing thin ----------------------

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// the wind-up, the weather that waives it, and being out of reach
    @MainActor func testTwoTurnMoves() throws {
print("\n== two-turn moves ==")
    let chargers = fighters([("Kingambit", "Leftovers", ["Electro Shot", "Solar Beam", "Fly", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
    let standing = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    let chargeBoard = Board(mine: chargers, theirs: standing, rules: store.rulebook,
                            field: Field(isDoubles: true), alreadyEvolved: false)
    let eShot = at(chargeBoard.mine[0], "Electro Shot")
    let beam = at(chargeBoard.mine[0], "Solar Beam")
    let fly = at(chargeBoard.mine[0], "Fly")
    let electro = chargeBoard.mine[0].moves[eShot]
    print("  Electro Shot reads: hides \(electro.charge?.hides ?? false), skips in \(electro.charge?.skipsIn.map { "\($0)" } ?? "nothing"), boosts \(electro.charge?.boosts ?? [:])")
    check("Electro Shot is read as a two-turn move that boosts Sp. Atk and skips in rain",
          electro.charge?.skipsIn == Weather.rain && electro.charge?.boosts[Stage.spAttack] == 1 && electro.charge?.hides == false)
    // One quiet turn: the charging Pokémon does what it is told, and nothing
    // on the other side interferes with the wind-up.
    func quiet(_ board: Board, _ left: Choice) -> Board {
        TurnModel.resolve(board,
                          mine: Play(left: left, right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
                          // Rillaboom attacks rather than Protects, or the
                          // one-turn tests would be measuring its Protect.
                          theirs: Play(left: .attack(move: at(board.theirs[0], "Swords Dance"), target: 0),
                                       right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 1)))
    }
    let charged1 = quiet(chargeBoard, .attack(move: eShot, target: 1))
    for line in charged1.story where line.contains("Kingambit") { print("    \(line)") }
    let charged1SpA: Int = charged1.mine[0].build.boosts[Stat.spAttack.rawValue]
    let charged1Unhurt: Bool = charged1.theirs[1].hp == charged1.theirs[1].maxHP
    let charged1Charging: Bool = charged1.mine[0].charging == eShot
    check("with no rain, the first turn only charges: +1 Sp. Atk and no damage",
          charged1SpA == 1 && charged1Unhurt && charged1Charging,
          "spa \(charged1SpA), hp \(charged1.theirs[1].hp)/\(charged1.theirs[1].maxHP)")
    // Next turn it fires, whatever it is told to do.
    let fired = quiet(charged1, .attack(move: at(charged1.mine[0], "Protect"), target: 0))
    for line in fired.story where line.contains("Kingambit") { print("    \(line)") }
    check("the second turn fires it, even when asked to do something else",
          fired.theirs[1].hp < fired.theirs[1].maxHP && fired.mine[0].charging == nil,
          "hp \(fired.theirs[1].hp)/\(fired.theirs[1].maxHP)")
    var rainy = chargeBoard
    rainy.field.weather = .rain
    let atOnce = quiet(rainy, .attack(move: eShot, target: 1))
    for line in atOnce.story where line.contains("Kingambit") { print("    \(line)") }
    let atOnceSpA: Int = atOnce.mine[0].build.boosts[Stat.spAttack.rawValue]
    let atOnceHurt: Bool = atOnce.theirs[1].hp < atOnce.theirs[1].maxHP
    check("in rain the boost and the beam both land in one turn",
          atOnceSpA == 1 && atOnceHurt && atOnce.mine[0].charging == nil)
    var sunny = chargeBoard
    sunny.field.weather = .sun
    let solar = quiet(sunny, .attack(move: beam, target: 0))
    let solarSlow = quiet(chargeBoard, .attack(move: beam, target: 0))
    let solarHurt: Bool = solar.theirs[0].hp < solar.theirs[0].maxHP
    let solarSlowUnhurt: Bool = solarSlow.theirs[0].hp == solarSlow.theirs[0].maxHP
    check("Solar Beam fires at once in sun and charges without it",
          solarHurt && solar.mine[0].charging == nil && solarSlowUnhurt && solarSlow.mine[0].charging == beam)
    // Fly: out of reach for the turn it is up — once it is up, which means
    // it has to move first. Whimsicott outspeeds both of theirs; a Kingambit
    // would have been hit before it left the ground, as in the game.
    var flyBoard = chargeBoard
    flyBoard.mine[1].moves = [chargeBoard.mine[0].moves[fly], chargeBoard.mine[1].moves[0]]
    let flew = TurnModel.resolve(flyBoard,
        mine: Play(left: .attack(move: at(flyBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(flyBoard.theirs[0], "Earthquake"), target: 1),
                     right: .attack(move: at(flyBoard.theirs[1], "Wood Hammer"), target: 1)))
    for line in flew.story where line.contains("reach") || line.contains("Fly") { print("    \(line)") }
    check("a Pokémon in the air cannot be hit", flew.mine[1].hidden && flew.mine[1].hp == flew.mine[1].maxHP,
          "hp \(flew.mine[1].hp)/\(flew.mine[1].maxHP)")
    check("and the search offers only the finish while it is charging",
          TurnGame(board: charged1).choices(forMine: true, slot: 0) == [.attack(move: eShot, target: 1)])

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// a third of the chance each time, and the search weighing both branches
    @MainActor func testProtectWearingThin() throws {
    let chargers = fighters([("Kingambit", "Leftovers", ["Electro Shot", "Solar Beam", "Fly", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
    let standing = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    let chargeBoard = Board(mine: chargers, theirs: standing, rules: store.rulebook,
                            field: Field(isDoubles: true), alreadyEvolved: false)

print("\n== Protect wearing thin ==")
    let protect = at(chargeBoard.mine[1], "Protect")
    let once = TurnModel.resolve(chargeBoard,
        mine: Play(left: .attack(move: at(chargeBoard.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: protect)),
        theirs: Play(left: .attack(move: at(chargeBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(chargeBoard.theirs[1], "Wood Hammer"), target: 1)))
    check("the first Protect holds and starts a streak",
          once.mine[1].hp == once.mine[1].maxHP && once.mine[1].protectStreak == 1)
    let twice = TurnModel.resolve(once,
        mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: protect)),
        theirs: Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(once.theirs[1], "Wood Hammer"), target: 1)))
    for line in twice.story where line.contains("Whimsicott") { print("    \(line)") }
    check("the search takes a second Protect in a row as a failure",
          twice.mine[1].hp < twice.mine[1].maxHP && twice.mine[1].protectStreak == 0)
    var heldCount = 0
    for _ in 0..<600 {
        let rolled = TurnModel.resolve(once,
            mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                       right: .protectSelf(move: protect)),
            theirs: Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(once.theirs[1], "Protect"), target: 0)), rolling: true)
        // `protectedLast` rather than `isProtected`: the shield comes down at
        // the end of the turn it covered, so once resolve has returned, the
        // flag that still answers "did it hold" is the one the turn recorded.
        if rolled.mine[1].protectedLast { heldCount += 1 }
    }
    print("  600 second Protects in a row: \(heldCount) held (about 200 expected)")
    check("a played second Protect holds about a third of the time", heldCount > 140 && heldCount < 260, "\(heldCount)")
    var rested = once
    rested.mine[1].isProtected = false
    let afterRest = TurnModel.resolve(rested,
        mine: Play(left: .attack(move: at(rested.mine[0], "Protect"), target: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(rested.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(rested.theirs[1], "Protect"), target: 0)))
    check("a turn without Protect resets the streak", afterRest.mine[1].protectStreak == 0)
    // The search weighs a repeat Protect at its odds, not as a certain miss.
    let repeatGame = TurnGame(board: once)
    let repeatChoices = repeatGame.choices(forMine: true, slot: 1)
    check("the search still offers a second Protect, at a third",
          repeatChoices.contains { $0.isProtect }, "\(repeatChoices)")
    var thrice = once
    thrice.mine[1].protectStreak = 2
    check("but not a third one, at a ninth",
          !TurnGame(board: thrice).choices(forMine: true, slot: 1).contains { $0.isProtect })
    // Kingambit charges rather than Protects, or it would be a second chancy
    // Protect and four branches.
    let guardPlay = Play(left: .attack(move: at(once.mine[0], "Solar Beam"), target: 1),
                         right: .protectSelf(move: protect))
    let hammerPlay = Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                          right: .attack(move: at(once.theirs[1], "Wood Hammer"), target: 1))
    let branches = TurnModel.outcomes(once, mine: guardPlay, theirs: hammerPlay)
    print("  branches: " + branches.map { String(format: "%.0f%% -> Whimsicott %d/%d", $0.chance * 100, $0.board.mine[1].hp, $0.board.mine[1].maxHP) }.joined(separator: ", "))
    check("a repeat Protect is two branches, a third and two thirds",
          branches.count == 2 && abs(branches[0].chance - 2.0 / 3.0) < 0.01 && abs(branches[1].chance - 1.0 / 3.0) < 0.01)
    let blend = repeatGame.settle(guardPlay, hammerPlay).expected
    let before = Evaluation.value(once)
    let byHand = branches.reduce(0) { $0 + $1.chance * (Evaluation.value($1.board) - before) }
    let missOnly = Evaluation.value(branches[0].board) - before
    print(String(format: "  the cell is worth %+.3f blended, %+.3f if the Protect were a certain miss", blend, missOnly))
    check("and the matrix scores it as the blend", abs(blend - byHand) < 0.0001 && blend > missOnly)
    check("the engine says how likely it is to hold",
          repeatGame.describe(Choice.protectSelf(move: protect), fighter: once.mine[1], foes: [], team: once.mine).contains("33%"))

    // Feint goes through Protect and takes it down for the partner.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// through a Protect, and taking it down for the partner
    @MainActor func testFeint() throws {
print("\n== Feint ==")
    let feinters = fighters([("Whimsicott", "Focus Sash", ["Feint", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"])])
    let guardedSide = fighters([("Kingambit", "Chople Berry", ["Protect", "Iron Head"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    let feintBoard = Board(mine: feinters, theirs: guardedSide, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    let feint = at(feintBoard.mine[0], "Feint")
    check("Feint is +2 and not protectable",
          feintBoard.mine[0].moves[feint].priority == 2 && !feintBoard.mine[0].moves[feint].isProtectable
            && feintBoard.mine[0].moves[feint].breaksProtect)
    let broken = TurnModel.resolve(feintBoard,
        mine: Play(left: .attack(move: feint, target: 0),
                   right: .attack(move: at(feintBoard.mine[1], "Dragon Claw"), target: 0)),
        theirs: Play(left: .protectSelf(move: at(feintBoard.theirs[0], "Protect")),
                     right: .attack(move: at(feintBoard.theirs[1], "Protect"), target: 0)))
    for line in broken.story where line.contains("Kingambit") || line.contains("Feint") || line.contains("Dragon Claw") { print("    \(line)") }
    let feintOnly = TurnModel.resolve(feintBoard,
        mine: Play(left: .attack(move: feint, target: 0),
                   right: .attack(move: at(feintBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .protectSelf(move: at(feintBoard.theirs[0], "Protect")),
                     right: .attack(move: at(feintBoard.theirs[1], "Protect"), target: 0)))
    let feintDamage = feintOnly.theirs[0].maxHP - feintOnly.theirs[0].hp
    print("  Feint alone took \(feintDamage); with Dragon Claw after it, \(broken.theirs[0].maxHP - broken.theirs[0].hp)")
    check("Feint lands through Protect", feintDamage > 0)
    check("and the partner's move then lands on the opened target",
          broken.theirs[0].maxHP - broken.theirs[0].hp > feintDamage
            && broken.story.contains { $0.contains("broke through") })

    // A move whose target fell before its turn came turns to the one left.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// a move whose target fell before its turn came
    @MainActor func testTheTargetThatWasGone() throws {
print("\n== the target that was gone ==")
    let turners = fighters([("Whimsicott", "Focus Sash", ["Moonblast", "Protect"]),
                            ("Garchomp", "Life Orb", ["Dragon Claw", "Protect"])])
    let falling = fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                            ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var turnBoard = Board(mine: turners, theirs: falling, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    turnBoard.theirs[0].hp = 1
    let turned = TurnModel.resolve(turnBoard,
        mine: Play(left: .attack(move: at(turnBoard.mine[0], "Moonblast"), target: 0),
                   right: .attack(move: at(turnBoard.mine[1], "Dragon Claw"), target: 0)),
        theirs: Play(left: .attack(move: at(turnBoard.theirs[0], "Wood Hammer"), target: 1),
                     right: .attack(move: at(turnBoard.theirs[1], "Iron Head"), target: 0)))
    for line in turned.story where line.contains("Dragon Claw") || line.contains("turned") || line.contains("fainted") { print("    \(line)") }
    check("Whimsicott removed Rillaboom first", turned.theirs[0].fainted)
    check("and Garchomp's Dragon Claw turned to Kingambit instead of hitting nothing",
          turned.story.contains { $0.contains("turned toward Kingambit") },
          turned.story.joined(separator: " | "))

    // Being hit by the right kind of move is worth a stage to some.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Revival Blessing, aimed at your own fallen
    @MainActor func testThePartyAsATarget() throws {
print("\n== the party as a target ==")
    let revivers = fighters([("Pawmot", "Focus Sash", ["Revival Blessing", "Close Combat", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let bystanders = fighters([("Rillaboom", "Life Orb", ["Protect"]),
                               ("Incineroar", "Sitrus Berry", ["Protect"])])
    var reviveBoard = Board(mine: revivers, theirs: bystanders, rules: store.rulebook,
                            field: Field(isDoubles: true), alreadyEvolved: false)
    reviveBoard.mine[3].hp = 0        // Kingambit is down
    let blessing = at(reviveBoard.mine[0], "Revival Blessing")
    check("Revival Blessing is aimed at the party", reviveBoard.mine[0].moves[blessing].aim == .party)
    let game2 = TurnGame(board: reviveBoard)
    let offered = game2.choices(forMine: true, slot: 0)
    check("the search offers it once somebody has fainted",
          offered.contains(.attack(move: blessing, target: 3)), "\(offered)")
    let revived = TurnModel.resolve(
        reviveBoard,
        mine: Play(left: .attack(move: blessing, target: 3),
                   right: .attack(move: at(reviveBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(reviveBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(reviveBoard.theirs[1], "Protect"), target: 0)))
    for line in revived.story where line.contains("Kingambit") { print("    \(line)") }
    check("and the fallen one comes back at half its health",
          revived.mine[3].hp == revived.mine[3].maxHP / 2, "\(revived.mine[3].hp)/\(revived.mine[3].maxHP)")
    print("  described as: \(game2.describe(Choice.attack(move: blessing, target: 3), fighter: reviveBoard.mine[0], foes: Array(reviveBoard.theirs.prefix(2)), team: reviveBoard.mine))")

    // Both of theirs act every turn, and a switch is said out loud.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// hitting your own partner on purpose
    @MainActor func testTheTech() throws {
print("\n== the tech ==")
    var techBoard = Board(mine: sunPair, theirs: dragonPair, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    techBoard.mine[1].build.item = "Weakness Policy"
    let selfHit = TurnModel.resolve(techBoard,
        mine: Play(left: .attack(move: at(techBoard.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(techBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(techBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(techBoard.theirs[1], "Protect"), target: 0)))
    _ = selfHit
    var ally = techBoard
    // A small Fire move: enough to set the Policy off, not enough to remove
    // the partner, since a fainted Pokémon boosts nothing.
    ally.mine[0].moves = [store.data.moves.values.first { $0.name == "Ember" }
                          ?? store.data.moves.values.first { $0.type == "Fire" && $0.power > 0 && $0.power <= 50 }!]
                         + ally.mine[0].moves
    // The partner attacks rather than Protects, or it would block its own side.
    ally.mine[1].moves = [store.data.moves.values.first { $0.name == "Moonblast" }!] + ally.mine[1].moves
    let hitOwn = TurnModel.resolve(ally,
        mine: Play(left: Choice.attackingAlly(move: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(ally.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(ally.theirs[1], "Protect"), target: 0)))
    for line in hitOwn.story where line.contains("Whimsicott") { print("    \(line)") }
    check("a move can be aimed at your own partner",
          hitOwn.mine[1].hp < hitOwn.mine[1].maxHP && hitOwn.theirs[0].hp == hitOwn.theirs[0].maxHP,
          "\(hitOwn.mine[1].hp)/\(hitOwn.mine[1].maxHP)")
    check("and what it carries goes off — the Weakness Policy",
          hitOwn.mine[1].build.boosts[Stat.attack.rawValue] == 2, "\(hitOwn.mine[1].build.boosts)")
    print("  described as: \(TurnGame(board: ally).describe(Choice.attackingAlly(move: 0), fighter: ally.mine[0], foes: Array(ally.theirs.prefix(2)), team: ally.mine))")

    // -- dice per target, moves that give back, and a field that runs out -----

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// nothing quick reaches anything standing on a Psychic Terrain
    @MainActor func testPsychicTerrainRefusesPriority() throws {
        print("== the terrain that refuses priority ==")
        let quickOnes = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                                  ("Kingambit", "Chople Berry", ["Sucker Punch", "Iron Head", "Protect"])])
        // Garchomp carries a single-target attack as well as the Earthquake.
        // The grounded half of this case needs its partner attacking — Sucker
        // Punch is only legal into something that attacks — without that attack
        // also landing on the Pokémon whose health the check reads. An
        // Earthquake hits its own side, so it would.
        let grounded = fighters([("Indeedee (Female)", "Psychic Seed", ["Trick Room", "Dazzling Gleam", "Protect"]),
                                 ("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"])])
        var board = Board(mine: quickOnes, theirs: grounded, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.field.terrain = .psychic
        board.terrainTurns = 5
        let refused = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Fake Out"), target: 0),
                       right: .attack(move: at(board.mine[1], "Sucker Punch"), target: 1)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Trick Room"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Dragon Claw"), target: 0)))
        for line in refused.story where line.contains("Psychic Terrain") { print("    \(line)") }
        check("a Fake Out does not reach something standing on it",
              refused.theirs[0].hp == refused.theirs[0].maxHP && !refused.theirs[0].flinched,
              "\(refused.theirs[0].hp)/\(refused.theirs[0].maxHP)")
        check("and the Trick Room it was meant to stop goes up", refused.trickRoom > 0)
        check("the refusal is said out loud",
              refused.story.filter { $0.contains("Psychic Terrain refused") }.count == 2)
        // Off the ground, the terrain does nothing.
        var airborne = board
        airborne.theirs[0].build.ability = "Levitate"
        airborne.theirs[1].build.ability = "Levitate"
        let landed = TurnModel.resolve(airborne,
            mine: Play(left: .attack(move: at(airborne.mine[0], "Fake Out"), target: 0),
                       right: .attack(move: at(airborne.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(airborne.theirs[0], "Trick Room"), target: 0),
                         right: .attack(move: at(airborne.theirs[1], "Earthquake"), target: 0)))
        check("something off the ground gets no protection from it",
              landed.theirs[0].hp < landed.theirs[0].maxHP,
              "\(landed.theirs[0].hp)/\(landed.theirs[0].maxHP)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Sucker Punch needs a target that is winding up to attack
    @MainActor func testSuckerPunch() throws {
        print("== Sucker Punch ==")
        let dark = fighters([("Kingambit", "Chople Berry", ["Sucker Punch", "Iron Head", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
        let targets = fighters([("Garchomp", "Life Orb", ["Earthquake", "Swords Dance", "Protect"]),
                                ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
        let board = Board(mine: dark, theirs: targets, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let punch = at(board.mine[0], "Sucker Punch")
        func into(_ theirLeft: Choice) -> Board {
            TurnModel.resolve(board,
                mine: Play(left: .attack(move: punch, target: 0),
                           right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
                theirs: Play(left: theirLeft,
                             right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 0)))
        }
        let landed = into(.attack(move: at(board.theirs[0], "Earthquake"), target: 0))
        check("it lands on something about to attack",
              landed.theirs[0].hp < landed.theirs[0].maxHP,
              "\(landed.theirs[0].hp)/\(landed.theirs[0].maxHP)")
        let setup = into(.attack(move: at(board.theirs[0], "Swords Dance"), target: 0))
        for line in setup.story where line.contains("failed") { print("    \(line)") }
        check("and fails against something setting up",
              setup.theirs[0].hp == setup.theirs[0].maxHP && setup.story.contains { $0.contains("about to attack") })
        let guarded = into(.protectSelf(move: at(board.theirs[0], "Protect")))
        check("and against a Protect", guarded.theirs[0].hp == guarded.theirs[0].maxHP)
        check("a failed Sucker Punch is remembered as a failed move", setup.mine[0].lastMoveFailed)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// two of yours trading places, and the odds of doing it twice
    @MainActor func testAllySwitch() throws {
        print("== Ally Switch ==")
        let pair = fighters([("Indeedee (Female)", "Psychic Seed", ["Ally Switch", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"])])
        let board = Board(mine: pair, theirs: soaked, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let swapped = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Ally Switch"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Swords Dance"), target: 0)))
        for line in swapped.story where line.contains("traded places") { print("    \(line)") }
        check("the two of yours trade places",
              swapped.mine[0].build.form.formLabel == "Charizard"
                && swapped.mine[1].build.form.formLabel == "Indeedee (Female)",
              swapped.mine.prefix(2).map(\.build.form.formLabel).joined(separator: ", "))
        check("and the one that did it is on a streak", swapped.mine[1].switchStreak == 1)
        // A second in a row is a third as likely, and the search will not bet on it.
        let again = TurnModel.resolve(swapped,
            mine: Play(left: .attack(move: at(swapped.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(swapped.mine[1], "Ally Switch"), target: 0)),
            theirs: Play(left: .attack(move: at(swapped.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(swapped.theirs[1], "Swords Dance"), target: 0)))
        check("a second in a row is refused by the search",
              again.story.contains { $0.contains("33%") },
              again.story.filter { $0.contains("Indeedee") }.joined(separator: " | "))
        var held = 0
        for _ in 0..<300 {
            let rolled = TurnModel.resolve(swapped,
                mine: Play(left: .attack(move: at(swapped.mine[0], "Protect"), target: 0),
                           right: .attack(move: at(swapped.mine[1], "Ally Switch"), target: 0)),
                theirs: Play(left: .attack(move: at(swapped.theirs[0], "Swords Dance"), target: 0),
                             right: .attack(move: at(swapped.theirs[1], "Swords Dance"), target: 0)),
                rolling: true)
            if rolled.story.contains(where: { $0.contains("traded places") }) { held += 1 }
        }
        print("  300 second Ally Switches: \(held) worked (about 100 expected)")
        check("and about a third of them work when played", held > 55 && held < 150, "\(held)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// a move the terrain doubles
    @MainActor func testRisingVoltage() throws {
        print("== Rising Voltage ==")
        guard let bolt = store.data.moves.values.first(where: { $0.name == "Rising Voltage" }) else {
            print("  (not in this format)"); return
        }
        let user = Combatant(form: form("Pawmot"), ability: "Volt Absorb", item: "",
                             sp: Array(repeating: 0, count: 6), alignment: .neutral)
        // Not a Ground type: an Electric move into one of those is nothing at
        // all, doubled or otherwise.
        var target = Combatant(form: form("Politoed"), ability: "Drizzle", item: "",
                               sp: Array(repeating: 0, count: 6), alignment: .neutral)
        let plainField = Field(isDoubles: true)
        let charged = Field(terrain: .electric, isDoubles: true)
        let flat = DamageCalc.calculate(attacker: user, defender: target, move: bolt, field: plainField).maxDamage
        let lit = DamageCalc.calculate(attacker: user, defender: target, move: bolt, field: charged).maxDamage
        print("  Rising Voltage: \(flat) on bare ground, \(lit) on Electric Terrain")
        check("it doubles into something standing in the charge", lit > flat * 2, "\(flat) vs \(lit)")
        target.ability = "Levitate"
        let floating = DamageCalc.calculate(attacker: user, defender: target, move: bolt, field: charged).maxDamage
        check("and not into something off the ground", floating < lit, "\(floating) vs \(lit)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// the support moves a doubles format is actually played with
    @MainActor func testTheSupportMoves() throws {
        print("== the support moves ==")
        let helpers = fighters([("Whimsicott", "Focus Sash",
                                 ["Quick Guard", "Coaching", "Leech Seed", "Taunt"]),
                                ("Garchomp", "Life Orb", ["Dragon Claw", "Swords Dance", "Protect"])])
        let quick = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                              ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
        let board = Board(mine: helpers, theirs: quick, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        // Quick Guard turns away what moves first.
        let guarded = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Quick Guard"), target: 0),
                       right: .attack(move: at(board.mine[1], "Swords Dance"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Fake Out"), target: 1),
                         right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 1)))
        for line in guarded.story where line.contains("Quick Guard") { print("    \(line)") }
        check("Quick Guard turns away a Fake Out",
              !guarded.mine[1].flinched && guarded.mine[1].build.boosts[Stat.attack.rawValue] == 2,
              "flinched \(guarded.mine[1].flinched)")
        check("and lets an ordinary attack through",
              guarded.mine[1].hp < board.mine[1].maxHP, "\(guarded.mine[1].hp)/\(board.mine[1].maxHP)")

        // Coaching is the partner's two stages.
        let coached = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Coaching"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Protect"), target: 0)))
        check("Coaching raises the partner's Attack and Defence",
              coached.mine[1].build.boosts[Stat.attack.rawValue] == 1
                && coached.mine[1].build.boosts[Stat.defense.rawValue] == 1,
              "\(coached.mine[1].build.boosts)")

        // Leech Seed drains across the field and heals the thrower's slot.
        // Against Garchomp, not Incineroar: Whimsicott has Prankster, and a
        // Prankster's status move does not touch a Dark type at all.
        var seedBoard = Board(mine: helpers, theirs: soaked, rules: store.rulebook,
                              field: Field(isDoubles: true), alreadyEvolved: false)
        seedBoard.mine[0].hp = seedBoard.mine[0].maxHP / 2
        let seeded = TurnModel.resolve(seedBoard,
            mine: Play(left: .attack(move: at(seedBoard.mine[0], "Leech Seed"), target: 0),
                       right: .attack(move: at(seedBoard.mine[1], "Protect"), target: 0)),
            // Attacking, not Protecting: a seed thrown at a Protect bounces.
            theirs: Play(left: .attack(move: at(seedBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(seedBoard.theirs[1], "Swords Dance"), target: 0)))
        for line in seeded.story where line.contains("seed") { print("    \(line)") }
        check("the seed takes hold and drains the same turn",
              seeded.theirs[0].seededFrom == 0 && seeded.theirs[0].hp < seedBoard.theirs[0].maxHP,
              "\(seeded.theirs[0].hp)/\(seeded.theirs[0].maxHP)")
        check("and what it drains comes back",
              seeded.mine[0].hp > seedBoard.mine[0].hp,
              "\(seedBoard.mine[0].hp) -> \(seeded.mine[0].hp)")
        // Grass shrugs it off, and so does a Dark type facing a Prankster.
        var grassy = Board(mine: helpers, theirs: standing, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        grassy.mine[0].build.ability = "Infiltrator"     // not Prankster, so the Dark rule is not what is being tested
        let refused = TurnModel.resolve(grassy,
            mine: Play(left: .attack(move: at(grassy.mine[0], "Leech Seed"), target: 1),
                       right: .attack(move: at(grassy.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(grassy.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(grassy.theirs[1], "Wood Hammer"), target: 1)))
        for line in refused.story where line.contains("Grass type") { print("    \(line)") }
        check("a Grass type cannot be seeded", refused.theirs[1].seededFrom == nil)

        // Taunt: nothing but attacks.
        // Rillaboom, not Incineroar: the Prankster rule again.
        let taunted = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Taunt"), target: 1),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Flare Blitz"), target: 1),
                         right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 1)))
        check("Taunt lands", taunted.theirs[1].tauntedFor > 0, "\(taunted.theirs[1].tauntedFor)")
        let silenced = TurnModel.resolve(taunted,
            mine: Play(left: .attack(move: at(taunted.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(taunted.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(taunted.theirs[0], "Flare Blitz"), target: 0),
                         right: .attack(move: at(taunted.theirs[1], "Protect"), target: 0)))
        for line in silenced.story where line.contains("taunted") { print("    \(line)") }
        check("and a taunted Pokémon cannot Protect",
              !silenced.theirs[1].isProtected
                && silenced.story.contains { $0.contains("still taunted") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Parting Shot, Endure and Focus Energy
    @MainActor func testPivotsAndBracing() throws {
        print("== pivots and bracing ==")
        let pivots = fighters([("Incineroar", "Sitrus Berry", ["Parting Shot", "Endure", "Flare Blitz"]),
                               ("Whimsicott", "Focus Sash", ["Protect"]),
                               ("Garchomp", "Life Orb", ["Dragon Claw", "Protect"])])
        let board = Board(mine: pivots, theirs: soaked, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let shot = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Parting Shot"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Swords Dance"), target: 0)))
        for line in shot.story where line.contains("came in") || line.contains("fell") { print("    \(line)") }
        check("Parting Shot takes two stages off the target",
              shot.theirs[0].build.boosts[Stat.attack.rawValue] == 1
                && shot.theirs[0].build.boosts[Stat.spAttack.rawValue] == -1,
              "\(shot.theirs[0].build.boosts)")
        check("and the user leaves",
              shot.mine[0].build.form.formLabel == "Garchomp" && shot.mine[0].seen,
              shot.mine[0].build.form.formLabel)

        // Endure: one health point, not none.
        var doomed = Board(mine: pivots, theirs: standing, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        doomed.mine[0].hp = 1
        doomed.mine[0].build.item = ""      // no berry to do Endure's job for it
        let endured = TurnModel.resolve(doomed,
            mine: Play(left: .attack(move: at(doomed.mine[0], "Endure"), target: 0),
                       right: .attack(move: at(doomed.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(doomed.theirs[0], "Earthquake"), target: 0),
                         right: .attack(move: at(doomed.theirs[1], "Wood Hammer"), target: 0)),
            rolling: true)
        for line in endured.story where line.contains("endured") { print("    \(line)") }
        check("Endure leaves it on one health point", endured.mine[0].hp == 1 && !endured.mine[0].fainted,
              "\(endured.mine[0].hp)")
        check("and wears off at the end of the turn", !endured.mine[0].enduring)

        // Focus Energy: every hit a critical, at three stages.
        var eager = board
        eager.mine[0].critStage = 3
        var crits = 0
        for _ in 0..<40 {
            let rolled = TurnModel.resolve(eager,
                mine: Play(left: .attack(move: at(eager.mine[0], "Flare Blitz"), target: 0),
                           right: .attack(move: at(eager.mine[1], "Protect"), target: 0)),
                theirs: Play(left: .attack(move: at(eager.theirs[0], "Swords Dance"), target: 0),
                             right: .attack(move: at(eager.theirs[1], "Swords Dance"), target: 0)),
                rolling: true)
            if rolled.story.contains(where: { $0.contains("critical") }) { crits += 1 }
        }
        print("  40 hits at three stages of crit ratio: \(crits) critical")
        check("three stages of crit ratio is every hit", crits == 40, "\(crits)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
