//  TurnPlayback.swift
//  A turn, played rather than printed.
//
//  A turn resolves all at once; it used to appear all at once too, with one
//  flash on whatever had lost health. This walks the steps the model recorded
//  and shows them in the order they happened: the beam travels, the blow lands,
//  the number floats off, the next one starts.
//
//  It is an object of its own for two reasons. The animation state -- which
//  step is showing, what is flying, who is leaning in, what each Pokemon just
//  lost -- is a dozen properties that the arena reads and nothing else needs to
//  know about, and they were a dozen @State properties on a four-thousand-line
//  view. And the walk is a task, which has to be cancelled when a turn is taken
//  back or the screen goes away: a detached task nobody cancelled is what made
//  this app stutter once already. `reset` is the one place that cancels it, and
//  the screen calls it on the way out.
//
//  Three numbers rather than one, because an attack and a turn want opposite
//  things. An attack should be fast: a beam crosses the field, a Pokemon lunges
//  and is back. A turn should not, or four of them blur into one event nobody
//  can follow. These were the same number once, so slowing the turn down slowed
//  the attacks with it. The time a turn takes lives in the pause *after* a move
//  -- when the damage number is on screen and there is something to read.

import SwiftUI

@MainActor
final class TurnPlayback: ObservableObject {
    /// The attack itself -- beam travel and burst, or the lunge and the return.
    /// Short on purpose.
    static let flourishSeconds: Double = 0.40
    /// How long the damage sits there once the move has finished, which is
    /// what actually paces a turn.
    static let dwellSeconds: Double = 0.52
    /// A beat between one action and the next, so four decisions read as four.
    static let betweenActions: Double = 0.20
    /// How far through a move the blow actually lands. The beam is travelling
    /// before this and bursting after it, and the board is held at the state
    /// *before* the move until this moment -- so the health bar drops as the
    /// move arrives rather than before it has been thrown.
    static let impactAt: Double = 0.55

    /// The turn being walked through, and how far into it we are.
    @Published var replay: [Board.Step] = []
    @Published var at = 0
    /// The board the steps were recorded against, before anything fainted was
    /// replaced. Stepping through the finished board would map the health of a
    /// Pokemon that fainted onto the one that came in for it.
    @Published var replayBoard: Board?
    /// What each Pokemon just lost, floating off it as the blow lands. The
    /// number is the thing a player actually wants at that moment and the log
    /// is the last place to look for it.
    @Published var damage: [Seat: Int] = [:]
    /// Who took a hit on the last turn, so they can flinch on screen.
    @Published var struck: Set<Int> = []
    @Published var struckTheirs: Set<Int> = []
    /// The walk itself. Nil when no turn is playing, which two things read:
    /// the Protect bubble, drawn during playback from what the turn left
    /// behind, and the ring asking for orders, which waits until it is over.
    @Published private(set) var task: Task<Void, Never>?

    /// A move's choreography on the arena, playing from `startedAt`.
    struct Scene {
        let timeline: MoveTimeline
        let startedAt: Date
        /// The Pokemon a recipe flies as its own sprite, by seat.
        let ghosts: [Seat: NSImage]
    }
    /// The card leans and the ground shakes of the move being played, and a
    /// clock that runs 0 to 1 over its length. One state change starts the
    /// clock; LeanEffect and QuakeEffect read it every frame from the render
    /// server, so the field's body is evaluated once when a move starts and
    /// once when it ends rather than once per lean.
    struct Tracks {
        let leans: [MoveTimeline.Lean]
        let shakes: [MoveTimeline.Shake]
        let duration: TimeInterval
    }
    @Published var scene: Scene?
    @Published var tracks: Tracks?
    @Published var moveClock: Double = 0
    /// The scene as the field has laid it out, told to the playback so a
    /// recipe can be placed on it. Nil until the field has appeared, and
    /// then a move plays as a pause with no picture.
    private(set) var stage: MoveTimeline.Stage?
    /// The longest a move is allowed to take. A recipe past this is played
    /// faster rather than cut short.
    static let longestMove: TimeInterval = 2.2

    func stage(_ laid: MoveTimeline.Stage) { stage = laid }

    /// A turn's steps to walk, and the board they were recorded against.
    func show(_ recorded: Board, steps: [Board.Step]) {
        replay = steps
        replayBoard = recorded
        at = 0
    }

    /// Stop whatever is playing and clear everything it put on screen. What a
    /// turn taken back, or a new game, wants.
    func reset() {
        task?.cancel(); task = nil
        scene = nil
        stopTracks()
        damage = [:]
        struck = []; struckTheirs = []
        replay = []; at = 0; replayBoard = nil
    }

    /// Walk a turn's steps and show each move as it happened.
    ///
    /// The model records one step per action, carrying who acted and with
    /// what, and the health of everything at that moment. Whoever lost health
    /// between one step and the one before it is who that move reached — which
    /// gets a spread move's two targets, a redirected move's real one, and a
    /// miss's none, without the model having to predict any of them.
    ///
    /// `hitMine` and `hitTheirs` are the whole turn's damage, kept for the end:
    /// once the moves have played, whatever took a hit flashes, which is the
    /// summary the screen used to show on its own.
    func play(_ steps: [Board.Step], hitMine: Set<Int>, hitTheirs: Set<Int>, singles: Bool) {
        task?.cancel()
        struck = []; struckTheirs = []
        let actions = steps.enumerated().compactMap { index, step -> (Int, Board.Step)? in
            step.action == nil ? nil : (index, step)
        }
        guard !actions.isEmpty else {
            flash(hitMine: hitMine, hitTheirs: hitTheirs)
            return
        }
        task = Task { @MainActor in
            for (order, (index, step)) in actions.enumerated() {
                guard !Task.isCancelled, let action = step.action else { return }
                // Hold the field on the state before this action. `replay` and
                // `at` already drive this for the scrubber; the playback just
                // walks them.
                at = Swift.max(0, index - 1)
                // Health before this step: the step before it, or the health
                // the turn started at for the first one.
                let earlier = index > 0 ? steps[index - 1] : nil
                var reached: [Seat] = []
                for slot in step.myHP.indices where slot < 2 {
                    let was = earlier?.myHP.indices.contains(slot) == true
                        ? earlier!.myHP[slot] : step.myHP[slot]
                    if step.myHP[slot] < was { reached.append(Seat(mine: true, slot: slot)) }
                }
                for slot in step.theirHP.indices where slot < 2 {
                    let was = earlier?.theirHP.indices.contains(slot) == true
                        ? earlier!.theirHP[slot] : step.theirHP[slot]
                    if step.theirHP[slot] < was { reached.append(Seat(mine: false, slot: slot)) }
                }
                // A move never animates as reaching the Pokémon that used it,
                // even when that Pokémon lost health doing it: recoil, a Life
                // Orb and Belly Drum all come off the user, and a Flare Blitz
                // that bursts on its own face reads as a bug.
                let user = Seat(mine: action.byMine, slot: action.slot)
                reached.removeAll { $0 == user }

                let staged = stage(action, order: order, user: user, reached: reached, singles: singles)
                // Travel, then the blow: the step's own health is shown at the
                // moment the move reaches, not when it was thrown.
                try? await Task.sleep(nanoseconds: UInt64(staged.impact * 1_000_000_000))
                guard !Task.isCancelled else { return }
                at = index
                // The blow lands: show what it took, from the same health diff
                // the targets were worked out from.
                var took: [Seat: Int] = [:]
                if let earlier {
                    for seat in reached {
                        let before = seat.mine ? earlier.myHP : earlier.theirHP
                        let after = seat.mine ? step.myHP : step.theirHP
                        guard before.indices.contains(seat.slot),
                              after.indices.contains(seat.slot) else { continue }
                        let lost = before[seat.slot] - after[seat.slot]
                        if lost > 0 { took[seat] = lost }
                    }
                }
                withAnimation(.easeOut(duration: 0.18)) { damage = took }
                // The rest of the move, and then it is over.
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, staged.total - staged.impact) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Take the picture away but leave the number: what is worth
                // looking at after a move has landed is what it did.
                scene = nil
                stopTracks()
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.dwellSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { damage = [:] }
                if order < actions.count - 1 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.betweenActions * 1_000_000_000))
                }
            }
            guard !Task.isCancelled else { return }
            scene = nil
            stopTracks()
            damage = [:]
            // Rest on the last step rather than past it: the field shows the end
            // of the turn, and the Back and Forward buttons still work from
            // there, which is how a turn was reviewed before it was played out.
            // Stepping forward off the end clears the replay, as it always did.
            at = Swift.max(0, replay.count - 1)
            flash(hitMine: hitMine, hitTheirs: hitTheirs)
            // The turn is over, so let go of the task.
            //
            // Nothing released it before, so `playback` stayed non-nil for the
            // rest of the game once a single turn had played. Two things read
            // it and both were wrong from that moment: the Protect bubble is
            // drawn during playback from the flag the turn left behind, so it
            // stayed drawn over a Pokémon that was open again; and the ring
            // that asks "what will this one do?" is suppressed during playback,
            // so it never came back at all.
            //
            // Safe to clear from inside: a replaced playback is cancelled
            // first, and a cancelled task returns above this line rather than
            // nilling out its replacement.
            task = nil
        }
    }

    /// The move on the scene, and when it lands and ends.
    ///
    /// The client's choreography: the move's own recipe, or the client's
    /// fallback for that kind of move, or -- when the Pokemon never got to
    /// act -- the condition's own animation, a flinch drawn as the client
    /// draws one. The recipe's primitives go to the scene the field draws;
    /// its leans ride the move's clock as geometry effects. A switch draws
    /// nothing, and so does a move before the field has told the playback
    /// its stage.
    private func stage(_ action: Board.Action, order: Int, user: Seat, reached: [Seat],
                       singles: Bool) -> (impact: TimeInterval, total: TimeInterval) {
        let table = Choreography.shared
        if !table.isEmpty, let geometry = stage, action.category != "Switch" {
            var targets = reached
            let recipe: Choreography.Resolved?
            if let why = action.stopped {
                targets = []
                recipe = Self.stoppedAs[why].flatMap { table.status($0) }
            } else {
                if targets.isEmpty, let aimed = action.target {
                    targets = [Seat(mine: !action.byMine, slot: aimed)]
                }
                recipe = table.recipe(forMove: action.move)
                    ?? table.fallback(category: action.category, targetsSelf: targets.isEmpty)
            }
            if let recipe {
                var timeline = MoveTimeline.build(recipe, attacker: user, targets: targets,
                                                  sizes: table.sprites, stage: geometry)
                if timeline.duration > Self.longestMove {
                    timeline = MoveTimeline.build(recipe, attacker: user, targets: targets, sizes: table.sprites,
                                                  stage: geometry, speed: timeline.duration / Self.longestMove)
                }
                var ghosts: [Seat: NSImage] = [:]
                for seat in [user] + targets {
                    guard let form = fighter(at: seat)?.build.form, let image = Store.shared.sprite(form) else { continue }
                    ghosts[seat] = image
                }
                let total = max(0.25, timeline.duration)
                scene = Scene(timeline: timeline, startedAt: Date(), ghosts: ghosts)
                tracks = Tracks(leans: timeline.leans, shakes: timeline.shakes, duration: total)
                withAnimation(.linear(duration: total)) { moveClock = 1 }
                return (timeline.impact(near: targets.map { geometry.project(geometry.home($0)) },
                                        attacker: user, within: 60 * geometry.k + 10), total)
            }
        }
        return (Self.flourishSeconds * Self.impactAt, Self.flourishSeconds)
    }

    /// The client's animation for each reason a Pokemon did not get to act.
    /// A reason with none -- disabled, tormented -- recoils as before.
    private static let stoppedAs: [String: String] = [
        "flinched": "flinch", "asleep": "slp", "frozen": "frz", "paralysed": "par",
        "confused": "confusedselfhit", "in love": "attracted",
    ]

    private func fighter(at seat: Seat) -> Fighter? {
        guard let board = replayBoard else { return nil }
        let side = seat.mine ? board.mine : board.theirs
        return side.indices.contains(seat.slot) ? side[seat.slot] : nil
    }

    /// The clock back to nought and the tracks gone, without animating either:
    /// a recipe's last lean is home, so there is nothing to ease back from.
    private func stopTracks() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            moveClock = 0
            tracks = nil
        }
    }

    /// What took a hit over the whole turn, flashed once at the end.
    func flash(hitMine: Set<Int>, hitTheirs: Set<Int>) {
        struck = hitMine; struckTheirs = hitTheirs
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            struck = []; struckTheirs = []
        }
    }
}
