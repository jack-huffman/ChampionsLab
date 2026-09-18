//  ImprisonTests.swift
//  Imprison seals what its user knows, not what it uses.
//
//      swift test --filter ImprisonTests

import XCTest
@testable import ChampionsLab

@MainActor
final class ImprisonTests: HarnessCase {
    /// Both sides carry Protect, so the seal has something to bite on.
    private func mirrored() -> Board {
        Board(mine: fighters([("Alakazam", "", ["Imprison", "Psychic", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Protect", "Calm Mind"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }

    /// Nothing across the field is on my Alakazam's list, so there is nothing
    /// to seal.
    private func sharingNothing() -> Board {
        Board(mine: fighters([("Alakazam", "", ["Imprison", "Psychic"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Scald", "Recover"]),
                                ("Farigiraf", "", ["Hyper Voice", "Calm Mind"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }

    private func cast(_ board: Board) -> Play {
        Play(left: .attack(move: at(board.mine[0], "Imprison"), target: 0),
             right: .attack(move: at(board.mine[1], "Protect"), target: 0))
    }

    func testImprisonSealsAMoveBothSidesKnow() {
        let start = mirrored()
        let sealed = TurnModel.resolve(start, mine: cast(start),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        check("the seal goes up", sealed.mine[0].imprisoning)
        check("and it is said so", sealed.story.contains { $0.contains("sealed away") },
              sealed.story.joined(separator: " | "))
        check("their Protect is sealed",
              MoveLegality.sealed(sealed.theirs[0].moves[at(sealed.theirs[0], "Protect")],
                                  byMine: false, board: sealed))
        // And clicking it costs them the turn.
        let refused = TurnModel.resolve(sealed,
            mine: Play(left: .attack(move: at(sealed.mine[0], "Psychic"), target: 0),
                       right: .attack(move: at(sealed.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(sealed.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(sealed.theirs[1], "Calm Mind"), target: 0)))
        check("and clicking it costs them the turn",
              refused.story.contains { $0.contains("cannot use the sealed Protect") },
              refused.story.joined(separator: " | "))
    }

    func testMySideIsNotSealedByMyOwnImprison() {
        let start = mirrored()
        let sealed = TurnModel.resolve(start, mine: cast(start),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Calm Mind"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        // My partner knows Protect too, and it is mine to use.
        let ours = sealed.mine[1].moves[at(sealed.mine[1], "Protect")]
        check("my own side may still use what I sealed",
              !MoveLegality.sealed(ours, byMine: true, board: sealed))
        check("and the search still offers it",
              !TurnGame(board: sealed).choices(forMine: true, slot: 1).isEmpty)
    }

    func testImprisonFailsWhenTheOtherSideKnowsNoneOfIt() {
        let start = sharingNothing()
        check("there is nothing to seal",
              !MoveLegality.imprisonWouldHold(byMine: true, slot: 0, board: start))
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Imprison"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Recover"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        check("so it fails", !after.mine[0].imprisoning)
        check("and says so", after.story.contains { $0.contains("But it failed") },
              after.story.joined(separator: " | "))
    }

    func testTheSealLeavesWithItsPokemon() {
        var start = mirrored()
        start.mine[0].imprisoning = true
        let protect = start.theirs[0].moves[at(start.theirs[0], "Protect")]
        check("sealed while it stands there",
              MoveLegality.sealed(protect, byMine: false, board: start))
        // Send it away. Nothing it did to the field survives it.
        var left = start
        Switching.depart(&left.mine, active: 0)
        check("and free once it has gone",
              !MoveLegality.sealed(protect, byMine: false, board: left))
    }

    func testSomethingSealedIntoACornerStruggles() {
        var start = Board(mine: fighters([("Alakazam", "", ["Imprison", "Psychic", "Protect"]),
                                          ("Rillaboom", "", ["Wood Hammer", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Psychic", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        // Their Milotic knows only what my Alakazam knows, so a seal leaves it
        // with nothing at all.
        start.mine[0].imprisoning = true
        check("nothing of theirs may be thrown",
              !MoveLegality.anyUsable(byMine: false, slot: 0, board: start))
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Psychic"), target: 1),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Psychic"), target: 0),
                         right: .attack(move: at(start.theirs[1], "Calm Mind"), target: 0)))
        check("so it Struggles", after.story.contains { $0.contains("used Struggle") },
              after.story.joined(separator: " | "))
    }
}
