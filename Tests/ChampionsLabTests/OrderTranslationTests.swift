//  OrderTranslationTests.swift
//  What the app calls an order, said the way the simulator reads one.
//
//      swift test --filter OrderTranslationTests
//
//  A refused order does not fail quietly on its own -- it takes the whole
//  side's turn with it, because the engine is handed both Pokemon's choices
//  as one line. So a Charm aimed at your own partner, spelled without the
//  target Showdown needs, lost the *other* Pokemon's Mega Evolution too.

import XCTest
@testable import ChampionsLab

@MainActor
final class OrderTranslationTests: HarnessCase {
    /// A team whose first Pokemon can Mega Evolve and whose second has a move
    /// aimed at its partner.
    private func table() throws -> (Team, Form) {
        guard let mega = store.data.forms.first(where: { form in
            form.isMega && store.data.forms.contains { !$0.isMega && $0.dex == form.dex }
        }), let base = store.data.forms.first(where: { !$0.isMega && $0.dex == mega.dex }) else {
            throw XCTSkip("no Mega in the dex")
        }
        // A different species: a legal team has no two of the same, and
        // matching one Pokemon to its set is what tells them apart.
        guard let helper = store.data.forms.first(where: { form in
            form.dex != base.dex && form.moves.contains { store.move($0)?.aimsAtAlly == true }
        }), let ally = helper.moves.first(where: { store.move($0)?.aimsAtAlly == true }) else {
            throw XCTSkip("nothing with a move for its partner")
        }
        guard let filler = store.data.forms.first(where: {
            $0.dex != base.dex && $0.dex != helper.dex && !$0.isMega
        }) else { throw XCTSkip("not enough of a dex") }
        var team = Team(name: "Orders")
        team.format = "doubles"
        func slot(_ form: Form, moves: [String], item: String = "") -> TeamSlot {
            var out = TeamSlot(formID: form.id)
            out.ability = form.abilities.first?.name ?? ""
            out.item = item
            out.moves = moves
            out.sp = [2, 32, 0, 0, 0, 32]
            return out
        }
        // A plain attack aimed at one foe: not spread, not on itself, not on
        // its partner, so its target is the ordinary positive one.
        guard let attack = base.moves.first(where: { id in
            guard let move = store.move(id) else { return false }
            return move.category != "Other" && !move.isSpread
                && !move.aimsAtUser && !move.aimsAtAlly
        }) else { throw XCTSkip("\(base.formLabel) has no single-target attack") }
        let fillerMove = filler.moves.first { store.move($0)?.aimsAtAlly == false } ?? filler.moves[0]
        team.slots = [slot(base, moves: [attack], item: mega.megaTrigger),
                      slot(helper, moves: [ally, helper.moves.first { $0 != ally } ?? ally]),
                      slot(filler, moves: [fillerMove]),
                      slot(filler, moves: [fillerMove])]
        for index in team.slots.indices { team.slots[index].id = UUID() }
        return (team, mega)
    }

    func testAMoveOnYourOwnPartnerReachesIt() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let (team, _) = try table()
        let game = try ShowdownBattle.start(mine: team, theirs: team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [4, 4, 4, 4])
        // Whichever of the two carries the move for its partner: the board
        // stands its four in its own order, so which slot that is is the
        // board's to say.
        let ally = game.board.mine.prefix(2).firstIndex { $0.moves.first?.aimsAtAlly == true }
        guard let ally else { throw XCTSkip("neither lead leads with a move for its partner") }
        let play = ally == 0
            ? Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))
            : Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))
        _ = try game.play(mine: play, theirs: Play(left: .attack(move: 0, target: 0),
                                                   right: .attack(move: 0, target: 0)))
        check("the engine took the order as given", game.substituted.isEmpty,
              game.substituted.joined(separator: "; "))
        let said = game.board.story.joined(separator: " ")
        check("and the partner's move went off", said.contains("used"), String(said.prefix(120)))
    }

    /// The two together, which is the shape that broke: one Pokemon Mega
    /// Evolving while the other helps its partner.
    func testAMegaSurvivesAnOrderAimedAtAPartner() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let (team, mega) = try table()
        let game = try ShowdownBattle.start(mine: team, theirs: team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [5, 1, 2, 9])
        var play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0))
        play.megaSlot = 0
        _ = try game.play(mine: play, theirs: Play(left: .attack(move: 0, target: 0),
                                                   right: .attack(move: 0, target: 0)))
        check("nothing was substituted", game.substituted.isEmpty,
              game.substituted.joined(separator: "; "))
        check("and the stone went off: \(game.board.mine[0].build.form.formLabel)",
              game.board.mine[0].build.form.isMega
                || game.board.story.joined(separator: " ").contains("Mega"),
              "expected \(mega.formLabel)")
    }
}
