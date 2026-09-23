//  ProtectTests.swift
//  Protect blocks, and the app stops telling you it will not.
//
//      swift test --filter ProtectTests
//
//  Reported as "Protect doesn't work". The move worked -- the simulator
//  blocks with it exactly as it should. Everything the app said *about* it
//  was wrong, which amounts to the same thing from a chair in front of it.
//
//  Showdown counts consecutive Protects and lets the odds fall away: a
//  second one in a row holds one time in three. The app counts the same
//  thing as `protectStreak`, and on the Showdown path only the increment
//  was running -- the reset lives in `Residuals`, which is the old engine's
//  end of turn and is never reached when Showdown resolves the game. So the
//  count climbed all game and never fell back. One Protect and the move tile
//  read "33% chance after last turn's" for the rest of the game; two and
//  `TurnGame` stopped offering Protect at all, because it will not consider
//  one under three tenths.

import XCTest
@testable import ChampionsLab

@MainActor
final class ProtectTests: HarnessCase {
    /// Protect blocks, and the app stops telling you it will not.
    func testProtectBlocksAndItsCounterFallsBack() throws {
        guard ShowdownEngine.bundleURL() != nil else { throw XCTSkip("no engine") }
        func slot(_ name: String, _ moves: [String]) -> TeamSlot? {
            guard let form = store.data.forms.first(where: { $0.formLabel == name }) else { return nil }
            var s = TeamSlot(formID: form.id)
            s.ability = form.abilities.first?.name ?? ""
            s.moves = moves.compactMap { m in form.moves.first { store.move($0)?.name == m } }
            s.sp = [32, 32, 0, 0, 0, 0]; s.id = UUID()
            return s
        }
        guard let attacker = slot("Incineroar", ["Darkest Lariat", "Protect"]),
              let defender = slot("Milotic", ["Protect", "Scald"]),
              let filler = slot("Whimsicott", ["Moonblast", "Protect"]) else {
            throw XCTSkip("cast missing")
        }
        var mine = Team(name: "A"); mine.format = "doubles"; mine.slots = [attacker, filler]
        var theirs = Team(name: "B"); theirs.format = "doubles"; theirs.slots = [defender, filler]
        for i in mine.slots.indices { mine.slots[i].id = UUID() }
        for i in theirs.slots.indices { theirs.slots[i].id = UUID() }
        let game = try ShowdownBattle.start(mine: mine, theirs: theirs,
                                            myFour: [0, 1], theirFour: [0, 1],
                                            store: store, seed: [3, 3, 3, 3])

        // Turn one: they Protect, I attack it.
        let before = game.board.theirs[0].hp
        try game.play(mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1)),
                      theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1)))
        check("Protect blocked it", game.board.theirs[0].hp == before,
              "\(before - game.board.theirs[0].hp) got through")
        check("and the streak is counted", game.board.theirs[0].protectStreak == 1,
              "\(game.board.theirs[0].protectStreak)")
        print("  after protecting: streak \(game.board.theirs[0].protectStreak), "
              + "the tile would say \(Int((game.board.theirs[0].protectChance * 100).rounded()))%")

        // Turn two: they do something else.
        try game.play(mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 1)),
                      theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 0, target: 1)))
        print("  after doing something else: streak \(game.board.theirs[0].protectStreak), "
              + "the tile would say \(Int((game.board.theirs[0].protectChance * 100).rounded()))%")
        check("the streak falls back once it does something else",
              game.board.theirs[0].protectStreak == 0, "\(game.board.theirs[0].protectStreak)")
        // Which is the difference between the search offering Protect and not:
        // TurnGame will not consider one under three tenths.
        check("so Protect is offered again",
              game.board.theirs[0].protectChance >= 0.3,
              "\(game.board.theirs[0].protectChance)")
        print("  --- log ---")
        for line in game.board.story.prefix(8) { print("    | \(line)") }
    }

    /// The flare has to reach the field. Showdown lights its shield every
    /// time the shield stops something, and that flare is the whole of how a
    /// Protect reads as doing rather than merely being up.
    func testAShieldThatTurnsSomethingAwaySaysSo() {
        let ladder = store.ladderTeams(format: "doubles")
        guard ladder.count >= 2 else { return check("no ladder teams", false) }
        var board = Board.opening(mine: ladder[0].team,
                                  bringing: ladder[0].team.slots.prefix(4).map(\.id.uuidString),
                                  theirs: ladder[1].team, rules: store.rulebook,
                                  singles: false, sendOut: true)
        // A step with nothing to animate, so the field shows what the step
        // says rather than waiting on a move's clock to reach its impact.
        board.beginStep()
        board.turnedAway(onMine: false, slot: 1, by: "Protect")
        board.note("It was blocked.")
        board.closeStep()

        guard let step = board.steps.last else { return check("a step was made", false) }
        check("the step says whose shield held",
              step.blocked == [Board.Step.Firing(mine: false, slot: 1, name: "Protect")],
              "\(step.blocked)")
        check("and from the other chair it is the other side's",
              step.flipped.blocked == [Board.Step.Firing(mine: true, slot: 1, name: "Protect")],
              "\(step.flipped.blocked)")
        do {
            let back = try JSONDecoder().decode(Board.Step.self,
                                                from: try JSONEncoder().encode(step))
            check("and it survives the wire", back.blocked == step.blocked, "\(back.blocked)")
        } catch {
            check("and it survives the wire", false, "\(error)")
        }
        let playback = TurnPlayback()
        playback.show(board, steps: board.steps)
        playback.replay(step: board.steps.count - 1)
        check("the field is told to flare it",
              playback.blocked.contains(Seat(mine: false, slot: 1)), "\(playback.blocked)")
    }
}
