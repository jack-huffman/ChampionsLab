//  TurnOrderTests.swift
//  The order a turn actually resolves in, and what each action costs the one that took it.
//
//      swift test --filter TurnOrderTests

import XCTest
@testable import ChampionsLab

final class TurnOrderTests: HarnessCase {
    /// status, screens, residuals and the rest of what a turn does
    @MainActor func testTheRestOfATurn() throws {
print("\n== the rest of a turn ==")
    func fighters(_ rows: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = rows.map { name, item, moveNames in
            var slot = TeamSlot(formID: form(name).id)
            slot.item = item
            slot.ability = form(name).abilities.first?.name ?? ""
            slot.moves = moveNames.compactMap { n in
                store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32
            sp[Stat.hp.rawValue] = 2
            slot.sp = sp; slot.alignmentName = "Adamant"
            return slot
        }
        return out
    }
    let supporters = fighters([
        ("Incineroar", "Sitrus Berry", ["Will-O-Wisp", "Fake Out", "Flare Blitz", "Protect"]),
        ("Indeedee (Female)", "Leftovers", ["Follow Me", "Protect", "Dazzling Gleam"]),
        ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let aggressors = fighters([
        ("Garchomp", "Focus Sash", ["Earthquake", "Swords Dance", "Rock Slide", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
        ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let opening = Board(mine: supporters, theirs: aggressors, store: store,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    func at(_ fighter: Fighter, _ name: String) -> Int {
        fighter.moves.firstIndex { $0.name == name } ?? 0
    }

    let firstTurn = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Will-O-Wisp"), target: 0),
                   right: .attack(move: at(opening.mine[1], "Follow Me"), target: 0)),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Wood Hammer"), target: 1)))
    print("  the turn, in order:")
    for line in firstTurn.story.prefix(7) { print("    \(line)") }
    check("Will-O-Wisp actually burns something",
          firstTurn.theirs[0].status == .burn, firstTurn.theirs[0].status.rawValue)
    check("a burn then costs health between turns",
          firstTurn.theirs[0].hp < firstTurn.theirs[0].maxHP)
    check("Swords Dance actually raises Attack",
          firstTurn.theirs[0].build.boosts[Stat.attack.rawValue] == 2,
          "\(firstTurn.theirs[0].build.boosts[Stat.attack.rawValue])")
    // Follow Me was aimed away from Indeedee, so redirection has to have moved it.
    check("Follow Me pulls a single-target move onto itself",
          firstTurn.mine[1].hp < firstTurn.mine[1].maxHP
            || firstTurn.mine[1].fainted,
          "\(firstTurn.mine[1].hp)/\(firstTurn.mine[1].maxHP)")
    check("and the turn reads as a sequence rather than one line",
          firstTurn.story.count >= 5, "\(firstTurn.story.count)")

    // Protect, however it was chosen.
    var settled = firstTurn
    settled.fillGaps()
    let behindProtect = TurnModel.resolve(
        settled,
        mine: Play(left: .attack(move: at(settled.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: at(settled.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(settled.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(settled.theirs[1], "Wood Hammer"), target: 0)))
    check("Protect picked as a move still protects",
          behindProtect.mine[0].hp == settled.mine[0].hp,
          "\(behindProtect.mine[0].hp) vs \(settled.mine[0].hp)")

    // Screens, redirection of spread moves, and Wide Guard.
    let screened = fighters([("Whimsicott", "Focus Sash", ["Light Screen", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Wide Guard", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let wide = Board(mine: screened, theirs: aggressors, store: store,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    let blocked = TurnModel.resolve(
        wide,
        mine: Play(left: .attack(move: at(wide.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(wide.mine[1], "Wide Guard"), target: 0)),
        theirs: Play(left: .attack(move: at(wide.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(wide.theirs[1], "Protect"), target: 0)))
    check("Wide Guard turns a spread move away from the whole side",
          blocked.mine[1].hp == wide.mine[1].maxHP,
          "\(blocked.mine[1].hp)/\(wide.mine[1].maxHP)")

    let lit = TurnModel.resolve(
        wide,
        mine: Play(left: .attack(move: at(wide.mine[0], "Light Screen"), target: 0),
                   right: .attack(move: at(wide.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(wide.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(wide.theirs[1], "Protect"), target: 0)))
    check("Light Screen goes up and stays up", lit.myScreens.lightScreen > 0,
          "\(lit.myScreens.lightScreen)")

    // Rolling is what separates a battle from an evaluation.
    var rolls = Set<Int>()
    for _ in 0..<40 {
        let rolled = TurnModel.resolve(
            opening,
            mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                       right: .protectSelf(move: at(opening.mine[1], "Protect"))),
            theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)), rolling: true)
        rolls.insert(rolled.theirs[0].hp)
    }
    print("  the same attack, rolled forty times: \(rolls.count) different results")
    check("a played turn rolls the damage", rolls.count > 1, "\(rolls.count)")
    let averaged = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                   right: .protectSelf(move: at(opening.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)))
    let again = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                   right: .protectSelf(move: at(opening.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)))
    check("while the search still gets the same answer every time",
          averaged.theirs[0].hp == again.theirs[0].hp)

    // -- turn order is re-checked, not decided once -------------------------
    //
    // A Prankster Whimsicott putting up Tailwind goes first on priority, and
    // its partner -- which has not moved yet -- is twice as fast from that
    // moment. Sorting the whole turn up front makes that impossible, and it is
    // most of why the move is worth a slot.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// order re-checked before every action, not sorted once
    @MainActor func testTurnOrder() throws {
print("\n== turn order ==")
    let windUp = fighters([("Whimsicott", "Focus Sash", ["Tailwind", "Protect"]),
                           ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                           ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let quick = fighters([("Garchomp", "Choice Scarf", ["Earthquake", "Protect"]),
                          ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                          ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var windBoard = Board(mine: windUp, theirs: quick, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    windBoard.mine[0].build.ability = "Prankster"
    let mySlow = windBoard.mine[1].build.speed(in: windBoard.field)
    let theirFast = windBoard.theirs[1].build.speed(in: windBoard.field)
    print("  your Incineroar \(mySlow) against their Rillaboom \(theirFast)")
    let blown = TurnModel.resolve(
        windBoard,
        mine: Play(left: .attack(move: at(windBoard.mine[0], "Tailwind"), target: 0),
                   right: .attack(move: at(windBoard.mine[1], "Flare Blitz"), target: 1)),
        theirs: Play(left: .attack(move: at(windBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(windBoard.theirs[1], "Wood Hammer"), target: 1)))
    let order = blown.story
    print("  the turn, in order:")
    for line in order.prefix(6) { print("    \(line)") }
    check("Tailwind went up", blown.myTailwind > 0, "\(blown.myTailwind)")
    // Incineroar is slower than Rillaboom on raw Speed, so without Tailwind
    // taking effect immediately it could only have moved second.
    let incinAt = order.firstIndex { $0.contains("Incineroar used") }
    let rillaAt = order.firstIndex { $0.contains("Rillaboom used") }
    // Either it moved first, or it moved first and knocked the other out before
    // it could — both mean the Tailwind applied inside the turn.
    check("and the partner it sped up moved before something faster than it",
          mySlow < theirFast && incinAt != nil && (rillaAt == nil || incinAt! < rillaAt!),
          "Incineroar at \(incinAt.map(String.init) ?? "-"), Rillaboom at \(rillaAt.map(String.init) ?? "-")")

    // Every line of a turn is in some step, and every step carries the board
    // as it stood, so the turn can be walked without losing anything.
    let stepped = blown.steps.flatMap { $0.text.split(separator: "\n").map(String.init) }
    check("every line of the turn is in a step", stepped == blown.story,
          "\(stepped.count) lines in \(blown.steps.count) steps vs \(blown.story.count)")
    check("and the snapshots carry the field with them",
          blown.steps.last?.myTailwind ?? 0 > 0)
    // A spread move is one step that names everyone it hit.
    let heaters = fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                            ("Whimsicott", "Focus Sash", ["Protect"])])
    let heated = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake"]),
                           ("Rillaboom", "Life Orb", ["Wood Hammer"])])
    let heatBoard = Board(mine: heaters, theirs: heated, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    let heatTurn = TurnModel.resolve(
        heatBoard,
        mine: Play(left: .attack(move: at(heatBoard.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(heatBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(heatBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(heatBoard.theirs[1], "Wood Hammer"), target: 1)))
    let heatStep = heatTurn.steps.first { $0.text.contains("Heat Wave") }
    print("  the Heat Wave step:")
    for line in heatStep?.text.split(separator: "\n") ?? [] { print("    \(line)") }
    check("a spread move is a single step",
          heatTurn.steps.filter { $0.text.contains("Heat Wave") }.count == 1,
          "\(heatTurn.steps.filter { $0.text.contains("Heat Wave") }.count)")
    check("and that step names both it hit",
          heatStep?.text.contains("Garchomp") == true && heatStep?.text.contains("Rillaboom") == true)

    // Final Gambit, and the rest of what a move costs the one that used it.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// recoil, crash, Life Orb and the moves that end the user's game
    @MainActor func testWhatAMoveCosts() throws {
print("\n== what a move costs its user ==")
    if store.data.moves.values.contains(where: { $0.name == "Final Gambit" }) {
        let gambit = fighters([("Whimsicott", "Focus Sash", ["Final Gambit", "Protect"]),
                               ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                               ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
        let board2 = Board(mine: gambit, theirs: quick, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        if board2.mine[0].moves.contains(where: { $0.name == "Final Gambit" }) {
            let after = TurnModel.resolve(
                board2,
                mine: Play(left: .attack(move: at(board2.mine[0], "Final Gambit"), target: 0),
                           right: .attack(move: at(board2.mine[1], "Protect"), target: 0)),
                // Into something attacking, not Protecting: a Final Gambit that
                // is blocked leaves its user standing, as in the game.
                theirs: Play(left: .attack(move: board2.theirs[0].moves.firstIndex { !DuelEngine.protectMoves.contains($0.name) } ?? 0, target: 1),
                             right: .attack(move: at(board2.theirs[1], "Protect"), target: 0)))
            check("Final Gambit faints the one that used it",
                  after.mine[0].fainted, "\(after.mine[0].hp)")
        }
    }
    // Recoil, and a Life Orb.
    let orbed = fighters([("Garchomp", "Life Orb", ["Double-Edge", "Protect"]),
                          ("Incineroar", "Sitrus Berry", ["Protect"]),
                          ("Whimsicott", "Focus Sash", ["Protect"])])
    let orbBoard = Board(mine: orbed, theirs: quick, store: store,
                         field: Field(isDoubles: true), alreadyEvolved: false)
    if orbBoard.mine[0].moves.contains(where: { $0.name == "Double-Edge" }) {
        let after = TurnModel.resolve(
            orbBoard,
            mine: Play(left: .attack(move: at(orbBoard.mine[0], "Double-Edge"), target: 1),
                       right: .attack(move: at(orbBoard.mine[1], "Protect"), target: 0)),
            // They have to actually stand there, or nothing lands and nothing
            // is paid for it.
            theirs: Play(left: .attack(move: at(orbBoard.theirs[0], "Earthquake"), target: 0),
                         right: .attack(move: at(orbBoard.theirs[1], "Wood Hammer"), target: 0)))
        print("  Double-Edge off a Life Orb cost the user "
              + "\(orbBoard.mine[0].maxHP - after.mine[0].hp)")
        check("recoil and a Life Orb both come out of the attacker",
              after.mine[0].hp < orbBoard.mine[0].maxHP,
              "\(after.mine[0].hp)/\(orbBoard.mine[0].maxHP)")
    }

    // -- abilities that refuse priority outright -----------------------------
    //
    // Armor Tail and Queenly Majesty stop anything with increased priority
    // reaching that Pokemon or its partner. It is why Farigiraf is on Trick
    // Room teams: it is what stops a Fake Out taking the setup turn away.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Armor Tail and the abilities that refuse priority outright
    @MainActor func testPriorityRefused() throws {
print("\n== priority refused ==")
    let guarded2 = fighters([("Farigiraf", "Mental Herb", ["Trick Room", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let fakers = fighters([("Rillaboom", "Life Orb", ["Fake Out", "Wood Hammer", "Protect"]),
                           ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var tailed = Board(mine: guarded2, theirs: fakers, store: store,
                       field: Field(isDoubles: true), alreadyEvolved: false)
    tailed.mine[0].build.ability = "Armor Tail"
    print("  your lead is \(tailed.mine[0].build.form.formLabel) with "
          + "\(tailed.mine[0].build.ability)")
    let refused = TurnModel.resolve(
        tailed,
        mine: Play(left: .attack(move: at(tailed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(tailed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tailed.theirs[0], "Fake Out"), target: 0),
                     right: .attack(move: at(tailed.theirs[1], "Fake Out"), target: 1)))
    for line in refused.story.prefix(6) { print("    \(line)") }
    check("a Fake Out aimed at the Armor Tail is refused",
          refused.story.contains { $0.contains("refused it") })
    check("and nothing on that side flinched",
          !refused.mine[0].flinched && !refused.mine[1].flinched)

    // It must not refuse a priority move aimed at its own side.
    let ownSide = TurnModel.resolve(
        tailed,
        mine: Play(left: .attack(move: at(tailed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(tailed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tailed.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(tailed.theirs[1], "Protect"), target: 0)))
    check("but Protect, which is priority aimed at itself, still works",
          ownSide.story.contains { $0.contains("braced") })

    // And the search stops offering a move that cannot be used.
    var tailedGame = TurnGame(board: tailed)
    tailedGame.width = 8
    let theirOptions = tailedGame.choices(forMine: false, slot: 0)
    let stillOffered = theirOptions.contains { choice in
        if case .attack(let index, _) = choice,
           tailed.theirs[0].moves.indices.contains(index) {
            return tailed.theirs[0].moves[index].name == "Fake Out"
        }
        return false
    }
    check("the search stops offering Fake Out into it", !stillOffered)

    // -- who comes in ---------------------------------------------------------
    //
    // The game asks, and it matters: whoever arrives takes whatever lands next
    // turn without acting first. The battle fills the opponent's gaps and
    // leaves yours for you.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// who comes in when something falls
    @MainActor func testSendingOneIn() throws {
print("\n== sending one in ==")
    var wounded = Board(mine: supporters, theirs: aggressors, store: store,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    wounded.mine[0].hp = 0
    wounded.theirs[0].hp = 0
    var asked = wounded
    asked.fillGaps(mine: false, theirs: true)
    check("their side fills itself", !asked.theirs[0].fainted,
          asked.theirs[0].build.form.formLabel)
    check("yours is left standing empty, to be chosen", asked.mine[0].fainted)
    check("and it says which slot is waiting", asked.gapsOfMine == [0],
          "\(asked.gapsOfMine)")
    let bench = (asked.activeCount..<asked.mine.count).first { !asked.mine[$0].fainted }!
    let comingIn = asked.mine[bench].build.form.formLabel
    asked.sendIn(bench, to: 0)
    check("sending one in puts that one in", asked.mine[0].build.form.formLabel == comingIn,
          asked.mine[0].build.form.formLabel)
    check("it arrives having not acted yet", asked.mine[0].justArrived)
    check("and there is nothing left waiting", asked.gapsOfMine.isEmpty)

    // A search cannot stop to ask, so it still fills both.
    var searching = wounded
    searching.fillGaps()
    check("a search fills both sides so it can keep going",
          !searching.mine[0].fainted && !searching.theirs[0].fainted)

    // -- what an ability does during a turn -----------------------------------

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
