//  EnginePlaybackTests.swift
//  A turn the engine resolved, handed to the thing that draws it.
//
//      swift test --filter EnginePlaybackTests
//
//  The battle screen animates a turn from its steps, and a step is only
//  animated if it carries the action behind it -- who used what. The reader
//  writing the protocol's text and nothing else is the difference between a
//  turn that plays and a turn that arrives as a list to click through.

import XCTest
@testable import ChampionsLab

@MainActor
final class EnginePlaybackTests: HarnessCase {
    func testASessionTurnReachesThePlaybackWithSomethingToPlay() throws {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no data/showdown-engine.js; run ./Scripts/mkengine.sh")
        }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let mine = ladder[0].team, theirs = ladder[1].team

        let playback = TurnPlayback()
        let session = BattleSession(rules: store.rulebook, playback: playback)
        // The field tells the playback how the scene is laid out; without it
        // nothing is choreographed, and the turn plays as bare text.
        playback.stage(MoveTimeline.Stage(size: CGSize(width: 900, height: 520), singles: false))

        let start = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.id.uuidString),
                                  theirs: theirs, rules: store.rulebook,
                                  singles: false, sendOut: false)
        let game = try ShowdownBattle.start(from: start, mine: mine, theirs: theirs,
                                            store: store, seed: [3, 3, 3, 3])
        session.showdown = game
        session.board = game.board

        let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
        let solved = TurnGame(board: game.board, believingTheirs: true).solve()
        session.resolve(game.board, mine: play, solved: solved)

        let steps = playback.replay
        check("the turn reached the playback", !steps.isEmpty, "\(steps.count) steps")
        let playable = steps.filter { $0.action != nil }
        check("and some of it is playable", !playable.isEmpty,
              "\(playable.count) of \(steps.count) carry an action")
        for step in playable.prefix(3) {
            guard let action = step.action else { continue }
            // A switch and a Mega Evolution are steps with no move in them:
            // the field draws both itself. Everything else names its move.
            let drawnByTheField = action.category == "Switch" || action.category == "Mega"
            check("  \(drawnByTheField ? action.category : action.move) is somebody's, of some kind",
                  drawnByTheField || (!action.move.isEmpty && !action.category.isEmpty),
                  "\(action.category)/\(action.type)")
        }
        check("the board moved on", session.board != nil)
    }

    /// Mega Evolution is part of the order, not something that happens to
    /// you: the sim is told on the move that triggers it, and left off the
    /// stone never goes off at all.
    func testAMegaEvolutionIsAskedFor() throws {
        guard ShowdownEngine.bundleURL() != nil else {
            throw XCTSkip("no engine")
        }
        // A Pokemon that holds a stone, and the order that should set it off.
        var team = Team(name: "Stones")
        team.format = "doubles"
        guard let base = store.data.forms.first(where: { form in
            store.data.forms.contains { $0.isMega && $0.dex == form.dex } && !form.isMega
        }) else { throw XCTSkip("no Mega in the dex") }
        guard let mega = store.data.forms.first(where: { $0.isMega && $0.dex == base.dex }) else {
            throw XCTSkip("no Mega")
        }
        var slot = TeamSlot(formID: base.id)
        slot.item = mega.megaTrigger
        slot.ability = base.abilities.first?.name ?? ""
        slot.moves = Array(base.moves.prefix(2))
        slot.sp = [2, 32, 0, 0, 0, 32]
        team.slots = [slot, slot, slot, slot]
        for index in team.slots.indices { team.slots[index].id = UUID() }

        let game = try ShowdownBattle.start(mine: team, theirs: team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [5, 5, 5, 5])
        print("  item: \(slot.item)  base: \(base.formLabel) -> \(mega.formLabel)")
        if let req = try ShowdownEngine.shared.request("p1") {
            print("  canMegaEvo present: \(req.contains("canMegaEvo"))")
            if let r = req.range(of: "\"canMegaEvo\"[^,]*", options: .regularExpression) {
                print("  -> \(req[r])")
            }
        }
        var play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
        play.megaSlot = 0
        _ = try? game.play(mine: play, theirs: Play(left: .attack(move: 0, target: 0),
                                                    right: .attack(move: 0, target: 1)))
        let said = game.board.story.joined(separator: " ")
        check("the stone went off", said.lowercased().contains("mega")
              || game.board.mine[0].build.form.isMega,
              "\(game.board.mine[0].build.form.formLabel): \(said.prefix(120))")
    }
}
