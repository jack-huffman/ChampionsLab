//  SecondaryEffectTests.swift
//  The part of a move that is not the damage.
//
//      swift test --filter SecondaryEffectTests

import XCTest
@testable import ChampionsLab

final class SecondaryEffectTests: HarnessCase {
    @MainActor private func move(_ name: String) -> Move {
        store.data.moves.values.first { $0.name == name }!
    }

    /// Every legal move's secondary effects come from the reference table
    /// rather than from guessing at Serebii's English.
    ///
    /// The guessing was wrong for ninety-one of the five hundred and ten legal
    /// moves, and for the Fang moves it could not have been right at all: they
    /// carry two secondary effects each and the parser only ever produced one.
    @MainActor func testTheReferenceTableIsWhatTheModelUses() throws {
        print("\n== secondary effects come from the reference table ==")
        let expected: [(String, Int, String)] = [
            ("Heat Wave", 10, "burned"), ("Blizzard", 10, "frozen"),
            ("Lava Plume", 30, "burned"), ("Discharge", 30, "paralysed"),
            ("Sludge Wave", 10, "poisoned"),
        ]
        for (name, chance, status) in expected {
            let effects = move(name).secondaries
            guard let first = effects.first, case .status(let ailment) = first.kind else {
                check("\(name) carries a status secondary", false); continue
            }
            print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + "\(first.chance)% \(ailment.rawValue)")
            check("\(name) is \(chance)% \(status)",
                  first.chance == chance && ailment.rawValue == status)
        }

        // Two effects on one move, which the sentence parser could not express.
        for name in ["Fire Fang", "Ice Fang", "Thunder Fang"] {
            let effects = move(name).secondaries
            let hasFlinch = effects.contains { if case .flinch = $0.kind { return true }; return false }
            let hasStatus = effects.contains { if case .status = $0.kind { return true }; return false }
            print("  \(name): \(effects.count) effects, flinch \(hasFlinch), status \(hasStatus)")
            check("\(name) carries both of its effects", effects.count == 2 && hasFlinch && hasStatus)
        }

        // A secondary that pays the user rather than costing the target.
        let beam = move("Charge Beam").secondaries
        guard let boost = beam.first, case .selfBoosts(let stats) = boost.kind else {
            return check("Charge Beam boosts the user", false)
        }
        print("  Charge Beam: \(boost.chance)% \(stats)")
        check("Charge Beam is a 70% Special Attack boost for the user",
              boost.chance == 70 && stats[.spAttack] == 1)
    }

    /// A guaranteed drop lands exactly once.
    ///
    /// Icy Wind's Speed drop is in the reference table as a 100% secondary and
    /// was also in the sentence parser's target drops. Applying both took two
    /// stages of Speed for a move that takes one.
    @MainActor func testAGuaranteedDropLandsOnce() throws {
        print("\n== a guaranteed drop lands once ==")
        var board = Board(mine: fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Life Orb", ["Protect"]),
                                            ("Kingambit", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.sendOutLeads()
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Icy Wind"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let dropped = after.theirs[0].build.boosts[Stat.speed.rawValue]
        print("  Garchomp's Speed stage after one Icy Wind: \(dropped)")
        check("one stage, not two", dropped == -1)
    }

    /// The search prices a coin flip instead of pretending it never comes up.
    ///
    /// A 30% flinch used to be worth nothing to the search, because the search
    /// applies only what is certain. Now the turn is played out both ways and
    /// the two are weighed.
    @MainActor func testTheSearchPricesAChanceEffect() throws {
        print("\n== the search prices a chance effect ==")
        var board = Board(mine: fighters([("Kingambit", "Leftovers", ["Iron Head", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Life Orb", ["Protect"]),
                                            ("Whimsicott", "Focus Sash", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.sendOutLeads()
        let ways = TurnModel.outcomes(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Iron Head"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass))
        let total = ways.reduce(0) { $0 + $1.chance }
        print("  Iron Head produced \(ways.count) outcomes, weights \(ways.map { String(format: "%.2f", $0.chance) })")
        check("it comes out more than one way", ways.count > 1)
        check("the weights are a probability", abs(total - 1) < 0.001)
        let flinched = ways.contains { $0.board.theirs[0].flinched }
        check("one of those ways is a flinch", flinched)
    }

    /// Flags decide which ability answers a move, and Serebii had some wrong.
    @MainActor func testClawMovesAreNotSlicing() throws {
        print("\n== the flags the abilities read ==")
        for name in ["Dragon Claw", "Metal Claw", "Shadow Claw", "Crush Claw", "Dual Chop"] {
            let slicing = move(name).isSlicing
            print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))slicing: \(slicing)")
            check("\(name) is not a slicing move, so Sharpness does not boost it", !slicing)
        }
        check("Sacred Sword still is", move("Sacred Sword").isSlicing)
    }
}

extension SecondaryEffectTests {
    /// A move that hits more than once has to hit more than once.
    ///
    /// Double Hit was being played as a single thirty-five power attack when
    /// it is two of them, and the parity audit could not see it: a damaging
    /// move registers as implemented the moment it does any damage at all, not
    /// when it does the right amount.
    @MainActor func testAMultiHitMoveLandsEveryBlow() throws {
        print("\n== every blow lands ==")
        // A plain multi-hit move: accuracy is rolled once for the attack, so
        // its blows are worth one each.
        for (name, expected) in [("Double Hit", 2.0), ("Dual Wingbeat", 2.0),
                                 ("Bullet Seed", 3.0)] {
            var dice: RandomNumberGenerator = SystemRandomNumberGenerator()
            let blows = move(name).blows(for: "", accuracy: 1, rolling: false, using: &dice)
            print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0))\(blows) blows")
            check("\(name) lands \(expected) blows to the search", blows == expected)
        }
        var dice: RandomNumberGenerator = SystemRandomNumberGenerator()
        let linked = move("Bullet Seed").blows(for: "Skill Link", accuracy: 1,
                                               rolling: false, using: &dice)
        check("Skill Link always lands five", linked == 5)

        // Triple Axel gets stronger with each blow — 20, 40, 60 — and rolls
        // accuracy for every one, so it stops at the first miss. All three
        // landing is worth six of the first; at 90% a blow it is about 4.7.
        let axelSure = move("Triple Axel").blows(for: "", accuracy: 1,
                                                 rolling: false, using: &dice)
        let axelReal = move("Triple Axel").blows(for: "", accuracy: 0.9,
                                                 rolling: false, using: &dice)
        // `blows` counts from the first blow onwards; the caller has already
        // applied one accuracy factor, so the landed total is that times 0.9.
        let axelLanded = axelReal * 0.9
        print(String(format: "  Triple Axel     %.2f blows if nothing misses, %.2f landed at 90%%",
                     axelSure, axelLanded))
        check("three escalating blows are worth six of the first", axelSure == 6)
        check("and about 4.7 of that survives the misses",
              axelLanded > 4.6 && axelLanded < 4.8)

        // Population Bomb throws ten and stops at the first miss, so at 90%
        // it lands about six.
        let bomb = move("Population Bomb").blows(for: "", accuracy: 0.9,
                                                 rolling: false, using: &dice)
        let bombLanded = bomb * 0.9
        print(String(format: "  Population Bomb %.2f of its ten land, at 90%% a blow", bombLanded))
        check("about six of the ten land", bombLanded > 5.5 && bombLanded < 6.2)

        // And the damage actually doubles on the board.
        var board = Board(mine: fighters([("Kingambit", "Leftovers", ["Double Hit", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          // No Leftovers on the target: it heals a sixteenth at
                          // the end of the turn, which comes quietly off the
                          // damage being measured.
                          theirs: fighters([("Garchomp", "", ["Protect"]),
                                            ("Whimsicott", "", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.narrating = false
        board.sendOutLeads()
        let after = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Double Hit"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let taken = board.theirs[0].hp - after.theirs[0].hp
        let single = DamageCalc.calculate(attacker: board.mine[0].build,
                                          defender: board.theirs[0].build,
                                          move: move("Double Hit"),
                                          field: Field(isDoubles: true))
        // `single` is badly named for what it holds: calculate() already totals
        // a multi-hit move across its strikes, so this is *both* blows. This
        // test used to call it one blow and then require the played damage to
        // beat one and a half of it — which only ever passed because the turn
        // model was multiplying by the blows a second time. The test was
        // confirming the bug, which is why the bug lasted.
        let bothBlows = (single.minDamage + single.maxDamage) / 2
        let perBlow = Double(bothBlows) / single.strikes
        print("  Double Hit took \(taken); the calculator totals \(bothBlows) "
              + String(format: "across %.0f strikes (%.0f each)", single.strikes, perBlow))
        check("the calculator is already totalling both blows", single.strikes == 2,
              "\(single.strikes)")
        // The played figure carries the move's accuracy — Double Hit lands 90
        // times in a hundred — where the calculator's range does not, so the
        // turn comes in a little under the calculator rather than level with it.
        check("and the played move agrees with it",
              Double(taken) > Double(bothBlows) * 0.75
                  && Double(taken) < Double(bothBlows) * 1.1,
              "\(taken) against \(bothBlows)")
        check("which is two blows rather than one",
              Double(taken) > perBlow * 1.5, "\(taken) against \(perBlow) a blow")
    }

    /// Defog clears the other side's screens, both sides' hazards, and the
    /// terrain. Rapid Spin clears only its own side's hazards.
    @MainActor func testDefogAndRapidSpinClearTheRightThings() throws {
        print("\n== what Defog and Rapid Spin clear ==")
        func cluttered(_ user: String, _ moveName: String) -> Board {
            var b = Board(mine: fighters([(user, "Leftovers", [moveName, "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Garchomp", "Leftovers", ["Protect"]),
                                            ("Whimsicott", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
            b.narrating = false
            b.myScreens.spikes = 2; b.myScreens.stealthRock = true; b.myScreens.reflect = 5
            b.theirScreens.spikes = 3; b.theirScreens.stickyWeb = true
            b.theirScreens.lightScreen = 5
            b.field.terrain = .grassy; b.terrainTurns = 5
            b.sendOutLeads()
            return b
        }

        let before = cluttered("Whimsicott", "Defog")
        let defogged = TurnModel.resolve(before,
            mine: Play(left: .attack(move: at(before.mine[0], "Defog"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        print("  after Defog: my spikes \(defogged.myScreens.spikes),"
              + " my reflect \(defogged.myScreens.reflect),"
              + " their spikes \(defogged.theirScreens.spikes),"
              + " their screen \(defogged.theirScreens.lightScreen),"
              + " terrain \(defogged.field.terrain)")
        check("my own hazards go", defogged.myScreens.spikes == 0 && !defogged.myScreens.stealthRock)
        check("my own screens stay", defogged.myScreens.reflect > 0)
        check("their hazards go", defogged.theirScreens.spikes == 0 && !defogged.theirScreens.stickyWeb)
        check("their screens go", defogged.theirScreens.lightScreen == 0)
        check("and the terrain goes", defogged.field.terrain == .none)

        let spinBoard = cluttered("Kingambit", "Rapid Spin")
        let spun = TurnModel.resolve(spinBoard,
            mine: Play(left: .attack(move: at(spinBoard.mine[0], "Rapid Spin"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        print("  after Rapid Spin: my spikes \(spun.myScreens.spikes),"
              + " their spikes \(spun.theirScreens.spikes),"
              + " terrain \(spun.field.terrain)")
        check("Rapid Spin clears its own hazards",
              spun.myScreens.spikes == 0 && !spun.myScreens.stealthRock)
        check("and leaves the other side alone", spun.theirScreens.spikes == 3)
        check("and leaves the terrain alone", spun.field.terrain == .grassy)
    }
}

extension SecondaryEffectTests {
    /// Dragon Darts splits between the two foes, and both darts land on
    /// whichever one can still be reached.
    ///
    /// The only move in the game that targets this way. Aimed at a Pokémon
    /// that then protects, both darts go to its partner — which is the reason
    /// anybody thinks about which of the two to aim it at.
    @MainActor func testDragonDartsSplitsAndRedirects() throws {
        print("\n== where the darts go ==")
        func board() -> Board {
            // Neither of theirs may be a Fairy type: Dragon does not touch
            // one at all, and an immune partner cannot show a dart arriving.
            var b = Board(mine: fighters([("Garchomp", "Leftovers", ["Dragon Darts", "Protect"]),
                                          ("Milotic", "Leftovers", ["Protect"])]),
                          theirs: fighters([("Kingambit", "Leftovers", ["Protect"]),
                                            ("Incineroar", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
            b.narrating = false
            b.sendOutLeads()
            return b
        }

        // Nobody protecting: one dart each.
        let open = board()
        let split = TurnModel.resolve(open,
            mine: Play(left: .attack(move: at(open.mine[0], "Dragon Darts"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let leftHit = open.theirs[0].hp - split.theirs[0].hp
        let rightHit = open.theirs[1].hp - split.theirs[1].hp
        print("  nobody protecting: left took \(leftHit), right took \(rightHit)")
        check("both of them were hit", leftHit > 0 && rightHit > 0)

        // The one it was aimed at protects: both darts go to the partner.
        let guarded = board()
        let redirected = TurnModel.resolve(guarded,
            mine: Play(left: .attack(move: at(guarded.mine[0], "Dragon Darts"), target: 0), right: .pass),
            theirs: Play(left: .protectSelf(move: at(guarded.theirs[0], "Protect")), right: .pass),
            rolling: false)
        let blocked = guarded.theirs[0].hp - redirected.theirs[0].hp
        let doubled = guarded.theirs[1].hp - redirected.theirs[1].hp
        print("  aimed one protects: it took \(blocked), its partner took \(doubled)")
        check("the protecting one took nothing", blocked <= 0)
        check("and its partner took both darts", doubled > rightHit)
    }
}

extension SecondaryEffectTests {
    /// Helping Hand is half again on one move, not a stat change that lasts.
    @MainActor func testHelpingHandBoostsOneMoveAndThenStops() throws {
        print("\n== a helping hand lasts one move ==")
        func board() -> Board {
            var b = Board(mine: fighters([("Kingambit", "Leftovers", ["Iron Head", "Protect"]),
                                          ("Milotic", "Leftovers", ["Helping Hand", "Protect"])]),
                          theirs: fighters([("Garchomp", "Leftovers", ["Protect"]),
                                            ("Incineroar", "Leftovers", ["Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
            b.narrating = false
            b.sendOutLeads()
            return b
        }
        let alone = board()
        let plain = TurnModel.resolve(alone,
            mine: Play(left: .attack(move: at(alone.mine[0], "Iron Head"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let unaided = alone.theirs[0].hp - plain.theirs[0].hp

        let helped = board()
        let lent = TurnModel.resolve(helped,
            mine: Play(left: .attack(move: at(helped.mine[0], "Iron Head"), target: 0),
                       right: .attack(move: at(helped.mine[1], "Helping Hand"), target: 0)),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let aided = helped.theirs[0].hp - lent.theirs[0].hp
        print("  Iron Head alone took \(unaided), with a hand \(aided)")
        check("the hand made the move hit harder", aided > unaided)

        // And it is a power boost, not a stat change that outlives the turn.
        check("no stat change was left behind",
              lent.mine[0].build.boosts.allSatisfy { $0 == 0 })
        check("and the hand itself is gone", !lent.mine[0].helped)
    }

    /// A stage never leaves [-6, +6], whichever route it takes there
    ///
    /// The central path clamps, but not everything goes through it: Swallow
    /// subtracts what was stockpiled directly, and Sticky Web and Intimidate
    /// each move a stage on their own. One route out of range is enough to
    /// make a stat multiplier the damage step cannot express.
    @MainActor func testAStageNeverLeavesItsRange() throws {
        print("\n== stages stay inside six ==")
        let lax = fighters([("Snorlax", "Leftovers", ["Stockpile", "Swallow", "Body Slam", "Protect"]),
                            ("Whimsicott", "Focus Sash", ["Protect"])])
        let across = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                               ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])

        // The top first: Stockpile three times is +3 and the fourth fails.
        var rising = Board(mine: lax, theirs: across, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        for _ in 0..<4 {
            rising = TurnModel.resolve(rising,
                mine: Play(left: .attack(move: at(rising.mine[0], "Stockpile"), target: 0), right: .pass),
                theirs: Play(left: .pass, right: .pass), rolling: false)
        }
        let stacked = rising.mine[0].build.boosts[Stat.defense.rawValue]
        print("  four Stockpiles left Defense at \(stacked), holding \(rising.mine[0].stockpile)")
        check("Stockpile stops at three", rising.mine[0].stockpile == 3 && stacked == 3)

        // And the floor. A Pokémon holding three stockpiles whose Defense has
        // since been driven to the bottom still owes three stages on Swallow,
        // and three below the bottom is not a place a stage can be.
        var sunk = Board(mine: lax, theirs: across, rules: store.rulebook,
                         field: Field(isDoubles: true), alreadyEvolved: false)
        sunk.mine[0].stockpile = 3
        sunk.mine[0].build.boosts[Stat.defense.rawValue] = -6
        sunk.mine[0].build.boosts[Stat.spDefense.rawValue] = -5
        sunk.mine[0].hp = sunk.mine[0].maxHP / 2
        let swallowed = TurnModel.resolve(sunk,
            mine: Play(left: .attack(move: at(sunk.mine[0], "Swallow"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let def = swallowed.mine[0].build.boosts[Stat.defense.rawValue]
        let spd = swallowed.mine[0].build.boosts[Stat.spDefense.rawValue]
        print("  Swallow off a floored Defense left Def \(def), SpD \(spd)")
        check("Swallow does not push a stage below -6", def >= -6 && spd >= -6,
              "Def \(def), SpD \(spd)")

        // Sticky Web takes its stage on the way in — and it has to take it
        // with nothing else on the floor, which is the ordinary case: a web is
        // set precisely because it is cheap to set alone.
        var webbed = Board(mine: lax, theirs: across, rules: store.rulebook,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        webbed.myScreens.stickyWeb = true
        webbed.takeHazards(mine: true, slot: 0)
        let slowed = webbed.mine[0].build.boosts[Stat.speed.rawValue]
        print("  walking into a web with nothing else down: Speed \(slowed)")
        check("a web on its own still slows what walks into it", slowed == -1, "Speed \(slowed)")

        // And not past the floor.
        var floored = Board(mine: lax, theirs: across, rules: store.rulebook,
                            field: Field(isDoubles: true), alreadyEvolved: false)
        floored.myScreens.stickyWeb = true
        floored.mine[0].build.boosts[Stat.speed.rawValue] = -6
        floored.takeHazards(mine: true, slot: 0)
        let bottom = floored.mine[0].build.boosts[Stat.speed.rawValue]
        print("  a floored Speed walking into the web: \(bottom)")
        check("the web does not push Speed below -6", bottom >= -6, "Speed \(bottom)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Every step says who was acting and with what
    ///
    /// The battlefield animates a turn off this: a physical move makes the card
    /// lean in, a special one sends a beam in the move's type colour, and who
    /// it reached is worked out by diffing health across the step. All of that
    /// is silent if the metadata is wrong — the turn would simply resolve with
    /// nothing drawn — so it is worth a test rather than an eyeball.
    @MainActor func testEveryStepSaysWhoWasActing() throws {
        print("\n== a step knows whose it is ==")
        let mine = fighters([("Garchomp", "Leftovers", ["Earthquake", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Farigiraf", "Mental Herb", ["Psychic", "Protect"])])
        let theirs = fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind", "Protect"]),
                               ("Kingambit", "Leftovers", ["Sucker Punch", "Protect"])])
        let start = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        let played = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Earthquake"), target: 0),
                       right: .attack(move: at(start.mine[1], "Heat Wave"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Wood Hammer"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Tailwind"), target: 0)),
            rolling: false)

        let acts = played.steps.compactMap(\.action)
        for act in acts {
            print("    \(act.byMine ? "you" : "they") slot \(act.slot): "
                  + "\(act.move.isEmpty ? "(switch)" : act.move) — \(act.category) \(act.type)")
        }
        check("every move played left a step that names it", acts.count >= 4, "\(acts.count)")

        let quake = acts.first { $0.move == "Earthquake" }
        check("Earthquake is recorded as a physical Ground move by you",
              quake?.category == "Physical" && quake?.type == "Ground" && quake?.byMine == true,
              "\(String(describing: quake))")
        let wave = acts.first { $0.move == "Heat Wave" }
        check("Heat Wave as a special Fire move",
              wave?.category == "Special" && wave?.type == "Fire", "\(String(describing: wave))")
        // The dataset files a status move under "Other", which is the word the
        // screen matches on: anything that is neither Physical nor Special
        // draws the ring rather than a beam.
        let wind = acts.first { $0.move == "Tailwind" }
        check("Tailwind as a status move of theirs",
              wind?.category == "Other" && wind?.byMine == false, "\(String(describing: wind))")

        // The type has to be one the interface can colour, or the beam falls
        // back to the accent and every move looks the same.
        let colourable = acts.filter { !$0.type.isEmpty }
        check("every recorded type is a real type",
              colourable.allSatisfy { PokeType(loose: $0.type) != nil },
              colourable.map(\.type).joined(separator: ", "))

        // The residual step at the end of a turn belongs to nobody, and must
        // not be drawn as somebody's move. Garchomp holds Leftovers precisely
        // so there is one: with nothing to report the residual step is never
        // opened, and the last step would be the last move instead.
        let residual = played.steps.last
        check("the end-of-turn step names no actor", residual?.action == nil,
              "\(residual?.text ?? "no step") / \(String(describing: residual?.action))")

        // And a switch reads as a switch, which draws nothing.
        let swapped = TurnModel.resolve(start,
            mine: Play(left: .swap(to: 2), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let switches = swapped.steps.compactMap(\.action).filter { $0.category == "Switch" }
        check("a switch is recorded as one", switches.count == 1, "\(switches.count)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// A multi-hit move does its hits once, not its hits squared
    ///
    /// `DamageCalc.calculate` already multiplies a multi-hit move up by the
    /// strikes it assumes, because the calculator screen should show the whole
    /// flurry. The turn model then took that total as a *single* blow and
    /// multiplied by the blows again, so every multi-hit move did strikes
    /// squared: Bullet Seed three times three, and Population Bomb — ten
    /// hits — a hundred times one.
    ///
    /// The check is that a played turn agrees with the calculator, which is
    /// the relationship that broke and the one worth pinning.
    @MainActor func testAMultiHitMoveDoesNotSquareItself() throws {
        print("\n== a flurry is not a flurry of flurries ==")
        let mine = fighters([("Rillaboom", "Leftovers", ["Bullet Seed", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Garchomp", "Leftovers", ["Protect"]),
                               ("Kingambit", "Leftovers", ["Protect"])])
        let start = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        let seed = store.data.moves.values.first { $0.name == "Bullet Seed" }!
        let reckoned = DamageCalc.calculate(attacker: start.mine[0].build,
                                            defender: start.theirs[0].build,
                                            move: seed, field: start.field)
        print("  the calculator says \(reckoned.minDamage)–\(reckoned.maxDamage) "
              + "across \(reckoned.strikes) strikes")
        check("the calculator is totalling the flurry", reckoned.strikes > 1,
              "\(reckoned.strikes)")

        // Played without rolling, so it takes the average of everything.
        let before = start.theirs[0].hp
        let played = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Bullet Seed"), target: 0),
                       right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let dealt = before - played.theirs[0].hp
        for line in played.story where line.contains("hits") { print("    \(line)") }
        print("  the turn dealt \(dealt), the calculator's middle is "
              + "\((reckoned.minDamage + reckoned.maxDamage) / 2)")

        // Within a quarter: the turn rounds per blow and the calculator rounds
        // once, so they will not agree to the point. Squaring would be 3x out.
        let middle = Double(reckoned.minDamage + reckoned.maxDamage) / 2
        let ratio = middle > 0 ? Double(dealt) / middle : 0
        print(String(format: "  ratio %.2f", ratio))
        check("a played flurry matches the calculator", ratio > 0.75 && ratio < 1.25,
              String(format: "%.2f", ratio))

        // And the same in the other direction: nowhere near the target's whole
        // bar from one 25-power move.
        check("and 25 base power does not delete a Garchomp",
              dealt < played.theirs[0].maxHP / 2,
              "\(dealt) of \(played.theirs[0].maxHP)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
