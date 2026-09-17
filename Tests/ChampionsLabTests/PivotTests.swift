//  PivotTests.swift
//  Moves whose user leaves: a U-turn stops a played turn for the choice of
//  who comes in and the turn resumes after; theirs, and yours in a search,
//  send in the best answer at once; a U-turn into Protect stays; nowhere to
//  go is said.

import XCTest
@testable import ChampionsLab

final class PivotTests: HarnessCase {
    @MainActor private func lineup() -> Board {
        let mine = fighters([("Incineroar", "Sitrus Berry", ["U-turn", "Parting Shot", "Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer", "U-turn"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "Swords Dance", "U-turn", "Protect"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat", "Dire Claw", "Protect"]),
                               ("Milotic", "Leftovers", ["Scald", "Recover"]),
                               ("Pelipper", "Sitrus Berry", ["Hurricane", "Protect"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook)
    }

    @MainActor func testTheDexSaysWhichMovesPivot() {
        let names = Set(store.data.moves.values.filter(\.pivots).map(\.name))
        for name in ["U-turn", "Volt Switch", "Flip Turn", "Parting Shot", "Teleport", "Chilly Reception"] {
            check("\(name) pivots", names.contains(name))
        }
        check("Revival Blessing does not, whatever Showdown's table borrows", !names.contains("Revival Blessing"))
        check("a plain attack does not", !(store.data.moves.values.first { $0.name == "Flare Blitz" }?.pivots ?? true))
    }

    @MainActor func testAUturnOfYoursStopsAPlayedTurnAndItResumes() {
        var board = lineup()
        board.asksBeforePivot = true
        let uturn = at(board.mine[0], "U-turn")
        let dance = at(board.theirs[0], "Swords Dance")
        let stopped = TurnModel.resolve(board,
                                        mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                        theirs: Play(left: .attack(move: dance, target: 0), right: .pass))
        check("the turn stopped at the pivot",
              stopped.pendingPivot == Board.Pivot(mine: true, slot: 0), "\(String(describing: stopped.pendingPivot))")
        check("with the rest of the turn waiting",
              stopped.paused?.contains { !$0.mine && $0.slot == 0 } == true)
        check("Kingambit took the hit first", stopped.theirs[0].hp < board.theirs[0].hp)
        check("Kingambit has not moved yet", !stopped.story.contains { $0.contains("Swords Dance") })
        check("Incineroar stands there until somebody is chosen",
              stopped.mine[0].build.form.formLabel == "Incineroar")
        check("the leaving was told", stopped.story.contains { $0.contains("Incineroar went out") })

        let resumed = TurnModel.resume(stopped, sendingIn: 2)
        check("Rillaboom came in", resumed.mine[0].build.form.formLabel == "Rillaboom")
        check("and was told", resumed.story.contains { $0.contains("Rillaboom came in for Incineroar") })
        check("Incineroar sits on the bench", resumed.mine[2].build.form.formLabel == "Incineroar")
        check("then Kingambit moved", resumed.story.contains { $0.contains("Swords Dance") })
        check("and the turn is finished", resumed.pendingPivot == nil && resumed.paused == nil)
        check("the steps carry on from the stop", resumed.steps.count > stopped.steps.count)
    }

    @MainActor func testTheirsAndTheSearchSendInTheBestAtOnce() {
        var board = lineup()
        let theirUturn = at(board.theirs[0], "U-turn")
        let theirs = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                       theirs: Play(left: .attack(move: theirUturn, target: 0), right: .pass))
        check("their U-turn did not stop the turn", theirs.pendingPivot == nil && theirs.paused == nil)
        check("Kingambit went out", theirs.theirs[0].build.form.formLabel != "Kingambit")
        check("and it was told", theirs.story.contains { $0.contains("Kingambit went out;") })

        board.asksBeforePivot = true
        let asked = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                      theirs: Play(left: .attack(move: theirUturn, target: 0), right: .pass))
        check("asking is for yours only", asked.pendingPivot == nil)

        let searching = lineup()
        let uturn = at(searching.mine[0], "U-turn")
        let auto = TurnModel.resolve(searching, mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                     theirs: Play(left: .pass, right: .pass))
        check("a search does not stop", auto.pendingPivot == nil)
        check("Incineroar went out anyway", auto.mine[0].build.form.formLabel != "Incineroar")
        check("for somebody from the bench", ["Rillaboom", "Whimsicott"].contains(auto.mine[0].build.form.formLabel))
    }

    @MainActor func testAUturnIntoProtectStays() {
        var board = lineup()
        board.asksBeforePivot = true
        let uturn = at(board.mine[0], "U-turn")
        let protect = at(board.theirs[0], "Protect")
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                    theirs: Play(left: .protectSelf(move: protect), right: .pass))
        check("nothing was hit", out.theirs[0].hp == board.theirs[0].hp)
        check("so nobody left", out.pendingPivot == nil && out.mine[0].build.form.formLabel == "Incineroar")
    }

    @MainActor func testPartingShotDropsThenLeaves() {
        var board = lineup()
        board.asksBeforePivot = true
        let shot = at(board.mine[0], "Parting Shot")
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: shot, target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        // Kingambit's Defiant answers the Attack drop; the Sp. Atk drop stands.
        check("Kingambit's Sp. Atk fell", out.theirs[0].build.boosts[Stat.spAttack.rawValue] < 0)
        check("and the turn stopped for who comes in", out.pendingPivot == Board.Pivot(mine: true, slot: 0))
        let resumed = TurnModel.resume(out, sendingIn: 3)
        check("Whimsicott came in", resumed.mine[0].build.form.formLabel == "Whimsicott")
        check("once", resumed.story.filter { $0.contains("came in") }.count == 1)
    }

    @MainActor func testNowhereToGoIsSaid() {
        var board = lineup()
        board.asksBeforePivot = true
        board.mine[2].hp = 0
        board.mine[3].hp = 0
        let uturn = at(board.mine[0], "U-turn")
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the hit landed", out.theirs[0].hp < board.theirs[0].hp)
        check("nobody could come in", out.pendingPivot == nil && out.mine[0].build.form.formLabel == "Incineroar")
        check("and it was said", out.story.contains { $0.contains("nowhere to go") })
    }

    @MainActor func testTheFlipCarriesAStoppedTurn() {
        var board = lineup()
        board.asksBeforePivot = true
        let uturn = at(board.mine[0], "U-turn")
        let dance = at(board.theirs[0], "Swords Dance")
        let stopped = TurnModel.resolve(board, mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                        theirs: Play(left: .attack(move: dance, target: 0), right: .pass))
        let flipped = stopped.flipped
        check("the pivot changes sides", flipped.pendingPivot == Board.Pivot(mine: false, slot: 0))
        let waiting = stopped.paused ?? [], turned = flipped.paused ?? []
        check("and so does what is waiting",
              !waiting.isEmpty && waiting.count == turned.count
                && zip(waiting, turned).allSatisfy { $0.mine != $1.mine })
    }

    @MainActor func testShedTailLeavesItsShellForWhoeverIsChosen() {
        let mine = fighters([("Orthworm", "Leftovers", ["Shed Tail", "Protect"]),
                             ("Milotic", "Leftovers", ["Protect"]),
                             ("Garchomp", "Leftovers", ["Protect"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let theirs = fighters([("Rillaboom", "Leftovers", ["Protect"]),
                               ("Kingambit", "Leftovers", ["Protect"]),
                               ("Milotic", "Leftovers", ["Scald"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.asksBeforePivot = true
        let worm = board.mine[0]
        let stopped = TurnModel.resolve(board,
                                        mine: Play(left: .attack(move: at(worm, "Shed Tail"), target: 0), right: .pass),
                                        theirs: Play(left: .pass, right: .pass))
        check("Shed Tail stopped the turn to ask", stopped.pendingPivot?.slot == 0)
        check("carrying the shell", stopped.pendingPivot?.carrying?.substitute == worm.maxHP / 4)
        check("Orthworm paid for it already", stopped.mine[0].hp == worm.maxHP - worm.maxHP / 2)
        let resumed = TurnModel.resume(stopped, sendingIn: 2)
        check("Garchomp was chosen", resumed.mine[0].build.form.formLabel == "Garchomp")
        check("and stands behind the shell", resumed.mine[0].substitute == worm.maxHP / 4,
              "\(resumed.mine[0].substitute)")
        check("Orthworm has none", resumed.mine[2].substitute == 0)
    }
}
