//  CrownTests.swift
//  Who wears the crown when a game ends.

import XCTest
@testable import ChampionsLab

@MainActor
final class CrownTests: HarnessCase {
    private func session(_ board: Board) -> BattleSession {
        BattleSession(rules: store.rulebook, playback: TurnPlayback(), board: board)
    }

    private func lineup() -> Board {
        let mine = fighters([("Garchomp", "Life Orb", ["Earthquake"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        return Board(mine: mine, theirs: theirs, rules: store.rulebook)
    }

    func testNobodyIsCrownedWhileTheGameIsOn() {
        let board = lineup()
        check("no crown yet", session(board).won(board) == nil)
    }

    func testTheSideStillStandingIsCrowned() {
        var board = lineup()
        for index in board.theirs.indices { board.theirs[index].hp = 0 }
        let mine = session(board)
        mine.finished = "You win."
        check("mine wears it", mine.won(board) == true)

        var other = lineup()
        for index in other.mine.indices { other.mine[index].hp = 0 }
        let theirs = session(other)
        theirs.finished = "They win."
        check("theirs wears it", theirs.won(other) == false)
    }

    func testTheVerdictIsThreeWordsNotASentenceAboutHavingNothingLeft() {
        var board = lineup()
        for index in board.theirs.indices { board.theirs[index].hp = 0 }
        let out = TurnModel.resolve(board, mine: Play(left: .pass, right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        let session = self.session(out)
        session.finished = out.isOut(mine: false) ? "You win." : "They win."
        check("short and plain", session.finished == "You win.", session.finished ?? "-")
        check("and says nothing about what is left",
              session.finished?.contains("nothing left") == false)
    }
}
