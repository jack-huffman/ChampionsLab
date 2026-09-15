//  ReplayMoveTests.swift
//  The moves real games use that the model did not have.
//
//      swift test --filter ReplayMoveTests
//
//  Every move here was found by counting what the replay corpus actually
//  played and checking it against what the turn model implements. Each one
//  sets a clock or a flag rather than doing its work immediately, which is
//  exactly the shape the parity audit is worst at: the battery plays a move
//  and looks for a change in the board, and a move whose whole effect arrives
//  three turns later leaves the board looking untouched.
//
//  So these check the effect at the turn it is supposed to land, not that
//  something happened.

import XCTest
@testable import ChampionsLab

final class ReplayMoveTests: HarnessCase {
    /// Perish Song takes the field, the singer's own side included
    @MainActor func testPerishSongTakesEverybody() throws {
        print("\n== perish song ==")
        let mine = fighters([("Gengar", "Leftovers", ["Perish Song", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect", "Surf"]),
                             ("Garchomp", "Leftovers", ["Protect", "Earthquake"])])
        let theirs = fighters([("Kingambit", "Leftovers", ["Protect"]),
                               ("Rillaboom", "Leftovers", ["Protect"]),
                               ("Blastoise", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Perish Song"), target: 0),
                       right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Protect"), target: 0)),
            rolling: false)

        // Everybody on the field, both sides. The singer is not exempt, which
        // is the cost that makes the move a decision rather than a button.
        let counts = [board.mine[0].perishIn, board.mine[1].perishIn,
                      board.theirs[0].perishIn, board.theirs[1].perishIn]
        print("  after the song, counts on the field: \(counts)")
        check("all four on the field are counting down", counts.allSatisfy { $0 == 2 },
              "\(counts)")
        check("and the bench is untouched",
              board.mine[2].perishIn == 0 && board.theirs[2].perishIn == 0)

        // Two more turns of nothing, then everything standing falls together.
        for turn in 0..<2 {
            board = TurnModel.resolve(board,
                mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0),
                           right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
                theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                             right: .attack(move: at(board.theirs[1], "Protect"), target: 0)),
                rolling: false)
            print("  turn \(turn + 2): gengar \(board.mine[0].hp)/\(board.mine[0].maxHP), "
                  + "count \(board.mine[0].perishIn)")
        }
        check("the song fainted everything it caught, full health or not",
              board.mine[0].fainted && board.mine[1].fainted
                  && board.theirs[0].fainted && board.theirs[1].fainted,
              "mine \(board.mine[0].hp)/\(board.mine[1].hp), "
                  + "theirs \(board.theirs[0].hp)/\(board.theirs[1].hp)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Switching out is the answer to the song
    @MainActor func testTheSongDoesNotFollowToTheBench() throws {
        print("\n== the song does not follow ==")
        let mine = fighters([("Gengar", "Leftovers", ["Perish Song", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"]),
                             ("Garchomp", "Leftovers", ["Protect"])])
        let theirs = fighters([("Kingambit", "Leftovers", ["Protect"]),
                               ("Rillaboom", "Leftovers", ["Protect"]),
                               ("Blastoise", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Perish Song"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        check("their lead is counting", board.theirs[0].perishIn == 2)

        // They pivot the caught one out and the fresh one in.
        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0), right: .pass),
            theirs: Play(left: .swap(to: 2), right: .pass), rolling: false)
        print("  after the pivot, their lead's count: \(board.theirs[0].perishIn) "
              + "(\(board.theirs[0].build.form.formLabel))")
        check("whatever came in is not counting", board.theirs[0].perishIn == 0)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Yawn is not sleep, and that turn in between is the move
    @MainActor func testYawnSleepsAtTheEndOfTheNextTurn() throws {
        print("\n== yawn ==")
        let mine = fighters([("Oranguru", "Leftovers", ["Yawn", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Garchomp", "Leftovers", ["Protect", "Earthquake"]),
                               ("Rillaboom", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Yawn"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        print("  turn 1: drowsy \(board.theirs[0].drowsyFor), status \(board.theirs[0].status)")
        check("it is drowsy, not asleep", board.theirs[0].drowsyFor == 1
              && board.theirs[0].status == .none)

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        print("  turn 2: drowsy \(board.theirs[0].drowsyFor), status \(board.theirs[0].status)")
        check("asleep at the end of the next turn", board.theirs[0].status == .sleep,
              "\(board.theirs[0].status)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Disable shuts a move off, and trying it anyway costs the turn
    @MainActor func testDisableShutsOffTheMoveItNames() throws {
        print("\n== disable ==")
        let mine = fighters([("Gengar", "Leftovers", ["Disable", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Garchomp", "Leftovers", ["Earthquake", "Protect"]),
                               ("Rillaboom", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let quake = at(board.theirs[0], "Earthquake")

        // It has to have used something before there is anything to disable.
        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: quake, target: 0), right: .pass), rolling: false)
        // Gengar outruns Garchomp, so one turn does both halves: the Disable
        // lands first and the Earthquake behind it is refused. Garchomp must
        // not use a priority move on this turn, or the Protect would go first
        // and Disable would quite correctly name *that* as the last move.
        let before = board.mine[0].hp
        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Disable"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: quake, target: 0), right: .pass),
            rolling: false)
        print("  disabled slot \(String(describing: board.theirs[0].disabled)), "
              + "for \(board.theirs[0].disabledFor) turns")
        for line in board.story where line.contains("isabled") { print("    \(line)") }
        check("Earthquake is the move it named", board.theirs[0].disabled == quake,
              "\(String(describing: board.theirs[0].disabled)) vs \(quake)")
        check("the Earthquake behind it did nothing", board.mine[0].hp >= before,
              "\(before) -> \(board.mine[0].hp)")
        check("and the log says why",
              board.story.contains { $0.contains("is disabled") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Destiny Bond takes its killer with it
    @MainActor func testDestinyBondTakesTheAttacker() throws {
        print("\n== destiny bond ==")
        let mine = fighters([("Gengar", "Leftovers", ["Destiny Bond", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                               ("Garchomp", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        // On the brink, so the Wood Hammer certainly finishes it.
        board.mine[0].hp = 1

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Destiny Bond"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Wood Hammer"), target: 0), right: .pass),
            rolling: false)
        print("  gengar \(board.mine[0].hp), rillaboom \(board.theirs[0].hp)")
        for line in board.story where line.contains("Destiny") { print("    \(line)") }
        check("the bonded Pokémon fainted", board.mine[0].fainted)
        check("and took what killed it", board.theirs[0].fainted,
              "rillaboom on \(board.theirs[0].hp)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Octolock holds it there and grinds its guard down
    @MainActor func testOctolockTrapsAndGrinds() throws {
        print("\n== octolock ==")
        let mine = fighters([("Grapploct", "Leftovers", ["Octolock", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Garchomp", "Leftovers", ["Protect"]),
                               ("Rillaboom", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Octolock"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        let def1 = board.theirs[0].build.boosts[Stat.defense.rawValue]
        let spd1 = board.theirs[0].build.boosts[Stat.spDefense.rawValue]
        print("  after one turn: Def \(def1), SpD \(spd1), trapped \(board.theirs[0].cannotEscape)")
        check("it cannot leave", board.theirs[0].cannotEscape)
        check("and lost a stage of each defence", def1 == -1 && spd1 == -1, "\(def1)/\(spd1)")

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Protect"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        let def2 = board.theirs[0].build.boosts[Stat.defense.rawValue]
        print("  after two: Def \(def2)")
        check("and keeps losing them while it stands there", def2 == -2, "\(def2)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Shed Tail leaves the substitute behind for whatever comes in
    @MainActor func testShedTailLeavesTheShellForTheNextOne() throws {
        print("\n== shed tail ==")
        let mine = fighters([("Orthworm", "Leftovers", ["Shed Tail", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"]),
                             ("Garchomp", "Leftovers", ["Protect"])])
        let theirs = fighters([("Rillaboom", "Leftovers", ["Protect"]),
                               ("Kingambit", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let worm = board.mine[0]
        let expectedShell = worm.maxHP / 4

        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Shed Tail"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0), right: .pass),
            rolling: false)
        print("  slot now holds \(board.mine[0].build.form.formLabel) "
              + "behind a substitute worth \(board.mine[0].substitute)")
        check("something else is standing there", board.mine[0].build.form.formLabel != "Orthworm",
              board.mine[0].build.form.formLabel)
        check("behind the shell the tail left", board.mine[0].substitute == expectedShell,
              "\(board.mine[0].substitute), expected \(expectedShell)")
        // What is left after paying, not "half": an odd bar keeps the larger
        // half, and `maxHP / 2` is the smaller one.
        let leftOver = worm.maxHP - worm.maxHP / 2
        check("and the one that left paid half its health for it",
              board.mine.contains { $0.build.form.formLabel == "Orthworm" && $0.hp == leftOver },
              "expected \(leftOver), got "
                  + "\(board.mine.first { $0.build.form.formLabel == "Orthworm" }?.hp ?? -1)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Instruct gets a second use out of the partner's move
    @MainActor func testInstructRepeatsThePartnersMove() throws {
        print("\n== instruct ==")
        func board() -> Board {
            let mine = fighters([("Oranguru", "Leftovers", ["Instruct", "Protect"]),
                                 ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
            let theirs = fighters([("Kingambit", "Leftovers", ["Protect"]),
                                   ("Rillaboom", "Leftovers", ["Protect"])])
            return Board(mine: mine, theirs: theirs, rules: store.rulebook,
                         field: Field(isDoubles: true), alreadyEvolved: false)
        }
        // Turn one so the partner has a last move to be instructed into.
        var once = board()
        once = TurnModel.resolve(once,
            mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(once.mine[1], "Earthquake"), target: 0)),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let afterOne = once.theirs[0].hp

        // Turn two: the partner attacks again and Oranguru makes it a third.
        let quake = at(once.mine[1], "Earthquake")
        let instructed = TurnModel.resolve(once,
            mine: Play(left: .attack(move: at(once.mine[0], "Instruct"),
                                     target: Choice.allyTarget),
                       right: .attack(move: quake, target: 0)),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        // Across both foes. Measuring only the first one hid the whole effect
        // the first time: Kingambit was on 16 and fell to the first Earthquake
        // either way, so the slot read 0 in both and the second Earthquake --
        // which landed on Rillaboom -- was invisible.
        let withInstruct = (afterOne - instructed.theirs[0].hp)
            + (once.theirs[1].hp - instructed.theirs[1].hp)

        // The same turn without the Instruct, for the comparison.
        let plain = TurnModel.resolve(once,
            mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                       right: .attack(move: quake, target: 0)),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let without = (afterOne - plain.theirs[0].hp)
            + (once.theirs[1].hp - plain.theirs[1].hp)

        print("  foes after turn 1: \(once.theirs[0].hp)/\(once.theirs[1].hp); "
              + "plain \(plain.theirs[0].hp)/\(plain.theirs[1].hp), "
              + "instructed \(instructed.theirs[0].hp)/\(instructed.theirs[1].hp)")
        print("  Earthquake alone took \(without), with an Instruct \(withInstruct)")
        for line in instructed.story where line.contains("again") { print("    \(line)") }
        check("the instructed turn did more", withInstruct > without,
              "\(withInstruct) vs \(without)")
        check("and the log says the move was used again",
              instructed.story.contains { $0.contains("use Earthquake again") })

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Coil raises what this model can hold
    @MainActor func testCoilRaisesAttackAndDefense() throws {
        print("\n== coil ==")
        let mine = fighters([("Milotic", "Leftovers", ["Coil", "Protect"]),
                             ("Garchomp", "Leftovers", ["Protect"])])
        let theirs = fighters([("Rillaboom", "Leftovers", ["Protect"]),
                               ("Kingambit", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Coil"), target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let atk = board.mine[0].build.boosts[Stat.attack.rawValue]
        let def = board.mine[0].build.boosts[Stat.defense.rawValue]
        print("  Atk \(atk), Def \(def) (the accuracy stage is not modelled)")
        check("a stage of Attack and a stage of Defense", atk == 1 && def == 1, "\(atk)/\(def)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// The sky decides whether Hurricane, Thunder and Blizzard land
    ///
    /// These are the reason a rain team runs Thunder and a snow team runs
    /// Blizzard: 70 accuracy is a gamble, and the weather takes the gamble
    /// away. None of it was modelled, so a Hurricane thrown under the rain the
    /// whole team was built around was still rolling 70.
    @MainActor func testWeatherDecidesTheseAccuracies() throws {
        print("\n== weather and accuracy ==")
        let mine = fighters([("Pelipper", "Focus Sash", ["Hurricane", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"])])
        let theirs = fighters([("Garchomp", "Leftovers", ["Protect"]),
                               ("Rillaboom", "Leftovers", ["Protect"])])
        func chance(_ moveName: String, _ sky: Weather, on team: Team) -> Double {
            let board = Board(mine: team, theirs: theirs, rules: store.rulebook,
                              field: Field(weather: sky, isDoubles: true), alreadyEvolved: false)
            let move = store.data.moves.values.first { $0.name == moveName }!
            return TurnModel.chanceToHit(move, attacker: board.mine[0],
                                         defender: board.theirs[0], board: board)
        }
        let clear = chance("Hurricane", .none, on: mine)
        let wet = chance("Hurricane", .rain, on: mine)
        let bright = chance("Hurricane", .sun, on: mine)
        print("  Hurricane: clear \(Int(clear)), rain \(Int(wet)), sun \(Int(bright))")
        check("Hurricane is 70 with nothing up", clear == 70, "\(clear)")
        check("certain in rain", wet == 100, "\(wet)")
        check("and half-blind in sun", bright == 50, "\(bright)")

        let thunder = fighters([("Raichu", "Focus Sash", ["Thunder", "Protect"]),
                                ("Milotic", "Leftovers", ["Protect"])])
        print("  Thunder: rain \(Int(chance("Thunder", .rain, on: thunder))), "
              + "sun \(Int(chance("Thunder", .sun, on: thunder)))")
        check("Thunder is certain in rain and halved in sun",
              chance("Thunder", .rain, on: thunder) == 100
                  && chance("Thunder", .sun, on: thunder) == 50)

        let blizzard = fighters([("Blastoise", "Leftovers", ["Blizzard", "Protect"]),
                                 ("Milotic", "Leftovers", ["Protect"])])
        let snowy = chance("Blizzard", .snow, on: blizzard)
        let dry = chance("Blizzard", .rain, on: blizzard)
        print("  Blizzard: snow \(Int(snowy)), rain \(Int(dry))")
        check("Blizzard does not miss in snow, and is a gamble without it",
              snowy == 100 && dry == 70, "\(snowy)/\(dry)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// First Impression works on a Pokémon's first turn, not on turn one
    ///
    /// A Golisopod pivoted in partway through turn five was not on the field
    /// when that turn began, so its first turn is turn six. The flag used to be
    /// cleared at the end of whatever turn it arrived in, which meant the only
    /// turn it could have used the move was already too late — and the move it
    /// is brought for could never be used at all after a pivot.
    @MainActor func testFirstImpressionAfterAMidTurnSwitch() throws {
        print("\n== the first turn is not turn one ==")
        let mine = fighters([("Garchomp", "Leftovers", ["Protect", "Earthquake"]),
                             ("Milotic", "Leftovers", ["Protect"]),
                             // Sirfetch'd rather than Golisopod, which is the Pokémon
                             // this was reported on: Golisopod's only ability is
                             // Emergency Exit, so a hit big enough to notice sends it
                             // straight back out and there is no mid-turn arrival left
                             // to test. The rule under test is the same for both.
                             ("Sirfetch'd", "Leftovers", ["First Impression", "Protect"])])
        let theirs = fighters([("Rillaboom", "Leftovers", ["Bullet Seed", "Protect"]),
                               ("Kingambit", "Leftovers", ["Protect"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        // Turn one: it is on the bench and Garchomp pivots out for it, so it
        // arrives partway through the turn and takes a hit on the way in.
        board = TurnModel.resolve(board,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
            // Aimed at the partner, which protects. Whether the arriving
            // Pokémon takes a hit on the way in is incidental to the rule —
            // what matters is that it was not on the field when the turn
            // began — and a hit large enough to be interesting killed it.
            theirs: Play(left: .attack(move: at(board.theirs[0], "Bullet Seed"), target: 1),
                         right: .pass),
            rolling: false)
        let pod = board.mine[0]
        print("  after the pivot: \(pod.build.form.formLabel) on \(pod.hp)/\(pod.maxHP), "
              + "first turn still ahead: \(pod.justArrived)")
        check("it came in mid-turn", pod.build.form.formLabel == "Sirfetch'd",
              pod.build.form.formLabel)
        check("and its first turn has not happened yet", pod.justArrived)

        // Turn two is its first turn on the field, so the move is legal and
        // actually lands.
        let before = board.theirs[0].hp
        let hit = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "First Impression"), target: 0),
                       right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let took = before - hit.theirs[0].hp
        for line in hit.story where line.contains("Impression") { print("    \(line)") }
        print("  First Impression took \(took)")
        check("First Impression lands on the turn after it came in", took > 0, "took \(took)")

        // And the turn after that it is too late, which is the other half of
        // the rule.
        let again = TurnModel.resolve(hit,
            mine: Play(left: .attack(move: at(hit.mine[0], "First Impression"), target: 0),
                       right: .pass),
            theirs: Play(left: .pass, right: .pass), rolling: false)
        let twice = hit.theirs[0].hp - again.theirs[0].hp
        // Not `== 0`: the target holds Leftovers, so a turn in which it takes
        // nothing is a turn in which it comes out ahead.
        print("  and a turn later it took \(twice) (negative is its Leftovers)")
        check("but not on the turn after that", twice <= 0, "took \(twice)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
