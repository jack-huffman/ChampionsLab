//  PlayerViewTests.swift
//  What the other player is sent is their side whole and this side as the
//  game has shown it, and a board survives the wire.

import XCTest
@testable import ChampionsLab

final class PlayerViewTests: HarnessCase {
    @MainActor private func game() -> Board {
        let mine = fighters([("Incineroar", "Sitrus Berry", ["U-turn", "Fake Out", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"]),
                             ("Milotic", "Leftovers", ["Scald"]),
                             ("Pelipper", "Damp Rock", ["Hurricane"])])
        let theirs = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "Protect"]),
                               ("Sneasler", "Grassy Seed", ["Close Combat"]),
                               ("Milotic", "Leftovers", ["Scald"]),
                               ("Whimsicott", "Focus Sash", ["Tailwind"]),
                               ("Garchomp", "Choice Scarf", ["Earthquake"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        return Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.formID),
                             theirs: theirs, theirBringing: theirs.slots.prefix(4).map(\.formID),
                             rules: store.rulebook, singles: false)
    }

    @MainActor func testTheOtherPlayerSeesTheirSideWholeAndOursAsShown() {
        let board = game()
        let view = board.asTheOtherPlayerSeesIt()
        check("the chair turned: their side is now mine", view.mine.map(\.build.form.id) == board.theirs.map(\.build.form.id))
        check("and whole", view.mine[0].build.item == "Black Glasses" && view.mine[0].moves.count == board.theirs[0].moves.count)
        let lead = view.theirs[0]
        check("our lead's form shows", lead.build.form.formLabel == "Incineroar")
        check("but not its item", lead.build.item.isEmpty)
        check("nor its ability", lead.build.ability.isEmpty)
        check("nor its moves", lead.moves.isEmpty)
        check("nor its spread", lead.build.sp.allSatisfy { $0 == 0 })
        check("our bench is what they would expect, not what it is",
              !view.theirs[2].seen && !view.theirs[3].seen)
        check("nothing worked out from our builds crosses", view.theirWorth.isEmpty && view.theirBeats.isEmpty)
    }

    @MainActor func testWhatTheGameShowsCrosses() {
        var board = game()
        board.mine[0].build.ability = "Intimidate"
        let uturn = at(board.mine[0], "U-turn")
        let out = TurnModel.resolve(board, mine: Play(left: .attack(move: uturn, target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        let view = out.asTheOtherPlayerSeesIt()
        let incineroar = view.theirs.first { $0.build.form.formLabel == "Incineroar" }
        check("a move used crosses", incineroar?.moves.map(\.name) == ["U-turn"], "\(incineroar?.moves.map(\.name) ?? [])")
        check("and still no item", incineroar?.build.item.isEmpty == true)
        check("the steps came across from their chair",
              view.steps.count == out.steps.count && view.steps.contains { $0.action?.byMine == false && $0.action?.move == "U-turn" })
        // The bench they have not seen is their expected pair, not ours, so
        // only what has come out is compared.
        let hostView = out.asThisPlayerSeesIt()
        check("the host's own view keeps the host's chair in its steps",
              hostView.steps.map { $0.action?.byMine } == out.steps.map { $0.action?.byMine }
                && hostView.mine.map(\.build.form.id) == out.mine.map(\.build.form.id))
        check("health as it is, for what has been seen",
              zip(view.theirs, out.mine).filter { $1.seen }.allSatisfy { $0.hp == $1.hp })
    }

    @MainActor func testABoardSurvivesTheWire() throws {
        let board = game().asTheOtherPlayerSeesIt()
        let sent = try JSONEncoder().encode(Wire.Snapshot(rqid: 3, turn: 1, board: board.wired, asking: .orders))
        let back = try JSONDecoder().decode(Wire.Snapshot.self, from: sent)
        let rebuilt = Board(wired: back.board)
        check("the request number", back.rqid == 3 && back.asking == .orders)
        check("both sides", rebuilt.mine.map(\.build.form.id) == board.mine.map(\.build.form.id)
              && rebuilt.theirs.map(\.build.form.id) == board.theirs.map(\.build.form.id))
        check("health, field and story", rebuilt.mine.map(\.hp) == board.mine.map(\.hp)
              && rebuilt.field.weather == board.field.weather && rebuilt.story == board.story)
        check("the steps, without their ids", rebuilt.steps.count == board.steps.count
              && rebuilt.steps.map(\.text) == board.steps.map(\.text))
        let framed = try Wire.frame(.snapshot(Wire.Snapshot(rqid: 3, turn: 1, board: board.wired, asking: .sendIn([1]))))
        var buffer = framed
        check("and frames as a message", (try Wire.unframe(&buffer)).count == 1)
    }
}
