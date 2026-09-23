//  Board.swift
//  The state of a battle: two sides, the field, and what everyone remembers.
//
//  A Fighter is one Pokemon as it stands right now rather than as a build on
//  paper -- its health, its stages, its status, whether it protected last turn,
//  what it used last, whether it has just arrived. Screens is everything laid
//  on one side of the field. Board is both sides and the field together, plus
//  the story of what has happened so it can be told back, and the small
//  helpers that read or move that state without deciding anything: who is
//  standing, who has a gap, what the flipped board looks like from the other
//  chair.
//
//  Nothing here resolves a move or scores a position. The rules live in the
//  aspects around it -- TurnOrder, Strikes, SupportMoves, Ailments,
//  StatChanges, Switching, Residuals, Evaluation -- and every one of them
//  takes a Board and hands one back. This file is what they agree on.

import Foundation

// MARK: - The board

/// One Pokémon as it stands right now, rather than as a build on paper.
struct Fighter {
    var build: Combatant
    var moves: [Move]
    var hp: Int
    let maxHP: Int
    /// Set during a turn: it has been made to flinch and will not act.
    var flinched = false
    /// Its first turn on the field, which is what makes Fake Out and First
    /// Impression legal.
    ///
    /// Not the same as "arrived this turn". A Pokémon that comes in partway
    /// through a turn — a chosen switch, a replacement after a faint — was not
    /// there when that turn began, so its first turn is the *next* one. This
    /// used to be cleared at the end of whatever turn it arrived in, which
    /// meant a Golisopod pivoted in on turn five could never use First
    /// Impression at all: by turn six, the only turn it could have, the flag
    /// was already gone.
    var justArrived = true
    /// Whether the arrival happened during this turn rather than before it.
    /// Cleared at the top of every turn and set by landing, so the end of the
    /// turn can tell the two apart.
    var arrivedThisTurn = false
    /// It protected last turn, so doing it again is unreliable.
    var protectedLast = false
    /// Protecting this turn. Cleared at the end of it.
    var isProtected = false
    /// What it becomes when it Mega Evolves, if it is holding the stone and has
    /// not done it yet. Nil once it has, or if it never could.
    var pendingMega: Form?
    /// Whether this side has already used its one Mega Evolution.
    var hasMegaEvolved = false
    /// A lasting condition. Burn halves what a physical attacker does and chips
    /// it every turn; paralysis halves Speed and costs a turn now and then.
    var status: Ailment = .none
    /// Turns of sleep left.
    var asleepFor = 0
    /// Turns of freeze left before it thaws regardless. Zero when the freeze
    /// was set on the board by hand, and then only the roll thaws it.
    var frozenFor = 0
    /// Follow Me or Rage Powder this turn: single-target moves come here.
    var drawingFire = false
    /// It has stood on the field, so the other side knows it came. Until then
    /// a benched Pokémon is one of the two they might have brought, and the
    /// game is played against that, not against the answer.
    var seen = false
    /// What the other side has been shown of what this one carries: the
    /// moves it has used, by id, and whether its item and its ability have
    /// done something in the open. A game between two people sends the
    /// other player only this much of a Pokemon.
    var revealedMoves: Set<String> = []
    var itemRevealed = false
    var abilityRevealed = false
    /// A two-turn move it began last turn — the index into its moves — and
    /// where it was aimed. Its next action is that move, whatever else is
    /// asked of it.
    var charging: Int?
    var chargingTarget = 0
    /// Up in the air, underground, under water: nothing reaches it this turn.
    var hidden = false
    /// Protects landed in a row. Each one after the first has a third of the
    /// chance of the one before, and a turn without one starts the count over.
    var protectStreak = 0
    /// Its last move missed, failed, or never happened. Stomping Tantrum
    /// doubles on it.
    var lastMoveFailed = false
    /// Turns of confusion left. It sits on top of a burn or a paralysis, one
    /// in three of its actions goes into its own face, and it is gone the
    /// moment it leaves the field.
    var confusedFor = 0
    var isConfused: Bool { confusedFor > 0 }
    /// The last move it used and where it aimed it, for Encore to hold it to.
    var lastMove: Int?
    var lastTarget = 0
    /// Turns of Encore left: it repeats its last move, whatever it is told.
    var encoredFor = 0
    /// Ally Switches landed in a row. Like Protect, each one after the first
    /// has a third of the chance of the one before.
    var switchStreak = 0
    /// A Cud Chew has a berry to bring back up at the end of the next turn.
    var chewedOn = false
    /// Seeded: an eighth of its health goes across the field every turn, to
    /// whoever is standing where the seed came from.
    var seededFrom: Int?
    /// Turns of Taunt left: it cannot use a status move while this is running.
    var tauntedFor = 0
    /// Bracing this turn: it lives on one health point rather than fainting.
    var enduring = false
    /// Stages of critical-hit ratio, from Focus Energy or a Dragon Cheer.
    var critStage = 0
    /// After You put it to the front of the queue: it acts next regardless of
    /// Speed. Cleared once it has.
    var goesNext = false
    /// Electromorphosis: the next Electric move it throws is twice as strong.
    var charged = false
    /// Turns spent badly poisoned. Toxic takes a sixteenth on the first turn, a
    /// second sixteenth on the next, and so on — which is the whole difference
    /// between it and ordinary poison, and it was being taken as a flat eighth
    /// for ever.
    var toxicTurns = 0
    /// Its partner used Helping Hand on it this turn: half again on the move
    /// it is about to use, and gone at the end of the turn.
    var helped = false
    /// Quash sent it to the back of the queue: it acts last regardless of
    /// Speed. The mirror image of `goesNext`, and cleared the same way.
    var goesLast = false
    /// A Substitute standing in front of it, in health points. While it is up
    /// it takes the damage and the status, and the Pokémon behind it takes
    /// neither.
    var substitute = 0
    /// Infatuated with the slot it is looking at: one action in two is lost.
    var infatuatedWith: Int?
    /// Tormented: it cannot use the same move twice in a row.
    var tormented = false
    /// Held in place by Mean Look or Block, or by a Shadow Tag or Arena Trap
    /// across the field. It cannot switch out.
    var cannotEscape = false
    /// Aqua Ring: a sixteenth of its health back every turn, for as long as it
    /// stands there.
    var aquaRing = false
    /// Stockpiles held, which is what Swallow and Spit Up spend.
    var stockpile = 0
    /// Turns left before Perish Song takes it. Three when the song lands, and
    /// it faints when the count runs out — the one clock in the game that
    /// beats a Pokémon nothing can hurt, which is why it is worth having.
    /// Switching out clears it; the song does not follow to the bench.
    var perishIn = 0
    /// Yawn: it falls asleep when this runs out, which is next turn. A Yawn is
    /// not sleep yet, and the difference is the whole move — the turn in
    /// between is the one the other side has to answer in.
    var drowsyFor = 0
    /// The move Disable has shut off, as an index into `moves`, and for how
    /// much longer.
    var disabled: Int?
    var disabledFor = 0
    /// Power Points left for each move, in the same order as `moves`.
    ///
    /// Spent when a move actually goes off, so a turn lost to sleep, a full
    /// paralysis or a flinch costs nothing — and never given back by
    /// switching out, which is what makes them the one resource a battle
    /// really runs down. A Pokémon with none left anywhere Struggles.
    var ppLeft: [Int] = []
    /// Imprison: while this one stands there, nobody across the field may use
    /// a move it knows itself. It seals what it has, not what it uses, so it
    /// costs the other side the move for as long as this one is out.
    var imprisoning = false
    /// Destiny Bond: if this faints before its next action, whatever did it
    /// goes too.
    var destinyBound = false
    /// Octolock: a stage of Defense and Special Defense every turn, and it
    /// cannot leave. The trapping half lives in `cannotEscape`.
    var octolocked = false
    /// The types it actually has right now, which is not always what the dex
    /// says: Soak makes its target a pure Water type.
    var types: [PokeType] { build.effectiveTypes }
    /// Deaf to sound moves, which is what keeps Perish Song off it. Computed,
    /// so it stays out of the board fingerprint — the ability it reads is
    /// already in there.
    var isSoundproof: Bool { build.ability == "Soundproof" }
    /// Standing on the ground, so the floor can reach it: hazards, the terrain,
    /// an Earthquake.
    ///
    /// Delegated rather than restated. It had been written out inline in five
    /// places with four different answers — one forgot the balloon, one forgot
    /// Levitate too, one read the printed types instead of the ones it has
    /// after a Soak — and a terrain that reaches a Pokémon it should not is the
    /// kind of bug that only shows up in a game somebody is losing.
    var isGrounded: Bool { build.grounded }
    /// What it is held to, if anything.
    var encored: Choice? {
        guard encoredFor > 0, let last = lastMove, moves.indices.contains(last) else { return nil }
        return .attack(move: last, target: lastTarget)
    }

    /// Power Points left on one move.
    ///
    /// A Fighter that arrived from somewhere carrying none — an older peer
    /// across the network, a position built by hand — reads as full rather
    /// than as empty. A battle in which nobody may move is a worse wrong
    /// answer than one in which nothing ever runs out.
    func pp(at index: Int) -> Int {
        guard ppLeft.indices.contains(index) else {
            return moves.indices.contains(index) ? moves[index].pp : 0
        }
        return ppLeft[index]
    }

    /// The chance Protect works right now.
    var protectChance: Double { pow(1.0 / 3.0, Double(protectStreak)) }

    var fainted: Bool { hp <= 0 }
    var share: Double { maxHP > 0 ? max(0, Double(hp) / Double(maxHP)) : 0 }

    init(build: Combatant, moves: [Move], hp: Int? = nil, pendingMega: Form? = nil) {
        self.build = build
        self.moves = moves
        self.ppLeft = moves.map(\.pp)
        self.maxHP = build.maxHP
        self.hp = hp ?? build.maxHP
        self.pendingMega = pendingMega
    }
}

/// Something that sticks to a Pokémon rather than to the turn.

/// Screens on one side of the field, in turns remaining.
struct Screens {
    var reflect = 0
    var lightScreen = 0
    var auroraVeil = 0
    /// Wide Guard and Quick Guard, which last the turn rather than five of
    /// them: one turns away what hits everybody, the other what moves first.
    var wideGuard = false
    var quickGuard = false
    /// Safeguard: five turns during which nothing on this side can be given a
    /// status condition.
    var safeguard = 0
    /// Layers of Spikes (up to three) and Toxic Spikes (up to two), and whether
    /// Stealth Rock is down. These bite whatever walks in, which is the whole
    /// reason a pivot costs something.
    var spikes = 0
    var toxicSpikes = 0
    var stealthRock = false
    /// Sticky Web: whatever walks in loses a stage of Speed.
    var stickyWeb = false
    /// A Wish in the air: how much it will heal and how many turns until it
    /// lands. It heals whoever is standing in the spot when it arrives.
    var wishAmount = 0
    var wishTurns = 0

    var any: Bool { reflect > 0 || lightScreen > 0 || auroraVeil > 0 }
    /// Hazards survive a tick: they sit there until something clears them.
    mutating func tick() {
        reflect = max(0, reflect - 1)
        lightScreen = max(0, lightScreen - 1)
        auroraVeil = max(0, auroraVeil - 1)
        safeguard = max(0, safeguard - 1)
        wideGuard = false
        quickGuard = false
    }
    /// Whether a move of this kind is halved coming in.
    func blunt(_ move: Move) -> Bool {
        if auroraVeil > 0 { return true }
        return move.category == "Physical" ? reflect > 0 : lightScreen > 0
    }
}

/// A doubles board: the first two of each side are out, the rest are waiting.
struct Board {
    var mine: [Fighter]
    var theirs: [Fighter]

    /// One way their unseen back two could be, and how likely it is.
    struct BenchGuess {
        let fighters: [Fighter]
        let chance: Double
    }
    /// What their back two probably are, from their six and the two they led
    /// with. `theirs` holds the truth so the game can be played out; nothing
    /// that advises you is allowed to read past what has been seen, and the
    /// search plays against these instead. Empty when nothing is hidden — a
    /// bare analysis board, or a team of exactly four.
    var theirBenchGuesses: [BenchGuess] = []
    /// And the same from their chair: what they expect *your* back two to be,
    /// worked out from your six and the two you led with. The engine gives
    /// them their orders out of this, so they cannot see what you kept back
    /// any more than you can see what they did.
    var myBenchGuesses: [BenchGuess] = []

    /// Benched slots that have not shown themselves yet.
    func unseenBench(mine side: Bool) -> [Int] {
        let team = side ? mine : theirs
        return (activeCount..<team.count).filter { !team[$0].seen && !team[$0].fainted }
    }
    var theirUnseenBench: [Int] { unseenBench(mine: false) }
    var myUnseenBench: [Int] { unseenBench(mine: true) }

    /// The guesses still possible given what has since been seen: one of the
    /// pair walking on rules out every pair it was not in.
    func liveGuesses(mine side: Bool) -> [BenchGuess] {
        let all = side ? myBenchGuesses : theirBenchGuesses
        let team = side ? mine : theirs
        // Only what was ever in doubt counts as evidence: a lead that fainted
        // and slid to the bench has been seen, but it was never a guess.
        let pool = Set(all.flatMap { $0.fighters.map(\.build.form.id) })
        let shown = Set(team.filter { $0.seen && pool.contains($0.build.form.id) }
                            .map(\.build.form.id))
        let consistent = all.filter { guess in
            shown.isSubset(of: Set(guess.fighters.map(\.build.form.id)))
        }
        let total = consistent.reduce(0) { $0 + $1.chance }
        guard total > 0 else { return [] }
        return consistent.map { BenchGuess(fighters: $0.fighters, chance: $0.chance / total) }
    }
    var liveBenchGuesses: [BenchGuess] { liveGuesses(mine: false) }

    /// Each Pokémon that might be in a back, with the chance it is there.
    func benchCandidates(mine side: Bool) -> [(fighter: Fighter, chance: Double)] {
        let team = side ? mine : theirs
        let shown = Set(team.filter(\.seen).map(\.build.form.id))
        var chance: [String: Double] = [:]
        var fighter: [String: Fighter] = [:]
        for guess in liveGuesses(mine: side) {
            for member in guess.fighters where !shown.contains(member.build.form.id) {
                chance[member.build.form.id, default: 0] += guess.chance
                fighter[member.build.form.id] = member
            }
        }
        return chance.keys.compactMap { id in fighter[id].map { ($0, chance[id]!) } }
            .sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.build.form.formLabel < $1.0.build.form.formLabel) }
    }
    var theirBenchCandidates: [(fighter: Fighter, chance: Double)] { benchCandidates(mine: false) }
    var myBenchCandidates: [(fighter: Fighter, chance: Double)] { benchCandidates(mine: true) }

    /// Whether anything on a side is still a guess.
    func hidesBench(mine side: Bool) -> Bool {
        !unseenBench(mine: side).isEmpty && !liveGuesses(mine: side).isEmpty
    }
    var hidesTheirBench: Bool { hidesBench(mine: false) }

    /// The board as the other side sees it: your unseen back two replaced by
    /// the pair they most expect. This is what their half of the matrix is
    /// solved on, so their orders are an answer to what they believe rather
    /// than to what is actually sitting on your bench.
    var asTheySeeIt: Board {
        var out = self
        // Your side is worth one a Pokémon to them, whoever is on it.
        //
        // The weights are per form, so the table itself is a description of
        // your six and of how each one fares against theirs. Handing it to the
        // board they reason on would let the identity of a Pokémon they have
        // never seen move their orders — the substitution above exists
        // precisely to stop that, and this is the same rule applied to the
        // thing the substitution does not reach.
        out.myWorth = [:]
        let hidden = myUnseenBench
        guard !hidden.isEmpty, let guess = liveGuesses(mine: true).first else { return out }
        let shown = Set(mine.filter(\.seen).map(\.build.form.id))
        let arriving = guess.fighters.filter { !shown.contains($0.build.form.id) }
        guard !arriving.isEmpty else { return out }
        for (slot, fighter) in zip(hidden, arriving) { out.mine[slot] = fighter }
        return out
    }
    /// What each Pokémon is worth *against this particular opponent*, keyed by
    /// form id, around an average of one.
    ///
    /// The engine used to price every Pokémon identically — 0.35 for being
    /// alive and 0.65 scaled by health — so it would trade a Mega Charizard
    /// that beats four of their six for an Incineroar that beats none and call
    /// it even. One Pokémon for one Pokémon. That is not how anybody plays:
    /// a team has a win condition, and the whole game is keeping it alive long
    /// enough to use it.
    ///
    /// Empty means every Pokémon is worth one, which is exactly the old
    /// behaviour — so a board built without this behaves as it always did.
    var myWorth: [String: Double] = [:]
    var theirWorth: [String: Double] = [:]
    /// How each side's Pokémon fare against each of the other's, cell by cell.
    /// Depends only on the two teams, so it is worked out once and the weights
    /// above are re-derived from it as Pokémon fall.
    var myBeats: [String: [String: Double]] = [:]
    var theirBeats: [String: [String: Double]] = [:]
    /// The six each side registered, which both players saw at team preview.
    ///
    /// Public, and that is the point: weights are counted against the roster
    /// minus whoever has visibly fainted, rather than against the four that
    /// were actually brought. Which four you brought is the secret; who is on
    /// your team is not, and a weight built from the roster cannot give the
    /// secret away.
    var myRoster: [String] = []
    var theirRoster: [String] = []
    /// Whether each side's evaluation counts the stat stages on its Pokémon.
    /// Per side, and only so that one can be measured against the other — in
    /// play both are on.
    var myCountsStages = true
    var theirCountsStages = true
    /// Whether each side scores a turn by how much it moves its chance of
    /// winning, rather than by how much material it gains. Per side so that one
    /// can be measured against the other; in play both are on.
    var myPlaysForWin = true
    var theirPlaysForWin = true
    /// What a Pokémon is worth for being alive at all, before health.
    ///
    /// Per side so it can be measured; in play both are the same. The number
    /// had never been tuned against anything, and the argument against it is
    /// specific: "all of your Pokemon will function in exactly the same way no
    /// matter how much health they have left" — a Pokémon on 1 HP attacks for
    /// exactly what a healthy one does, and only its survivability has gone.
    var myAliveFloor = Board.aliveFloor
    var theirAliveFloor = Board.aliveFloor
    static let aliveFloor = 0.35

    /// Derive both sides' weights from the duel table.
    ///
    /// Called once, when the board is made. It was called again after every
    /// turn for a while, so that a counter stopped being precious once the
    /// thing it countered had fainted — "preserve Basculegion for later, into
    /// their Swampert" is only true while the Swampert is there, and that is
    /// real reasoning that people really do.
    ///
    /// It measured worse. Against a flat engine the fixed weights took 57.3%
    /// of 2,000 games and the moving ones 55.0% of another 2,000, both give or
    /// take 2.2 — no gain, and a point estimate that went the wrong way. The
    /// likeliest reason is that the set it counts against shrinks: with one
    /// opponent left every weight is driven to one end of its range or the
    /// other, so the late game, where the position is tightest, is exactly
    /// where the numbers get loudest and least reliable. Damping that is a
    /// parameter to tune and was not worth it on this evidence.
    ///
    /// Kept as a single call so the behaviour is one line away if somebody
    /// wants to try again with the late game handled.
    mutating func refreshWorth() {
        // The roster everyone saw, less whoever has visibly fallen. Counting
        // only what has been *seen* was the first attempt and starved it: two
        // turns in, a side has revealed two Pokémon, so every weight was an
        // opinion about half a matchup and barely moved off one.
        func standing(_ roster: [String], _ team: [Fighter]) -> [String] {
            let gone = Set(team.filter(\.fainted).map(\.build.form.id))
            let left = roster.filter { !gone.contains($0) }
            return left.isEmpty ? roster : left
        }
        myWorth = Worth.weights(from: myBeats, against: standing(theirRoster, theirs))
        theirWorth = Worth.weights(from: theirBeats, against: standing(myRoster, mine))
    }

    var field: Field
    /// Turns left on each side's speed control.
    var myTailwind = 0
    var theirTailwind = 0
    var trickRoom = 0
    /// Magic Room: no held item does anything for five turns.
    var magicRoom = 0
    /// Wonder Room: every Pokémon's Defense and Special Defense trade places.
    var wonderRoom = 0
    /// The field as the damage calculator needs to see it, with the two rooms
    /// folded in. Every call site reads this rather than `field`, so a room
    /// cannot be forgotten at one of them.
    var calcField: Field {
        var out = field
        out.magicRoom = magicRoom > 0
        out.wonderRoom = wonderRoom > 0
        // Cloud Nine and Air Lock make the weather decoration while they stand
        // there. Done here rather than at the thirteen places the calculator
        // reads the weather, and *not* by clearing the board's weather, which
        // is still there and comes back the moment the ability leaves.
        let becalmed = (mine + theirs).prefix(activeCount * 2).contains {
            !$0.fainted && ["Cloud Nine", "Air Lock"].contains($0.build.ability)
        }
        if becalmed { out.weather = .none; out.weatherSuppressed = true }
        return out
    }
    /// How many stand on each side. Two in doubles, one in singles.
    var activeCount = 2
    var myScreens = Screens()
    var theirScreens = Screens()
    /// What happened this turn, in the order it happened.
    var story: [String] = []
    /// The same, with the board as it stood at each line, so a turn can be
    /// walked through rather than landing all at once.
    var steps: [Step] = []

    /// A Pokemon leaving under its own move -- a U-turn, a Parting Shot, an
    /// Eject Button -- with the turn stopped for the choice of who comes in.
    struct Pivot: Equatable, Sendable {
        let mine: Bool
        let slot: Int
        var carrying: Carried? = nil
    }
    /// What a pivot hands to whoever comes in: Baton Pass its stages, its
    /// substitute and its Aqua Ring; Shed Tail the shell it paid for.
    struct Carried: Equatable, Sendable {
        var boosts: [Int]? = nil
        var substitute = 0
        var aquaRing = false
    }
    /// Set by a played turn, so a pivot of yours stops the turn and the
    /// screen asks. Off for the search, which sends in the best answer at
    /// once, the way it replaces a fallen Pokemon.
    var asksBeforePivot = false
    /// The same for their side: a game between two people stops for either
    /// player's pivot, and the host asks whoever has the decision.
    var asksTheirsBeforePivot = false
    var pendingPivot: Pivot?
    /// The actions still to come when a pivot stopped the turn, for
    /// `TurnModel.resume`.
    var paused: [Queued]?

    /// One Pokémon's action this turn, with the reasoning behind where it sits.
    struct Queued: Sendable {
        let mine: Bool
        let slot: Int
        let choice: Choice
        let bracket: Int
        /// Speed as it stood when the turn was declared. `next` re-reads the
        /// live value; this is kept for anything describing the turn later.
        let speed: Int
        /// What moved the bracket off the move's own number.
        let becauseOfPriority: [String]
        /// What moved the Speed off the Pokémon's own number.
        let becauseOfSpeed: [String]
    }
    /// Whether the Pokemon acting has already left during this action, so a
    /// Parting Shot's own leaving and the pipeline's do not both fire.
    var leftThisStep = false

    /// A moment inside a turn.
    /// What a Pokémon was doing when a step happened, for the screen to draw.
    ///
    /// The step already carried the text and the board; it did not carry who
    /// was acting, so the only thing the battlefield could show was a flash on
    /// whatever lost health. A physical move and a special one look nothing
    /// alike, and neither looks like a switch.
    ///
    /// Targets are deliberately absent: a spread move hits two, a redirect
    /// moves the one it was aimed at, and a miss hits none. The screen works
    /// out who was struck by diffing this step's health against the step
    /// before, which gets all three right without the model predicting them.
    struct Action: Equatable {
        let byMine: Bool
        let slot: Int
        let move: String
        /// "Physical", "Special" or "Other", as the dataset writes it — a
        /// status move is "Other" there, and one vocabulary is worth more than
        /// a nicer word. "Switch" is the one value added on top, for the one
        /// action that is not a move.
        let category: String
        let type: String
        /// Why the action never happened -- "flinched", "asleep", "frozen",
        /// "paralysed" -- and nil when it did. The playback reads it: a
        /// Pokemon that never got its move off does not lunge, it recoils.
        var stopped: String?
        /// The far-side slot an attack was aimed at, so a move that missed or
        /// was blocked still flies at the Pokemon it was meant for.
        var target: Int?
        /// Whether the move is on the user itself, or on its partner: the
        /// playback draws a Swords Dance over the dancer and a Helping Hand
        /// over the one being helped, not over a foe.
        var aimsAtUser = false
        var aimsAtAlly = false
        /// Winding up rather than firing. The action is recorded before the
        /// move resolves, so a Sky Attack on its charging turn reads as a Sky
        /// Attack -- and the field played the whole flight, on the turn
        /// nothing had left the ground yet.
        var charging = false
        /// Each blow of a multi-hit move as it landed, in order -- a Dual
        /// Wingbeat's two, a Rock Blast's two to five -- so the field plays
        /// each one. Empty for a move that strikes once.
        var hits: [Int] = []

        /// The action behind a choice, read off the move it actually plays.
        /// A switch, a Protect and a pass each read as themselves.
        init(played: Choice, by actor: Fighter, byMine: Bool, slot: Int) {
            self.byMine = byMine
            self.slot = slot
            switch played {
            case .attack(let index, _), .protectSelf(let index):
                let move = actor.moves.indices.contains(index) ? actor.moves[index] : nil
                self.move = move?.name ?? ""
                self.category = move?.category ?? "Other"
                self.type = move?.type ?? ""
                if case .attack(_, let aimed) = played { self.target = aimed }
                if case .protectSelf = played { self.aimsAtUser = true }
                else {
                    self.aimsAtUser = move?.aimsAtUser ?? false
                    self.aimsAtAlly = move?.aimsAtAlly ?? false
                }
            case .swap:
                self.move = ""; self.category = "Switch"; self.type = ""
            case .pass:
                self.move = ""; self.category = "Other"; self.type = ""
            }
        }

        init(byMine: Bool, slot: Int, move: String, category: String, type: String) {
            self.byMine = byMine; self.slot = slot
            self.move = move; self.category = category; self.type = type
        }
    }

    struct Step: Identifiable {
        let id = UUID()
        let text: String
        var action: Action?
        let myHP: [Int]
        let theirHP: [Int]
        let myForms: [String]
        let theirForms: [String]
        let field: Field
        let myTailwind: Int
        let theirTailwind: Int
        let trickRoom: Int
        /// Stages and conditions as they stood, so a card read mid-turn shows
        /// the Intimidate that has landed and not the Swords Dance that has yet to.
        var myBoosts: [[Int]] = []
        var theirBoosts: [[Int]] = []
        /// Items that did something during the step, and whose. Drawn over
        /// the Pokemon the way an ability is, because a Focus Sash deciding a
        /// game is exactly as worth seeing as an Intimidate.
        var items: [Firing] = []
        /// Who took a critical hit during the step, and what did it. The log
        /// has said "A critical hit!" since the beginning and the field never
        /// did — so the one number on screen that a crit changes had nothing
        /// beside it to say why it was so large.
        var criticals: [Firing] = []
        /// And who a move did not touch at all. The log has always said "It
        /// does not affect Garchomp"; the field showed nothing, so a move
        /// aimed at something immune to it looked the same as one that
        /// fizzled for any other reason.
        var untouched: [Firing] = []
        /// And who the move was thrown at and did not reach. An immunity and
        /// a miss are two different answers, and the field was giving neither:
        /// the attack flew out and nothing at all came back.
        var missed: [Firing] = []
        /// An ability that went off during the step, and whose.
        struct Firing: Equatable {
            let mine: Bool
            let slot: Int
            let name: String
        }
        var abilities: [Firing] = []
        /// What happened in the step, in order: an ability going off, a stage
        /// moving. A drop and the ability that answers it are two events with
        /// two causes, so the field can show them one after the other rather
        /// than netted into one.
        enum Event: Equatable {
            case ability(Firing)
            case stat(mine: Bool, slot: Int, stat: Int, delta: Int, cause: String?)
            case status(mine: Bool, slot: Int, ailment: Ailment)
            case item(Firing)
        }
        var events: [Event] = []
        var myStatus: [Ailment] = []
        var theirStatus: [Ailment] = []
        var myConfused: [Bool] = []
        var theirConfused: [Bool] = []
        /// Whether each Pokemon was behind a Protect as the step closed, so
        /// the shield goes up on the field when the Protect is used and not
        /// from the first step of the turn.
        var myProtected: [Bool] = []
        var theirProtected: [Bool] = []
    }

    /// Turns of weather and terrain left. Five when something sets them; zero
    /// with nothing up — or with something up indefinitely, which is how an
    /// analysis board is handed a field and left alone.
    var weatherTurns = 0
    var terrainTurns = 0

    /// Whatever just happened to the field, start its clock if it changed.
    mutating func fieldSettled(from old: Field) {
        if field.weather != old.weather { weatherTurns = field.weather == .none ? 0 : 5 }
        if field.terrain != old.terrain { terrainTurns = field.terrain == .none ? 0 : 5 }
    }

    /// What each Pokémon was told to do this turn, keyed "m0" or "t1", and
    /// which of them have gone already. Sucker Punch is the only thing that
    /// reads this, and it is exactly what Sucker Punch needs to know: whether
    /// the Pokémon in front of it is winding up to attack, and whether it has
    /// already done so. Cleared once the turn is over.
    var declared: [String: Choice] = [:]
    var acted: Set<String> = []

    /// Coin flips already decided for this turn, so the search can follow a
    /// branch instead of rolling. The key names the flip and the slot it
    /// belongs to: "protect:m0" is your left slot trying a repeat Protect,
    /// "secondary:t1" their right slot's move landing its secondary effect,
    /// "poisontouch:m0", "quickclaw:m0". Cleared once the turn has been played.
    ///
    /// A played turn ignores this entirely and rolls.
    var rulings: [String: Bool] = [:]

    /// The same position seen from the other chair.
    ///
    /// Everything on a board is written from one side's point of view — "mine"
    /// and "theirs", my screens and theirs, what I can see of their bench. To
    /// ask the engine what the *other* side should do, the whole thing has to
    /// be turned round. Used by the duel tool to put two engines in one game,
    /// and by anything else that needs to think as the opponent.
    var flipped: Board {
        var out = self
        swap(&out.mine, &out.theirs)
        swap(&out.myScreens, &out.theirScreens)
        swap(&out.myTailwind, &out.theirTailwind)
        swap(&out.theirBenchGuesses, &out.myBenchGuesses)
        swap(&out.myWorth, &out.theirWorth)
        swap(&out.myBeats, &out.theirBeats)
        swap(&out.myRoster, &out.theirRoster)
        swap(&out.myCountsStages, &out.theirCountsStages)
        swap(&out.myPlaysForWin, &out.theirPlaysForWin)
        swap(&out.myAliveFloor, &out.theirAliveFloor)
        // The per-slot keys name a side, so they have to be relabelled too.
        func relabel(_ table: [String: Bool]) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: table.map { key, value in
                (key.replacingOccurrences(of: ":m", with: ":@")
                    .replacingOccurrences(of: ":t", with: ":m")
                    .replacingOccurrences(of: ":@", with: ":t"), value)
            })
        }
        out.rulings = relabel(rulings)
        out.declared = [:]
        out.acted = []
        out.asksBeforePivot = asksTheirsBeforePivot
        out.asksTheirsBeforePivot = asksBeforePivot
        if let pivot = pendingPivot {
            out.pendingPivot = Pivot(mine: !pivot.mine, slot: pivot.slot, carrying: pivot.carrying)
        }
        out.paused = paused?.map {
            Queued(mine: !$0.mine, slot: $0.slot, choice: $0.choice, bracket: $0.bracket,
                   speed: $0.speed, becauseOfPriority: $0.becauseOfPriority,
                   becauseOfSpeed: $0.becauseOfSpeed)
        }
        return out
    }

    /// Whether the hit just resolved was a critical one. Set as the hit lands
    /// and read immediately after by the abilities that answer a crit.
    var lastWasCritical = false

    /// A line that explains the one above it rather than standing alone.
    ///
    /// "Garchomp used Earthquake" is a thing that happened; the spread penalty,
    /// the terrain halving it and what each target took are its reasons. The
    /// log hangs these under it instead of listing nine equal events, and the
    /// two-space prefix is the whole protocol.
    mutating func detail(_ line: String) { note("  " + line) }

    /// The key for one coin flip: which flip, whose side, which slot.
    static func flip(_ what: String, _ mine: Bool, _ slot: Int) -> String {
        "\(what):\(mine ? "m" : "t")\(slot)"
    }

    /// Whether anybody is going to read the commentary. A played turn is read;
    /// the search plays out a thousand boards per solve and reads none of it,
    /// and snapshotting the whole board on every line of every one of them was
    /// a fifth of a solve.
    var narrating = true

    /// Lines being gathered into a single step: everything one action does.
    /// A spread move used to be five steps — a target, the spread modifier,
    /// the other target, its modifier, the drop — which is a log, not a move.
    /// Nil when each line is its own step, as switches and evolutions are.
    var gathering: [String]?

    /// Whose action the lines being gathered belong to. Set for the length of
    /// one action and cleared with it, so the residual step at the end of a
    /// turn — which belongs to nobody — carries none.
    var acting: Action?

    /// Start collecting the lines of one action into one step.
    mutating func beginStep(_ action: Action? = nil) {
        closeStep()
        acting = action
        gathering = []
        leftThisStep = false
        markStepStart()
    }

    private mutating func markStepStart() {
        stepStart = StepStart(mine: mine.map(\.build.boosts), theirs: theirs.map(\.build.boosts),
                              myStatus: mine.map(\.status), theirStatus: theirs.map(\.status),
                              myForms: mine.map(\.build.form.id), theirForms: theirs.map(\.build.form.id))
    }

    /// Whatever moved since the step began that no door recorded.
    private mutating func reconcileEvents() {
        guard let start = stepStart else { return }
        for mineSide in [true, false] {
            let team = mineSide ? mine : theirs
            let was = mineSide ? start.mine : start.theirs
            let wasStatus = mineSide ? start.myStatus : start.theirStatus
            let wasForm = mineSide ? start.myForms : start.theirForms
            for slot in team.indices where slot < was.count {
                // Somebody else is standing there now: nothing about the two
                // of them is a change that happened to either.
                guard slot >= wasForm.count || wasForm[slot] == team[slot].build.form.id else { continue }
                for stat in team[slot].build.boosts.indices where stat < was[slot].count {
                    let moved = team[slot].build.boosts[stat] - was[slot][stat]
                    let recorded = events.reduce(0) { sum, event in
                        if case .stat(let m, let s, let st, let delta, _) = event, m == mineSide, s == slot, st == stat {
                            return sum + delta
                        }
                        return sum
                    }
                    if moved - recorded != 0 {
                        events.append(.stat(mine: mineSide, slot: slot, stat: stat, delta: moved - recorded, cause: nil))
                    }
                }
                if slot < wasStatus.count, team[slot].status != wasStatus[slot], team[slot].status != .none,
                   !events.contains(.status(mine: mineSide, slot: slot, ailment: team[slot].status)) {
                    events.append(.status(mine: mineSide, slot: slot, ailment: team[slot].status))
                }
            }
        }
    }

    /// The abilities that have fired since the step began, off the notes.
    /// Not private: a private stored property would make the memberwise
    /// initialiser private too, and a board is rebuilt from the wire with it.
    var firing: [Step.Firing] = []
    /// Items that went off since the last step closed, cleared with it.
    var itemsFired: [Step.Firing] = []
    /// Critical hits landed since the last step closed, cleared with it.
    var criticals: [Step.Firing] = []
    /// And who was untouched, for the same window.
    var untouched: [Step.Firing] = []
    /// And who avoided one, for the same window.
    var missed: [Step.Firing] = []
    /// Everything that happened since the step began, in order.
    var events: [Step.Event] = []
    /// Where every stage and status stood when the step began. At the close,
    /// whatever moved without going through `StatChanges.change` -- a Belly
    /// Drum straight to six, a Haze, a switch resetting -- is put on the
    /// record from the difference, so the field can never show a stage
    /// moving the wrong way, or not at all, for want of a door.
    struct StepStart: Equatable {
        var mine: [[Int]]
        var theirs: [[Int]]
        var myStatus: [Ailment]
        var theirStatus: [Ailment]
        /// Who stood in each slot. A slot that changed hands during the step
        /// cannot be compared with itself: the stages and the status belong
        /// to whoever was standing there, and reading the difference as
        /// something that happened gave a Pokemon that had just switched in
        /// the stat drop its predecessor was carrying.
        var myForms: [String]
        var theirForms: [String]
    }
    var stepStart: StepStart?

    /// The action being gathered never happened, and this is why. One door,
    /// so the playback learns it from the same place the log does.
    mutating func stopAction(_ reason: String) {
        acting?.stopped = reason
    }

    /// This action is a wind-up, not the move. It did not fail and nothing is
    /// wrong with it, which is why it is not a `stopAction`.
    mutating func markCharging() {
        acting?.charging = true
    }

    /// Close the step being gathered, if it said anything.
    mutating func closeStep() {
        if let lines = gathering, !lines.isEmpty {
            steps.append(snapshot(lines.joined(separator: "\n")))
        }
        gathering = nil
        acting = nil
    }

    private mutating func snapshot(_ text: String) -> Step {
        reconcileEvents()
        defer {
            firing = []; itemsFired = []; criticals = []; untouched = []; missed = []
            events = []; markStepStart()
        }
        return Step(text: text, action: acting,
                    myHP: mine.map(\.hp), theirHP: theirs.map(\.hp),
                    myForms: mine.map(\.build.form.id),
                    theirForms: theirs.map(\.build.form.id),
                    field: field, myTailwind: myTailwind,
                    theirTailwind: theirTailwind, trickRoom: trickRoom,
                    myBoosts: mine.map(\.build.boosts), theirBoosts: theirs.map(\.build.boosts),
                    items: itemsFired, criticals: criticals, untouched: untouched,
                    missed: missed, abilities: firing, events: events,
                    myStatus: mine.map(\.status), theirStatus: theirs.map(\.status),
                    myConfused: mine.map(\.isConfused), theirConfused: theirs.map(\.isConfused),
                    myProtected: mine.map(\.isProtected), theirProtected: theirs.map(\.isProtected))
    }

    /// A critical hit landed on somebody, so the field can say so where the
    /// damage lands rather than only in the log.
    mutating func critical(onMine mine: Bool, slot: Int, from move: String) {
        let hit = Step.Firing(mine: mine, slot: slot, name: move)
        if !criticals.contains(hit) { criticals.append(hit) }
    }

    /// A move did not touch somebody at all, so the field can say so over
    /// them rather than only in the log.
    mutating func untouchable(onMine mine: Bool, slot: Int, by move: String) {
        let hit = Step.Firing(mine: mine, slot: slot, name: move)
        if !untouched.contains(hit) { untouched.append(hit) }
    }

    /// A move was aimed at somebody and went past them. The same door as
    /// `untouchable`, for the other reason nothing landed.
    mutating func miss(onMine mine: Bool, slot: Int, by move: String) {
        let hit = Step.Firing(mine: mine, slot: slot, name: move)
        if !missed.contains(hit) { missed.append(hit) }
    }

    /// Say what happened, and remember what the board looked like when it did.
    /// A note that names an active Pokemon's own ability is that ability
    /// going off, and the step remembers whose, so the field can say so over
    /// the Pokemon the way it says what a hit took.
    mutating func note(_ text: String) {
        guard narrating else { return }
        story.append(text)
        let fired = abilitiesNamed(in: text)
        firing.append(contentsOf: fired.filter { !firing.contains($0) })
        events.append(contentsOf: fired.filter { !events.contains(.ability($0)) }.map(Step.Event.ability))
        // Said in the open is shown to the other side.
        for hit in fired {
            if hit.mine { mine[hit.slot].abilityRevealed = true } else { theirs[hit.slot].abilityRevealed = true }
        }
        for hit in itemsNamed(in: text) {
            if hit.mine { mine[hit.slot].itemRevealed = true } else { theirs[hit.slot].itemRevealed = true }
            if !itemsFired.contains(hit) { itemsFired.append(hit) }
            if !events.contains(.item(hit)) { events.append(.item(hit)) }
        }
        if gathering != nil {
            gathering?.append(text)
        } else {
            steps.append(snapshot(text))
        }
    }

    /// Which active Pokemon's abilities a line names. The board knows what
    /// everyone standing has, so only those names count; "Incineroar's
    /// Intimidate" names Incineroar, and a bare "Supreme Overlord" the one
    /// acting, or the only one standing that has it.
    func abilitiesNamed(in text: String) -> [Step.Firing] {
        owners(of: { $0.build.ability }, in: text)
    }

    /// Which active Pokemon's held items a line names -- a Sitrus Berry
    /// eaten, a Focus Sash that held -- by the same reading.
    func itemsNamed(in text: String) -> [Step.Firing] {
        owners(of: { $0.build.item }, in: text)
    }

    private func owners(of what: (Fighter) -> String, in text: String) -> [Step.Firing] {
        var out: [Step.Firing] = []
        for mineSide in [true, false] {
            let team = mineSide ? mine : theirs
            for slot in 0..<Swift.min(activeCount, team.count) {
                let name = what(team[slot])
                guard !name.isEmpty, text.contains(name) else { continue }
                let label = team[slot].build.form.formLabel
                // Two ways a line says whose it is. Most name it in the
                // possessive -- "Incineroar's Intimidate" -- but the items are
                // written as sentences about somebody: "Garchomp hung on with
                // its Focus Sash", "Garchomp is worn down by its Life Orb".
                // Reading only the first shape left every item unattributed
                // whenever two of them were on the field at once.
                let opening = text.trimmingCharacters(in: .whitespaces)
                let owned = text.contains("\(label)'s \(name)")
                    || opening.hasPrefix("\(label) ") || opening.hasPrefix("\(label)'s ")
                let others = (0..<Swift.min(activeCount, mine.count)).filter { what(mine[$0]) == name }.count
                    + (0..<Swift.min(activeCount, theirs.count)).filter { what(theirs[$0]) == name }.count
                // How many Pokemon standing here answer to that name. Both
                // sides running the same good Pokemon is the ordinary case in
                // this format, not a corner: with a Sneasler out on each side,
                // "Sneasler's Unburden" names neither of them because it names
                // both, and the field put the word over both their heads.
                let sharing = (0..<Swift.min(activeCount, mine.count))
                        .filter { mine[$0].build.form.formLabel == label }.count
                    + (0..<Swift.min(activeCount, theirs.count))
                        .filter { theirs[$0].build.form.formLabel == label }.count
                let isActing = acting.map { $0.byMine == mineSide && $0.slot == slot } ?? false
                // Named unmistakably, or the only one who could have done it,
                // or the one whose turn it is. Anything else is a guess, and a
                // guess drawn over a Pokemon reads as a fact.
                if (owned && sharing == 1) || others == 1 || isActing {
                    out.append(Step.Firing(mine: mineSide, slot: slot, name: name))
                }
            }
        }
        return out
    }

    /// A stage moved, for the step's record of what happened in what order.
    mutating func recordStat(mine side: Bool, slot: Int, stat: Int, delta: Int, cause: String?) {
        events.append(.stat(mine: side, slot: slot, stat: stat, delta: delta, cause: cause))
    }

    /// A status given, for the same record.
    mutating func recordStatus(mine side: Bool, slot: Int, ailment: Ailment) {
        events.append(.status(mine: side, slot: slot, ailment: ailment))
    }

    /// A move declared is a move the other side has seen.
    mutating func reveal(move id: String, mine side: Bool, slot: Int) {
        if side, mine.indices.contains(slot) { mine[slot].revealedMoves.insert(id) }
        else if !side, theirs.indices.contains(slot) { theirs[slot].revealedMoves.insert(id) }
    }

    var myActive: ArraySlice<Fighter> { mine.prefix(activeCount) }
    var theirActive: ArraySlice<Fighter> { theirs.prefix(activeCount) }

    /// Whether a side has anything left to send out.
    func isOut(mine side: Bool) -> Bool {
        (side ? mine : theirs).allSatisfy(\.fainted)
    }

    /// What is lying on the floor when something walks in.
    ///
    /// Hazards are the reason a pivot costs something, and without them a
    /// switch was free: the search would pivot every turn because nothing ever
    /// charged it for the privilege.
    /// Clear the hazards lying on one side of the field, and say whether there
    /// were any.
    ///
    /// Defog and Rapid Spin both do this. Rapid Spin does nothing else to the
    /// field, which is the whole reason a team picks one over the other. It is
    /// on the Board rather than in either move's resolver because a damaging
    /// move and a status move both need it, and the two resolvers should not
    /// have to know about each other to share eight lines.
    @discardableResult
    mutating func sweepHazards(mine side: Bool) -> Bool {
        var own = side ? myScreens : theirScreens
        let had = own.spikes > 0 || own.toxicSpikes > 0 || own.stealthRock || own.stickyWeb
        own.spikes = 0; own.toxicSpikes = 0
        own.stealthRock = false; own.stickyWeb = false
        if side { myScreens = own } else { theirScreens = own }
        return had
    }

    mutating func takeHazards(mine side: Bool, slot: Int) {
        let field = side ? myScreens : theirScreens
        // The web belongs in this guard. Without it the Sticky Web handling
        // below was unreachable unless some other hazard happened to be down —
        // so a web set on its own, which is the ordinary way it is set, did
        // nothing at all.
        guard field.spikes > 0 || field.toxicSpikes > 0 || field.stealthRock
                || field.stickyWeb else { return }
        var who = side ? mine[slot] : theirs[slot]
        guard !who.fainted else { return }
        let name = who.build.form.formLabel
        let grounded = who.isGrounded

        if field.stealthRock {
            // Stealth Rock is a Rock-type hit, so it reads off the type chart:
            // four times on a Charizard, a quarter on a Tyranitar.
            let effect = who.types.reduce(1.0) { $0 * TypeChart.multiplier(.rock, into: $1) }
            let hit = Swift.max(1, Int(Double(who.maxHP) / 8 * effect))
            who.hp -= hit
            note("Pointed stones dug into \(name).")
        }
        if grounded, field.spikes > 0 {
            let share = [0, 8, 6, 4][Swift.min(3, field.spikes)]
            who.hp -= Swift.max(1, who.maxHP / share)
            note("\(name) is hurt by the spikes.")
        }
        if grounded, field.stickyWeb, !who.fainted {
            // A stage of Speed, which is the whole point: it does not hurt,
            // it just means whatever came in is now slower than it planned.
            let stage = who.build.boosts[Stat.speed.rawValue]
            if stage > -6 {
                who.build.boosts[Stat.speed.rawValue] = stage - 1
                note("\(name) was caught in the sticky web and slowed down.")
            }
        }
        if grounded, field.toxicSpikes > 0 {
            if who.types.contains(.poison) {
                // A grounded Poison type takes them away rather than being hurt.
                if side { myScreens.toxicSpikes = 0 } else { theirScreens.toxicSpikes = 0 }
                note("\(name) absorbed the toxic spikes.")
            } else if who.status == .none, !who.types.contains(.steel),
                      who.build.ability != "Immunity" {
                who.status = field.toxicSpikes >= 2 ? .badPoison : .poison
                note("\(name) was poisoned by the toxic spikes.")
            }
        }
        if who.hp <= 0 { who.hp = 0; note("\(name) fainted.") }
        if side { mine[slot] = who } else { theirs[slot] = who }
    }

    /// The Seeds: a stage of Defence or Special Defence, once, when the
    /// terrain they answer to is on the field.
    mutating func terrainSeeds() {
        let wanted: [String: (Terrain, Stat)] = [
            "Grassy Seed": (.grassy, .defense), "Psychic Seed": (.psychic, .spDefense),
            "Electric Seed": (.electric, .defense), "Misty Seed": (.misty, .spDefense),
        ]
        for side in [true, false] {
            let count = Swift.min(activeCount, (side ? mine : theirs).count)
            for index in 0..<count {
                let who = (side ? mine : theirs)[index]
                guard !who.fainted, !who.build.itemSpent,
                      let (terrain, stat) = wanted[who.build.item], field.terrain == terrain
                else { continue }
                if side {
                    mine[index].build.itemSpent = true
                    mine[index].build.boosts[stat.rawValue] = Swift.min(6, mine[index].build.boosts[stat.rawValue] + 1)
                } else {
                    theirs[index].build.itemSpent = true
                    theirs[index].build.boosts[stat.rawValue] = Swift.min(6, theirs[index].build.boosts[stat.rawValue] + 1)
                }
                note("\(who.build.form.formLabel) used its \(who.build.item): \(stat.short) rose.")
            }
        }
    }

    /// The start of the game: everyone out front arrives at once, and their
    /// abilities go off in Speed order, which is what decides whose weather
    /// the first turn is played in.
    mutating func sendOutLeads() {
        for entry in leadOrder { landed(mine: entry.mine, slot: entry.slot) }
    }

    /// The order the leads' abilities go off in: fastest first, a tie to you,
    /// the same way every time. The battle screen walks this one at a time
    /// so the start of the game can be watched rather than read.
    var leadOrder: [(mine: Bool, slot: Int)] {
        var order: [(mine: Bool, slot: Int, speed: Int)] = []
        for slot in 0..<min(activeCount, mine.count) where !mine[slot].fainted {
            order.append((true, slot, mine[slot].build.speed(in: field)))
        }
        for slot in 0..<min(activeCount, theirs.count) where !theirs[slot].fainted {
            order.append((false, slot, theirs[slot].build.speed(in: field)))
        }
        order.sort { $0.speed > $1.speed || ($0.speed == $1.speed && $0.mine && !$1.mine) }
        return order.map { ($0.mine, $0.slot) }
    }

    /// Slots on my side standing empty with somebody able to fill them.
    /// The slots you have to send something into — and never more of them than
    /// you have Pokémon to send.
    ///
    /// This used to report every fallen active as long as *any* bench Pokémon
    /// was standing, which is right until it is not: lose both actives with one
    /// Pokémon left and it asked for two replacements, you gave it the only one
    /// you had, and the screen waited for a second that could not exist. The
    /// game has no such state — you send in what you have — and the battle
    /// screen had no way out of it.
    var gapsOfMine: [Int] {
        let ready = (activeCount..<mine.count).filter { !mine[$0].fainted }.count
        guard ready > 0 else { return [] }
        return Array((0..<Swift.min(activeCount, mine.count))
            .filter { mine[$0].fainted }
            .prefix(ready))
    }

}

extension Board {
    /// A board at the start of a game: two teams, the named leads out in front.
    ///
    /// Slots with nothing selected still need a set to fight with, so they get
    /// the same worth-ranked fallback the versus grid uses. A Pokémon with no
    /// moves is not a harmless one.
    /// `alreadyEvolved` is how every analysis screen wants it: a Mega is its
    /// Mega, because the question there is what the team fights as. A battle is
    /// the other case — it starts as what was registered and evolves during a
    /// turn, which is the only way the order of it can matter, and the order is
    /// what decides a weather war.
    init(mine myTeam: Team, theirs theirTeam: Team, rules: Rulebook,
         myLeads: [String] = [], theirLeads: [String] = [],
         field: Field = Field(isDoubles: true),
         alreadyEvolved: Bool = true) {
        func build(_ team: Team, leads: [String]) -> [Fighter] {
            let made: [(String, Fighter)] = team.slots.compactMap { slot in
                guard let registered = slot.form(in: rules),
                      let evolved = slot.battleForm(in: rules),
                      let combatant = slot.combatant(in: rules) else { return nil }
                let mega = slot.megaEvolution(in: rules)
                let form = alreadyEvolved ? evolved : registered
                // A slot with nothing chosen still has an ability; treating it
                // as blank means an Intimidate that never fires.
                // It has to be an ability this form actually has. A team list
                // written for the Mega carries the Mega's ability, and reading
                // that onto the base form gives a Charizard with Drought, which
                // is a Pokémon that does not exist.
                let named: String = {
                    let own = form.abilities.map(\.name)
                    if !slot.ability.isEmpty, own.contains(slot.ability) { return slot.ability }
                    return own.first ?? ""
                }()
                var fighting = combatant
                if fighting.ability.isEmpty { fighting.ability = named }
                if !alreadyEvolved, mega != nil {
                    // Before it evolves it is what the list registered, ability
                    // and all: a Salamence with Intimidate, not Aerilate.
                    //
                    // Two fields, not a fresh Combatant. Rebuilding it here
                    // threw away everything else the slot had said, and the
                    // only slots it happened to were the ones holding a stone:
                    // a shiny Salamence walked into a battle the ordinary
                    // colours while a shiny Sneasler, which has no Mega, was
                    // fine. The item, the Stat Points and the alignment were
                    // being copied back in by hand, which is the tell.
                    fighting.form = registered
                    fighting.ability = named
                }
                var moves = slot.moves.compactMap { rules.move($0) }
                if !moves.contains(where: \.isDamaging) {
                    let pool = rules.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
                    moves += pool.sorted {
                        rules.moveValue($0, for: form, ability: combatant.ability, item: slot.item)
                            > rules.moveValue($1, for: form, ability: combatant.ability, item: slot.item)
                    }.prefix(3)
                }
                return (registered.id,
                        Fighter(build: fighting, moves: moves,
                                pendingMega: alreadyEvolved ? nil : mega))
            }
            // The leads go to the front; everything else keeps its order behind.
            let front = leads.compactMap { id in made.first { $0.0 == id }?.1 }
            let rest = made.filter { entry in !leads.contains(entry.0) }.map(\.1)
            return front + rest
        }
        var mine = build(myTeam, leads: myLeads)
        var theirs = build(theirTeam, leads: theirLeads)
        // The leads are on show from the first moment; the rest are not.
        let out = field.isDoubles ? 2 : 1
        for index in mine.indices where index < out { mine[index].seen = true }
        for index in theirs.indices where index < out { theirs[index].seen = true }
        self.init(mine: mine, theirs: theirs, field: field)
    }

    /// A game as it actually starts: your chosen four in order, their four
    /// chosen the same way against your six, and their back two recorded as
    /// what they probably are rather than what they are.
    ///
    /// Every pair they could be carrying behind the leads they showed is
    /// weighed by how much it costs you — which is how a good player chooses,
    /// so it is how the guess is made — and the likeliest pairs are what the
    /// search plays against until one of them walks on.
    /// `sendOut` false leaves the leads' abilities for the caller to fire, one
    /// at a time, which is how the battle screen shows them happening.
    /// `theirBringing` is their four as another player chose them, in order;
    /// left out, they are chosen for them the way a good player would.
    static func opening(mine myTeam: Team, bringing: [String], theirs theirTeam: Team,
                        theirBringing: [String]? = nil,
                        rules: Rulebook, singles: Bool, sendOut: Bool = true) -> Board {
        let bring = singles ? 3 : 4
        let leadCount = singles ? 1 : 2
        let field = Field(isDoubles: !singles)

        var brought = myTeam
        brought.slots = bringing.compactMap { id in myTeam.slots.first { $0.formID == id } }
        if brought.slots.count < leadCount { brought = myTeam }

        var theirBrought = theirTeam
        if let theirBringing {
            theirBrought.slots = theirBringing.compactMap { id in theirTeam.slots.first { $0.formID == id } }
        } else {
            // They choose their own four the same way, against your six.
            let theirGrid = Matchup(mine: theirTeam, theirs: myTeam, rules: rules, field: field)
            let picker = BringFour(matchup: theirGrid, rules: rules, bring: bring)
            if let plan = picker.plans.first {
                theirBrought.slots = plan.bring.compactMap { form in
                    theirTeam.slots.first { $0.battleForm(in: rules)?.id == form.id }
                }
            }
        }
        if theirBrought.slots.count < leadCount { theirBrought = theirTeam }

        var board = Board(mine: brought, theirs: theirBrought, rules: rules,
                          field: field, alreadyEvolved: false)
        board.activeCount = leadCount
        // What each side's Pokémon are worth against the other side. Worked
        // out once here, off the six each side registered rather than the four
        // they brought, and read on every evaluation after.
        board.myBeats = Worth.table(for: myTeam, against: theirTeam, rules: rules, field: field)
        board.theirBeats = Worth.table(for: theirTeam, against: myTeam, rules: rules, field: field)
        board.myRoster = myTeam.slots.compactMap { $0.battleForm(in: rules)?.id }
        board.theirRoster = theirTeam.slots.compactMap { $0.battleForm(in: rules)?.id }
        board.refreshWorth()
        if sendOut { board.sendOutLeads() }

        // What each side's back two probably are, from both chairs.
        board.theirBenchGuesses = benchGuesses(
            for: theirTeam, against: myTeam, opposite: brought,
            leadIDs: Set(board.theirs.prefix(leadCount).map(\.build.form.id)),
            behind: bring - leadCount, rules: rules, field: field)
        board.myBenchGuesses = benchGuesses(
            for: myTeam, against: theirTeam, opposite: theirBrought,
            leadIDs: Set(board.mine.prefix(leadCount).map(\.build.form.id)),
            behind: bring - leadCount, rules: rules, field: field)
        return board
    }

    /// Every pair one side could be keeping behind its leads, and how likely
    /// each is — weighed the way that side would weigh it, by how much the
    /// four it completes is worth against the six it is facing.
    ///
    /// `chooser` is the six doing the choosing, `against` the six it is being
    /// chosen against, and `opposite` a team to stand on the other side while
    /// the chooser's members are built into fighters.
    /// Not private: `Tools/reading` asks this the same question the engine
    /// asks, but conditioned on the leads a real player actually sent out
    /// rather than the ones the engine assumed they would.
    static func benchGuesses(for chooser: Team, against other: Team,
                             opposite: Team, leadIDs: Set<String>,
                             behind: Int, rules: Rulebook, field: Field) -> [BenchGuess] {
        let grid = Matchup(mine: chooser, theirs: other, rules: rules, field: field)
        // Every Pokémon on the chooser's six as a fighter, so a guess can be
        // played out rather than only scored.
        let whole = Board(mine: opposite, theirs: chooser, rules: rules,
                          field: field, alreadyEvolved: false)
        // A fighter stands as what was registered; the grid rates what it
        // fights as. For a stone-holder those are different Pokémon, and
        // matching them by id silently dropped every pair with a Mega in it.
        var fightsAs: [String: Form] = [:]
        for slot in chooser.slots {
            if let registered = slot.form(in: rules), let battle = slot.battleForm(in: rules) {
                fightsAs[registered.id] = battle
            }
        }
        let leadForms = leadIDs.compactMap { fightsAs[$0] }
        let rest = whole.theirs.filter { !leadIDs.contains($0.build.form.id) }
        guard behind > 0, rest.count > behind, !leadForms.isEmpty else { return [] }

        var guesses: [BenchGuess] = []
        var weights: [Double] = []
        for pair in Board.choose(rest, behind) {
            let forms = pair.compactMap { fightsAs[$0.build.form.id] }
            guard forms.count == pair.count,
                  forms.filter(\.isMega).count + leadForms.filter(\.isMega).count <= 1
            else { continue }
            // How much the four it completes is worth, which is how much the
            // side choosing it likes it.
            let edge = grid.rate(bringing: leadForms + forms, against: grid.theirForms).score
            guesses.append(BenchGuess(fighters: pair, chance: 0))
            weights.append(Double(edge))
        }
        guard !guesses.isEmpty else { return [] }
        // A soft preference: the best pair is likeliest, not certain. Twelve
        // points of edge is one factor of e.
        let top = weights.max() ?? 0
        var raw = weights.map { exp(($0 - top) / 12) }

        // And then what people actually do. The score above is a theory of how
        // somebody chooses — that they bring whatever our own grid rates best —
        // and measured against a thousand real games it named the right pair no
        // better than chance. A Pokémon's measured bring rate is the evidence
        // it was missing: four of six is 67%, and something brought 83% of the
        // time it is on a team, or 37%, is telling you something no grid works
        // out. Multiplied in as odds, so a pair of two reluctant picks is
        // doubly unlikely and the grid still decides between equals.
        if ProcessInfo.processInfo.environment["CHAMPIONSLAB_NO_BRING_PRIOR"] == nil {
            for (index, guess) in guesses.enumerated() {
                let odds = guess.fighters.reduce(1.0) { $0 * $1.build.form.bringOdds }
                raw[index] *= odds
            }
        }
        let total = raw.reduce(0, +)
        guard total > 0 else { return [] }
        return zip(guesses, raw).map {
            BenchGuess(fighters: $0.fighters, chance: $1 / total)
        }.sorted { $0.chance > $1.chance }
    }
    /// Every way of choosing `count` from `items`, order ignored.
    static func choose<T>(_ items: [T], _ count: Int) -> [[T]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        if count == items.count { return [items] }
        var out: [[T]] = []
        for (index, item) in items.enumerated() {
            for rest in choose(Array(items[(index + 1)...]), count - 1) {
                out.append([item] + rest)
            }
        }
        return out
    }
}

// MARK: - What a side can do

/// One Pokémon's choice for the turn.
enum Choice: Hashable {
    /// An index into that Pokémon's own move list, and which opponent it is
    /// aimed at. Spread moves ignore the target.
    case attack(move: Int, target: Int)
    case protectSelf(move: Int)
    case swap(to: Int)
    /// Nobody is standing in the second slot. Singles is this every turn, and
    /// doubles becomes it once a side is down to its last Pokémon.
    case pass

    var isProtect: Bool { if case .protectSelf = self { return true }; return false }
    var isSwap: Bool { if case .swap = self { return true }; return false }
    var isPass: Bool { if case .pass = self { return true }; return false }

    /// A target at or past this is the user's own partner, not an opponent:
    /// the tech of hitting your own Pokémon — a Weakness Policy, a Justified,
    /// a Thermal Exchange — on purpose.
    static let allyTarget = 100
    static func attackingAlly(move: Int) -> Choice { .attack(move: move, target: allyTarget) }
    var aimsAtAlly: Bool {
        if case .attack(_, let target) = self { return target >= Choice.allyTarget }
        return false
    }
}

/// Both actives choosing at once, which is the unit a turn is actually played in.
struct Play: Hashable {
    var left: Choice
    var right: Choice
    /// Which of the two is Mega Evolving this turn, if either.
    ///
    /// In the game this is a toggle you flip while choosing that Pokémon's
    /// move, not something that happens to you, and it is a decision worth
    /// having: evolving changes your Speed, it shows the other side what you
    /// brought, and when both sides bring weather the one that evolves second
    /// is the one whose weather stays. Holding it back a turn is sometimes the
    /// whole plan.
    var megaSlot: Int?
}

// MARK: - Across the wire
//
// A game between two people is one board on one machine and a view of it on
// the other, so the pieces of a board the other player may see have to be
// encodable. Swift synthesises that only beside the type itself, which is why
// these live here; turning a board round for the other chair does not, and is
// in BoardWire.swift. Nothing here decides what they may see;
// `asTheOtherPlayerSeesIt` in the LAN folder does that.

extension Fighter: Codable {}
extension Screens: Codable {}
extension Choice: Codable {}
extension Play: Codable {}
extension Board.Action: Codable {}
extension Board.Pivot: Codable {}
extension Board.Carried: Codable {}
extension Board.BenchGuess: Codable {}
extension Board.Queued: Codable {}
extension Board.Step.Firing: Codable {}
extension Board.Step: Codable {
    /// Everything but the id, which is the step's own and fresh on each side.
    enum CodingKeys: String, CodingKey {
        case text, action, myHP, theirHP, myForms, theirForms, field, myTailwind, theirTailwind,
             trickRoom, myBoosts, theirBoosts, abilities, items, criticals, untouched, missed,
             events, myStatus, theirStatus, myConfused, theirConfused,
             myProtected, theirProtected
    }
}
extension Board.Step.Event: Codable {}
