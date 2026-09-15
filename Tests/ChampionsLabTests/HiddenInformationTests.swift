//  HiddenInformationTests.swift
//  What neither side can see, and what the engine is allowed to read.
//
//      swift test --filter HiddenInformationTests

import XCTest
@testable import ChampionsLab

final class HiddenInformationTests: HarnessCase {
    /// their back two as guesses, and the guesses shrinking
    @MainActor func testTheHiddenBackTwo() throws {
print("\n== the hidden back two ==")
    let mySix = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                          ("Indeedee (Female)", "Leftovers", ["Follow Me", "Dazzling Gleam", "Protect"]),
                          ("Garchomp", "Life Orb", ["Earthquake", "Rock Slide", "Protect"]),
                          ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"]),
                          ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                          ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"])])
    let theirSix = fighters([("Garchomp", "Focus Sash", ["Earthquake", "Rock Slide", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"]),
                             ("Farigiraf", "Leftovers", ["Trick Room", "Psychic", "Protect"])])
    let game = Board.opening(mine: mySix, bringing: mySix.slots.prefix(4).map(\.formID),
                             theirs: theirSix, rules: store.rulebook, singles: false)
    print("  they brought \(game.theirs.map { $0.build.form.formLabel }), leading the first two")
    check("their four is chosen, but only the leads are on show",
          game.theirs.count == 4 && game.theirs[0].seen && game.theirs[1].seen
            && !game.theirs[2].seen && !game.theirs[3].seen)
    let odds = game.liveBenchGuesses
    print("  guesses: " + odds.prefix(3).map { g in
        g.fighters.map(\.build.form.formLabel).joined(separator: "+") + String(format: " %.0f%%", g.chance * 100)
    }.joined(separator: ", "))
    check("the back two are weighed as guesses that add up",
          odds.count > 1 && abs(odds.reduce(0) { $0 + $1.chance } - 1) < 0.01, "\(odds.count)")
    check("every pair they could be carrying is on the list", odds.count == 6, "\(odds.count)")
    check("including the one holding a stone",
          odds.contains { $0.fighters.contains { $0.build.form.formLabel == "Charizard" } })
    let searcher = BattleEngine(rules: store.rulebook, budget: 0.1)
    let worlds = searcher.imagine(game, belief: BattleEngine.Belief())
    let truth = game.theirs.dropFirst(2).map(\.build.form.id)
    let benches = worlds.map { $0.board.theirs.dropFirst(2).map(\.build.form.id) }
    print("  worlds see: " + benches.map { $0.joined(separator: "+") }.joined(separator: " | "))
    check("the search plays several possible back twos, not the answer",
          Set(benches.map { $0.joined(separator: "+") }).count > 1, "\(benches)")
    check("no world's bench is anything but a live guess",
          benches.allSatisfy { bench in odds.contains { $0.fighters.map(\.build.form.id) == bench } })
    // One walks on, and is known from then on.
    var revealed = game
    revealed.fillGaps()
    var hurt = game
    hurt.theirs[0].hp = 0
    hurt.fillGaps(mine: false, theirs: true)
    print("  after their lead fell, \(hurt.theirs[0].build.form.formLabel) came in")
    check("a Pokémon that comes in is seen", hurt.theirs[0].seen && hurt.theirUnseenBench == [3])
    let after = hurt.liveBenchGuesses
    let arrived = hurt.theirs[0].build.form.id
    check("the guesses shrink to pairs it was in",
          !after.isEmpty && after.allSatisfy { $0.fighters.contains { $0.build.form.id == arrived } },
          "\(after.count) left")
    let laterWorlds = searcher.imagine(hurt, belief: BattleEngine.Belief())
    check("the one still hidden stays a guess; the one that showed does not",
          laterWorlds.allSatisfy { $0.board.theirs[0].build.form.id == arrived }
            && Set(laterWorlds.map { $0.board.theirs[3].build.form.id }).count >= 1)
    _ = truth; _ = revealed

    // -- arriving, and what a move costs its user in stages ------------------

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// both of theirs act every turn, and a switch is said out loud
    @MainActor func testBothOfTheirsAct() throws {
        let theirSix = fighters([("Garchomp", "Focus Sash", ["Earthquake", "Rock Slide", "Protect"]),
                                 ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
                                 ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                                 ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                                 ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"]),
                                 ("Farigiraf", "Leftovers", ["Trick Room", "Psychic", "Protect"])])
print("\n== both of theirs act ==")
    let bothGame = Board.opening(mine: mySix, bringing: mySix.slots.prefix(4).map(\.formID),
                                 theirs: theirSix, rules: store.rulebook, singles: false)
    let bothSolve = TurnGame(board: bothGame).solve(iterations: 300)
    let theirsActing = bothSolve.theirPlays.filter { !$0.left.isPass && !$0.right.isPass }.count
    check("every line of theirs gives both Pokémon something to do",
          theirsActing == bothSolve.theirPlays.count, "\(theirsActing) of \(bothSolve.theirPlays.count)")
    let kinds = Set(bothSolve.theirPlays.flatMap { [$0.left, $0.right] }.map { choice -> String in
        switch choice {
        case .attack: return "attack"
        case .protectSelf: return "protect"
        case .swap: return "switch"
        case .pass: return "pass"
        }
    })
    check("and they can attack, Protect and switch, like you", kinds.isSuperset(of: ["attack", "protect", "switch"]), "\(kinds)")
    let switching = TurnModel.resolve(
        bothGame,
        mine: Play(left: .protectSelf(move: at(bothGame.mine[0], "Protect")),
                   right: .protectSelf(move: at(bothGame.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: 0, target: 0), right: .swap(to: 2)))
    for line in switching.story.prefix(4) { print("    \(line)") }
    check("a switch is narrated", switching.story.contains { $0.hasPrefix("They switched") })
    check("and the one that came in is seen", switching.theirs[1].seen)
    // Both sides switch: the faster one leaves first, and each switch is a
    // step of its own that also carries what the arrival did.
    var bothSwitch = bothGame
    bothSwitch.mine[2].build.ability = "Intimidate"
    let leaverSpeed = bothSwitch.mine[0].build.speed(in: bothSwitch.field)
    let theirLeaverSpeed = bothSwitch.theirs[1].build.speed(in: bothSwitch.field)
    let swapped = TurnModel.resolve(
        bothSwitch,
        mine: Play(left: .swap(to: 2), right: .protectSelf(move: at(bothSwitch.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: 0, target: 0), right: .swap(to: 2)))
    print("  \(bothSwitch.mine[0].build.form.formLabel) \(leaverSpeed) leaves against \(bothSwitch.theirs[1].build.form.formLabel) \(theirLeaverSpeed)")
    for step in swapped.steps.prefix(3) { print("    step: \(step.text.replacingOccurrences(of: "\n", with: " / "))") }
    let mineAt = swapped.story.firstIndex { $0.hasPrefix("You switched") }!
    let theirsAt = swapped.story.firstIndex { $0.hasPrefix("They switched") }!
    check("switches happen in Speed order", leaverSpeed > theirLeaverSpeed ? mineAt < theirsAt : theirsAt < mineAt)
    check("and before any move", max(mineAt, theirsAt) < swapped.story.firstIndex { $0.contains(" used ") }!)
    check("and the arrival's ability is in the switch's step",
          swapped.steps.contains { $0.text.hasPrefix("You switched") && $0.text.contains("Intimidate") },
          swapped.steps.first { $0.text.hasPrefix("You switched") }?.text ?? "-")

    // Weather Ball is whatever the weather says it is, when it lands.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// their half of the matrix is answered on what they can see, not on what
    /// is actually sitting on your bench
    @MainActor func testTheyAnswerWhatTheyCanSee() throws {
        print("== the board as they see it ==")
        let theirSix = fighters([("Garchomp", "Focus Sash", ["Earthquake", "Rock Slide", "Protect"]),
                                 ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
                                 ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                                 ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                                 ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"]),
                                 ("Farigiraf", "Leftovers", ["Trick Room", "Psychic", "Protect"])])
        let game = Board.opening(mine: mySix, bringing: mySix.slots.prefix(4).map(\.formID),
                                 theirs: theirSix, rules: store.rulebook, singles: false)
        check("they have a guess about your back two as well",
              game.myBenchGuesses.count > 1 && abs(game.myBenchGuesses.reduce(0) { $0 + $1.chance } - 1) < 0.01,
              "\(game.myBenchGuesses.count)")
        print("  they expect: " + game.myBenchCandidates.prefix(3).map {
            "\($0.fighter.build.form.formLabel) \(Int(($0.chance * 100).rounded()))%" }.joined(separator: ", "))

        let believed = game.asTheySeeIt
        check("their view keeps your leads exactly as they are",
              believed.mine.prefix(2).map(\.build.form.id) == game.mine.prefix(2).map(\.build.form.id))
        check("and replaces the back two you have not shown",
              believed.myUnseenBench.allSatisfy { slot in
                  game.myBenchCandidates.contains { $0.fighter.build.form.id == believed.mine[slot].build.form.id }
              })

        // The same position, with a different pair actually hidden behind the
        // same leads. Nothing they can see has changed.
        var swapped = game
        for slot in game.myUnseenBench {
            let unexpected = fighters([("Milotic", "Leftovers", ["Recover", "Muddy Water", "Protect"])])
            let other = Board(mine: unexpected, theirs: theirSix, rules: store.rulebook,
                              field: Field(isDoubles: true), alreadyEvolved: false)
            // A board marks its own first two as seen, because they are the
            // ones standing on the field. This one is being put on the *bench*
            // of another board, where it has never been sent out — so it
            // arrives carrying a flag no benched Pokémon would have, and the
            // swap has to undo it. Without this the test is not comparing two
            // hidden benches, it is comparing a hidden one against a revealed
            // one, and anything that treats those differently looks like a leak.
            var hiddenOne = other.mine[0]
            hiddenOne.seen = false
            swapped.mine[slot] = hiddenOne
        }
        check("the swap is real", swapped.mine[2].build.form.formLabel != game.mine[2].build.form.formLabel)

        let honest = TurnGame(board: game, believingTheirs: true).solve(iterations: 900)
        let honestSwapped = TurnGame(board: swapped, believingTheirs: true).solve(iterations: 900)
        let drift = zip(honest.theirMix, honestSwapped.theirMix).map { abs($0 - $1) }.max() ?? 1
        print(String(format: "  their mix moves by %.4f when your hidden bench changes", drift))
        check("their orders do not move when your hidden bench changes", drift < 0.001, String(format: "%.4f", drift))

        // And the leak it replaces: read off the real board, the bench is in
        // the arithmetic, so the two positions are not even the same matrix.
        let leaky = TurnGame(board: game).solve(iterations: 900)
        let leakySwapped = TurnGame(board: swapped).solve(iterations: 900)
        check("reading the real bench would have changed the matrix",
              leaky.payoff != leakySwapped.payoff)

        // Once it walks on, it is theirs to know.
        var shown = swapped
        shown.mine[0].hp = 0
        shown.fillGaps(mine: true, theirs: false)
        check("a Pokémon that has come in is no longer a guess",
              shown.mine[0].seen && !shown.asTheySeeIt.mine[0].build.form.id.isEmpty
                && shown.asTheySeeIt.mine[0].build.form.id == shown.mine[0].build.form.id)

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
