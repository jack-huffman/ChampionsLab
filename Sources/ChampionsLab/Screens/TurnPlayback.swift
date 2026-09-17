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
    /// The move being shown right now, and when it started. The start date is
    /// what the animation reads, so nothing redraws per frame.
    @Published var flourish: Flourish?
    @Published var flourishFrom = Date()
    /// What each Pokemon just lost, floating off it as the blow lands. The
    /// number is the thing a player actually wants at that moment and the log
    /// is the last place to look for it.
    @Published var damage: [Seat: Int] = [:]
    /// The Pokemon leaning into a physical move, and how far.
    @Published var lunging: Seat?
    @Published var lungeBy: CGSize = .zero
    /// Who took a hit on the last turn, so they can flinch on screen.
    @Published var struck: Set<Int> = []
    @Published var struckTheirs: Set<Int> = []
    /// The walk itself. Nil when no turn is playing, which two things read:
    /// the Protect bubble, drawn during playback from what the turn left
    /// behind, and the ring asking for orders, which waits until it is over.
    @Published private(set) var task: Task<Void, Never>?

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
        flourish = nil; lunging = nil; lungeBy = .zero; damage = [:]
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
            flourish = nil
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

                if action.stopped != nil {
                    // The move never happened -- flinched, asleep, frozen,
                    // paralysed -- so nothing flies and nobody charges. The
                    // Pokemon recoils where it stands, and the stepper's line
                    // says why. The damage still shows, for the one stop that
                    // costs health: hurting itself in confusion.
                    flourish = nil
                    recoil(user)
                } else {
                    flourish = Flourish(id: order, action: action, targets: reached)
                    flourishFrom = Date()
                    leanIn(action: action, at: reached, singles: singles)
                }
                // Travel, then the blow: the step's own health is shown at the
                // moment the move reaches, not when it was thrown.
                let whole = Self.flourishSeconds
                try? await Task.sleep(nanoseconds: UInt64(whole * Self.impactAt * 1_000_000_000))
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
                // The rest of the burst, and then the move is over.
                try? await Task.sleep(
                    nanoseconds: UInt64(whole * (1 - Self.impactAt) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Take the beam away but leave the number: what is worth
                // looking at after a move has landed is what it did. `lunging`
                // is deliberately left alone — leanIn owns the return and is
                // mid-animation right about now, and clearing it here would
                // snap the card back instead of letting it settle.
                flourish = nil
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
            flourish = nil
            lunging = nil
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

    /// A physical move is the Pokémon arriving in person, so the card leans
    /// into it and comes back. Two animated state changes for the whole thing
    /// rather than an offset recomputed every frame.
    private func leanIn(action: Board.Action, at targets: [Seat], singles: Bool) {
        guard action.category == "Physical" else {
            withAnimation(.easeOut(duration: 0.12)) { lunging = nil }
            return
        }
        let user = Seat(mine: action.byMine, slot: action.slot)
        // Toward whoever it reached; toward the other side when it reached
        // nobody, because the Pokémon still swung.
        let from = Seat.fraction(user, singles: singles)
        let toward = targets.first.map { Seat.fraction($0, singles: singles) }
            ?? CGPoint(x: user.mine ? 0.75 : 0.25, y: from.y)
        let dx = toward.x - from.x, dy = toward.y - from.y
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        // Far enough to read as a charge rather than a twitch. A physical
        // move is the Pokémon crossing the field and hitting something.
        let reach: CGFloat = 52
        let step = CGSize(width: dx / length * reach, height: dy / length * reach)
        // `lunging` first and unanimated, so the card is eligible to move but
        // has not moved; then the offset animates from nothing to the lean.
        // Setting both at once put the card there without the step.
        lunging = user
        lungeBy = .zero
        // Out fast, arriving as the blow lands, then back slower — which is
        // what a charge looks like and what a recoil from one looks like.
        let strike = Self.flourishSeconds * Self.impactAt
        withAnimation(.easeIn(duration: strike)) { lungeBy = step }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(strike * 1_000_000_000))
            guard lunging == user else { return }
            withAnimation(.easeOut(duration: Self.flourishSeconds * 0.45)) { lungeBy = .zero }
        }
    }

    /// A Pokemon that never got its move off does not charge anything. It
    /// jolts back where it stands, half-way forward again, and settles --
    /// which is what a flinch looks like, and what a lunge at nothing does not.
    /// Drawn through the same offset as the lunge, so the card needs no new
    /// state to move.
    private func recoil(_ user: Seat) {
        lunging = user
        lungeBy = .zero
        // Away from the far side: your side stands on the left.
        let away: CGFloat = user.mine ? -14 : 14
        let beat = Self.flourishSeconds * Self.impactAt / 3
        withAnimation(.easeOut(duration: beat)) { lungeBy = CGSize(width: away, height: 0) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            guard lunging == user else { return }
            withAnimation(.easeInOut(duration: beat)) {
                lungeBy = CGSize(width: -away * 0.5, height: 0)
            }
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            guard lunging == user else { return }
            withAnimation(.easeOut(duration: Self.flourishSeconds * 0.45)) { lungeBy = .zero }
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
