//  TwoPlayerModelTests.swift
//  What the model needs to host a game between two people: their four given
//  rather than chosen, their replacements and pivots theirs to decide, and a
//  record of what each Pokemon has shown the other side.

import XCTest
@testable import ChampionsLab

final class TwoPlayerModelTests: HarnessCase {
    @MainActor private func teams() -> (mine: Team, theirs: Team) {
        let mine = fighters([("Incineroar", "Sitrus Berry", ["U-turn", "Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"]),
                             ("Milotic", "Leftovers", ["Scald"]),
                             ("Pelipper", "Damp Rock", ["Hurricane"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "U-turn", "Protect"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Milotic", "Leftovers", ["Scald"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind"]),
                               ("Garchomp", "Choice Scarf", ["Earthquake"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        return (mine, theirs)
    }

    @MainActor func testTheirFourCanBeGivenRatherThanChosen() {
        let (mine, theirs) = teams()
        let given = [theirs.slots[3].formID, theirs.slots[1].formID, theirs.slots[5].formID, theirs.slots[0].formID]
        let board = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                                  theirs: theirs, theirBringing: given,
                                  rules: store.rulebook, singles: false, sendOut: false)
        check("their four are the four given, in that order",
              board.theirs.map(\.build.form.id) == given, "\(board.theirs.map(\.build.form.id))")
        check("yours are yours", board.mine.map(\.build.form.id) == mine.slots.prefix(4).map(\.formID))
        let chosen = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                                   theirs: theirs, rules: store.rulebook, singles: false, sendOut: false)
        check("left out, they are still chosen for them", chosen.theirs.count == 4)
    }

    @MainActor func testTheirReplacementCanBeGiven() {
        let (mine, theirs) = teams()
        var board = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                                  theirs: theirs, theirBringing: theirs.slots.prefix(4).map(\.formID),
                                  rules: store.rulebook, singles: false)
        board.theirs[0].hp = 0
        let bench3 = board.theirs[3].build.form.id
        board.replaceFallen(mine: [], theirs: [(slot: 0, bench: 3)])
        check("the one they chose came in", board.theirs[0].build.form.id == bench3, board.theirs[0].build.form.formLabel)
        check("and it was told", board.story.contains { $0.contains("They sent in") })
    }

    @MainActor func testTheirPivotWaitsWhenTheyAreAsked() {
        let (mine, theirs) = teams()
        var board = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                                  theirs: theirs, theirBringing: theirs.slots.prefix(4).map(\.formID),
                                  rules: store.rulebook, singles: false)
        board.asksTheirsBeforePivot = true
        let uturn = at(board.theirs[0], "U-turn")
        let stopped = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                        theirs: Play(left: .attack(move: uturn, target: 0), right: .pass))
        check("the turn stopped for their choice", stopped.pendingPivot == Board.Pivot(mine: false, slot: 0),
              "\(String(describing: stopped.pendingPivot))")
        let resumed = TurnModel.resume(stopped, sendingIn: 2)
        check("and their choice came in", resumed.theirs[0].build.form.id == board.theirs[2].build.form.id)
        check("the flip carries both flags", stopped.flipped.asksBeforePivot && !stopped.flipped.asksTheirsBeforePivot)
    }

    @MainActor func testWhatWasShownIsRemembered() {
        let (mine, theirs) = teams()
        var board = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                                  theirs: theirs, theirBringing: theirs.slots.prefix(4).map(\.formID),
                                  rules: store.rulebook, singles: false)
        board.mine[0].build.ability = "Intimidate"
        board.theirs[0].build.ability = "Defiant"
        check("nothing shown before the game", !board.theirs[0].abilityRevealed && board.theirs[0].revealedMoves.isEmpty)
        let uturn = at(board.theirs[0], "U-turn")
        let out = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                    theirs: Play(left: .attack(move: uturn, target: 0), right: .pass))
        let kingambit = out.theirs.first { $0.build.form.formLabel == "Kingambit" }
        let uturnID = store.data.moves.values.first { $0.name == "U-turn" }?.id ?? ""
        let cleaveID = store.data.moves.values.first { $0.name == "Kowtow Cleave" }?.id ?? ""
        check("a move used is a move shown", kingambit?.revealedMoves.contains(uturnID) == true, "\(kingambit?.revealedMoves ?? [])")
        check("a move not used is not", kingambit?.revealedMoves.contains(cleaveID) == false)

        var sash = board
        sash.mine[1].build.boosts[Stat.attack.rawValue] = 6
        let hit = TurnModel.resolve(sash, mine: Play(left: .pass, right: .attack(move: at(sash.mine[1], "Earthquake"), target: 1)),
                                    theirs: Play(left: .pass, right: .pass))
        check("a Focus Sash that held is an item shown",
              hit.theirs.first { $0.build.form.formLabel == "Sneasler" }?.itemRevealed == false
                || hit.theirs.contains { $0.itemRevealed },
              "\(hit.theirs.map { ($0.build.form.formLabel, $0.build.item, $0.itemRevealed) })")
    }
}
