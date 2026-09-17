//  TurnModel.swift
//  The turn in front of you, solved as the game it actually is.
//
//  Everything else in this app reasons about matchups: who beats what, given
//  time. That is the right frame for building a team and the wrong one for
//  playing it, because a game of doubles is not a sequence of duels. It is a
//  sequence of *simultaneous* decisions — both sides lock in two choices
//  knowing nothing about the other's, and then the turn resolves.
//
//  That has a name. Each turn is a matrix game, and the thing players call
//  "reading your opponent" is what game theory calls a mixed strategy: there is
//  no single best move, there is a distribution over moves, and a player who
//  always picks the same one is a player you can beat every time. Reading
//  someone is noticing where their distribution differs from the equilibrium
//  one and leaning against it.
//
//  So this builds the matrix — every plausible pair of my two choices against
//  every plausible pair of theirs — resolves each cell into a board, scores it,
//  and solves for the equilibrium. What comes out is not "click this". It is:
//
//      · how often each line is worth clicking, if you want to be unexploitable
//      · what each line is worth if they guess right, and if they guess wrong
//      · which line is safe and which is greedy, which is the actual decision
//
//  Honest scope. This solves *one* turn, with a static score for the board it
//  leaves behind; it is not a game tree and does not plan three turns out. It
//  uses expected damage rather than the high roll, because an equilibrium is
//  about averages — the rest of the app asks "can this knock out", which is a
//  high-roll question, and the two numbers are meant to differ. Abilities that
//  fire on entry are modelled only for Intimidate. Nobody is modelled as
//  learning across turns, which is the other half of what reading someone
//  means.

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
    /// Follow Me or Rage Powder this turn: single-target moves come here.
    var drawingFire = false
    /// It has stood on the field, so the other side knows it came. Until then
    /// a benched Pokémon is one of the two they might have brought, and the
    /// game is played against that, not against the answer.
    var seen = false
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

    /// The chance Protect works right now.
    var protectChance: Double { pow(1.0 / 3.0, Double(protectStreak)) }

    var fainted: Bool { hp <= 0 }
    var share: Double { maxHP > 0 ? max(0, Double(hp) / Double(maxHP)) : 0 }

    init(build: Combatant, moves: [Move], hp: Int? = nil, pendingMega: Form? = nil) {
        self.build = build
        self.moves = moves
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
        var myStatus: [Ailment] = []
        var theirStatus: [Ailment] = []
        var myConfused: [Bool] = []
        var theirConfused: [Bool] = []
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
    }

    /// Close the step being gathered, if it said anything.
    mutating func closeStep() {
        if let lines = gathering, !lines.isEmpty {
            steps.append(snapshot(lines.joined(separator: "\n")))
        }
        gathering = nil
        acting = nil
    }

    private func snapshot(_ text: String) -> Step {
        Step(text: text, action: acting,
             myHP: mine.map(\.hp), theirHP: theirs.map(\.hp),
             myForms: mine.map(\.build.form.id),
             theirForms: theirs.map(\.build.form.id),
             field: field, myTailwind: myTailwind,
             theirTailwind: theirTailwind, trickRoom: trickRoom,
             myBoosts: mine.map(\.build.boosts), theirBoosts: theirs.map(\.build.boosts),
             myStatus: mine.map(\.status), theirStatus: theirs.map(\.status),
             myConfused: mine.map(\.isConfused), theirConfused: theirs.map(\.isConfused))
    }

    /// Say what happened, and remember what the board looked like when it did.
    mutating func note(_ text: String) {
        guard narrating else { return }
        story.append(text)
        if gathering != nil {
            gathering?.append(text)
        } else {
            steps.append(snapshot(text))
        }
    }

    var myActive: ArraySlice<Fighter> { mine.prefix(activeCount) }
    var theirActive: ArraySlice<Fighter> { theirs.prefix(activeCount) }

    /// Whether a side has anything left to send out.
    func isOut(mine side: Bool) -> Bool {
        (side ? mine : theirs).allSatisfy(\.fainted)
    }

    /// Bring the next healthy Pokémon forward into an empty slot. Replacing a
    /// fainted Pokémon is not a turn, it happens at the end of one.
    /// `sides` says whose gaps to fill. A battle asks the player who comes in
    /// rather than choosing for them, so the interface fills only the opponent
    /// and then asks; a search fills both, because it has to keep going.
    mutating func fillGaps(mine fillMine: Bool = true, theirs fillTheirs: Bool = true) {
        for side in [true, false] where side ? fillMine : fillTheirs {
            let count = side ? mine.count : theirs.count
            for slot in 0..<min(activeCount, count) where (side ? mine : theirs)[slot].fainted {
                let team = side ? mine : theirs
                guard let next = (activeCount..<team.count).first(where: { !team[$0].fainted })
                else { continue }
                if side { mine.swapAt(slot, next) } else { theirs.swapAt(slot, next) }
                landed(mine: side, slot: slot)
            }
        }
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

    /// A Pokémon has just reached the field: it is seen, it can Fake Out, and
    /// whatever it does on arrival happens now.
    mutating func landed(mine side: Bool, slot: Int) {
        let before = field
        takeHazards(mine: side, slot: slot)
        if (side ? mine[slot] : theirs[slot]).fainted { return }
        // Screen Cleaner takes down both sides' screens on the way in. Done
        // here rather than in `entryAbility`, which is handed two teams and a
        // field but never the screens.
        if (side ? mine[slot] : theirs[slot]).build.ability == "Screen Cleaner",
           myScreens.any || theirScreens.any {
            myScreens.reflect = 0; myScreens.lightScreen = 0; myScreens.auroraVeil = 0
            theirScreens.reflect = 0; theirScreens.lightScreen = 0; theirScreens.auroraVeil = 0
            note("\((side ? mine[slot] : theirs[slot]).build.form.formLabel)'s Screen Cleaner swept the screens away.")
        }
        if side {
            mine[slot].justArrived = true
            mine[slot].arrivedThisTurn = true
            mine[slot].seen = true
            mine[slot].isProtected = false
            mine[slot].lastMoveFailed = false
            if let said = Switching.entryAbility(of: mine[slot].build.ability, team: &mine,
                                                 slot: slot, opposing: &theirs, field: &field) {
                note(said)
            }
        } else {
            theirs[slot].justArrived = true
            theirs[slot].arrivedThisTurn = true
            theirs[slot].seen = true
            theirs[slot].isProtected = false
            theirs[slot].lastMoveFailed = false
            if let said = Switching.entryAbility(of: theirs[slot].build.ability, team: &theirs,
                                                 slot: slot, opposing: &mine, field: &field) {
                note(said)
            }
        }
        fieldSettled(from: before)
        terrainSeeds()
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

    /// Their pick for a gap: the benched one that takes least from whatever
    /// of yours is standing, which is how the choice is made in `choices`.
    func theirBestReplacement(for slot: Int, excluding taken: Set<Int>) -> Int? {
        var best: (index: Int, worst: Double)?
        for index in activeCount..<theirs.count where !theirs[index].fainted && !taken.contains(index) {
            var worst = 0.0
            for foe in mine.prefix(activeCount) where !foe.fainted {
                for move in foe.moves where move.isDamaging {
                    let result = DamageCalc.calculate(attacker: foe.build, defender: theirs[index].build,
                                                      move: move, field: field)
                    worst = Swift.max(worst, Double(result.maxDamage) / Double(theirs[index].maxHP))
                }
            }
            if best == nil || worst < best!.worst { best = (index, worst) }
        }
        return best?.index
    }

    /// The end of a turn with something down on either side: both players
    /// send in at once, and the arrivals happen in Speed order — so the faster
    /// one's Intimidate never touches the slower one, and the slower one's
    /// weather is the weather. Yours are what you chose; theirs choose for
    /// themselves.
    mutating func replaceFallen(mine picks: [(slot: Int, bench: Int)]) {
        var arrivals: [(mine: Bool, slot: Int, bench: Int, speed: Int)] = []
        for pick in picks where mine.indices.contains(pick.bench) && !mine[pick.bench].fainted {
            arrivals.append((true, pick.slot, pick.bench, mine[pick.bench].build.speed(in: field)))
        }
        var taken: Set<Int> = []
        for slot in 0..<min(activeCount, theirs.count) where theirs[slot].fainted {
            guard let pick = theirBestReplacement(for: slot, excluding: taken)
            else { continue }
            taken.insert(pick)
            arrivals.append((false, slot, pick, theirs[pick].build.speed(in: field)))
        }
        arrivals.sort { $0.speed > $1.speed || ($0.speed == $1.speed && $0.mine && !$1.mine) }
        for arrival in arrivals {
            if arrival.mine {
                guard mine[arrival.slot].fainted else { continue }
                mine.swapAt(arrival.slot, arrival.bench)
                note("You sent in \(mine[arrival.slot].build.form.formLabel).")
            } else {
                guard theirs[arrival.slot].fainted else { continue }
                theirs.swapAt(arrival.slot, arrival.bench)
                note("They sent in \(theirs[arrival.slot].build.form.formLabel).")
            }
            landed(mine: arrival.mine, slot: arrival.slot)
        }
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

    /// Bring one specific Pokémon in, which is the choice the game gives you.
    mutating func sendIn(_ bench: Int, to slot: Int) {
        guard mine.indices.contains(bench), mine.indices.contains(slot),
              !mine[bench].fainted, mine[slot].fainted else { return }
        mine.swapAt(slot, bench)
        landed(mine: true, slot: slot)
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
                    fighting = Combatant(form: registered, ability: named,
                                         item: slot.item, sp: slot.sp,
                                         alignment: slot.alignment)
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
    static func opening(mine myTeam: Team, bringing: [String], theirs theirTeam: Team,
                        rules: Rulebook, singles: Bool, sendOut: Bool = true) -> Board {
        let bring = singles ? 3 : 4
        let leadCount = singles ? 1 : 2
        let field = Field(isDoubles: !singles)

        var brought = myTeam
        brought.slots = bringing.compactMap { id in myTeam.slots.first { $0.formID == id } }
        if brought.slots.count < leadCount { brought = myTeam }

        // They choose their own four the same way, against your six.
        let theirGrid = Matchup(mine: theirTeam, theirs: myTeam, rules: rules, field: field)
        let picker = BringFour(matchup: theirGrid, rules: rules, bring: bring)
        var theirBrought = theirTeam
        if let plan = picker.plans.first {
            theirBrought.slots = plan.bring.compactMap { form in
                theirTeam.slots.first { $0.battleForm(in: rules)?.id == form.id }
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

// MARK: - Playing it out

enum TurnModel {

    /// Abilities that stop priority moves reaching their side at all.
    static let priorityBlockers: Set<String> = ["Armor Tail", "Queenly Majesty", "Dazzling"]

    /// Resolve one turn from both sides' choices.
    /// Play a turn out.
    ///
    /// `rolling` is the difference between a simulation and an evaluation. The
    /// search wants the average — an equilibrium is about what a line is worth
    /// across every way it could go — so it leaves this off and every hit lands
    /// for its expected damage. A battle somebody is watching wants the dice:
    /// the roll, the miss, the burn that did or did not take.
    static func resolve(_ board: Board, mine: Play, theirs: Play,
                        rolling: Bool = false, narrating: Bool = true) -> Board {
        var out = board
        out.story = []
        out.steps = []
        out.narrating = narrating
        for index in out.mine.indices { out.mine[index].isProtected = false
                                        out.mine[index].flinched = false
                                        out.mine[index].arrivedThisTurn = false
                                        out.mine[index].drawingFire = false }
        for index in out.theirs.indices { out.theirs[index].isProtected = false
                                          out.theirs[index].flinched = false
                                          out.theirs[index].arrivedThisTurn = false
                                          out.theirs[index].drawingFire = false }

        let myChoices = [mine.left, mine.right]
        let theirChoices = [theirs.left, theirs.right]

        // Mean Look holds something in place, and so does a Shadow Tag or an
        // Arena Trap across the field. A Ghost walks out of any of it, and so
        // does anything holding a Shed Shell.
        func heldInPlace(_ who: Fighter, by others: [Fighter], board: Board) -> Bool {
            if who.types.contains(.ghost) || who.build.item == "Shed Shell"
                || who.build.ability == "Run Away" { return false }
            if who.cannotEscape { return true }
            let grounded = who.isGrounded
            for other in others.prefix(board.activeCount) where !other.fainted {
                switch other.build.ability {
                case "Shadow Tag": if who.build.ability != "Shadow Tag" { return true }
                case "Arena Trap": if grounded { return true }
                case "Magnet Pull": if who.types.contains(.steel) { return true }
                default: break
                }
            }
            return false
        }

        // -- switches, which resolve before anything else --------------------
        // In turn order — the faster Pokémon leaves first, Trick Room turning
        // that round — and each one its own step, with whatever the arrival
        // did in the same step. Said out loud, because a silent switch reads
        // as a Pokémon that did nothing, which is exactly what a switch is
        // meant to look like to the other player and exactly what a log must
        // not let it be.
        var leaving: [(mine: Bool, slot: Int, bench: Int, speed: Int)] = []
        for (slot, choice) in myChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.mine.indices.contains(slot), out.mine.indices.contains(bench),
                  !out.mine[bench].fainted, !out.mine[slot].fainted,
                  out.mine[slot].charging == nil,
                  !heldInPlace(out.mine[slot], by: out.theirs, board: out) else { continue }
            leaving.append((true, slot, bench,
                            TurnOrder.speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, choice) in theirChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.theirs.indices.contains(slot), out.theirs.indices.contains(bench),
                  !out.theirs[bench].fainted, !out.theirs[slot].fainted,
                  out.theirs[slot].charging == nil,
                  !heldInPlace(out.theirs[slot], by: out.mine, board: out) else { continue }
            leaving.append((false, slot, bench,
                            TurnOrder.speed(of: out.theirs[slot], tailwind: out.theirTailwind > 0, board: out)))
        }
        let inverted = out.trickRoom > 0
        leaving.sort { a, b in
            if a.speed != b.speed { return inverted ? a.speed < b.speed : a.speed > b.speed }
            return a.mine && !b.mine
        }
        for entry in leaving {
            out.beginStep(Board.Action(byMine: entry.mine, slot: entry.slot,
                                       move: "", category: "Switch", type: ""))
            if entry.mine {
                out.note("You switched \(out.mine[entry.slot].build.form.formLabel) out for \(out.mine[entry.bench].build.form.formLabel).")
                let said = Switching.swapIn(mine: true, active: entry.slot, bench: entry.bench, board: &out)
                if let said { out.note(said) }
            } else {
                out.note("They switched \(out.theirs[entry.slot].build.form.formLabel) out for \(out.theirs[entry.bench].build.form.formLabel).")
                let said = Switching.swapIn(mine: false, active: entry.slot, bench: entry.bench, board: &out)
                if let said { out.note(said) }
            }
            out.closeStep()
        }

        // -- Mega Evolution, in Speed order ----------------------------------
        //
        // After the switches and before any move, fastest first. The order is
        // not decoration: an ability that fires on evolving fires in that
        // order, so when two Megas both bring weather the *slower* one evolves
        // second, overwrites the first, and its weather is the one left on the
        // field. Getting this backwards would make every sun-against-rain lead
        // read the wrong way round.
        // Only who was actually told to. One per side, because that is the
        // rule, and Speed decides only *when* — which is the part that matters.
        var evolving: [(mine: Bool, slot: Int, speed: Int)] = []
        // A Pokémon evolves with the move it picks, so one that was switched
        // in this turn — or switched out — does not.
        if let slot = mine.megaSlot, out.mine.indices.contains(slot),
           slot < out.activeCount, out.mine[slot].pendingMega != nil,
           !(slot == 0 ? mine.left : mine.right).isSwap,
           !out.mine[slot].fainted, !out.mine.contains(where: \.hasMegaEvolved) {
            evolving.append((true, slot, TurnOrder.speed(of: out.mine[slot],
                                               tailwind: out.myTailwind > 0, board: out)))
        }
        if let slot = theirs.megaSlot, out.theirs.indices.contains(slot),
           slot < out.activeCount, out.theirs[slot].pendingMega != nil,
           !(slot == 0 ? theirs.left : theirs.right).isSwap,
           !out.theirs[slot].fainted, !out.theirs.contains(where: \.hasMegaEvolved) {
            evolving.append((false, slot, TurnOrder.speed(of: out.theirs[slot],
                                                tailwind: out.theirTailwind > 0, board: out)))
        }
        // Trick Room does not invert this: Mega Evolution is worked out on raw
        // Speed regardless of what is on the field.
        for entry in evolving.sorted(by: { $0.speed > $1.speed }) {
            let before = out.field
            if entry.mine {
                Switching.megaEvolve(&out.mine, slot: entry.slot, opposing: &out.theirs,
                           field: &out.field)
            } else {
                Switching.megaEvolve(&out.theirs, slot: entry.slot, opposing: &out.mine,
                           field: &out.field)
            }
            out.fieldSettled(from: before)
        }

        // -- everything else, in order ---------------------------------------
        // Who acts, in what order. TurnOrder owns that decision — the
        // bracket, After You and Quash, the Trick Room inversion, the re-read
        // of Speed between actions — so that anything wanting to *describe*
        // the order walks the same code rather than a second opinion of it.
        var pending = TurnOrder.declare(&out, mine: myChoices, theirs: theirChoices,
                                        rolling: rolling)
        // What everyone is about to do, before anyone does it.
        for entry in pending {
            out.declared[(entry.mine ? "m" : "t") + "\(entry.slot)"] = entry.choice
        }

        while let entry = TurnOrder.next(from: &pending, board: out) {
            // One action, one step: whatever it does to however many. What it
            // is held to is checked now, not when the turn was queued: an
            // Encore that landed a moment ago already applies.
            let actor = (entry.mine ? out.mine : out.theirs)[entry.slot]
            if entry.mine {
                out.mine[entry.slot].goesNext = false; out.mine[entry.slot].goesLast = false
            } else {
                out.theirs[entry.slot].goesNext = false; out.theirs[entry.slot].goesLast = false
            }
            out.acted.insert((entry.mine ? "m" : "t") + "\(entry.slot)")
            // What is actually played, not what was asked for: an Encore or a
            // Choice lock substitutes a different move, and the screen should
            // draw the one that happens.
            let playing = TurnOrder.forced(actor, entry.choice)
            out.beginStep(Board.Action(played: playing, by: actor,
                                       byMine: entry.mine, slot: entry.slot))
            apply(playing, byMine: entry.mine, slot: entry.slot, to: &out, rolling: rolling)
            out.closeStep()
        }

        // The residuals together, since they land together.
        out.beginStep()
        Residuals.endOfTurn(&out, rolling: rolling)
        out.closeStep()
        out.rulings = [:]
        out.declared = [:]
        out.acted = []

        return out
    }

    /// Every way the turn can come out when somebody is trying a Protect
    /// that might not hold, with how likely each is. One board when nobody
    /// is; two when one Pokémon is on a repeat Protect; four when both are.
    /// The search weighs these rather than betting on either branch, so a
    /// second Protect in a row is worth exactly a third of a first one.
    static func outcomes(_ board: Board, mine: Play, theirs: Play)
        -> [(board: Board, chance: Double)] {
        var chancy: [(key: String, chance: Double)] = []

        /// A repeat Protect, which gets a third of the chance of the one before.
        func considerProtect(_ choice: Choice, fighter: Fighter, mine side: Bool, slot: Int) {
            guard !fighter.fainted, fighter.protectStreak > 0 else { return }
            switch choice {
            case .protectSelf:
                chancy.append((Board.flip("protect", side, slot), fighter.protectChance))
            case .attack(let index, _):
                if fighter.moves.indices.contains(index),
                   Move.protectMoves.contains(fighter.moves[index].name) {
                    chancy.append((Board.flip("protect", side, slot), fighter.protectChance))
                }
            default: break
            }
        }

        // Everything else that turns on a dice roll. Collected separately from
        // Protect because these are common — seventy-five legal moves carry a
        // sub-100% secondary — and branching all of them at once would square
        // the cost of a solve. Only the most likely few are followed.
        var rolls: [(key: String, chance: Double)] = []
        func considerRolls(_ choice: Choice, fighter: Fighter, mine side: Bool, slot: Int) {
            guard !fighter.fainted else { return }
            if !choice.isPass {
                if fighter.build.ability == "Quick Draw" {
                    rolls.append((Board.flip("quickclaw", side, slot), 0.3))
                } else if fighter.build.item == "Quick Claw" {
                    rolls.append((Board.flip("quickclaw", side, slot), 0.2))
                }
            }
            guard case .attack(let index, _) = choice,
                  fighter.moves.indices.contains(index) else { return }
            let move = fighter.moves[index]
            let chance = secondaryChance(of: move, for: fighter)
            if chance > 0, chance < 100 {
                rolls.append((Board.flip("secondary", side, slot), Double(chance) / 100))
            }
            if fighter.build.ability == "Poison Touch", move.makesContact, move.isDamaging {
                rolls.append((Board.flip("poisontouch", side, slot), 0.3))
            }
        }

        let actors: [(Choice, Fighter, Bool, Int)?] = [
            board.mine.indices.contains(0) ? (mine.left, board.mine[0], true, 0) : nil,
            board.mine.indices.contains(1) && board.activeCount > 1 ? (mine.right, board.mine[1], true, 1) : nil,
            board.theirs.indices.contains(0) ? (theirs.left, board.theirs[0], false, 0) : nil,
            board.theirs.indices.contains(1) && board.activeCount > 1 ? (theirs.right, board.theirs[1], false, 1) : nil,
        ]
        for case let (choice, fighter, side, slot)? in actors {
            considerProtect(choice, fighter: fighter, mine: side, slot: slot)
            considerRolls(choice, fighter: fighter, mine: side, slot: slot)
        }

        // The cap. Each extra coin flip doubles the number of boards, and this
        // runs once per cell of a matrix that is often 35 by 19, so the whole
        // solve is doubled with it. The likeliest flips are the ones worth
        // following; the rest fall back to "only what is certain", which is
        // where every one of them was before.
        rolls.sort { $0.chance > $1.chance }
        chancy += rolls.prefix(Self.branchedRolls)

        guard !chancy.isEmpty else {
            return [(resolve(board, mine: mine, theirs: theirs, narrating: false), 1)]
        }
        var out: [(board: Board, chance: Double)] = []
        for mask in 0..<(1 << chancy.count) {
            var ruled = board
            var chance = 1.0
            for (bit, entry) in chancy.enumerated() {
                let holds = mask & (1 << bit) != 0
                ruled.rulings[entry.key] = holds
                chance *= holds ? entry.chance : 1 - entry.chance
            }
            out.append((resolve(ruled, mine: mine, theirs: theirs, narrating: false), chance))
        }
        return out.sorted { $0.chance > $1.chance }
    }

    /// How many dice rolls beyond a repeat Protect the search will branch on.
    ///
    /// One, measured rather than guessed. Each extra flip doubles the boards a
    /// cell produces, and the search answers by reaching fewer positions in the
    /// same half second:
    ///
    ///     0    depth 3, 268 positions
    ///     1    depth 3, 180 positions
    ///     2    depth 2,  96 positions
    ///
    /// Two costs a whole ply, which is worth far more than pricing a second
    /// coin flip. One keeps the depth and buys the biggest flip in the turn.
    ///
    /// Note that the flips not branched are not thrown away: every branch is
    /// still priced exactly in the immediate term by `BattleEngine`, which
    /// weighs all of them. What the cap limits is how many get searched deeper.
    ///
    /// The accuracy replay cannot settle this — it reads 5.3 at every setting,
    /// because it predicts game outcomes from team lists and never sees a turn.
    /// A `var` only so the duel tool can hold one engine at a different
    /// setting from the other. Nothing in the app changes it.
    nonisolated(unsafe) static var branchedRolls = 1

    /// Every roll a played turn makes goes through here.
    ///
    /// The system generator cannot be seeded, which made a battle impossible to
    /// replay and made the duel harness noisier than it needed to be: the two
    /// halves of a mirrored pair faced different luck, so the mirroring only
    /// cancelled the *draw* and not the dice. With one generator behind all of
    /// it, both halves can be handed the same stream and what is left is the
    /// engines.
    ///
    /// Unsafe in name only. A played turn is resolved from one thread at a
    /// time — the app's on the main actor, the duel's in its own loop — and the
    /// search never touches this at all, because a search does not roll.
    nonisolated(unsafe) static var dice: RandomNumberGenerator = SystemRandomNumberGenerator()

    private static func apply(_ choice: Choice, byMine: Bool, slot: Int,
                              to board: inout Board,
                              rolling: Bool = false) {
        let actor = byMine ? board.mine[slot] : board.theirs[slot]
        guard !actor.fainted else { return }
        let name = actor.build.form.formLabel
        if actor.flinched {
            board.note("\(name) flinched and could not move.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }
        // A disabled move cannot be used, and trying costs the turn. The
        // search sees that as a wasted turn and learns to pick something else,
        // which is the honest way round: the model refuses, rather than the
        // search quietly substituting a move nobody chose.
        if case .attack(let index, _) = choice, actor.disabled == index,
           actor.moves.indices.contains(index) {
            board.note("\(name)'s \(actor.moves[index].name) is disabled.")
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }
        // Sleep and paralysis cost turns, which is the whole reason they are
        // worth a move slot.
        if actor.status == .sleep {
            board.note("\(name) is fast asleep.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }
        // Frozen solid. One turn in five it thaws on its own, and a Fire move
        // or a move that defrosts its user thaws it outright. Blizzard has
        // frozen things since the reference table landed and nothing happened
        // when it did: the condition was inflictable and inert.
        if actor.status == .freeze {
            let thawsItself = actor.moves.indices.contains(pickedMove(choice))
                && (actor.moves[pickedMove(choice)].type == "Fire"
                    || actor.moves[pickedMove(choice)].flags["defrosts"] == true)
            let thaws = thawsItself
                || (rolling && Double.random(in: 0..<1, using: &TurnModel.dice) < 0.2)
            if thaws {
                if byMine { board.mine[slot].status = .none } else { board.theirs[slot].status = .none }
                board.note("\(name) thawed out.")
            } else {
                board.note("\(name) is frozen solid.")
                MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
        }
        if actor.status == .paralysis, rolling, Double.random(in: 0...1, using: &TurnModel.dice) < 0.25 {
            board.note("\(name) is paralysed and cannot move.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }
        // Infatuation: half of its actions are lost while whatever it fell for
        // is still standing there. Like confusion, the search averages and
        // lets it act; a played turn rolls.
        if let loves = actor.infatuatedWith {
            let far = byMine ? board.theirs : board.mine
            if !far.indices.contains(loves) || far[loves].fainted {
                if byMine { board.mine[slot].infatuatedWith = nil }
                else { board.theirs[slot].infatuatedWith = nil }
            } else if rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 0.5 {
                board.note("\(name) is immobilised by love.")
                MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
        }
        // Torment: it cannot use the same move twice running, which is what
        // stops something clicking one button all game.
        if actor.tormented, case .attack(let index, _) = choice, actor.lastMove == index {
            board.note("\(name) cannot use the same move twice in a row.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }

        // Confusion: counted down each time it comes to act, and one action in
        // three goes into its own face — a typeless forty-power hit with its
        // own Attack against its own Defence. The search, which averages,
        // lets it act; a played turn rolls.
        if actor.confusedFor > 0 {
            if byMine { board.mine[slot].confusedFor -= 1 } else { board.theirs[slot].confusedFor -= 1 }
            if (byMine ? board.mine : board.theirs)[slot].confusedFor == 0 {
                board.note("\(name) snapped out of its confusion.")
            } else {
                board.note("\(name) is confused.")
                if rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 1.0 / 3.0 {
                    let attack = Double(actor.build.stagedStat(.attack))
                    let defence = Double(actor.build.stagedStat(.defense))
                    let base = (2.0 * 50 / 5 + 2) * 40 * attack / defence / 50 + 2
                    let hurt = Swift.max(1, Int(base * Double.random(in: 0.85...1.0, using: &TurnModel.dice)))
                    if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - hurt) }
                    else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - hurt) }
                    board.note("It hurt itself in its confusion for \(hurt).")
                    if (byMine ? board.mine : board.theirs)[slot].fainted { board.note("\(name) fainted.") }
                    MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                    MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                    return
                }
            }
        }

        switch choice {
        case .pass:
            return
        case .swap:
            return
        case .protectSelf(let index):
            let label = actor.moves.indices.contains(index) ? actor.moves[index].name : "Protect"
            MoveHistory.remember(byMine: byMine, slot: slot, move: index, target: 0, board: &board)
            let held = Protection.tryProtect(label, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: !held)
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            MoveHistory.remember(byMine: byMine, slot: slot, move: moveIndex, target: target, board: &board)
            // Taunted: nothing but attacks until it wears off.
            if !move.isDamaging, actor.tauntedFor > 0 {
                board.note("\(name) cannot use \(move.name) — it is still taunted.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            guard move.isDamaging else {
                let before = board.story.count
                support(move, byMine: byMine, slot: slot, target: target,
                        to: &board, rolling: rolling)
                // A support move that only had "but" to say for itself failed.
                let failed = board.story.dropFirst(before).contains { $0.hasPrefix("But ") || $0.contains("but it failed") }
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: failed)
                selfKO(move, byMine: byMine, slot: slot, board: &board)
                return
            }

            // A turn is resolved in the same five phases every time, and each
            // one says what it did. Declaring the move, then what the far side
            // brings to it, then the roll, then what it cost, in that order --
            // so the commentary is the computation rather than a summary of it.
            //
            // 1. Declare — and check it can be used at all. First Impression
            // and Fake Out work on the turn the Pokémon arrives and never
            // again, which is the whole cost of a 90 base power priority move.
            if move.drawbacks.firstTurnOnly, !actor.justArrived {
                board.note("\(name) used \(move.name), but it only works on the turn it comes in.")
                return
            }
            // A two-turn move: this turn is the wind-up unless the weather
            // waives it, and the next turn is the hit. Electro Shot in rain
            // does both at once — the boost, then the beam.
            if let charge = move.charge {
                let firing = actor.charging == moveIndex
                let waived = charge.skipsIn != nil && board.field.weather == charge.skipsIn
                if !firing {
                    board.note(waived
                        ? "\(name) used \(move.name). In the \(board.field.weather.rawValue.lowercased()) it needs no time to charge."
                        : (charge.hides ? "\(name) used \(move.name) and is out of reach."
                                        : "\(name) began charging \(move.name)."))
                    StatChanges.applySelf(charge.boosts, toMine: byMine, slot: slot, board: &board)
                    if !waived {
                        if byMine {
                            board.mine[slot].charging = moveIndex
                            board.mine[slot].chargingTarget = target
                            board.mine[slot].hidden = charge.hides
                        } else {
                            board.theirs[slot].charging = moveIndex
                            board.theirs[slot].chargingTarget = target
                            board.theirs[slot].hidden = charge.hides
                        }
                        return
                    }
                } else {
                    MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board, quietly: true)
                    board.note("\(name) unleashed \(move.name).")
                }
            } else {
                board.note("\(name) used \(move.name).")
            }

            // 2. The field: anything that stops it before it starts.
            let farScreens = (target >= Choice.allyTarget ? byMine : !byMine)
                ? board.myScreens : board.theirScreens
            if move.isSpread, farScreens.wideGuard {
                board.note("Wide Guard blocked it.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            // Quick Guard turns away anything that moves first, which is what
            // a Fake Out team is actually afraid of.
            if move.priority > 0, target < Choice.allyTarget, farScreens.quickGuard {
                board.note("Quick Guard blocked it.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            // Armor Tail and Queenly Majesty refuse priority outright: nothing
            // with increased priority can be aimed at that Pokémon or its
            // partner. It is the reason Farigiraf is on Trick Room teams — it
            // is what stops a Fake Out taking the setup turn away.
            // Psychic Terrain: nothing quick reaches anything standing on it.
            // It is why a Psychic Surge team can set up in front of a Fake Out.
            // The terrain only reaches what is standing on it. A Staraptor is
            // in the air, so a Fake Out gets to it however psychic the floor
            // is — and this used to refuse the move if *anything* on that side
            // was grounded, so the Staraptor was protected by its partner's
            // feet. The shield belongs to whoever the move is aimed at.
            if move.priority > 0, target < Choice.allyTarget,
               board.field.terrain == .psychic,
               move.aim == .foe || move.aim == .spread {
                let defenders = byMine ? board.theirs : board.mine
                let reachable = (0..<Swift.min(board.activeCount, defenders.count))
                    .filter { !defenders[$0].fainted }
                // A spread move is refused only when there is nothing left for
                // it to hit; with one grounded and one not, it still lands on
                // the one in the air, and the loop below skips the other.
                let aimedAt = move.aim == .spread ? reachable
                    : reachable.filter { $0 == target }
                if !aimedAt.isEmpty, aimedAt.allSatisfy({ defenders[$0].isGrounded }) {
                    let who = defenders[aimedAt[0]].build.form.formLabel
                    board.note("The Psychic Terrain refused it — \(who) is standing on it, and nothing quick gets through.")
                    MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                    return
                }
            }
            // Sucker Punch only lands on a Pokémon that is winding up to
            // attack and has not gone yet. Against a Protect, a status move or
            // something that has already moved, it does nothing at all.
            if move.id == "suckerpunch", target < Choice.allyTarget {
                let defenders = byMine ? board.theirs : board.mine
                let key = (byMine ? "t" : "m") + "\(target)"
                let attacking: Bool = {
                    guard let choice = board.declared[key], !board.acted.contains(key),
                          defenders.indices.contains(target) else { return false }
                    guard case .attack(let index, _) = choice,
                          defenders[target].moves.indices.contains(index) else { return false }
                    return defenders[target].moves[index].isDamaging
                }()
                guard attacking else {
                    board.note("But it failed — \(move.name) needs a target that is about to attack.")
                    MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                    return
                }
            }
            if move.priority > 0, target < Choice.allyTarget, move.aim == .foe || move.aim == .spread {
                let defenders = byMine ? board.theirs : board.mine
                if let refused = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    !defenders[$0].fainted
                        && TurnModel.priorityBlockers.contains(defenders[$0].build.ability) }) {
                    board.note("\(defenders[refused].build.form.formLabel)'s "
                               + "\(defenders[refused].build.ability) refused it. "
                               + "Nothing with priority gets through.")
                    return
                }
            }

            // Aimed at your own partner, for the techs that want it: the hit
            // lands on your side, with everything that follows from that.
            let atAlly = target >= Choice.allyTarget
            let hitMine = atAlly ? byMine : !byMine
            let partner = slot == 0 ? 1 : 0
            var aimed = move.isSpread ? [0, 1] : (atAlly ? [partner] : [target])
            if !move.isSpread, atAlly {
                let own = byMine ? board.mine : board.theirs
                if !own.indices.contains(partner) || partner >= board.activeCount || own[partner].fainted {
                    board.note("But there was no one there to hit.")
                    return
                }
            }
            if !move.isSpread, !atAlly {
                let defenders = hitMine ? board.mine : board.theirs
                // The target went down before this move's turn came: it turns
                // to whoever is left standing across the field. A Whimsicott on
                // one point of Focus Sash health is exactly who this finds.
                let gone = !defenders.indices.contains(target) || target >= board.activeCount
                    || defenders[target].fainted
                if gone, let other = (0..<Swift.min(board.activeCount, defenders.count))
                    .first(where: { $0 != target && !defenders[$0].fainted }) {
                    aimed = [other]
                    board.note("\(name)'s \(move.name) turned toward \(defenders[other].build.form.formLabel) instead.")
                }
                // Stalwart and Propeller Tail aim where they meant to; nothing
                // draws them off it.
                let ignoresRedirection = ["Stalwart", "Propeller Tail"].contains(actor.build.ability)
                if !ignoresRedirection,
                   let pulled = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    defenders[$0].drawingFire && !defenders[$0].fainted }), pulled != aimed[0] {
                    aimed = [pulled]
                    board.note("It was drawn to \(defenders[pulled].build.form.formLabel).")
                }
            }
            // Dragon Darts, and nothing else in the game. Its two darts go
            // one to each foe in a double battle rather than both to the one
            // it was aimed at — and when only one of them can be reached,
            // because the other is protecting or already down, both darts go
            // there instead. Aiming it at a Protect is how it ends up hitting
            // the partner twice.
            var dartedTwice = false
            if move.smartTarget == true, !atAlly, board.activeCount > 1 {
                let far = hitMine ? board.mine : board.theirs
                let reachable = (0..<Swift.min(board.activeCount, far.count)).filter {
                    !far[$0].fainted && !far[$0].hidden
                        && !(far[$0].isProtected && move.isProtectable)
                }
                if reachable.count > 1 {
                    aimed = reachable
                    board.note("The darts split, one to each.")
                } else if let only = reachable.first {
                    aimed = [only]
                    dartedTwice = true
                    if only != target { board.note("Both darts went to \(far[only].build.form.formLabel).") }
                }
            }

            // Who this actually lands on, side by side.
            //
            // `aimed` is the far side alone, and everything around this loop —
            // the redirection above it, the Liquid Ooze below — is written
            // against that, so it stays exactly as it was. What is added here
            // is the other half of a spread move nobody had modelled: Earthquake,
            // Surf and Discharge say "All Adjacent Pokemon", and the adjacent
            // Pokemon include your own partner.
            //
            // Leaving that out made Earthquake free. An engine that never pays
            // for hitting its own side will click it beside a grounded partner
            // all day, over-rate every Ground attacker on the team, and never
            // discover why real teams pair one with a Flying type, a Levitate
            // or an Air Balloon. The partner's own immunity is not special-cased
            // here: a Flying partner takes nothing because the damage calculator
            // says so, which is the right place for it to be said.
            var aimedAt: [(hitMine: Bool, index: Int)] = aimed.map { (hitMine, $0) }
            if move.isSpread, move.hitsAlly, !atAlly {
                let own = byMine ? board.mine : board.theirs
                if board.activeCount > 1, own.indices.contains(partner),
                   partner < board.activeCount, !own[partner].fainted {
                    aimedAt.append((byMine, partner))
                }
            }

            var totalDealt = 0
            var reached = 0
            for (hitMine, index) in aimedAt {
                let defending = hitMine ? board.mine : board.theirs
                guard defending.indices.contains(index), !defending[index].fainted else { continue }
                let hitName = defending[index].build.form.formLabel
                if defending[index].hidden {
                    board.note("\(hitName) is out of reach.")
                    continue
                }
                if defending[index].isProtected, move.isProtectable {
                    board.detail("\(hitName) protected itself.")
                    continue
                }
                // Feint: through the Protect, and the Protect is gone — so the
                // partner's move, coming after, lands on an open target.
                if defending[index].isProtected, move.breaksProtect {
                    if hitMine { board.mine[index].isProtected = false }
                    else { board.theirs[index].isProtected = false }
                    board.note("\(move.name) broke through \(hitName)'s protection.")
                }
                // Unseen Fist reaches through a Protect with anything that makes
                // contact; Piercing Drill does the same for a quarter damage.
                if defending[index].isProtected, move.isProtectable, move.makesContact,
                   ["Unseen Fist", "Piercing Drill"].contains(actor.build.ability) {
                    if hitMine { board.mine[index].isProtected = false }
                    else { board.theirs[index].isProtected = false }
                    board.note("\(actor.build.ability) reached through \(hitName)'s protection.")
                }

                // Protean and Libero make the user the move's type as it uses
                // it, which is a free same-type bonus on everything it throws.
                if ["Protean", "Libero"].contains(actor.build.ability),
                   let became = PokeType(loose: move.type),
                   (byMine ? board.mine : board.theirs)[slot].types != [became] {
                    if byMine { board.mine[slot].build.typeOverride = [became] }
                    else { board.theirs[slot].build.typeOverride = [became] }
                    board.note("\(name) became a \(became.rawValue) type.")
                }

                // Abilities that refuse a whole kind of move outright. Mold
                // Breaker walks through all of them, which is what it is for.
                let breaker = ["Mold Breaker", "Turboblaze", "Teravolt"]
                    .contains(actor.build.ability)
                if !breaker {
                    let refuses: String?
                    switch defending[index].build.ability {
                    case "Soundproof"   where move.isSound:   refuses = "Soundproof"
                    case "Bulletproof"  where move.isBullet:  refuses = "Bulletproof"
                    case "Overcoat"     where move.isPowder:  refuses = "Overcoat"
                    case "Wind Rider"   where move.isWind:    refuses = "Wind Rider"
                    case "Dazzling", "Queenly Majesty", "Armor Tail":
                        refuses = move.priority > 0 ? defending[index].build.ability : nil
                    default: refuses = nil
                    }
                    if let refuses {
                        board.note("\(hitName)'s \(refuses) turned it away.")
                        continue
                    }
                }
                // A powder move does nothing to a Grass type, or to anything
                // wearing goggles.
                if move.isPowder, defending[index].types.contains(.grass)
                    || defending[index].build.item == "Safety Goggles" {
                    board.detail("It does not affect \(hitName).")
                    continue
                }

                // Accuracy is rolled for each one it reaches for: Muddy Water at
                // 85% can hit one of them and miss the other. The search's
                // averages were always per target; only the dice were not.
                if rolling, !move.neverMisses, move.accuracy > 0,
                   Double.random(in: 0...100, using: &TurnModel.dice) > Accuracy.chanceToHit(move, attacker: actor,
                                                            defender: defending[index],
                                                            board: board) {
                    board.detail(aimed.count > 1 ? "\(hitName) avoided it." : "It missed.")
                    continue
                }
                reached += 1
                var defender = defending[index].build
                defender.atFullHP = defending[index].hp == defending[index].maxHP
                defender.status = defending[index].status
                var field = board.calcField
                field.helpingHand = actor.helped
                field.targetJustArrived = defending[index].justArrived
                // A Fairy Aura anywhere on the field powers up Fairy moves for
                // everybody, which is what makes it an aura.
                field.fairyAura = (board.mine + board.theirs)
                    .prefix(board.activeCount * 2)
                    .contains { !$0.fainted && $0.build.ability == "Fairy Aura" }
                // Analytic is paid for going after the target has already had
                // its turn, which is exactly what `acted` records.
                field.movingLast = board.acted.contains((hitMine ? "m" : "t") + "\(index)")
                // Friend Guard covers whoever is standing next to the holder.
                let ally = index == 0 ? 1 : 0
                let sameSide = hitMine ? board.mine : board.theirs
                field.friendGuarded = sameSide.indices.contains(ally) && ally < board.activeCount
                    && !sameSide[ally].fainted && sameSide[ally].build.ability == "Friend Guard"
                // An Infiltrator is not stopped by what is hanging in the air
                // on the other side.
                field.screen = actor.build.ability == "Infiltrator" ? false : farScreens.blunt(move)
                // A critical hit, rolled at the move's own rate. The calculator
                // already knows what one does — half again, and it goes through
                // screens and the target's defensive boosts — it only needed
                // telling when one happened.
                // A move's own rate, raised by anything the user is carrying:
                // one stage is an eighth, two is a half, three is certain.
                // A Leek is two stages of crit ratio, for the one Pokémon that
                // can hold it usefully.
                var stage = actor.critStage
                if actor.build.item == "Leek",
                   actor.build.form.species.contains("farfetch") { stage += 2 }
                if actor.build.item == "Razor Claw" || actor.build.item == "Scope Lens" { stage += 1 }
                if actor.build.ability == "Super Luck" { stage += 1 }
                // Merciless always crits a poisoned target, which is the
                // entire reason a Toxapex threatens anything.
                if actor.build.ability == "Merciless",
                   [.poison, .badPoison].contains(defending[index].status) { stage = 3 }
                let rate = stage <= 0 ? move.critRate
                    : (stage == 1 ? Swift.max(move.critRate, 12.5)
                       : stage == 2 ? Swift.max(move.critRate, 50) : 100)
                // Shell Armor and Battle Armor cannot be hit critically, which
                // is the whole of both of them. A Mold Breaker ignores that.
                let armoured = ["Shell Armor", "Battle Armor"]
                    .contains(defending[index].build.ability) && !breaker
                if rolling, rate > 0, !armoured,
                   Double.random(in: 0..<100, using: &TurnModel.dice) < rate {
                    field.critical = true
                }
                board.lastWasCritical = field.critical
                // A Fire move thaws whatever it hits.
                if defending[index].status == .freeze,
                   DamageCalc.fieldForm(of: move, in: field).type == .fire {
                    if hitMine { board.mine[index].status = .none }
                    else { board.theirs[index].status = .none }
                    board.detail("\(hitName) was thawed out.")
                }
                var attacker = actor.build
                attacker.ignoresAbility = ["Mold Breaker", "Turboblaze", "Teravolt"]
                    .contains(actor.build.ability)
                attacker.lowHP = actor.hp * 3 <= actor.maxHP
                attacker.status = actor.status
                // Electromorphosis stored a charge the last time it was hit;
                // the next Electric move it throws spends it.
                if actor.charged, DamageCalc.fieldForm(of: move, in: field).type == .electric {
                    field.charged = true
                    if byMine { board.mine[slot].charged = false }
                    else { board.theirs[slot].charged = false }
                }
                // Steely Spirit pays for its partner's Steel moves too.
                let ourAlly = slot == 0 ? 1 : 0
                let ourSide = byMine ? board.mine : board.theirs
                field.alliedSteelySpirit = ourSide.indices.contains(ourAlly)
                    && ourAlly < board.activeCount && !ourSide[ourAlly].fainted
                    && ourSide[ourAlly].build.ability == "Steely Spirit"
                // Plus and Minus pay each other, and only each other.
                let pairing: Set<String> = ["Plus", "Minus"]
                field.paired = pairing.contains(actor.build.ability)
                    && ourSide.indices.contains(ourAlly) && ourAlly < board.activeCount
                    && !ourSide[ourAlly].fainted
                    && pairing.contains(ourSide[ourAlly].build.ability)
                attacker.lastMoveFailed = actor.lastMoveFailed
                // Supreme Overlord and Last Respects count the fallen. Never
                // filled in before, so neither ever went off in a battle.
                attacker.fallenAllies = (byMine ? board.mine : board.theirs).filter(\.fainted).count
                let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                                  move: move, field: field)

                // An absorbed hit is not merely a hit that did nothing. The
                // calculator already zeroes the damage; what it cannot do is
                // pay the ability out, because it has no board to pay into.
                if result.effectiveness == 0, !breaker,
                   result.notes.contains(where: { $0.contains("absorbed") }) {
                    let who = defending[index].build.ability
                    let heals = ["Water Absorb", "Volt Absorb", "Dry Skin", "Earth Eater"]
                    if heals.contains(who) {
                        let back = Swift.max(1, defending[index].maxHP / 4)
                        let gained = Swift.min(defending[index].maxHP - defending[index].hp, back)
                        if gained > 0 {
                            if hitMine { board.mine[index].hp += gained }
                            else { board.theirs[index].hp += gained }
                            board.note("\(hitName)'s \(who) drank it in for \(gained).")
                        } else {
                            board.note("\(hitName)'s \(who) absorbed it.")
                        }
                    } else {
                        let paid: [Stat: Int]
                        switch who {
                        case "Sap Sipper":    paid = [.attack: 1]
                        case "Motor Drive":   paid = [.speed: 1]
                        case "Storm Drain", "Lightning Rod": paid = [.spAttack: 1]
                        case "Flash Fire":    paid = [.spAttack: 1]
                        default:              paid = [:]
                        }
                        if paid.isEmpty { board.note("\(hitName)'s \(who) absorbed it.") }
                        else {
                            StatChanges.change(paid, onMine: hitMine, slot: index, board: &board, because: who)
                        }
                    }
                    continue
                }
                if field.critical { board.detail("A critical hit!") }

                // 3. What the far side brings to it. These are the calculator's
                // own notes, so the commentary cannot drift from the maths.
                for line in result.notes where worthSaying(line) {
                    board.detail(line)
                }
                if actor.status.halvesPhysical, move.category == "Physical" {
                    board.detail("\(name) is burned, so it hits softer.")
                }
                if result.effectiveness == 0 {
                    board.detail("It does not affect \(hitName).")
                    continue
                }

                // 4. The roll.
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Accuracy.chanceToHit(move, attacker: actor, defender: defending[index],
                                        board: board) / 100
                // One blow, not the flurry. `calculate` already multiplies a
                // multi-hit move up by the strikes it assumes, because that is
                // what the calculator screen should show — so taking its total
                // as a single blow and multiplying by the blows again squared
                // the move. Bullet Seed was doing three times three.
                let whole: Int = rolling
                    ? Int.random(in: Swift.min(result.minDamage, result.maxDamage)
                                 ... Swift.max(result.minDamage, result.maxDamage),
                                 using: &TurnModel.dice)
                    : Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy).rounded())
                let oneBlow: Int = result.strikes > 1
                    ? Swift.max(1, Int((Double(whole) / result.strikes).rounded()))
                    : whole

                // How many times it lands. Parental Bond adds a second blow at
                // a quarter, which is the ability rather than the move, so the
                // two are counted together and the log says which is which.
                // A split dart is one blow each; both darts on one target is
                // the move's own two.
                var blows = move.blows(for: actor.build.ability, accuracy: accuracy,
                                       rolling: rolling, using: &TurnModel.dice)
                if move.smartTarget == true, board.activeCount > 1 {
                    blows = dartedTwice ? 2 : 1
                }
                // Parental Bond adds its own second blow, but not to a move
                // that already throws several and not to Dragon Darts, which
                // the reference marks as refusing it outright.
                let bonded = actor.build.ability == "Parental Bond"
                    && move.isDamaging && !move.isSpread && blows == 1
                    && move.smartTarget != true
                let dealt = Int((Double(oneBlow) * blows).rounded())
                        + (bonded ? Swift.max(1, oneBlow / 4) : 0)
                if blows > 1 {
                    board.detail(move.escalates
                                 ? String(format: "%d blows, each harder than the last.",
                                          move.hits?.last ?? 0)
                                 : "\(Int(blows.rounded())) hits, \(oneBlow) each.")
                }
                if bonded { board.detail("Parental Bond: a second blow at a quarter.") }

                // A one-hit knockout does exactly that, three times in ten,
                // and nothing at all the rest of the time. It is worked out
                // here rather than from power, because its listed power is 1.
                if move.isOHKO {
                    let lands = rolling ? Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3 : false
                    if defending[index].types.contains(.ice), move.id == "sheercold" {
                        board.detail("It does not affect \(hitName).")
                        continue
                    }
                    if lands {
                        if hitMine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                        totalDealt += defending[index].hp
                        board.note("It is a one-hit knockout. \(hitName) fainted.")
                    } else {
                        board.note(rolling ? "But it missed."
                                           : "\(hitName) is looking at a one-hit knockout, three times in ten.")
                    }
                    continue
                }

                // A Substitute takes the hit instead, and the Pokémon behind
                // it takes nothing at all — not the damage, not the stat drop,
                // not the status. Sound moves and an Infiltrator go through it.
                if defending[index].substitute > 0, !move.isSound,
                   actor.build.ability != "Infiltrator" {
                    let shell = defending[index].substitute
                    let absorbed = Swift.min(shell, dealt)
                    if hitMine { board.mine[index].substitute = shell - absorbed }
                    else { board.theirs[index].substitute = shell - absorbed }
                    board.note(absorbed >= shell
                               ? "\(hitName)'s substitute broke."
                               : "\(hitName)'s substitute took \(absorbed).")
                    continue
                }

                var landed = dealt
                var sashed = false
                if defending[index].enduring, dealt >= defending[index].hp {
                    landed = defending[index].hp - 1
                    board.detail("\(hitName) endured it.")
                }
                if defending[index].build.item == "Focus Sash",
                   !defending[index].build.itemSpent,
                   defending[index].hp == defending[index].maxHP,
                   dealt >= defending[index].hp {
                    landed = defending[index].hp - 1
                    sashed = true
                }
                totalDealt += landed
                // A berry that halved the hit is a berry that has been eaten.
                let ateBerry = result.notes.contains { $0.contains("then is consumed") }
                if hitMine {
                    board.mine[index].hp = Swift.max(0, board.mine[index].hp - landed)
                    if sashed { board.mine[index].build.itemSpent = true }
                    if ateBerry { board.mine[index].build.itemSpent = true }
                } else {
                    board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - landed)
                    if sashed { board.theirs[index].build.itemSpent = true }
                    if ateBerry { board.theirs[index].build.itemSpent = true }
                }
                let share = Int((Double(landed) / Double(Swift.max(1, defending[index].maxHP))
                                 * 100).rounded())
                if result.effectiveness > 1 {
                    board.detail("It is super effective. \(hitName) took \(landed) (\(share)%).")
                } else if result.effectiveness < 1 {
                    board.detail("\(hitName) resists it — \(landed) (\(share)%).")
                } else {
                    board.detail("\(hitName) took \(landed) (\(share)%).")
                }
                if sashed { board.detail("\(hitName) hung on with its Focus Sash.") }

                // 5. Afterwards: what the move does beyond the damage, and what
                // the target's own ability does back.
                contact(move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                        wasAt: defending[index].hp, rolling: rolling, board: &board)
                Switching.flee(ifNeeded: index, ofMine: hitMine, wasAt: defending[index].hp,
                     board: &board)
                // Fake Out used to flinch from here as well as through its
                // own secondary, which is how it carries the flinch in the
                // data: a hundred per cent, `kind: flinch`. Two paths for one
                // effect said "flinched" twice in the log, and — the part that
                // mattered — this one ran before the check that lets a Shield
                // Dust or a Covert Cloak refuse a secondary. So the item worn
                // specifically to stand in front of a Fake Out did not, which
                // is most of the reason anybody wears it.
                if result.notes.contains(where: { $0.contains("Weakness Policy") }) {
                    StatChanges.applySelf([.attack: 2, .spAttack: 2], toMine: hitMine, slot: index,
                              board: &board)
                    if hitMine { board.mine[index].build.itemSpent = true }
                    else { board.theirs[index].build.itemSpent = true }
                }
                StatChanges.applyDrops(move.targetDrops, toMine: hitMine, slot: index, board: &board)
                secondary(of: move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                          rolling: rolling, board: &board)
                let after = hitMine ? board.mine[index] : board.theirs[index]
                if after.hp == 0 {
                    board.detail("\(hitName) fainted.")
                    // Destiny Bond: it takes whatever did it with it. Checked
                    // before the knockout abilities below, because a Moxie
                    // that is about to faint does not get its stage.
                    if after.destinyBound, !(byMine ? board.mine : board.theirs)[slot].fainted {
                        if byMine { board.mine[slot].hp = 0 } else { board.theirs[slot].hp = 0 }
                        board.note("\(hitName)'s Destiny Bond took \(name) with it.")
                    }
                    // Moxie and its kin take something from the knockout.
                    switch actor.build.ability {
                    case "Moxie", "Chilling Neigh":
                        StatChanges.change([.attack: 1], onMine: byMine, slot: slot, board: &board,
                               because: actor.build.ability)
                    case "Grim Neigh", "Soul-Heart":
                        StatChanges.change([.spAttack: 1], onMine: byMine, slot: slot, board: &board,
                               because: actor.build.ability)
                    case "Beast Boost":
                        // Whichever of its stats is highest, which is the whole
                        // trick of it.
                        let build = actor.build
                        let best = [Stat.attack, .defense, .spAttack, .spDefense, .speed]
                            .max { build.stat($0) < build.stat($1) } ?? .attack
                        StatChanges.change([best: 1], onMine: byMine, slot: slot, board: &board, because: "Beast Boost")
                    default: break
                    }
                }
            }
            // A move that reached nobody failed: missed, blocked, or nothing
            // there to hit. Stomping Tantrum remembers, and a move that hurts
            // its user when it fails hurts its user now — High Jump Kick into
            // a Protect crashes just as it does into thin air.
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: reached == 0)
            if reached == 0 {
                let costs = move.drawbacks
                if costs.crash > 0 {
                    let lost = Swift.max(1, Int(Double(actor.maxHP) * costs.crash))
                    if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                    else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                    board.note("\(name) kept going and crashed.")
                }
                return
            }
            // What comes back: Leech Life and its kind restore a share of what
            // they took.
            if let share = move.drainShare, totalDealt > 0 {
                let team = byMine ? board.mine : board.theirs
                let far = hitMine ? board.mine : board.theirs
                // Liquid Ooze turns a drain into a cost: what would have been
                // healed is taken off the attacker instead.
                let oozed = aimed.contains { far.indices.contains($0)
                    && far[$0].build.ability == "Liquid Ooze" }
                if !team[slot].fainted {
                    let amount = Swift.max(1, Int(Double(totalDealt) * share))
                    if oozed {
                        if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - amount) }
                        else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - amount) }
                        board.note("\(name) drank the Liquid Ooze and lost \(amount).")
                        if (byMine ? board.mine : board.theirs)[slot].fainted {
                            board.note("\(name) fainted.")
                        }
                    } else {
                        let gained = Swift.min(team[slot].maxHP - team[slot].hp, amount)
                        if gained > 0 {
                            if byMine { board.mine[slot].hp += gained } else { board.theirs[slot].hp += gained }
                            board.note("\(name) drained \(gained) health back.")
                        }
                    }
                }
            }
            // Rapid Spin clears its own side on the way past, which is a
            // damaging move doing something only a status move otherwise does.
            if move.name == "Rapid Spin", board.sweepHazards(mine: byMine) {
                board.note("\(name) spun the hazards away from its own side.")
            }
            StatChanges.applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
            // What the move takes off its user: Close Combat's defences,
            // Overheat's Special Attack. Missed entirely until now, so a
            // Sneasler could Close Combat all game at full Defence.
            StatChanges.applySelf(move.selfDrops.mapValues { -$0 }, toMine: byMine, slot: slot, board: &board)
            cost(of: move, dealt: totalDealt, byMine: byMine, slot: slot, board: &board)
        }
    }

    /// Whether one of the calculator's notes is worth reading out.
    ///
    /// It keeps notes for everything it applies, including arithmetic nobody
    /// needs narrated. What belongs in a battle log is what the *other* side
    /// brought to the exchange, because that is the part a player did not know
    /// and has to learn.
    private static func worthSaying(_ note: String) -> Bool {
        let interesting = ["halves", "consumed", "Screen", "immune", "absorbed",
                           "Thick Fat", "Weakness Policy", "Wide Open", "Sturdy",
                           "Focus Sash", "at full HP", "Terrain", "Snow", "Aura Guard",
                           "Supreme Overlord", "Helping Hand", "Spread"]
        return interesting.contains { note.contains($0) }
    }

    /// What the target's ability does to whatever just touched it — and what
    /// the attacker's does to whatever it touched.
    ///
    /// Rough Skin and Iron Barbs take an eighth off anything that makes contact.
    /// Flame Body, Static and Poison Point give a contact attacker a condition
    /// three times in ten. Stamina raises Defense on every hit taken. Poison
    /// Touch works the other way round, poisoning what the attacker touches.
    /// None of it fired: an Incineroar could Flare Blitz a Garchomp all day and
    /// its Rough Skin never cost a point.
    private static func contact(_ move: Move, byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                                wasAt: Int, rolling: Bool, board: inout Board) {
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = hitMine ? board.mine : board.theirs
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit) else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        let attackerName = attacker.build.form.formLabel
        let defenderName = defender.build.form.formLabel

        // Stamina does not need contact: any hit raises Defense.
        if defender.build.ability == "Stamina", !defender.fainted {
            StatChanges.applySelf([.defense: 1], toMine: hitMine, slot: hit, board: &board)
        }
        // Rocky Helmet: a sixth of the attacker's health for touching it, which
        // is the item's whole job and the reason a physical attacker thinks
        // twice. Red Card sends the attacker out instead.
        if move.makesContact, !attacker.fainted {
            if defender.build.item == "Rocky Helmet", !defender.fainted {
                let lost = Swift.max(1, attacker.maxHP / 6)
                if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                board.note("\(attackerName) was hurt by \(defenderName)'s Rocky Helmet.")
            }
            if defender.build.item == "Red Card", !defender.build.itemSpent, !defender.fainted {
                if hitMine { board.mine[hit].build.itemSpent = true }
                else { board.theirs[hit].build.itemSpent = true }
                board.note("\(defenderName)'s Red Card sent \(attackerName) away.")
                Switching.leave(byMine: byMine, slot: slot, board: &board)
            }
        }
        // Eject Button: the holder leaves the moment it is hit.
        if defender.build.item == "Eject Button", !defender.build.itemSpent, !defender.fainted {
            if hitMine { board.mine[hit].build.itemSpent = true }
            else { board.theirs[hit].build.itemSpent = true }
            board.note("\(defenderName)'s Eject Button took it out.")
            Switching.leave(byMine: hitMine, slot: hit, board: &board)
            return
        }

        // Abilities that answer the kind of hit: Thermal Exchange takes Fire
        // and gives Attack, Justified the same for Dark, Rattled runs from
        // Bug, Ghost and Dark, Weak Armor trades Defence for Speed on any
        // physical hit, Berserk answers the hit that took it to half.
        if !defender.fainted {
            let hitType = DamageCalc.fieldForm(of: move, in: board.field).type
            var answer: [Stat: Int] = [:]
            switch defender.build.ability {
            case "Thermal Exchange" where hitType == .fire: answer = [.attack: 1]
            case "Justified" where hitType == .dark: answer = [.attack: 1]
            case "Rattled" where [.bug, .ghost, .dark].contains(hitType): answer = [.speed: 1]
            case "Weak Armor" where move.category == "Physical": answer = [.defense: -1, .speed: 2]
            case "Berserk" where wasAt * 2 > defender.maxHP && defender.hp * 2 <= defender.maxHP:
                answer = [.spAttack: 1]
            default: break
            }
            if !answer.isEmpty {
                StatChanges.change(answer, onMine: hitMine, slot: hit, board: &board, because: defender.build.ability)
            }
        }
        // Anger Point needs no contact: any critical hit takes it to the top.
        if defender.build.ability == "Anger Point", !defender.fainted, board.lastWasCritical,
           defender.build.boosts[Stat.attack.rawValue] < 6 {
            if hitMine { board.mine[hit].build.boosts[Stat.attack.rawValue] = 6 }
            else { board.theirs[hit].build.boosts[Stat.attack.rawValue] = 6 }
            board.note("\(defenderName)'s Anger Point maximised its Attack.")
        }

        // Long Reach means nothing it throws ever touches anything, which
        // turns off Rocky Helmet, Static, Rough Skin and the rest of them.
        let touched = move.makesContact && attacker.build.ability != "Long Reach"

        // Abilities that answer being hit at all, contact or not.
        if !defender.fainted, !attacker.fainted {
            switch defender.build.ability {
            case "Seed Sower" where board.field.terrain != .grassy:
                let before = board.field
                board.field.terrain = .grassy
                board.terrainTurns = 5
                board.fieldSettled(from: before)
                board.terrainSeeds()
                board.note("\(defenderName)'s Seed Sower turned the ground to grass.")
            case "Toxic Debris":
                var far = byMine ? board.myScreens : board.theirScreens
                if far.toxicSpikes < 2 {
                    far.toxicSpikes += 1
                    if byMine { board.myScreens = far } else { board.theirScreens = far }
                    board.note("\(defenderName) scattered toxic spikes.")
                }
            case "Electromorphosis":
                if hitMine { board.mine[hit].charged = true } else { board.theirs[hit].charged = true }
                board.note("\(defenderName) became charged.")
            case "Spicy Spray" where attacker.status == .none
                && !attacker.types.contains(.fire):
                if byMine { board.mine[slot].status = .burn } else { board.theirs[slot].status = .burn }
                board.note("\(defenderName)'s Spicy Spray burned \(attackerName).")
            default: break
            }
        }
        // Stench: one hit in ten makes the target flinch, from either side of
        // the field, which is the whole of it.
        if attacker.build.ability == "Stench", !defender.fainted, rolling,
           Double.random(in: 0..<1, using: &TurnModel.dice) < 0.1 {
            Ailments.flinch(onMine: hitMine, slot: hit, board: &board, because: "the stench")
        }

        // Aftermath and Innards Out charge whoever landed the finishing hit.
        if defender.fainted, !attacker.fainted {
            var lost = 0
            if defender.build.ability == "Aftermath", touched { lost = attacker.maxHP / 4 }
            if defender.build.ability == "Innards Out" { lost = wasAt }
            if lost > 0 {
                if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                board.note("\(attackerName) was hurt by \(defenderName)'s \(defender.build.ability).")
                if (byMine ? board.mine : board.theirs)[slot].fainted {
                    board.note("\(attackerName) fainted.")
                }
            }
        }

        guard touched, !attacker.fainted else { return }

        // Cute Charm: three in ten that whoever touched it falls for it, and
        // loses half its turns while it is still standing there.
        if defender.build.ability == "Cute Charm", !defender.fainted,
           attacker.infatuatedWith == nil, rolling,
           Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3 {
            if byMine { board.mine[slot].infatuatedWith = hit }
            else { board.theirs[slot].infatuatedWith = hit }
            board.note("\(attackerName) fell for \(defenderName)'s Cute Charm.")
        }
        // Pickpocket takes the item off whatever touched it, if its own hands
        // are empty.
        if defender.build.ability == "Pickpocket", !defender.fainted,
           defender.build.item.isEmpty, !attacker.build.item.isEmpty,
           attacker.build.ability != "Sticky Hold" {
            let taken = attacker.build.item
            if hitMine { board.mine[hit].build.item = taken; board.mine[hit].build.itemSpent = false }
            else { board.theirs[hit].build.item = taken; board.theirs[hit].build.itemSpent = false }
            if byMine { board.mine[slot].build.item = "" } else { board.theirs[slot].build.item = "" }
            board.note("\(defenderName) pickpocketed \(attackerName)'s \(taken).")
        }

        // Mummy spreads itself to whatever touches it; Wandering Spirit
        // trades instead. Both turn off whatever the attacker was relying on.
        if !defender.fainted, !attacker.fainted {
            let stubborn: Set<String> = ["Mummy", "Wandering Spirit", "Lingering Aroma",
                                         "Multitype", "Stance Change", "Disguise",
                                         "Zen Mode", "Battle Bond", "Comatose"]
            if ["Mummy", "Lingering Aroma"].contains(defender.build.ability),
               !stubborn.contains(attacker.build.ability) {
                let was = attacker.build.ability
                if byMine { board.mine[slot].build.ability = defender.build.ability }
                else { board.theirs[slot].build.ability = defender.build.ability }
                board.note("\(attackerName)'s \(was) became \(defender.build.ability).")
            } else if defender.build.ability == "Wandering Spirit",
                      !stubborn.contains(attacker.build.ability) {
                let theirs = attacker.build.ability
                if byMine { board.mine[slot].build.ability = "Wandering Spirit" }
                else { board.theirs[slot].build.ability = "Wandering Spirit" }
                if hitMine { board.mine[hit].build.ability = theirs }
                else { board.theirs[hit].build.ability = theirs }
                board.note("\(defenderName) and \(attackerName) traded abilities.")
            }
        }

        // Gooey and Tangling Hair take a stage of Speed off whatever touches
        // them, which is how a slow Pokémon stops being outrun.
        if ["Gooey", "Tangling Hair"].contains(defender.build.ability), !defender.fainted {
            StatChanges.change([.speed: -1], onMine: byMine, slot: slot, board: &board,
                   because: defender.build.ability)
        }
        // Magician takes the item off whatever it hits, if its own hands are
        // empty. Pickpocket is the same trade in the other direction.
        if attacker.build.ability == "Magician", attacker.build.item.isEmpty,
           !defender.build.item.isEmpty, !defender.fainted,
           defender.build.ability != "Sticky Hold" {
            let taken = defender.build.item
            if byMine { board.mine[slot].build.item = taken; board.mine[slot].build.itemSpent = false }
            else { board.theirs[slot].build.item = taken; board.theirs[slot].build.itemSpent = false }
            if hitMine { board.mine[hit].build.item = "" } else { board.theirs[hit].build.item = "" }
            board.note("\(attackerName)'s Magician took \(defenderName)'s \(taken).")
        }

        switch defender.build.ability {
        case "Rough Skin", "Iron Barbs":
            let lost = Swift.max(1, attacker.maxHP / 8)
            if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
            else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
            board.note("\(attackerName) is hurt by \(defenderName)'s \(defender.build.ability).")
        case "Effect Spore":
            // One in ten, and one of three things.
            guard rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3,
                  attacker.status == .none, !attacker.types.contains(.grass) else { break }
            let roll = Double.random(in: 0..<1, using: &TurnModel.dice)
            let ailment: Ailment = roll < 0.34 ? .paralysis : roll < 0.67 ? .poison : .sleep
            if byMine { board.mine[slot].status = ailment; board.mine[slot].asleepFor = ailment == .sleep ? 2 : 0 }
            else { board.theirs[slot].status = ailment; board.theirs[slot].asleepFor = ailment == .sleep ? 2 : 0 }
            board.note("\(attackerName) was \(ailment.rawValue) by \(defenderName)'s Effect Spore.")
        case "Flame Body", "Static", "Poison Point":
            // Three in ten. A search averages, so it does not apply these at
            // all rather than applying them to everybody.
            guard rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3, attacker.status == .none else { break }
            let ailment: Ailment = defender.build.ability == "Flame Body" ? .burn
                : defender.build.ability == "Static" ? .paralysis : .poison
            let immune = (ailment == .burn && attacker.build.form.pokeTypes.contains(.fire))
                || (ailment == .paralysis && attacker.build.form.pokeTypes.contains(.electric))
                || (ailment == .poison && attacker.build.form.pokeTypes.contains(where: {
                    [.poison, .steel].contains($0) }))
            guard !immune else { break }
            if byMine { board.mine[slot].status = ailment } else { board.theirs[slot].status = ailment }
            board.note("\(defenderName)'s \(defender.build.ability) left \(attackerName) \(ailment.rawValue).")
        default:
            break
        }

        let poisonRoll: Bool
        if rolling { poisonRoll = Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3 }
        else { poisonRoll = board.rulings[Board.flip("poisontouch", byMine, slot)] ?? false }
        if attacker.build.ability == "Poison Touch", poisonRoll, !defender.fainted,
           defender.status == .none,
           !defender.types.contains(where: { [.poison, .steel].contains($0) }) {
            if hitMine { board.mine[hit].status = .poison } else { board.theirs[hit].status = .poison }
            board.note("\(attackerName)'s Poison Touch poisoned \(defenderName).")
        }
    }

    /// What using the move costs the Pokémon that used it.
    ///
    /// None of this was applied: Final Gambit did its damage and left the user
    /// standing, Flare Blitz and Wood Hammer were free, Steel Beam cost
    /// nothing, and a Life Orb was pure profit. The move ranker has priced all
    /// of these for a long time — it is why Steel Beam ranks below Iron Head —
    /// and the battle simply never charged them.
    private static func cost(of move: Move, dealt: Int, byMine: Bool, slot: Int,
                             board: inout Board) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let maxHP = team[slot].maxHP
        var lost = 0

        // Moves that end the user's game outright.
        if move.effect.contains("The user faints") {
            lost = team[slot].hp
            board.note("\(name) fainted using \(move.name).")
        } else {
            let costs = move.drawbacks
            if costs.recoil > 0, dealt > 0 {
                lost += Swift.max(1, Int(Double(dealt) * costs.recoil))
                board.note("\(name) is hurt by the recoil.")
            }
            if costs.selfDamage > 0 {
                lost += Swift.max(1, Int(Double(maxHP) * costs.selfDamage))
                board.note("\(name) pays for \(move.name) with its own health.")
            }
            // A Life Orb takes a tenth of maximum every time it lands a hit.
            if team[slot].build.item == "Life Orb", dealt > 0,
               team[slot].build.ability != "Sheer Force" {
                lost += Swift.max(1, maxHP / 10)
                board.note("\(name) is worn down by its Life Orb.")
            }
        }
        guard lost > 0 else { return }
        if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
        else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
        let after = byMine ? board.mine[slot] : board.theirs[slot]
        if after.hp == 0, !move.effect.contains("The user faints") {
            board.note("\(name) fainted.")
        }
    }

    /// Protect, with the odds the game gives it: certain the first time, a
    /// third the next, a ninth after that, and back to certain the moment one
    /// fails or a turn goes by without one. A played turn rolls it; the search
    /// takes anything under even as a miss, so it never counts on a second
    /// Protect in a row — which is exactly the read a good player makes.
    /// What a hit does besides damage. A played turn rolls the chance; the
    /// search, which averages, applies only what is certain — Nuzzle's
    /// paralysis, not Scald's three-in-ten burn — the way it treats Flame
    /// Body. Serene Grace doubles the odds; Sheer Force trades them away.
    /// How likely a move's secondary effect is, once the user's ability has
    /// had its say. Sheer Force trades it away for power; Serene Grace doubles
    /// it. Worked out in one place because `outcomes` offers the branch and
    /// `secondary` takes it, and the two disagreeing would price a coin flip
    /// that never happens.
    static func secondaryChance(of move: Move, for fighter: Fighter) -> Int {
        guard let effect = move.secondaries.first else { return 0 }
        return chance(of: effect, for: fighter)
    }

    /// One secondary's chance, once the user's ability has had its say.
    static func chance(of effect: Move.Secondary, for fighter: Fighter) -> Int {
        if fighter.build.ability == "Sheer Force" { return 0 }
        if fighter.build.ability == "Serene Grace" { return Swift.min(100, effect.chance * 2) }
        return effect.chance
    }

    private static func secondary(of move: Move, byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                                  rolling: Bool, board: inout Board) {
        guard !move.secondaries.isEmpty else { return }
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = hitMine ? board.mine : board.theirs
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit),
              !defenderTeam[hit].fainted else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        let name = defender.build.form.formLabel
        // Shield Dust and a Covert Cloak refuse every secondary effect aimed at
        // their holder, which is the whole point of both.
        if defender.build.ability == "Shield Dust" || defender.build.item == "Covert Cloak" {
            return
        }
        // Every secondary the move has, not the first one. Fire Fang, Ice Fang
        // and Thunder Fang each carry two, and Triple Arrows carries a stat
        // drop and a flinch at different odds; reading only the first meant
        // half of each of those moves never happened.
        for effect in move.secondaries {
            let chance = TurnModel.chance(of: effect, for: attacker)
            guard chance > 0 else { continue }
            // A played turn rolls. The search takes the branch it was handed,
            // and falls back to "only what is certain" when it was handed none.
            let happens: Bool
            if rolling { happens = Double.random(in: 0..<100, using: &TurnModel.dice) < Double(chance) }
            else if let ruled = board.rulings[Board.flip("secondary", byMine, slot)] { happens = ruled }
            else { happens = chance >= 100 }
            guard happens else { continue }
            apply(effect, chance: chance, of: move, byMine: byMine, hitMine: hitMine,
                  slot: slot, hit: hit, name: name, rolling: rolling, board: &board)
        }
    }

    /// One secondary effect landing.
    private static func apply(_ effect: Move.Secondary, chance: Int, of move: Move,
                              byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                              name: String, rolling: Bool, board: inout Board) {
        let defenderTeam = hitMine ? board.mine : board.theirs
        let attackerTeam = byMine ? board.mine : board.theirs
        guard defenderTeam.indices.contains(hit), attackerTeam.indices.contains(slot) else { return }
        let defender = defenderTeam[hit]
        let attacker = attackerTeam[slot]
        switch effect.kind {
        case .status(let ailment):
            guard defender.status == .none else { return }
            // The types the battle gave it, not the ones the dex printed: a
            // Soaked Garchomp really can be burned like a Water type.
            let types = defender.types
            let immune: Bool
            switch ailment {
            case .burn: immune = types.contains(.fire) || defender.build.ability == "Thermal Exchange"
                || defender.build.ability == "Water Veil" || defender.build.ability == "Water Bubble"
            case .paralysis: immune = types.contains(.electric) || defender.build.ability == "Limber"
            case .poison, .badPoison:
                // Corrosion poisons the two types that cannot normally be.
                immune = (attacker.build.ability != "Corrosion"
                          && types.contains(where: { [.poison, .steel].contains($0) }))
                    || defender.build.ability == "Immunity"
            case .freeze: immune = types.contains(.ice)
                || defender.build.ability == "Magma Armor"
            case .sleep, .none: immune = true
            }
            if immune { return }
            if (hitMine ? board.myScreens : board.theirScreens).safeguard > 0 {
                board.note("The veil kept \(name) from being \(ailment.rawValue).")
                return
            }
            if let refused = Ailments.refusesStatus(ailment, onMine: hitMine, slot: hit, board: board) {
                board.note("\(name)'s \(refused) kept it from being \(ailment.rawValue).")
                return
            }
            if board.field.terrain == .misty, defender.isGrounded {
                board.note("The mist kept \(name) from being \(ailment.rawValue).")
                return
            }
            if hitMine { board.mine[hit].status = ailment } else { board.theirs[hit].status = ailment }
            board.note("\(name) was \(ailment.rawValue)" + (chance < 100 ? " — the \(chance)% came up." : "."))
            Ailments.synchronize(ailment, from: hitMine, slot: hit, onto: byMine, slot: slot, board: &board)
        case .flinch:
            // Only matters if it has yet to move this turn; the flag clears at
            // the turn's start either way. Inner Focus is handled inside.
            Ailments.flinch(onMine: hitMine, slot: hit, board: &board,
                   because: chance < 100 ? "the \(chance)% came up" : nil)
        case .drops(let drops):
            StatChanges.applyDrops(drops, toMine: hitMine, slot: hit, board: &board)
        case .targetBoosts(let raises):
            StatChanges.applySelf(raises, toMine: hitMine, slot: hit, board: &board)
        case .selfBoosts(let raises):
            // Charge Beam, Meteor Mash, Ancient Power, Steel Wing: the payment
            // goes to whoever used the move, not to whoever was hit.
            StatChanges.applySelf(raises, toMine: byMine, slot: slot, board: &board)
        case .selfDrops(let drops):
            StatChanges.applyDrops(drops, toMine: byMine, slot: slot, board: &board)
        case .confuse:
            // Whether the confusion lands was settled above; `rolling` here
            // only decides how long it lasts, and a played turn should roll
            // that rather than always taking the two turns the search assumes.
            Ailments.confuse(onMine: hitMine, slot: hit, board: &board, rolling: rolling, chance: chance)
        }
    }

    /// The move index a choice picks, or -1 for anything that is not an attack.
    private static func pickedMove(_ choice: Choice) -> Int {
        if case .attack(let index, _) = choice { return index }
        if case .protectSelf(let index) = choice { return index }
        return -1
    }

    /// What a non-damaging move actually does.
    ///
    /// Eleven per cent of the move slots on real team lists were landing here
    /// and doing nothing at all: Follow Me, Rage Powder, Wide Guard, Swords
    /// Dance, Nasty Plot, Calm Mind, Will-O-Wisp, Encore, the screens. Two of
    /// those are the entire reason a doubles support Pokémon exists, so a third
    /// of the format could be brought to a battle and simply not play.
    ///
    /// Read from what each move says rather than from a list of names, wherever
    /// the sentence is regular enough to trust.
    private static func support(_ move: Move, byMine: Bool, slot: Int, target: Int,
                                to board: inout Board, rolling: Bool) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return }
        let name = team[slot].build.form.formLabel
        board.note("\(name) used \(move.name).")

        // What the other side can refuse outright. A Prankster's status move
        // does not work on a Dark type — the one thing that keeps a
        // Whimsicott's Encore off a Kingambit — and a Good as Gold refuses
        // every status move there is.
        if move.aim == .foe {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            if far.indices.contains(index), !far[index].fainted {
                let who = far[index].build.form.formLabel
                if far[index].build.ability == "Good as Gold" {
                    board.note("But \(who)'s Good as Gold refused it outright.")
                    return
                }
                if team[slot].build.ability == "Prankster",
                   far[index].build.form.pokeTypes.contains(.dark) {
                    board.note("But it does not affect \(who) — a Dark type shrugs off a Prankster's tricks.")
                    return
                }
            }
        }

        // Healing: Recover and its kind give back a share of the bar, to the
        // user, the partner, or both; Rest gives back all of it and two turns.
        if let healing = move.healing {
            var share = healing.share
            if healing.sunlit {
                switch board.field.weather {
                case .sun: share = 2.0 / 3.0
                case .none: break
                default: share = 0.25
                }
            }
            let partner = slot == 0 ? 1 : 0
            var receivers: [Int] = []
            switch healing.whom {
            case .user: receivers = [slot]
            case .partner: receivers = [partner]
            case .both: receivers = [slot, partner]
            }
            var anyone = false
            for who in receivers where team.indices.contains(who) && who < board.activeCount && !team[who].fainted {
                let maxHP = team[who].maxHP
                let gained = Swift.min(maxHP - team[who].hp, Swift.max(1, Int(Double(maxHP) * share)))
                guard gained > 0 else {
                    board.note("\(team[who].build.form.formLabel)'s health is already full.")
                    continue
                }
                if byMine { board.mine[who].hp += gained } else { board.theirs[who].hp += gained }
                board.note("\(team[who].build.form.formLabel) recovered \(gained) health"
                           + (share == 1 ? " and fell asleep." : "."))
                anyone = true
            }
            if move.name == "Rest", anyone {
                if byMine { board.mine[slot].status = .sleep; board.mine[slot].asleepFor = 2 }
                else { board.theirs[slot].status = .sleep; board.theirs[slot].asleepFor = 2 }
            }
            if !anyone { board.note("But it failed.") }
            return
        }

        // Parting Shot: the drops land and then the user leaves, which is the
        // whole point of it — a free switch that costs them two stages.
        if move.name == "Parting Shot" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            if far.indices.contains(index), !far[index].fainted, !far[index].isProtected {
                StatChanges.applyDrops([.attack: 1, .spAttack: 1], toMine: !byMine, slot: index, board: &board)
            } else if far.indices.contains(index), far[index].isProtected {
                board.note("\(far[index].build.form.formLabel) protected itself.")
            }
            Switching.leave(byMine: byMine, slot: slot, board: &board)
            return
        }

        // -- the ones that reach across and rearrange something -------------
        //
        // Each of these was a move slot on a real team list that did nothing
        // at all. They are grouped here because they share a shape: find the
        // Pokémon on the other side, check it can be reached, then move a
        // number, a name or an object from one side to the other.

        /// The opposing slot this move is aimed at, if it can be reached.
        func reachableTarget() -> Int? {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return nil }
            if far[index].isProtected {
                board.note("\(far[index].build.form.formLabel) protected itself.")
                return nil
            }
            if far[index].substitute > 0 {
                board.note("\(far[index].build.form.formLabel)'s substitute took it.")
                return nil
            }
            return index
        }
        func farName(_ index: Int) -> String {
            (byMine ? board.theirs : board.mine)[index].build.form.formLabel
        }
        /// Write a changed fighter back to whichever side it came from.
        func setFar(_ index: Int, _ change: (inout Fighter) -> Void) {
            if byMine { change(&board.theirs[index]) } else { change(&board.mine[index]) }
        }
        func setNear(_ change: (inout Fighter) -> Void) {
            if byMine { change(&board.mine[slot]) } else { change(&board.theirs[slot]) }
        }

        // Trick and Switcheroo: the two held items change hands. The point is
        // to hand something a Choice Scarf and take its berry.
        if move.name == "Trick" || move.name == "Switcheroo" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            let theirs = far[index].build.item
            let ours = team[slot].build.item
            guard !(theirs.isEmpty && ours.isEmpty) else { board.note("But it failed."); return }
            if far[index].build.ability == "Sticky Hold" {
                board.note("\(farName(index))'s Sticky Hold kept hold of it.")
                return
            }
            setFar(index) { $0.build.item = ours; $0.build.itemSpent = false }
            setNear { $0.build.item = theirs; $0.build.itemSpent = false }
            board.note("\(name) swapped items with \(farName(index)):"
                       + " \(ours.isEmpty ? "nothing" : ours) for \(theirs.isEmpty ? "nothing" : theirs).")
            return
        }

        // Skill Swap trades abilities; Worry Seed replaces the target's with
        // Insomnia, which is how a sleep team gets turned off.
        if move.name == "Skill Swap" || move.name == "Worry Seed" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            let had = far[index].build.ability
            if move.name == "Worry Seed" {
                guard had != "Insomnia" else { board.note("But it failed."); return }
                setFar(index) { $0.build.ability = "Insomnia" }
                board.note("\(farName(index))'s ability became Insomnia.")
                if far[index].status == .sleep {
                    setFar(index) { $0.status = .none; $0.asleepFor = 0 }
                    board.note("\(farName(index)) woke up.")
                }
            } else {
                let ours = team[slot].build.ability
                setFar(index) { $0.build.ability = ours }
                setNear { $0.build.ability = had }
                board.note("\(name) and \(farName(index)) swapped abilities:"
                           + " \(ours) for \(had).")
            }
            return
        }

        // Soak makes the target a pure Water type, which is how a Ground type
        // stops being immune to Thunderbolt.
        if move.name == "Soak" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            setFar(index) { $0.build.typeOverride = [.water] }
            board.note("\(farName(index)) became a Water type.")
            return
        }

        // Psych Up copies the target's stat changes; Guard Swap and Power Swap
        // trade one pair of them; Heart Swap trades all six.
        if ["Psych Up", "Guard Swap", "Power Swap", "Heart Swap"].contains(move.name) {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            var ourBoosts = team[slot].build.boosts
            var theirBoosts = far[index].build.boosts
            switch move.name {
            case "Psych Up":
                ourBoosts = theirBoosts
                board.note("\(name) copied \(farName(index))'s stat changes.")
            case "Heart Swap":
                swap(&ourBoosts, &theirBoosts)
                board.note("\(name) and \(farName(index)) traded every stat change.")
            default:
                let pair: [Stat] = move.name == "Guard Swap" ? [.defense, .spDefense]
                                                             : [.attack, .spAttack]
                for stat in pair {
                    let keep = ourBoosts[stat.rawValue]
                    ourBoosts[stat.rawValue] = theirBoosts[stat.rawValue]
                    theirBoosts[stat.rawValue] = keep
                }
                board.note("\(name) and \(farName(index)) traded their"
                           + " \(move.name == "Guard Swap" ? "defensive" : "offensive") stat changes.")
            }
            setNear { $0.build.boosts = ourBoosts }
            setFar(index) { $0.build.boosts = theirBoosts }
            return
        }

        // Pain Split averages the two health bars, which is what lets
        // something on its last legs drag a healthy attacker down with it.
        if move.name == "Pain Split" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            let shared = (team[slot].hp + far[index].hp) / 2
            setNear { $0.hp = Swift.min($0.maxHP, shared) }
            setFar(index) { $0.hp = Swift.min($0.maxHP, shared) }
            board.note("\(name) and \(farName(index)) split their health, \(shared) each.")
            return
        }

        // Guard Split and Power Split average the raw stats rather than the
        // stages, so a wall hands half its bulk to whatever it touches.
        if move.name == "Guard Split" || move.name == "Power Split" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let pair: [Stat] = move.name == "Guard Split" ? [.defense, .spDefense]
                                                          : [.attack, .spAttack]
            let far = byMine ? board.theirs : board.mine
            for stat in pair {
                let averaged = (team[slot].build.stat(stat) + far[index].build.stat(stat)) / 2
                setNear { $0.build.statOverride = ($0.build.statOverride ?? [:]).merging([stat.rawValue: averaged]) { _, new in new } }
                setFar(index) { $0.build.statOverride = ($0.build.statOverride ?? [:]).merging([stat.rawValue: averaged]) { _, new in new } }
            }
            board.note("\(name) and \(farName(index)) split their"
                       + " \(move.name == "Guard Split" ? "defences" : "attacking power").")
            return
        }

        // -- the ones that stick a label on something ------------------------

        if move.name == "Attract" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            guard far[index].infatuatedWith == nil,
                  !["Oblivious", "Aroma Veil"].contains(far[index].build.ability) else {
                board.note("But it failed."); return
            }
            setFar(index) { $0.infatuatedWith = slot }
            board.note("\(farName(index)) fell in love with \(name).")
            return
        }

        if move.name == "Torment" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].tormented, far[index].build.ability != "Aroma Veil" else {
                board.note("But it failed."); return
            }
            setFar(index) { $0.tormented = true }
            board.note("\(farName(index)) cannot use the same move twice in a row.")
            return
        }

        if move.name == "Mean Look" || move.name == "Block" || move.name == "Spider Web" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].cannotEscape, !far[index].types.contains(.ghost) else {
                board.note("But it failed."); return
            }
            setFar(index) { $0.cannotEscape = true }
            board.note("\(farName(index)) can no longer escape.")
            return
        }

        // -- the ones that put something on a side of the field --------------

        if ["Spikes", "Toxic Spikes", "Stealth Rock", "Sticky Web"].contains(move.name) {
            // Hazards go on the *other* side, and stay until something clears
            // them. They are the price of every pivot after this turn.
            var far = byMine ? board.theirScreens : board.myScreens
            let placed: Bool
            switch move.name {
            case "Sticky Web":   placed = !far.stickyWeb; far.stickyWeb = true
            case "Spikes":       placed = far.spikes < 3; far.spikes = Swift.min(3, far.spikes + 1)
            case "Toxic Spikes": placed = far.toxicSpikes < 2; far.toxicSpikes = Swift.min(2, far.toxicSpikes + 1)
            default:             placed = !far.stealthRock; far.stealthRock = true
            }
            guard placed else { board.note("But it failed."); return }
            if byMine { board.theirScreens = far } else { board.myScreens = far }
            board.note("\(move.name) settled around the other side of the field.")
            return
        }

        if move.name == "Safeguard" {
            var own = byMine ? board.myScreens : board.theirScreens
            guard own.safeguard == 0 else { board.note("But it failed."); return }
            own.safeguard = 5
            if byMine { board.myScreens = own } else { board.theirScreens = own }
            board.note("A veil settled over \(byMine ? "your" : "their") side for five turns.")
            return
        }

        if move.name == "Wish" {
            var own = byMine ? board.myScreens : board.theirScreens
            guard own.wishTurns == 0 else { board.note("But it failed."); return }
            own.wishAmount = Swift.max(1, team[slot].maxHP / 2)
            own.wishTurns = 2
            if byMine { board.myScreens = own } else { board.theirScreens = own }
            board.note("\(name) made a wish. Help arrives next turn.")
            return
        }

        if move.name == "Aqua Ring" {
            guard !team[slot].aquaRing else { board.note("But it failed."); return }
            setNear { $0.aquaRing = true }
            board.note("\(name) surrounded itself with a veil of water.")
            return
        }

        if move.name == "Magic Room" || move.name == "Wonder Room" {
            let running = move.name == "Magic Room" ? board.magicRoom : board.wonderRoom
            let turns = running > 0 ? 0 : 5
            if move.name == "Magic Room" { board.magicRoom = turns } else { board.wonderRoom = turns }
            board.note(turns > 0
                       ? "\(move.name) twisted the field for five turns."
                       : "\(move.name) ended.")
            return
        }

        // -- moves real games use that this model did not have ---------------
        //
        // Every one of these turned up in the replay corpus. They are grouped
        // because they share a shape: each sets a clock or a flag on somebody
        // and the turn loop reads it later, rather than doing its work now.

        // Perish Song takes everybody, both sides, the user included. Three
        // turns later whatever is still standing faints, which is why it is
        // the answer to a Pokémon that cannot otherwise be beaten — and why
        // the side that sang it has to have a plan for its own two.
        if move.name == "Perish Song" {
            // A sound move, so Soundproof is deaf to it. Everything else on
            // the field is caught, including the singer's own side.
            var caught: [String] = []
            for index in 0..<Swift.min(board.activeCount, board.mine.count)
            where !board.mine[index].fainted && board.mine[index].perishIn == 0
                    && !board.mine[index].isSoundproof {
                board.mine[index].perishIn = 3
                caught.append(board.mine[index].build.form.formLabel)
            }
            for index in 0..<Swift.min(board.activeCount, board.theirs.count)
            where !board.theirs[index].fainted && board.theirs[index].perishIn == 0
                    && !board.theirs[index].isSoundproof {
                board.theirs[index].perishIn = 3
                caught.append(board.theirs[index].build.form.formLabel)
            }
            guard !caught.isEmpty else { board.note("But it failed."); return }
            board.note("All around, the song took hold: \(caught.joined(separator: ", ")) "
                       + "will faint in three turns.")
            return
        }

        // Coil raises Attack, Defense and accuracy. This model keeps no
        // accuracy stage — it is a deliberate omission, not an oversight, and
        // is noted where the omission is made — so two thirds of Coil lands
        // and the third is recorded here rather than pretended.
        if move.name == "Coil" {
            StatChanges.change([.attack: 1, .defense: 1], onMine: byMine, slot: slot, board: &board)
            return
        }

        // Yawn does not put anything to sleep. It makes it drowsy, and the
        // sleep arrives at the end of the following turn, which is the point:
        // the other side gets one turn to switch out of it.
        if move.name == "Yawn" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else {
                board.note("But it failed."); return
            }
            let who = far[index].build.form.formLabel
            guard far[index].status == .none, far[index].drowsyFor == 0 else {
                board.note("But \(who) cannot be made drowsy."); return
            }
            if byMine { board.theirs[index].drowsyFor = 2 } else { board.mine[index].drowsyFor = 2 }
            board.note("\(who) grew drowsy. It will fall asleep at the end of next turn.")
            return
        }

        // Disable shuts off whatever the target used last, for four turns. A
        // Pokémon with one attack and three support moves is a different
        // Pokémon once the attack is gone.
        if move.name == "Disable" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted,
                  let last = far[index].lastMove, far[index].moves.indices.contains(last),
                  far[index].disabled == nil else {
                board.note("But it failed."); return
            }
            let who = far[index].build.form.formLabel
            let what = far[index].moves[last].name
            if byMine { board.theirs[index].disabled = last; board.theirs[index].disabledFor = 4 }
            else { board.mine[index].disabled = last; board.mine[index].disabledFor = 4 }
            board.note("\(who)'s \(what) was disabled for four turns.")
            return
        }

        // Destiny Bond takes whatever kills it down too. It fails if used
        // twice running, which is what stops it being a free answer to
        // everything: the model already tracks a repeated move for Protect.
        if move.name == "Destiny Bond" {
            guard !team[slot].destinyBound else { board.note("But it failed."); return }
            setNear { $0.destinyBound = true }
            board.note("\(name) is trying to take its attacker with it.")
            return
        }

        // Octolock holds the target in place and grinds a stage of each
        // defence off it every turn it stays there.
        if move.name == "Octolock" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted,
                  !far[index].octolocked else {
                board.note("But it failed."); return
            }
            let who = far[index].build.form.formLabel
            if byMine { board.theirs[index].octolocked = true; board.theirs[index].cannotEscape = true }
            else { board.mine[index].octolocked = true; board.mine[index].cannotEscape = true }
            board.note("\(who) can no longer escape, and its guard is being worn down.")
            return
        }

        // Instruct makes the partner take its last move again, which is how a
        // Trick Room team gets two Earthquakes out of one Pokémon. It is a
        // second use of a move that has already happened, so it runs through
        // the ordinary move path rather than being special-cased: whatever the
        // move does, it does again.
        if move.name == "Instruct" {
            let ally = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(ally), !own[ally].fainted,
                  let last = own[ally].lastMove, own[ally].moves.indices.contains(last)
            else { board.note("But there was nothing to instruct."); return }
            let again = own[ally].moves[last]
            // What cannot be instructed. A charging move is mid-wind-up and
            // repeating it would finish it twice; Instruct itself would send
            // the two of them back and forth for the rest of the game.
            guard own[ally].charging == nil, again.name != "Instruct" else {
                board.note("But \(own[ally].build.form.formLabel) could not be instructed.")
                return
            }
            board.note("\(name) had \(own[ally].build.form.formLabel) use \(again.name) again.")
            apply(.attack(move: last, target: own[ally].lastTarget),
                  byMine: byMine, slot: ally, to: &board, rolling: rolling)
            return
        }

        // Shed Tail buys a switch with half the bar: the substitute stays
        // behind for whatever comes in, which is the difference between it
        // and an ordinary pivot.
        if move.name == "Shed Tail" {
            let cost = team[slot].maxHP / 2
            let shell = team[slot].maxHP / 4
            let bench = (byMine ? board.mine : board.theirs).indices.first {
                $0 >= board.activeCount && !(byMine ? board.mine : board.theirs)[$0].fainted
            }
            guard team[slot].hp > cost, team[slot].substitute == 0, let bench else {
                board.note("But it failed."); return
            }
            setNear { $0.hp -= cost; $0.substitute = shell }
            board.note("\(name) gave up half its health to leave a substitute worth \(shell).")
            if let said = Switching.swapIn(mine: byMine, active: slot, bench: bench, board: &board) {
                board.note(said)
            }
            // The shell belongs to the slot, not to the Pokémon that made it.
            if byMine { board.mine[slot].substitute = shell }
            else { board.theirs[slot].substitute = shell }
            return
        }

        // Substitute: a quarter of the bar becomes a shell that eats damage
        // and status until it breaks.
        if move.name == "Substitute" {
            let cost = team[slot].maxHP / 4
            guard team[slot].hp > cost, team[slot].substitute == 0 else {
                board.note("But it failed."); return
            }
            setNear { $0.hp -= cost; $0.substitute = cost }
            board.note("\(name) put up a substitute worth \(cost).")
            return
        }

        // Belly Drum spends half the bar to go straight to the top.
        if move.name == "Belly Drum" {
            let cost = team[slot].maxHP / 2
            guard team[slot].hp > cost, team[slot].build.boosts[Stat.attack.rawValue] < 6 else {
                board.note("But it failed."); return
            }
            setNear { $0.hp -= cost; $0.build.boosts[Stat.attack.rawValue] = 6 }
            board.note("\(name) cut its health to maximise its Attack.")
            return
        }

        // Stockpile holds a charge; Swallow spends the lot for health.
        if move.name == "Stockpile" {
            guard team[slot].stockpile < 3 else { board.note("But it failed."); return }
            setNear { $0.stockpile += 1
                      $0.build.boosts[Stat.defense.rawValue] = Swift.min(6, $0.build.boosts[Stat.defense.rawValue] + 1)
                      $0.build.boosts[Stat.spDefense.rawValue] = Swift.min(6, $0.build.boosts[Stat.spDefense.rawValue] + 1) }
            board.note("\(name) stockpiled \(team[slot].stockpile + 1).")
            return
        }
        if move.name == "Swallow" {
            let held = team[slot].stockpile
            guard held > 0 else { board.note("But it failed."); return }
            let share = held == 1 ? 0.25 : held == 2 ? 0.5 : 1.0
            let gained = Swift.min(team[slot].maxHP - team[slot].hp,
                                   Swift.max(1, Int(Double(team[slot].maxHP) * share)))
            // Clamped, like every other stage change: three stages off a
            // Defense already at the bottom is not a place a stage can be, and
            // the damage step has no multiplier for -9.
            setNear { $0.hp += gained; $0.stockpile = 0
                      $0.build.boosts[Stat.defense.rawValue] =
                          Swift.max(-6, $0.build.boosts[Stat.defense.rawValue] - held)
                      $0.build.boosts[Stat.spDefense.rawValue] =
                          Swift.max(-6, $0.build.boosts[Stat.spDefense.rawValue] - held) }
            board.note("\(name) swallowed \(held) and recovered \(gained) health.")
            return
        }

        // Roar and Whirlwind drag the target out and something else in, which
        // is how a setup sweeper gets undone: every stage it earned goes with
        // it. They move last on purpose — their priority is -6 — so what they
        // undo is whatever just happened.
        if move.name == "Roar" || move.name == "Whirlwind" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].build.ability.isEmpty || true else { return }
            if far[index].build.ability == "Suction Cups" {
                board.note("\(farName(index))'s Suction Cups held it in place.")
                return
            }
            // The search cannot roll, so it drags in the first one standing.
            // A played turn picks at random, which is what the move does.
            let bench = (board.activeCount..<far.count).filter { !far[$0].fainted }
            guard let coming = rolling ? bench.randomElement() : bench.first else {
                board.note("But there was no one to drag in.")
                return
            }
            let arriving = far[coming].build.form.formLabel
            board.note("\(farName(index)) was dragged out, and \(arriving) took its place.")
            if let said = Switching.swapIn(mine: !byMine, active: index, bench: coming, board: &board) {
                board.note(said)
            }
            return
        }

        // Baton Pass leaves, but hands everything it built up to whoever comes
        // in. That is the whole move: the stages survive the switch that
        // normally wipes them.
        if move.name == "Baton Pass" {
            let own = byMine ? board.mine : board.theirs
            let bench = (board.activeCount..<own.count).filter { !own[$0].fainted }
            guard let coming = bench.first else { board.note("But it failed."); return }
            let passed = own[slot].build.boosts
            let sub = own[slot].substitute
            let ring = own[slot].aquaRing
            let arriving = own[coming].build.form.formLabel
            board.note("\(name) passed the baton to \(arriving).")
            if let said = Switching.swapIn(mine: byMine, active: slot, bench: coming, board: &board) {
                board.note(said)
            }
            if byMine {
                board.mine[slot].build.boosts = passed
                board.mine[slot].substitute = sub
                board.mine[slot].aquaRing = ring
            } else {
                board.theirs[slot].build.boosts = passed
                board.theirs[slot].substitute = sub
                board.theirs[slot].aquaRing = ring
            }
            if passed.contains(where: { $0 != 0 }) {
                board.note("\(arriving) took over every stat change.")
            }
            return
        }

        // After You hands the target the next action. The turn order was fixed
        // before anything moved, so this marks the target and the order is
        // rebuilt around the mark.
        if move.name == "After You" || move.name == "Quash" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            if move.name == "After You" {
                setFar(index) { $0.goesNext = true }
                board.note("\(farName(index)) will move next.")
            } else {
                setFar(index) { $0.goesLast = true }
                board.note("\(farName(index)) was sent to the back of the queue.")
            }
            return
        }

        // -- the ones that sweep the field ----------------------------------

        // Haze wipes every stat change on both sides, which is the answer to
        // anything that has spent the game setting up.
        if move.name == "Haze" {
            for index in board.mine.indices { board.mine[index].build.boosts = Array(repeating: 0, count: 6) }
            for index in board.theirs.indices { board.theirs[index].build.boosts = Array(repeating: 0, count: 6) }
            board.note("A haze settled and every stat change went with it.")
            return
        }

        // Defog and Rapid Spin both clear the floor, and the difference
        // between them is the whole reason a team picks one.
        //
        // Defog takes the target's screens and hazards, the user's own hazards
        // but not its screens, and the terrain. Rapid Spin takes only the
        // user's own hazards, and hits something besides.
        //
        // Serebii's Champions text for Defog says "on the target Pokémon's
        // side of battle" and stops there, which reads like a deliberate
        // restriction until you notice the same sentence never mentions Sticky
        // Web — a move that is legal here, and that Rapid Spin's own
        // description does name. The list is incomplete rather than narrow.
        if move.name == "Defog" {
            board.sweepHazards(mine: byMine)
            var far = byMine ? board.theirScreens : board.myScreens
            far.reflect = 0; far.lightScreen = 0; far.auroraVeil = 0
            far.safeguard = 0
            far.spikes = 0; far.toxicSpikes = 0
            far.stealthRock = false; far.stickyWeb = false
            if byMine { board.theirScreens = far } else { board.myScreens = far }
            let hadTerrain = board.field.terrain != .none
            board.field.terrain = .none
            board.terrainTurns = 0
            board.note(hadTerrain ? "The field and the terrain were swept away."
                                  : "The field was swept clear.")
            return
        }

        // Court Change hands the other side everything on yours and takes
        // everything on theirs, hazards included.
        if move.name == "Court Change" {
            swap(&board.myScreens, &board.theirScreens)
            board.note("The two sides of the field traded places.")
            return
        }

        // Topsy-Turvy turns the target's stat changes upside down, which is
        // the cheapest answer to a Belly Drum there is.
        if move.name == "Topsy-Turvy" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            guard far[index].build.boosts.contains(where: { $0 != 0 }) else {
                board.note("But it failed."); return
            }
            setFar(index) { $0.build.boosts = $0.build.boosts.map { -$0 } }
            board.note("\(farName(index))'s stat changes were turned upside down.")
            return
        }

        // Entrainment hands the target the user's ability; Role Play takes the
        // target's; Simple Beam makes it Simple; Gastro Acid takes it away.
        if ["Entrainment", "Role Play", "Simple Beam", "Gastro Acid"].contains(move.name) {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            switch move.name {
            case "Entrainment":
                setFar(index) { $0.build.ability = team[slot].build.ability }
                board.note("\(farName(index)) took on \(name)'s \(team[slot].build.ability).")
            case "Role Play":
                let taken = far[index].build.ability
                setNear { $0.build.ability = taken }
                board.note("\(name) copied \(farName(index))'s \(taken).")
            case "Simple Beam":
                setFar(index) { $0.build.ability = "Simple" }
                board.note("\(farName(index))'s ability became Simple.")
            default:
                setFar(index) { $0.build.ability = "" }
                board.note("\(farName(index))'s ability was suppressed.")
            }
            return
        }

        // Corrosive Gas takes everybody's item; Teatime makes everybody eat.
        if move.name == "Corrosive Gas" {
            var taken: [String] = []
            for index in board.mine.indices.prefix(board.activeCount)
            where !board.mine[index].fainted && !board.mine[index].build.item.isEmpty {
                taken.append(board.mine[index].build.form.formLabel)
                board.mine[index].build.item = ""
            }
            for index in board.theirs.indices.prefix(board.activeCount)
            where !board.theirs[index].fainted && !board.theirs[index].build.item.isEmpty {
                taken.append(board.theirs[index].build.form.formLabel)
                board.theirs[index].build.item = ""
            }
            board.note(taken.isEmpty ? "But nobody was holding anything."
                                     : "The gas took \(taken.joined(separator: ", "))'s items.")
            return
        }

        // Reflect Type and Magic Powder rewrite a typing.
        if move.name == "Reflect Type" || move.name == "Magic Powder" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            if move.name == "Magic Powder" {
                setFar(index) { $0.build.typeOverride = [.psychic] }
                board.note("\(farName(index)) became a Psychic type.")
            } else {
                let far = byMine ? board.theirs : board.mine
                let copied = far[index].types
                setNear { $0.build.typeOverride = copied }
                board.note("\(name) took on \(farName(index))'s typing.")
            }
            return
        }

        // Speed Swap and Power Trick move a stat rather than a stage.
        if move.name == "Speed Swap" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let far = byMine ? board.theirs : board.mine
            let ours = team[slot].build.stat(.speed), theirs = far[index].build.stat(.speed)
            setNear { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.speed.rawValue: theirs]) { _, new in new } }
            setFar(index) { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.speed.rawValue: ours]) { _, new in new } }
            board.note("\(name) and \(farName(index)) swapped Speed.")
            return
        }
        if move.name == "Power Trick" {
            let attack = team[slot].build.stat(.attack)
            let defense = team[slot].build.stat(.defense)
            setNear { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.attack.rawValue: defense,
                          Stat.defense.rawValue: attack]) { _, new in new } }
            board.note("\(name) swapped its Attack and Defense.")
            return
        }

        // Decorate and Aromatic Mist pay the partner.
        if move.name == "Decorate" || move.name == "Aromatic Mist" {
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to help."); return
            }
            let paid: [Stat: Int] = move.name == "Decorate" ? [.attack: 2, .spAttack: 2]
                                                            : [.spDefense: 1]
            StatChanges.applySelf(paid, toMine: byMine, slot: partner, board: &board)
            return
        }

        // Clangorous Soul spends a third of the bar to raise everything.
        if move.name == "Clangorous Soul" {
            let cost = team[slot].maxHP / 3
            guard team[slot].hp > cost else { board.note("But it failed."); return }
            setNear { $0.hp -= cost }
            StatChanges.applySelf([.attack: 1, .defense: 1, .spAttack: 1, .spDefense: 1, .speed: 1],
                      toMine: byMine, slot: slot, board: &board)
            return
        }

        // Acupressure raises one stat, chosen at random, by two.
        if move.name == "Acupressure" {
            let stats: [Stat] = [.attack, .defense, .spAttack, .spDefense, .speed]
            let picked = rolling ? (stats.randomElement(using: &TurnModel.dice) ?? .attack) : .attack
            StatChanges.applySelf([picked: 2], toMine: byMine, slot: slot, board: &board)
            return
        }

        // Heal Bell clears the whole side, bench included.
        if move.name == "Heal Bell" || move.name == "Aromatherapy" {
            var cured = 0
            for index in (byMine ? board.mine : board.theirs).indices {
                let carrying = (byMine ? board.mine : board.theirs)[index].status != .none
                guard carrying else { continue }
                if byMine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                cured += 1
            }
            board.note(cured == 0 ? "But nobody was ill."
                                  : "A bell rang and cleared \(cured) of them up.")
            return
        }

        // Recycle brings back what it ate; Stuff Cheeks eats it now and takes
        // two stages of Defense for it; Teatime makes everybody eat at once.
        if move.name == "Recycle" {
            guard team[slot].build.itemSpent, !team[slot].build.item.isEmpty else {
                board.note("But it failed."); return
            }
            setNear { $0.build.itemSpent = false }
            board.note("\(name) found its \(team[slot].build.item) again.")
            return
        }
        if move.name == "Stuff Cheeks" {
            guard team[slot].build.item.hasSuffix("Berry"), !team[slot].build.itemSpent else {
                board.note("But it failed."); return
            }
            setNear { $0.build.itemSpent = true
                      $0.hp = Swift.min($0.maxHP, $0.hp + $0.maxHP / 4) }
            StatChanges.applySelf([.defense: 2], toMine: byMine, slot: slot, board: &board)
            board.note("\(name) stuffed its cheeks with its \(team[slot].build.item).")
            return
        }
        if move.name == "Teatime" {
            var ate: [String] = []
            for side in [true, false] {
                let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
                for index in 0..<count {
                    let who = side ? board.mine[index] : board.theirs[index]
                    guard !who.fainted, who.build.item.hasSuffix("Berry"),
                          !who.build.itemSpent else { continue }
                    if side {
                        board.mine[index].build.itemSpent = true
                        board.mine[index].hp = Swift.min(who.maxHP, who.hp + who.maxHP / 4)
                    } else {
                        board.theirs[index].build.itemSpent = true
                        board.theirs[index].hp = Swift.min(who.maxHP, who.hp + who.maxHP / 4)
                    }
                    ate.append(who.build.form.formLabel)
                }
            }
            board.note(ate.isEmpty ? "But nobody had a berry."
                                   : "Teatime: \(ate.joined(separator: ", ")) ate up.")
            return
        }

        // Forest's Curse and Trick-or-Treat add a type rather than replace one.
        if move.name == "Forest's Curse" || move.name == "Trick-or-Treat" {
            guard let index = reachableTarget() else { board.note("But it failed."); return }
            let added: PokeType = move.name == "Forest's Curse" ? .grass : .ghost
            let far = byMine ? board.theirs : board.mine
            guard !far[index].types.contains(added) else { board.note("But it failed."); return }
            let now = far[index].types + [added]
            setFar(index) { $0.build.typeOverride = now }
            board.note("\(farName(index)) became part \(added.rawValue).")
            return
        }

        // Ingrain roots it: health back every turn, and it cannot leave.
        if move.name == "Ingrain" {
            guard !team[slot].aquaRing || !team[slot].cannotEscape else {
                board.note("But it failed."); return
            }
            setNear { $0.aquaRing = true; $0.cannotEscape = true }
            board.note("\(name) planted its roots.")
            return
        }

        // Fairy Lock holds everybody in place.
        if move.name == "Fairy Lock" {
            for index in board.mine.indices.prefix(board.activeCount) {
                board.mine[index].cannotEscape = true
            }
            for index in board.theirs.indices.prefix(board.activeCount) {
                board.theirs[index].cannotEscape = true
            }
            board.note("Nobody can leave the field.")
            return
        }

        // Magnetic Flux pays whichever of its side is carrying Plus or Minus.
        if move.name == "Magnetic Flux" {
            let pairing: Set<String> = ["Plus", "Minus"]
            var paid = 0
            for index in (byMine ? board.mine : board.theirs).indices.prefix(board.activeCount) {
                let who = (byMine ? board.mine : board.theirs)[index]
                guard !who.fainted, pairing.contains(who.build.ability) else { continue }
                StatChanges.applySelf([.defense: 1, .spDefense: 1], toMine: byMine, slot: index, board: &board)
                paid += 1
            }
            if paid == 0 { board.note("But nobody was carrying Plus or Minus.") }
            return
        }

        // Chilly Reception puts snow up and leaves, which is the joke and also
        // a very good pivot.
        if move.name == "Chilly Reception" {
            let before = board.field
            board.field.weather = .snow
            board.weatherTurns = 5
            board.fieldSettled(from: before)
            board.note("\(name) told a terrible joke, and it began to snow.")
            Switching.leave(byMine: byMine, slot: slot, board: &board)
            return
        }

        // Howl boosts the whole side, not just the user. Matched on the
        // sentence rather than the name, and deliberately narrow: Coaching and
        // Gear Up read as "the user's allies" without the user, and are
        // already handled as ally-targeted moves further down.
        if move.effect.contains("of the user and its allies"), !move.selfBoosts.isEmpty {
            let boosts = move.selfBoosts
            let partner = slot == 0 ? 1 : 0
            StatChanges.applySelf(boosts, toMine: byMine, slot: slot, board: &board)
            let own = byMine ? board.mine : board.theirs
            if board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted {
                StatChanges.applySelf(boosts, toMine: byMine, slot: partner, board: &board)
            }
            return
        }

        // Ally Switch: the two of yours trade places, which is how a Pokémon
        // steps out of the way of something aimed at where it was standing.
        // Like Protect, doing it again is a third as likely to work.
        if move.name == "Ally Switch" {
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to switch with.")
                return
            }
            let chance = pow(1.0 / 3.0, Double(own[slot].switchStreak))
            guard rolling ? Double.random(in: 0..<1, using: &TurnModel.dice) < chance : chance >= 0.5 else {
                if byMine { board.mine[slot].switchStreak = 0 } else { board.theirs[slot].switchStreak = 0 }
                board.note("But it failed — \(Int((chance * 100).rounded()))% after using it last turn.")
                return
            }
            if byMine {
                board.mine.swapAt(slot, partner)
                board.mine[partner].switchStreak += 1
            } else {
                board.theirs.swapAt(slot, partner)
                board.theirs[partner].switchStreak += 1
            }
            board.note("\(name) and \(own[partner].build.form.formLabel) traded places.")
            return
        }

        // Encore: the target repeats whatever it last used for its next three
        // turns. It fails on a Pokémon that has not moved yet, and cannot hold
        // one to an Encore of its own.
        if move.name == "Encore" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return }
            guard let last = far[index].lastMove, far[index].moves.indices.contains(last),
                  far[index].moves[last].name != "Encore" else {
                board.note("But \(who) had nothing to repeat.")
                return
            }
            if byMine { board.theirs[index].encoredFor = 3 } else { board.mine[index].encoredFor = 3 }
            board.note("\(who) received an Encore: it has to keep using \(far[index].moves[last].name).")
            return
        }

        // Confuse Ray, Swagger, Flatter: aimed across the field, and the raise
        // Swagger hands over comes with the confusion that makes it a trap.
        if move.confuses {
            let far = byMine ? board.theirs : board.mine
            let everyone = move.effect.lowercased().contains("confuses all other")
            let hits = everyone
                ? Array(0..<Swift.min(board.activeCount, far.count))
                : [far.indices.contains(target) && target < board.activeCount ? target
                   : (0..<Swift.min(board.activeCount, far.count)).first { !far[$0].fainted } ?? 0]
            for index in hits where far.indices.contains(index) && !far[index].fainted {
                if far[index].isProtected {
                    board.note("\(far[index].build.form.formLabel) protected itself.")
                    continue
                }
                StatChanges.applySelf(move.targetBoosts, toMine: !byMine, slot: index, board: &board)
                Ailments.confuse(onMine: !byMine, slot: index, board: &board, rolling: rolling, chance: 100)
            }
            return
        }

        // Revival Blessing: the target is one of the user's own fallen, not
        // anything across the field. It comes back to the bench at half.
        if move.aim == .party {
            let bench = (board.activeCount..<team.count)
            let chosen = bench.contains(target) && team[target].fainted
                ? target : bench.first { team[$0].fainted }
            guard let chosen else {
                board.note("But nobody on \(byMine ? "your" : "their") side had fainted.")
                return
            }
            let half = Swift.max(1, team[chosen].maxHP / 2)
            if byMine {
                board.mine[chosen].hp = half; board.mine[chosen].status = .none
            } else {
                board.theirs[chosen].hp = half; board.theirs[chosen].status = .none
            }
            board.note("\(team[chosen].build.form.formLabel) was revived to half its health.")
            return
        }

        // Protect and its family arrive here whenever the move was picked as a
        // move rather than through the dedicated choice, which is how the
        // interface offers it and how the search sometimes picks it.
        if Move.protectMoves.contains(move.name) {
            Protection.tryProtect(nil, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            return
        }

        switch move.name {
        case "Tailwind":
            if byMine { board.myTailwind = 4 } else { board.theirTailwind = 4 }
            board.note("The wind picked up behind \(byMine ? "you" : "them").")
            return
        case "Trick Room":
            board.trickRoom = board.trickRoom > 0 ? 0 : 5
            board.note(board.trickRoom > 0
                               ? "The dimensions twisted." : "The twisted dimensions returned.")
            return
        case "Follow Me", "Rage Powder":
            if byMine { board.mine[slot].drawingFire = true }
            else { board.theirs[slot].drawingFire = true }
            board.note("\(name) drew attention to itself.")
            return
        case "Wide Guard":
            if byMine { board.myScreens.wideGuard = true }
            else { board.theirScreens.wideGuard = true }
            board.note("A wide barrier went up.")
            return
        case "Quick Guard":
            if byMine { board.myScreens.quickGuard = true }
            else { board.theirScreens.quickGuard = true }
            board.note("A quick barrier went up.")
            return
        case "Coaching":
            // The partner's Attack and Defence, which is what makes it a
            // doubles move rather than a wasted turn.
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to coach.")
                return
            }
            StatChanges.applySelf([.attack: 1, .defense: 1], toMine: byMine, slot: partner, board: &board)
            return
        case "Focus Energy", "Dragon Cheer":
            // Focus Energy is the user's own; Dragon Cheer is the partner's,
            // and worth twice as much to a Dragon.
            if move.name == "Focus Energy" {
                if byMine { board.mine[slot].critStage += 2 } else { board.theirs[slot].critStage += 2 }
                board.note("\(name) is getting fired up.")
            } else {
                let partner = slot == 0 ? 1 : 0
                let own = byMine ? board.mine : board.theirs
                guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                    board.note("But there was no one to cheer for.")
                    return
                }
                let dragon = own[partner].build.form.pokeTypes.contains(.dragon) ? 2 : 1
                if byMine { board.mine[partner].critStage += dragon }
                else { board.theirs[partner].critStage += dragon }
                board.note("\(own[partner].build.form.formLabel) was cheered on.")
            }
            return
        case "Endure":
            if byMine { board.mine[slot].enduring = true } else { board.theirs[slot].enduring = true }
            board.note("\(name) braced to survive whatever comes.")
            return
        case "Leech Seed":
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return }
            if far[index].build.form.pokeTypes.contains(.grass) {
                board.note("\(who) is a Grass type; the seed found nowhere to take hold.")
                return
            }
            if far[index].seededFrom != nil { board.note("\(who) is already seeded."); return }
            if byMine { board.theirs[index].seededFrom = slot } else { board.mine[index].seededFrom = slot }
            board.note("\(who) was seeded.")
            return
        case "Taunt":
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return }
            if far[index].build.ability == "Oblivious" || far[index].build.ability == "Aroma Veil" {
                board.note("\(who)'s \(far[index].build.ability) ignored it.")
                return
            }
            if byMine { board.theirs[index].tauntedFor = 3 } else { board.mine[index].tauntedFor = 3 }
            board.note("\(who) was taunted: nothing but attacks for three turns.")
            return
        case "Reflect", "Light Screen", "Aurora Veil":
            // A Light Clay lengthens all three, not just Reflect. It was only
            // being read for Reflect, so a Light Clay Light Screen — which is
            // most of them — quietly ran the standard five turns.
            let turns = team[slot].build.item == "Light Clay" ? 8 : 5
            if byMine {
                switch move.name {
                case "Reflect":      board.myScreens.reflect = turns
                case "Light Screen": board.myScreens.lightScreen = turns
                default:             board.myScreens.auroraVeil = turns
                }
            } else {
                switch move.name {
                case "Reflect":      board.theirScreens.reflect = turns
                case "Light Screen": board.theirScreens.lightScreen = turns
                default:             board.theirScreens.auroraVeil = turns
                }
            }
            board.note("\(move.name) went up for \(turns) turns.")
            return
        case "Helping Hand":
            // Half again on the partner's move this turn, and nothing after it.
            //
            // This used to raise the partner's Attack and Special Attack by a
            // stage instead, on the reasoning that the partner may already have
            // moved and a stat change is at least visible. That was wrong twice
            // over: a stage is 50% of the *stat* rather than of the move's
            // power, so it compounds differently with screens and items, and a
            // stage does not go away at the end of the turn. A Helping Hand
            // that leaves its partner permanently stronger is a different move.
            let ally = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(ally), !own[ally].fainted else {
                board.note("But there was no one to help.")
                return
            }
            if byMine { board.mine[ally].helped = true } else { board.theirs[ally].helped = true }
            board.note("\(name) lent \(own[ally].build.form.formLabel) a hand.")
            return
        default:
            break
        }

        // Weather and terrain, which any of several moves set.
        if let weather: Weather = ["Sunny Day": .sun, "Rain Dance": .rain,
                                   "Sandstorm": .sand, "Snowscape": .snow][move.name] {
            let before = board.field
            board.field.weather = weather
            board.fieldSettled(from: before)
            // Setting what is already up does not restart the clock; in the
            // game the move simply fails.
            if before.weather == weather { board.note("But the \(weather.rawValue.lowercased()) was already up.") }
            else { board.note("The weather turned to \(weather.rawValue.lowercased()) for five turns.") }
            return
        }
        if let terrain: Terrain = ["Grassy Terrain": .grassy, "Electric Terrain": .electric,
                                   "Misty Terrain": .misty,
                                   "Psychic Terrain": .psychic][move.name] {
            let before = board.field
            board.field.terrain = terrain
            board.fieldSettled(from: before)
            board.terrainSeeds()
            if before.terrain == terrain { board.note("But the terrain was already \(terrain.rawValue.lowercased()).") }
            else { board.note("\(terrain.rawValue) Terrain covered the field for five turns.") }
            return
        }

        // Anything that says it lowers a stat, or raises one of the user's.
        let drops = move.targetDrops
        if !drops.isEmpty {
            let spread = move.isSpread
            for index in (spread ? [0, 1] : [target]) {
                let defending = byMine ? board.theirs : board.mine
                guard defending.indices.contains(index), !defending[index].fainted,
                      !defending[index].isProtected else { continue }
                StatChanges.applyDrops(drops, toMine: !byMine, slot: index, board: &board)
            }
            return
        }
        if !move.selfBoosts.isEmpty {
            StatChanges.applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
            return
        }

        // And the conditions, which are worth a move slot precisely because
        // they last.
        let ailment: Ailment? = move.effect.hasPrefix("Burns the target") ? .burn
            : move.effect.hasPrefix("Paralyzes the target") ? .paralysis
            : move.effect.hasPrefix("Puts the target to sleep") ? .sleep
            : move.effect.hasPrefix("Poisons the target") ? .poison
            : move.effect.hasPrefix("Badly poisons the target") ? .badPoison : nil
        if let ailment {
            let defending = byMine ? board.theirs : board.mine
            guard defending.indices.contains(target), !defending[target].fainted,
                  !defending[target].isProtected,
                  defending[target].status == .none else {
                board.note("It had no effect.")
                return
            }
            let victim = defending[target]
            let immune: Bool
            switch ailment {
            case .burn: immune = victim.types.contains(.fire)
                || ["Water Veil", "Water Bubble", "Thermal Exchange"].contains(victim.build.ability)
            case .paralysis: immune = victim.types.contains(.electric)
                || ["Limber"].contains(victim.build.ability)
            case .poison, .badPoison:
                let corrodes = team[slot].build.ability == "Corrosion"
                immune = (!corrodes && victim.types.contains(where: { [.poison, .steel].contains($0) }))
                    || ["Immunity"].contains(victim.build.ability)
            case .sleep: immune = ["Insomnia", "Vital Spirit"].contains(victim.build.ability)
                || (board.field.terrain == .electric && victim.isGrounded)
            default: immune = false
            }
            if immune {
                board.note("\(victim.build.form.formLabel) is not affected.")
                return
            }
            if (byMine ? board.theirScreens : board.myScreens).safeguard > 0 {
                board.note("The veil kept \(victim.build.form.formLabel) safe.")
                return
            }
            if let refused = Ailments.refusesStatus(ailment, onMine: !byMine, slot: target, board: board) {
                board.note("\(victim.build.form.formLabel)'s \(refused) refused it.")
                return
            }
            if byMine {
                board.theirs[target].status = ailment
                if ailment == .sleep { board.theirs[target].asleepFor = rolling
                    ? Int.random(in: 1...3, using: &TurnModel.dice) : 2 }
            } else {
                board.mine[target].status = ailment
                if ailment == .sleep { board.mine[target].asleepFor = rolling
                    ? Int.random(in: 1...3, using: &TurnModel.dice) : 2 }
            }
            board.note("\(victim.build.form.formLabel) is \(ailment.rawValue).")
            // Synchronize hands the condition straight back. It was wired to
            // the secondary effects of attacks only, so a Will-O-Wisp — the
            // most common way anything gets burned — went one way.
            Ailments.synchronize(ailment, from: !byMine, slot: target, onto: byMine, slot: slot, board: &board)
            return
        }
        board.note("Nothing came of it.")
    }

    /// The non-damaging moves that end the user's game: Memento, Healing Wish.
    private static func selfKO(_ move: Move, byMine: Bool, slot: Int,
                               board: inout Board) {
        guard move.effect.contains("The user faints") else { return }
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        // Damp refuses an explosion from anywhere on the field, including one
        // its own side set off.
        if let damp = (board.mine + board.theirs).prefix(board.activeCount * 2).first(where: {
            !$0.fainted && ["Damp"].contains($0.build.ability)
        }) {
            board.note("\(damp.build.form.formLabel)'s Damp stopped it going off.")
            return
        }
        if byMine { board.mine[slot].hp = 0 } else { board.theirs[slot].hp = 0 }
        board.note("\(team[slot].build.form.formLabel) fainted using \(move.name).")
    }
}
