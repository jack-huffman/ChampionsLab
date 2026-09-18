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
    static let dwellSeconds: Double = 0.75
    /// A beat between one action and the next, so four decisions read as four.
    static let betweenActions: Double = 0.55
    /// Before the first action: a moment to see the board as the turn begins.
    /// Longer over a link, where both players have just locked in and neither
    /// pressed the button that starts the picture.
    static let leadIn: Double = 1.0
    static let leadInOverLink: Double = 3.0
    /// How far through a move the blow actually lands. The beam is travelling
    /// before this and bursting after it, and the board is held at the state
    /// *before* the move until this moment -- so the health bar drops as the
    /// move arrives rather than before it has been thrown.
    static let impactAt: Double = 0.55

    /// The turn being walked through, and how far into it we are.
    @Published var replay: [Board.Step] = []
    @Published var at = 0
    /// How many of the turn's steps have been shown: a row appears in the
    /// stepper as its move begins and stays once seen, however far back the
    /// turn is then scrubbed.
    @Published private(set) var seen = 0
    /// The step whose move is playing right now. The field is held on the
    /// moment before it until the blow lands, so `at` trails by one while a
    /// move travels; the stepper lights this instead, so the row that was
    /// clicked is the row that is lit.
    @Published private(set) var focus: Int?
    /// Whether the turn was singles, for a step played again later.
    private var singles = false
    /// The board the steps were recorded against, before anything fainted was
    /// replaced. Stepping through the finished board would map the health of a
    /// Pokemon that fainted onto the one that came in for it.
    @Published var replayBoard: Board?
    /// The board the turn began on: what the first step is measured against.
    /// Measured against the board the turn ended on, the first step showed
    /// the inverse of everything that happened after it.
    private(set) var startBoard: Board?
    /// What each Pokemon just lost, floating off it as the blow lands. The
    /// number is the thing a player actually wants at that moment and the log
    /// is the last place to look for it.
    @Published var damage: [Seat: Int] = [:]
    /// A stage that moved, and by how much.
    struct StatChange: Equatable {
        let stat: Int
        let delta: Int
    }
    /// Whose stages moved as the step landed, and which: the arrows rising or
    /// falling over the Pokemon, and the labels beside them.
    @Published var boosts: [Seat: [StatChange]] = [:]
    /// Whose abilities went off as the step landed, named over the Pokemon.
    @Published var abilities: [Seat: [String]] = [:]
    /// Partway through a flurry: what each Pokemon has taken so far, so the
    /// health bar steps down blow by blow while the field is still held on
    /// the moment before the move.
    @Published var partial: [Seat: Int] = [:]
    /// Counts each blow shown, so the number over the Pokemon comes in fresh
    /// for every blow rather than editing itself in place.
    @Published var hitNumber = 0
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
    /// `revealed` is for a screen that wants the whole turn on show at once.
    func show(_ recorded: Board, steps: [Board.Step], before: Board? = nil, revealed: Int = 0) {
        replay = steps
        replayBoard = recorded
        startBoard = before
        at = revealed > 0 ? revealed - 1 : 0
        seen = revealed
    }

    /// A Pokemon's health before a step: the step before it, or the board
    /// the turn began on for the first, or the step's own if neither is known.
    private func health(before index: Int, in steps: [Board.Step], mine: Bool, slot: Int) -> Int {
        let step = steps[index]
        let own = (mine ? step.myHP : step.theirHP)[safe: slot] ?? 0
        if index > 0 {
            return (mine ? steps[index - 1].myHP : steps[index - 1].theirHP)[safe: slot] ?? own
        }
        return (mine ? startBoard?.mine : startBoard?.theirs)?[safe: slot]?.hp ?? own
    }

    /// Stop whatever is playing and clear everything it put on screen. What a
    /// turn taken back, or a new game, wants.
    func reset() {
        task?.cancel(); task = nil
        scene = nil
        stopTracks()
        damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld()
        struck = []; struckTheirs = []
        replay = []; at = 0; seen = 0; focus = nil; replayBoard = nil; startBoard = nil
    }

    /// Walk a turn's steps and show each move as it happened.
    ///
    /// The model records one step per action, carrying who acted and with
    /// what, and the health of everything at that moment. Whoever lost health
    /// between one step and the one before it is who that move reached -- which
    /// gets a spread move's two targets, a redirected move's real one, and a
    /// miss's none, without the model having to predict any of them.
    ///
    /// `hitMine` and `hitTheirs` are the whole turn's damage, kept for the end:
    /// once the moves have played, whatever took a hit flashes, which is the
    /// summary the screen used to show on its own.
    /// `from` starts partway: a turn that stopped for a pivot has already
    /// played its first steps, and only the rest are new.
    func play(_ steps: [Board.Step], hitMine: Set<Int>, hitTheirs: Set<Int>, singles: Bool,
              from: Int = 0, leadIn: TimeInterval = leadIn) {
        task?.cancel()
        struck = []; struckTheirs = []
        self.singles = singles
        let actions = steps.enumerated().dropFirst(from).compactMap { index, step -> (Int, Board.Step)? in
            step.action == nil ? nil : (index, step)
        }
        if from > 0 { at = Swift.max(0, from - 1) }
        seen = Swift.max(seen, from)
        guard !actions.isEmpty else {
            seen = steps.count
            flash(hitMine: hitMine, hitTheirs: hitTheirs)
            return
        }
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(leadIn * 1_000_000_000))
            guard !Task.isCancelled else { return }
            for (order, (index, _)) in actions.enumerated() {
                guard !Task.isCancelled else { return }
                await perform(index, order: order, in: steps, last: order == actions.count - 1)
            }
            guard !Task.isCancelled else { return }
            scene = nil
            stopTracks()
            damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld()
            focus = nil
            // The end of the turn: what the residuals took and gave -- a burn,
            // Leftovers, a Speed Boost -- shown over whoever it happened to,
            // one step at a time, since those steps have no move to play.
            let lastAction = actions.last?.0 ?? -1
            for index in steps.indices where index > lastAction && steps[index].action == nil {
                guard !Task.isCancelled else { return }
                at = index
                seen = Swift.max(seen, index + 1)
                var rest: [Phase] = []
                withAnimation(.easeOut(duration: 0.18)) { rest = land(index, in: steps) }
                await show(rest, firstDelay: 0)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1.6 * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld() }
            }
            // Rest on the last step rather than past it: the field shows the end
            // of the turn, and the stepper still works from there, which is how
            // a turn was reviewed before it was played out.
            at = Swift.max(0, replay.count - 1)
            seen = replay.count
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

    /// One step again, on a click in the stepper: whatever is playing stops,
    /// the field rewinds to the moment before the step, the move plays as it
    /// did, and the field rests on the step. A step with no action -- the
    /// residuals -- has nothing to play, and the field simply shows it.
    func replay(step index: Int) {
        guard replay.indices.contains(index) else { return }
        task?.cancel(); task = nil
        scene = nil
        stopTracks()
        damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld()
        struck = []; struckTheirs = []
        seen = Swift.max(seen, index + 1)
        let steps = replay
        focus = nil
        guard steps[index].action != nil else {
            // Nothing to play, but something to show: what the step took and gave.
            at = index
            var rest: [Phase] = []
            withAnimation(.easeOut(duration: 0.18)) { rest = land(index, in: steps) }
            task = Task { @MainActor in
                await show(rest, firstDelay: 0)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1.6 * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld() }
                task = nil
            }
            return
        }
        at = Swift.max(0, index - 1)
        focus = index
        task = Task { @MainActor in
            await perform(index, order: 0, in: steps, last: true)
            guard !Task.isCancelled else { return }
            scene = nil
            stopTracks()
            damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld()
            at = index
            focus = nil
            task = nil
        }
    }

    /// One cause and what it did: an Intimidate and the drops it took, then,
    /// as a phase of its own, the Defiant that answered and the stages it
    /// raised. A step with one cause is one phase.
    struct Phase: Equatable {
        var cause: String?
        var boosts: [Seat: [StatChange]] = [:]
        var abilities: [Seat: [String]] = [:]
        var statuses: [Seat: Ailment] = [:]
        var isEmpty: Bool { boosts.isEmpty && abilities.isEmpty && statuses.isEmpty }
    }

    /// What a step caused that the field has not shown yet. The board the
    /// field draws already has it; the field takes it back off until the
    /// beat that shows it, so a Close Combat's drops fall after the punches.
    struct Withheld: Equatable {
        var boosts: [Seat: [StatChange]] = [:]
        var statuses: [Seat: Ailment] = [:]
        var isEmpty: Bool { boosts.isEmpty && statuses.isEmpty }

        mutating func add(_ phase: Phase) {
            for (seat, changes) in phase.boosts { boosts[seat, default: []].append(contentsOf: changes) }
            for (seat, ailment) in phase.statuses { statuses[seat] = ailment }
        }
        mutating func subtract(_ phase: Phase) {
            for (seat, changes) in phase.boosts {
                var left = boosts[seat] ?? []
                for change in changes { if let at = left.firstIndex(of: change) { left.remove(at: at) } }
                boosts[seat] = left.isEmpty ? nil : left
            }
            for seat in phase.statuses.keys { statuses[seat] = nil }
        }
    }
    @Published private(set) var pending = Withheld()
    /// The status just given, named over the Pokemon for its beat.
    @Published private(set) var statusShown: [Seat: Ailment] = [:]

    /// A step's events, in order, cut into phases: a stage moving for a new
    /// cause starts a phase, and an ability firing goes with the phase it
    /// caused -- the one named as its cause, or the one it opens.
    func phases(of step: Board.Step) -> [Phase] {
        var out: [Phase] = []
        var current = Phase()
        // The last ability that fired on its own account -- an Intimidate --
        // is the cause of every stage that moves for no named reason after
        // it, even across the answers in between.
        var implied: Board.Step.Firing?
        func close() { if !current.isEmpty { out.append(current) }; current = Phase() }
        func attach(_ firing: Board.Step.Firing) {
            let seat = Seat(mine: firing.mine, slot: firing.slot)
            if !(current.abilities[seat] ?? []).contains(firing.name) {
                current.abilities[seat, default: []].append(firing.name)
            }
        }
        for event in step.events {
            switch event {
            case .stat(let mine, let slot, let stat, let delta, let cause):
                guard slot < 2, delta != 0 else { continue }
                let want = cause ?? implied?.name
                if !current.isEmpty, current.cause != want {
                    close()
                    current.cause = want
                    if cause == nil, let implied { attach(implied) }
                } else if current.cause == nil {
                    current.cause = want
                }
                current.boosts[Seat(mine: mine, slot: slot), default: []].append(StatChange(stat: stat, delta: delta))
            case .status(let mine, let slot, let ailment):
                // A status is a beat of its own.
                guard slot < 2, ailment != .none else { continue }
                close()
                current.cause = ailment.rawValue
                current.statuses[Seat(mine: mine, slot: slot)] = ailment
                close()
            case .ability(let firing):
                guard firing.slot < 2 else { continue }
                if current.cause == firing.name {
                    // Named as the cause of what just moved: it goes with it.
                    attach(firing)
                } else if current.isEmpty || current.cause == nil {
                    // Opens a phase, or explains stages that moved for no
                    // named reason.
                    current.cause = firing.name
                    implied = firing
                    attach(firing)
                } else {
                    close()
                    current.cause = firing.name
                    implied = firing
                    attach(firing)
                }
            }
        }
        close()
        return out
    }

    /// What a step took, shown over whoever it was taken from: the health
    /// lost, as the difference from the step before -- or from the board the
    /// turn started on, for the first. Everything else the step caused is
    /// withheld and returned as phases, to be shown a beat at a time after.
    @discardableResult
    private func land(_ index: Int, in steps: [Board.Step]) -> [Phase] {
        let step = steps[index]
        var took: [Seat: Int] = [:]
        for mineSide in [true, false] {
            let hp = mineSide ? step.myHP : step.theirHP
            for slot in hp.indices where slot < 2 {
                let before = health(before: index, in: steps, mine: mineSide, slot: slot)
                if hp[slot] < before { took[Seat(mine: mineSide, slot: slot)] = before - hp[slot] }
            }
        }
        var phases = phases(of: step)
        if phases.isEmpty {
            // A step that moved nothing through the one door still names what
            // fired.
            var fired: [Seat: [String]] = [:]
            for firing in step.abilities where firing.slot < 2 {
                fired[Seat(mine: firing.mine, slot: firing.slot), default: []].append(firing.name)
            }
            if !fired.isEmpty { phases = [Phase(cause: nil, boosts: [:], abilities: fired)] }
        }
        damage = took
        var withheld = Withheld()
        for phase in phases { withheld.add(phase) }
        pending = withheld
        return phases
    }

    /// The beat between one cause and the next.
    static let betweenPhases: TimeInterval = 0.8

    /// The phases, each shown for a beat: the first after `firstDelay`, the
    /// rest a beat apart. What a phase shows comes off what is withheld.
    private func show(_ phases: [Phase], firstDelay: TimeInterval) async {
        for (order, phase) in phases.enumerated() {
            let wait = order == 0 ? firstDelay : Self.betweenPhases
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                boosts = phase.boosts
                abilities = phase.abilities
                statusShown = phase.statuses
                pending.subtract(phase)
            }
        }
    }

    /// Stages moved and abilities fired outside a turn -- the leads coming
    /// out, an Intimidate landing and the Defiant answering it -- shown a
    /// cause at a time over the Pokemon.
    /// Everything these steps caused, held off the field until each is
    /// shown: the opening's arrivals, so an Intimidate's drop is not on the
    /// board before the Intimidate has come out.
    func withhold(_ steps: [Board.Step]) {
        var withheld = Withheld()
        for phase in steps.flatMap({ self.phases(of: $0) }) { withheld.add(phase) }
        pending = withheld
    }

    func flash(_ steps: [Board.Step], withheld already: Bool = false) {
        let phases = steps.flatMap { self.phases(of: $0) }
        guard !phases.isEmpty else { return }
        if !already {
            var withheld = pending
            for phase in phases { withheld.add(phase) }
            pending = withheld
        }
        Task { @MainActor in
            await show(phases, firstDelay: 0)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { boosts = [:]; abilities = [:]; statusShown = [:]; pending = Withheld() }
        }
    }

    /// The stepper is put away: the turn is over and the field shows where
    /// it ended up.
    func finish() {
        task?.cancel(); task = nil
        scene = nil
        stopTracks()
        damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld()
        replay = []; at = 0; seen = 0; focus = nil; replayBoard = nil; startBoard = nil
    }

    /// One action played: the field held on the moment before it, the move's
    /// travel, the blow at `impactAt` with the numbers off whoever it reached,
    /// then the dwell that paces a turn -- and, unless it is the last, the
    /// beat before the next.
    private func perform(_ index: Int, order: Int, in steps: [Board.Step], last: Bool) async {
        let step = steps[index]
        guard let action = step.action else { return }
        // Hold the field on the state before this action. `replay` and `at`
        // already drive this for the stepper; the playback just walks them.
        // The step itself is the one playing, and its row comes on now.
        at = Swift.max(0, index - 1)
        focus = index
        seen = Swift.max(seen, index + 1)
        // Health before this step: the step before it, or the board the turn
        // began on for the first one.
        var reached: [Seat] = []
        for slot in step.myHP.indices where slot < 2 {
            if step.myHP[slot] < health(before: index, in: steps, mine: true, slot: slot) {
                reached.append(Seat(mine: true, slot: slot))
            }
        }
        for slot in step.theirHP.indices where slot < 2 {
            if step.theirHP[slot] < health(before: index, in: steps, mine: false, slot: slot) {
                reached.append(Seat(mine: false, slot: slot))
            }
        }
        // A move never animates as reaching the Pokémon that used it, even
        // when that Pokémon lost health doing it: recoil, a Life Orb and Belly
        // Drum all come off the user, and a Flare Blitz that bursts on its own
        // face reads as a bug.
        let user = Seat(mine: action.byMine, slot: action.slot)
        reached.removeAll { $0 == user }

        // A flurry is played blow by blow: the move's own picture once per
        // blow, quicker, each with its own number, the health bar stepping
        // down between them. One target, as every flurry in the game has.
        let blows = action.hits
        let staged: (impact: TimeInterval, total: TimeInterval)
        // What the move caused besides the blow, to show after it.
        var caused: [Phase] = []
        if blows.count > 1, reached.count == 1, let target = reached.first {
            let each = Swift.max(0.32, Swift.min(0.75, 1.9 / Double(blows.count)))
            var soFar = 0
            for (n, blow) in blows.enumerated() {
                let one = stage(action, order: order + n, user: user, reached: reached,
                                singles: singles, within: each)
                try? await Task.sleep(nanoseconds: UInt64(one.impact * 1_000_000_000))
                guard !Task.isCancelled else { return }
                soFar += blow
                withAnimation(.easeOut(duration: 0.15)) {
                    damage = [target: blow]
                    partial = [target: soFar]
                    hitNumber += 1
                }
                try? await Task.sleep(nanoseconds: UInt64(Swift.max(0, one.total - one.impact) * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            at = index
            seen = Swift.max(seen, index + 1)
            // The step's own record for everything else the move did; the
            // number stays the last blow's, since the bar shows the whole.
            withAnimation(.easeOut(duration: 0.18)) {
                caused = land(index, in: steps)
                damage = [target: blows.last ?? 0]
                partial = [:]
            }
            staged = (impact: 0, total: 0)
        } else {
            staged = stage(action, order: order, user: user, reached: reached, singles: singles)
            // Travel, then the blow: the step's own health is shown at the moment
            // the move reaches, not when it was thrown.
            try? await Task.sleep(nanoseconds: UInt64(staged.impact * 1_000_000_000))
            guard !Task.isCancelled else { return }
            at = index
            seen = Swift.max(seen, index + 1)
            // The blow lands: show what it took and what it moved, from the same
            // differences the targets were worked out from -- then, a beat
            // each, whatever else the step caused: the Defiant that answered
            // an Intimidate, the Weakness Policy that went off.
            withAnimation(.easeOut(duration: 0.18)) { caused = land(index, in: steps); hitNumber += 1 }
        }
        // The rest of the move, and then it is over.
        try? await Task.sleep(
            nanoseconds: UInt64(max(0, staged.total - staged.impact) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        // Take the picture away but leave the number: what is worth looking
        // at after a move has landed is what it did -- and then, a beat each,
        // what it caused: the drops a Close Combat costs, the burn a Scald
        // gave, the Defiant that answered.
        scene = nil
        stopTracks()
        await show(caused, firstDelay: 0.3)
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.2)) { damage = [:]; boosts = [:]; abilities = [:]; partial = [:]; statusShown = [:]; pending = Withheld() }
        if !last {
            try? await Task.sleep(nanoseconds: UInt64(Self.betweenActions * 1_000_000_000))
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
                       singles: Bool, within: TimeInterval = TurnPlayback.longestMove) -> (impact: TimeInterval, total: TimeInterval) {
        let table = Choreography.shared
        if !table.isEmpty, let geometry = stage, action.category != "Switch" {
            var targets = reached
            let recipe: Choreography.Resolved?
            if let why = action.stopped {
                targets = []
                recipe = Self.stoppedAs[why].flatMap { table.status($0) }
            } else {
                // The client plays a move against its target, and a move on
                // the user has the user as its target: Swords Dance is written
                // against the defender, and the defender is the one dancing.
                if action.aimsAtUser {
                    targets = []
                } else if action.aimsAtAlly {
                    targets = [Seat(mine: action.byMine, slot: action.slot == 0 ? 1 : 0)]
                } else if targets.isEmpty, let aimed = action.target {
                    targets = [Seat(mine: !action.byMine, slot: aimed)]
                }
                recipe = table.recipe(forMove: action.move)
                    ?? table.fallback(category: action.category, targetsSelf: targets.isEmpty)
            }
            if let recipe {
                var timeline = MoveTimeline.build(recipe, attacker: user, targets: targets,
                                                  sizes: table.sprites, stage: geometry)
                if timeline.duration > within {
                    timeline = MoveTimeline.build(recipe, attacker: user, targets: targets, sizes: table.sprites,
                                                  stage: geometry, speed: timeline.duration / within)
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
