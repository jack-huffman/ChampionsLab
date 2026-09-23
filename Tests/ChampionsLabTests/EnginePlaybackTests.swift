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
        // And having gone off, it is gone. The deck offers "Mega Evolve" for
        // any Pokemon still holding one in hand, so a side that does not
        // record having spent its one is asked again the turn after -- on a
        // Pokemon that has already done it.
        if game.board.mine[0].build.form.isMega || said.lowercased().contains("mega") {
            check("the side has spent its one Mega",
                  game.board.mine.allSatisfy(\.hasMegaEvolved))
            check("and nobody is still holding one in hand",
                  game.board.mine.allSatisfy { $0.pendingMega == nil },
                  "\(game.board.mine.compactMap { $0.pendingMega?.formLabel })")
        }
    }

    /// The field works a move's aim out from whoever took damage, and a move
    /// that missed damaged nobody. Left without an aim, a move is played as a
    /// move on the user -- so a missed Close Combat went off over the Pokemon
    /// that threw it rather than flying past the one it was meant for.
    func testEveryMovePlayedSaysWhereItWasAimed() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let game = try ShowdownBattle.start(mine: ladder[0].team, theirs: ladder[1].team,
                                            myFour: [0, 1, 2, 3], theirFour: [0, 1, 2, 3],
                                            store: store, seed: [7, 7, 7, 7])
        var seen = 0, aimless: [String] = []
        for _ in 0..<6 {
            let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
            // A turn that cannot be played -- somebody has fainted and is
            // owed a replacement, or the game is over -- ends the sample.
            guard (try? game.play(mine: play, theirs: play)) != nil else { break }
            for step in game.board.steps {
                guard let action = step.action, action.category != "Switch",
                      action.category != "Mega", !action.move.isEmpty,
                      action.stopped == nil else { continue }
                seen += 1
                if action.target == nil && !action.aimsAtUser && !action.aimsAtAlly {
                    aimless.append(action.move)
                }
            }
        }
        check("moves were played", seen > 0, "\(seen)")
        check("and every one of them says where it went",
              aimless.isEmpty, "aimless: \(Set(aimless).sorted().joined(separator: ", "))")
    }

    /// A miss is drawn over the Pokemon that avoided it, the way an immunity
    /// is -- and it reaches the other chair, where all three of the field's
    /// badges were being dropped on the way.
    func testAMissIsSaidOverThePokemonThatAvoidedIt() {
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { return check("no ladder teams", false) }
        var board = Board.opening(mine: ladder[0].team,
                                  bringing: ladder[0].team.slots.prefix(4).map(\.id.uuidString),
                                  theirs: ladder[1].team, rules: store.rulebook,
                                  singles: false, sendOut: true)
        // A step that says a move went past somebody and nothing else. The
        // badge is the whole of what the field has to draw, which is the
        // case the marker exists for.
        board.beginStep()
        board.miss(onMine: false, slot: 1, by: "Focus Blast")
        board.note("It missed.")
        board.closeStep()

        guard let step = board.steps.last else { return check("a step was made", false) }
        check("the step says who avoided it",
              step.missed == [Board.Step.Firing(mine: false, slot: 1, name: "Focus Blast")],
              "\(step.missed)")
        // From the other chair it is their own Pokemon that dodged.
        check("and from the other chair it is the other side's",
              step.flipped.missed == [Board.Step.Firing(mine: true, slot: 1, name: "Focus Blast")],
              "\(step.flipped.missed)")
        // And it survives the wire, where it has to cross to be drawn at all.
        do {
            let wire = try JSONEncoder().encode(step)
            let back = try JSONDecoder().decode(Board.Step.self, from: wire)
            check("and it survives the wire", back.missed == step.missed, "\(back.missed)")
        } catch {
            check("and it survives the wire", false, "\(error)")
        }

        // The playback reads it into the seat the field draws over.
        let playback = TurnPlayback()
        playback.show(board, steps: board.steps)
        playback.replay(step: board.steps.count - 1)
        check("the field is told to draw it",
              playback.missed.contains(Seat(mine: false, slot: 1)), "\(playback.missed)")
    }

    /// A turn plays itself once and then it is your move. Watching it again
    /// is a button, not the next thing that happens to you.
    func testTheTurnDoesNotLeaveAReplayStandingInTheWay() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { throw XCTSkip("no ladder teams") }
        let mine = ladder[0].team, theirs = ladder[1].team
        let playback = TurnPlayback()
        let session = BattleSession(rules: store.rulebook, playback: playback)
        playback.stage(MoveTimeline.Stage(size: CGSize(width: 900, height: 520), singles: false))
        let start = Board.opening(mine: mine, bringing: mine.slots.prefix(4).map(\.id.uuidString),
                                  theirs: theirs, rules: store.rulebook,
                                  singles: false, sendOut: false)
        let battle = try ShowdownBattle.start(from: start, mine: mine, theirs: theirs,
                                              store: store, seed: [2, 2, 2, 2])
        session.showdown = battle
        session.board = battle.board

        check("nothing to replay before a turn has played", !session.canReplayTurn)
        let play = Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1))
        session.resolve(battle.board, mine: play,
                        solved: TurnGame(board: battle.board, believingTheirs: true).solve())

        check("the turn is not left being reviewed", !session.reviewing)
        check("but it can be asked for", session.canReplayTurn)
        session.replayLastTurn()
        check("and then it is being reviewed", session.reviewing)
        session.stopReviewing()
        check("until you are done with it", !session.reviewing)
    }

    /// A game between two people is played in real time. There is nothing to
    /// step back to, and offering it would let one player stop while the
    /// other is waiting on them.
    func testALinkedGameHasNothingToReplay() throws {
        let ladder = store.ladderTeams(format: "doubles")
        guard let team = ladder.first?.team else { throw XCTSkip("no ladder teams") }
        let link = LANLink(role: .guest, theirName: "Them", singles: false,
                           myTeam: team,
                           theirSix: Wire.Six(name: "Them", forms: []),
                           send: { _ in })
        let session = BattleSession(rules: store.rulebook, playback: TurnPlayback())
        session.link = link
        check("no replay over the wire", !session.canReplayTurn)
        session.replayLastTurn()
        check("and asking does nothing", !session.reviewing)
    }
}
