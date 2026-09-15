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
    /// It came in this turn, which is what makes Fake Out legal.
    var justArrived = true
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
    /// The types it actually has right now, which is not always what the dex
    /// says: Soak makes its target a pure Water type.
    var types: [PokeType] { build.effectiveTypes }
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
        let hidden = myUnseenBench
        guard !hidden.isEmpty, let guess = liveGuesses(mine: true).first else { return self }
        let shown = Set(mine.filter(\.seen).map(\.build.form.id))
        let arriving = guess.fighters.filter { !shown.contains($0.build.form.id) }
        guard !arriving.isEmpty else { return self }
        var out = self
        for (slot, fighter) in zip(hidden, arriving) { out.mine[slot] = fighter }
        return out
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
    struct Step: Identifiable {
        let id = UUID()
        let text: String
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

    /// Start collecting the lines of one action into one step.
    mutating func beginStep() {
        closeStep()
        gathering = []
    }

    /// Close the step being gathered, if it said anything.
    mutating func closeStep() {
        if let lines = gathering, !lines.isEmpty {
            steps.append(snapshot(lines.joined(separator: "\n")))
        }
        gathering = nil
    }

    private func snapshot(_ text: String) -> Step {
        Step(text: text,
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
    mutating func takeHazards(mine side: Bool, slot: Int) {
        let field = side ? myScreens : theirScreens
        guard field.spikes > 0 || field.toxicSpikes > 0 || field.stealthRock else { return }
        var who = side ? mine[slot] : theirs[slot]
        guard !who.fainted else { return }
        let name = who.build.form.formLabel
        let grounded = !who.types.contains(.flying) && who.build.ability != "Levitate"
            && who.build.item != "Air Balloon"

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
            mine[slot].seen = true
            mine[slot].isProtected = false
            mine[slot].lastMoveFailed = false
            if let said = TurnModel.entryAbility(of: mine[slot].build.ability, team: &mine,
                                                 slot: slot, opposing: &theirs, field: &field) {
                note(said)
            }
        } else {
            theirs[slot].justArrived = true
            theirs[slot].seen = true
            theirs[slot].isProtected = false
            theirs[slot].lastMoveFailed = false
            if let said = TurnModel.entryAbility(of: theirs[slot].build.ability, team: &theirs,
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
    var gapsOfMine: [Int] {
        (0..<min(activeCount, mine.count)).filter { slot in
            mine[slot].fainted
                && (activeCount..<mine.count).contains { !mine[$0].fainted }
        }
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

    /// What a board is worth to the side that owns `mine`.
    ///
    /// Deliberately simple, and zero-sum by construction so the matrix has an
    /// equilibrium. Staying alive is worth a lot more than the last third of a
    /// health bar: a Pokémon on one point still gets to act, still threatens,
    /// still has to be answered, and a model that values only health throws
    /// bodies away for chip damage.
    static func value(_ board: Board) -> Double {
        func side(_ team: [Fighter]) -> Double {
            team.reduce(0) { total, fighter in
                total + (fighter.fainted ? 0 : 0.35 + 0.65 * fighter.share)
            }
        }
        var out = side(board.mine) - side(board.theirs)
        out += speedControl(board.myTailwind, under: board.trickRoom)
            - speedControl(board.theirTailwind, under: board.trickRoom)
        return out
    }

    /// What a Tailwind is worth, given what the room is doing.
    ///
    /// Speed control is a real asset and the turn that sets it looks wasted
    /// without saying so. But a Tailwind under a Trick Room is not an asset at
    /// all — the room reverses the order, so doubling your Speed makes you
    /// move *later*. The engine used to count it as a flat gain either way and
    /// would cheerfully put a Tailwind up into a Trick Room that had four
    /// turns left on it, which no player would do.
    ///
    /// Counted turn by turn: the turns the Tailwind runs inside the room are
    /// worth what the turns outside it are worth, with the sign reversed. A
    /// Trick Room with one turn left and a four-turn Tailwind comes out
    /// positive, which is exactly when somebody would actually set it.
    private static func speedControl(_ tailwind: Int, under trickRoom: Int) -> Double {
        guard tailwind > 0 else { return 0 }
        let reversed = Swift.min(tailwind, trickRoom)
        let ordinary = Swift.max(0, tailwind - trickRoom)
        return Double(ordinary - reversed) * 0.12
    }

    /// Quick Claw: a fifth of the time the holder goes first regardless.
    /// Rolled once per turn per holder, when the turn is played; the search
    /// never counts on it, the way it never counts on a second Protect.
    private static func quickClawed(_ fighter: Fighter, mine: Bool, slot: Int,
                                    board: Board, rolling: Bool) -> Bool {
        // Quick Draw is the ability version, three times in ten rather than
        // two, and it rides the same pre-decided flip.
        let odds = fighter.build.ability == "Quick Draw" ? 0.3
            : (fighter.build.item == "Quick Claw" ? 0.2 : 0)
        guard odds > 0 else { return false }
        if rolling { return Double.random(in: 0..<1, using: &TurnModel.dice) < odds }
        return board.rulings[Board.flip("quickclaw", mine, slot)] ?? false
    }

    private static func priority(of choice: Choice, for fighter: Fighter) -> Int {
        switch choice {
        case .pass: return -99
        case .swap: return 6
        case .protectSelf(let index), .attack(let index, _):
            guard fighter.moves.indices.contains(index) else { return 0 }
            let move = fighter.moves[index]
            var priority = move.priority
            // Prankster: a stage on every status move, which is what puts a
            // Whimsicott's Tailwind or Encore ahead of anything without
            // priority of its own — though not ahead of a Fake Out at +3.
            if fighter.build.ability == "Prankster", !move.isDamaging { priority += 1 }
            // Stall always acts last, whatever it is doing.
            if fighter.build.ability == "Stall" { priority -= 7 }
            // Gale Wings: Flying moves first, while the bar is full.
            if fighter.build.ability == "Gale Wings", move.type == "Flying",
               fighter.hp == fighter.maxHP { priority += 1 }
            return priority
        }
    }

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
                                        out.mine[index].drawingFire = false }
        for index in out.theirs.indices { out.theirs[index].isProtected = false
                                          out.theirs[index].flinched = false
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
            let grounded = !who.types.contains(.flying) && who.build.ability != "Levitate"
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
                            speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, choice) in theirChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.theirs.indices.contains(slot), out.theirs.indices.contains(bench),
                  !out.theirs[bench].fainted, !out.theirs[slot].fainted,
                  out.theirs[slot].charging == nil,
                  !heldInPlace(out.theirs[slot], by: out.mine, board: out) else { continue }
            leaving.append((false, slot, bench,
                            speed(of: out.theirs[slot], tailwind: out.theirTailwind > 0, board: out)))
        }
        let inverted = out.trickRoom > 0
        leaving.sort { a, b in
            if a.speed != b.speed { return inverted ? a.speed < b.speed : a.speed > b.speed }
            return a.mine && !b.mine
        }
        for entry in leaving {
            out.beginStep()
            if entry.mine {
                out.note("You switched \(out.mine[entry.slot].build.form.formLabel) out for \(out.mine[entry.bench].build.form.formLabel).")
                let said = swapIn(mine: true, active: entry.slot, bench: entry.bench, board: &out)
                if let said { out.note(said) }
            } else {
                out.note("They switched \(out.theirs[entry.slot].build.form.formLabel) out for \(out.theirs[entry.bench].build.form.formLabel).")
                let said = swapIn(mine: false, active: entry.slot, bench: entry.bench, board: &out)
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
            evolving.append((true, slot, speed(of: out.mine[slot],
                                               tailwind: out.myTailwind > 0, board: out)))
        }
        if let slot = theirs.megaSlot, out.theirs.indices.contains(slot),
           slot < out.activeCount, out.theirs[slot].pendingMega != nil,
           !(slot == 0 ? theirs.left : theirs.right).isSwap,
           !out.theirs[slot].fainted, !out.theirs.contains(where: \.hasMegaEvolved) {
            evolving.append((false, slot, speed(of: out.theirs[slot],
                                                tailwind: out.theirTailwind > 0, board: out)))
        }
        // Trick Room does not invert this: Mega Evolution is worked out on raw
        // Speed regardless of what is on the field.
        for entry in evolving.sorted(by: { $0.speed > $1.speed }) {
            let before = out.field
            if entry.mine {
                megaEvolve(&out.mine, slot: entry.slot, opposing: &out.theirs,
                           field: &out.field)
            } else {
                megaEvolve(&out.theirs, slot: entry.slot, opposing: &out.mine,
                           field: &out.field)
            }
            out.fieldSettled(from: before)
        }

        // -- everything else, in order ---------------------------------------
        // A Pokémon halfway through a two-turn move has no choice this turn:
        // it fires, whatever it was asked to do.
        func forced(_ fighter: Fighter, _ choice: Choice) -> Choice {
            if let charging = fighter.charging {
                return .attack(move: charging, target: fighter.chargingTarget)
            }
            // Encore: the move it used last, three turns running.
            if let encored = fighter.encored { return encored }
            return choice
        }
        var entries: [(mine: Bool, slot: Int, choice: Choice, priority: Int, speed: Int)] = []
        for (slot, given) in myChoices.enumerated() {
            guard out.mine.indices.contains(slot), !out.mine[slot].fainted else { continue }
            let choice = forced(out.mine[slot], given)
            guard !choice.isSwap else { continue }
            var bracket = priority(of: choice, for: out.mine[slot])
            if quickClawed(out.mine[slot], mine: true, slot: slot, board: out, rolling: rolling) {
                bracket += 1
                out.note("\(out.mine[slot].build.form.formLabel)'s Quick Claw let it move first.")
            }
            entries.append((true, slot, choice, bracket,
                            speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, given) in theirChoices.enumerated() {
            guard out.theirs.indices.contains(slot), !out.theirs[slot].fainted else { continue }
            let choice = forced(out.theirs[slot], given)
            guard !choice.isSwap else { continue }
            var bracket = priority(of: choice, for: out.theirs[slot])
            if quickClawed(out.theirs[slot], mine: false, slot: slot, board: out, rolling: rolling) {
                bracket += 1
                out.note("\(out.theirs[slot].build.form.formLabel)'s Quick Claw let it move first.")
            }
            entries.append((false, slot, choice, bracket,
                            speed(of: out.theirs[slot], tailwind: out.theirTailwind > 0, board: out)))
        }

        // Chosen one at a time rather than sorted once, because Speed is
        // re-checked before every action and things change mid-turn. A
        // Prankster Whimsicott putting up Tailwind goes first on priority, and
        // its partner — who has not moved yet — is twice as fast from that
        // moment, which can move it ahead of something it was behind. Sorting
        // the whole turn up front makes that impossible.
        // What everyone is about to do, before anyone does it.
        for entry in entries {
            out.declared[(entry.mine ? "m" : "t") + "\(entry.slot)"] = entry.choice
        }

        var pending = entries
        while !pending.isEmpty {
            let inverted = out.trickRoom > 0
            var choice = 0
            typealias Entry = (mine: Bool, slot: Int, choice: Choice, priority: Int, speed: Int)
            func jumpsQueue(_ e: Entry) -> Bool {
                let team = e.mine ? out.mine : out.theirs
                return team.indices.contains(e.slot) && team[e.slot].goesNext
            }
            func sentToTheBack(_ e: Entry) -> Bool {
                let team = e.mine ? out.mine : out.theirs
                return team.indices.contains(e.slot) && team[e.slot].goesLast
            }
            for index in pending.indices.dropFirst() {
                let a = pending[index], b = pending[choice]
                // After You beats priority and Speed both: the whole move is
                // that the target acts next, whatever it was going to do.
                if jumpsQueue(a) != jumpsQueue(b) { if jumpsQueue(a) { choice = index }; continue }
                // Quash is the same in reverse, and loses to everything.
                if sentToTheBack(a) != sentToTheBack(b) {
                    if sentToTheBack(b) { choice = index }; continue
                }
                if a.priority != b.priority { if a.priority > b.priority { choice = index }; continue }
                let aSpeed = current(a, board: out), bSpeed = current(b, board: out)
                if aSpeed != bSpeed {
                    if inverted ? aSpeed < bSpeed : aSpeed > bSpeed { choice = index }
                    continue
                }
                // A genuine tie is a coin flip in the game. Resolved the same
                // way every time here so a search is reproducible.
                if a.mine && !b.mine { choice = index }
            }
            let entry = pending.remove(at: choice)
            // One action, one step: whatever it does to however many. What it
            // is held to is checked now, not when the turn was queued: an
            // Encore that landed a moment ago already applies.
            let actor = (entry.mine ? out.mine : out.theirs)[entry.slot]
            if entry.mine { out.mine[entry.slot].goesNext = false; out.mine[entry.slot].goesLast = false }
            else { out.theirs[entry.slot].goesNext = false; out.theirs[entry.slot].goesLast = false }
            out.acted.insert((entry.mine ? "m" : "t") + "\(entry.slot)")
            out.beginStep()
            apply(forced(actor, entry.choice), byMine: entry.mine, slot: entry.slot, to: &out, rolling: rolling)
            out.closeStep()
        }

        // The residuals together, since they land together.
        out.beginStep()
        endOfTurn(&out, rolling: rolling)
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

    /// Everything that happens after both sides have acted.
    ///
    /// Weather chips, berries and Leftovers fire, burn and poison take their
    /// cut, and the clocks tick. None of it existed: a sandstorm did nothing, a
    /// Sitrus Berry never healed, a Focus Sash worked every turn for ever
    /// because nothing ever marked it as used.
    private static func endOfTurn(_ board: inout Board, rolling: Bool) {
        // Written against the board rather than against a borrowed array: the
        // running commentary needs the whole board to snapshot it, and Swift
        // will not lend out one of its arrays while that is happening.
        func settle(mine: Bool) {
            let count = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
            for index in 0..<count {
                guard !(mine ? board.mine[index] : board.theirs[index]).fainted else { continue }
                let who = mine ? board.mine[index] : board.theirs[index]
                let name = who.build.form.formLabel
                let maxHP = who.maxHP
                let types = who.types
                var hp = who.hp

                // Magic Guard takes nothing it was not hit by; Overcoat is
                // the narrower version that only turns away the weather.
                let shielded = who.build.ability == "Magic Guard"
                if board.field.weather == .sand, !shielded,
                   who.build.ability != "Overcoat", who.build.item != "Safety Goggles",
                   !types.contains(where: { [.rock, .ground, .steel].contains($0) }) {
                    hp -= Swift.max(1, maxHP / 16)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("The sandstorm buffets \(name).")
                }
                if board.field.terrain == .grassy, !types.contains(.flying),
                   who.build.ability != "Levitate", hp < maxHP, hp > 0 {
                    hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("Grassy Terrain tops \(name) up.")
                }
                switch who.status {
                case .burn where !shielded:
                    hp -= Swift.max(1, maxHP / 16)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt by its burn.")
                case .poison where !shielded:
                    hp -= Swift.max(1, maxHP / 8)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt by poison.")
                case .badPoison where !shielded:
                    // A sixteenth more each turn it lasts, which is what makes
                    // Toxic a clock rather than chip damage.
                    let stage = Swift.min(15, who.toxicTurns + 1)
                    if mine { board.mine[index].toxicTurns = stage }
                    else { board.theirs[index].toxicTurns = stage }
                    hp -= Swift.max(1, maxHP * stage / 16)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt badly by poison"
                               + (stage > 1 ? ", worse each turn." : "."))
                default: break
                }
                // Speed Boost: a stage every turn it stays in, which is the
                // whole reason a Blaziken is frightening if it is left alone.
                if who.build.ability == "Speed Boost", hp > 0, !who.justArrived,
                   who.build.boosts[Stat.speed.rawValue] < 6 {
                    change([.speed: 1], onMine: mine, slot: index, board: &board,
                           because: "Speed Boost")
                }
                // Shed Skin: one turn in three it shakes a condition off.
                if who.build.ability == "Shed Skin", hp > 0, who.status != .none,
                   rolling, Double.random(in: 0..<1, using: &TurnModel.dice) < 1.0 / 3.0 {
                    if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                    else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                    board.note("\(name) shed its skin and shook it off.")
                }
                // Moody: one stat up two stages, another down one, chosen at
                // random. A search cannot price a coin flip with six faces, so
                // it takes nothing.
                if who.build.ability == "Moody", hp > 0, rolling {
                    let stats: [Stat] = [.attack, .defense, .spAttack, .spDefense, .speed]
                    if let up = stats.randomElement(using: &TurnModel.dice),
                       let down = stats.filter({ $0 != up }).randomElement(using: &TurnModel.dice) {
                        change([up: 2], onMine: mine, slot: index, board: &board, because: "Moody")
                        change([down: -1], onMine: mine, slot: index, board: &board, because: "Moody")
                    }
                }
                // Mimicry takes the terrain's type while it stands on it.
                if who.build.ability == "Mimicry", hp > 0 {
                    let became: PokeType? = switch board.field.terrain {
                    case .electric: .electric
                    case .grassy:   .grass
                    case .psychic:  .psychic
                    case .misty:    .fairy
                    case .none:     nil
                    }
                    let wanted = became.map { [$0] } ?? []
                    let holds = mine ? board.mine[index].build.typeOverride
                                     : board.theirs[index].build.typeOverride
                    if (holds ?? []) != wanted {
                        if mine { board.mine[index].build.typeOverride = wanted.isEmpty ? nil : wanted }
                        else { board.theirs[index].build.typeOverride = wanted.isEmpty ? nil : wanted }
                        if let became {
                            board.note("\(name)'s Mimicry made it a \(became.rawValue) type.")
                        }
                    }
                }
                // Harvest: in the sun, the berry it ate comes back.
                if who.build.ability == "Harvest", who.build.itemSpent, hp > 0,
                   who.build.item.hasSuffix("Berry"),
                   board.field.weather == .sun
                       || (rolling && Double.random(in: 0..<1, using: &TurnModel.dice) < 0.5) {
                    if mine { board.mine[index].build.itemSpent = false }
                    else { board.theirs[index].build.itemSpent = false }
                    board.note("\(name) harvested another \(who.build.item).")
                }
                // Healer: three in ten that it clears up whatever its partner
                // is carrying.
                if who.build.ability == "Healer", hp > 0, rolling,
                   Double.random(in: 0..<1, using: &TurnModel.dice) < 0.3 {
                    let ally = index == 0 ? 1 : 0
                    let side = mine ? board.mine : board.theirs
                    if side.indices.contains(ally), ally < board.activeCount,
                       !side[ally].fainted, side[ally].status != .none {
                        if mine { board.mine[ally].status = .none; board.mine[ally].asleepFor = 0 }
                        else { board.theirs[ally].status = .none; board.theirs[ally].asleepFor = 0 }
                        board.note("\(name)'s Healer cleared up \(side[ally].build.form.formLabel).")
                    }
                }
                // Hydration does the same, but only in the rain, and always.
                if who.build.ability == "Hydration", hp > 0, who.status != .none,
                   board.field.weather == .rain {
                    if mine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                    else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                    board.note("\(name)'s Hydration washed it off.")
                }
                if who.aquaRing, hp < maxHP, hp > 0 {
                    hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name)'s Aqua Ring restores a little.")
                }
                if who.build.item == "Leftovers", hp < maxHP, hp > 0 {
                    hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) restores a little with its Leftovers.")
                }
                if who.build.item == "Sitrus Berry", !who.build.itemSpent,
                   TurnModel.canEatBerry(mine, slot: index, board: board),
                   // A Sitrus fires at half, which is already the threshold
                   // Gluttony would lower a pinch berry to — and pinch berries
                   // are not modelled separately, so Gluttony has nothing here
                   // to bring forward. It reads as unproven in the audit, which
                   // is the honest answer.
                   hp > 0, hp <= maxHP / 2 {
                    var back = maxHP / 4
                    // Ripen doubles whatever a berry gives.
                    if who.build.ability == "Ripen" { back *= 2 }
                    hp = Swift.min(maxHP, hp + back)
                    // Cheek Pouch is a second helping on top of the berry.
                    if who.build.ability == "Cheek Pouch" {
                        hp = Swift.min(maxHP, hp + maxHP / 3)
                    }
                    if mine {
                        board.mine[index].hp = hp; board.mine[index].build.itemSpent = true
                    } else {
                        board.theirs[index].hp = hp; board.theirs[index].build.itemSpent = true
                    }
                    board.note("\(name) eats its Sitrus Berry."
                               + (who.build.ability == "Cheek Pouch" ? " Its Cheek Pouch gave more back." : ""))
                }
                // A Mental Herb clears whatever is stopping it choosing freely.
                if who.build.item == "Mental Herb", !who.build.itemSpent, hp > 0,
                   who.tauntedFor > 0 || who.encoredFor > 0 {
                    if mine {
                        board.mine[index].tauntedFor = 0; board.mine[index].encoredFor = 0
                        board.mine[index].build.itemSpent = true
                    } else {
                        board.theirs[index].tauntedFor = 0; board.theirs[index].encoredFor = 0
                        board.theirs[index].build.itemSpent = true
                    }
                    board.note("\(name) used its Mental Herb and can choose freely again.")
                }
                // A Lum Berry is eaten the moment anything is wrong.
                if who.build.item == "Lum Berry", !who.build.itemSpent, hp > 0,
                   TurnModel.canEatBerry(mine, slot: index, board: board),
                   who.status != .none || who.isConfused {
                    if mine {
                        board.mine[index].status = .none; board.mine[index].asleepFor = 0
                        board.mine[index].confusedFor = 0; board.mine[index].build.itemSpent = true
                    } else {
                        board.theirs[index].status = .none; board.theirs[index].asleepFor = 0
                        board.theirs[index].confusedFor = 0; board.theirs[index].build.itemSpent = true
                    }
                    board.note("\(name) eats its Lum Berry and shakes it off.")
                }
                // Cud Chew: a Grass-eater brings its berry back up the turn
                // after eating it.
                // Cud Chew brings a berry back up at the end of the turn after
                // it was eaten. Read fresh from the board rather than from
                // `who`, which was copied before this turn's berry was eaten —
                // so the turn it ate one never counted, and the ability paid
                // out one turn late for its whole life.
                let now = mine ? board.mine[index] : board.theirs[index]
                if now.build.ability == "Cud Chew", hp > 0 {
                    if now.chewedOn {
                        if mine { board.mine[index].build.itemSpent = false; board.mine[index].chewedOn = false }
                        else { board.theirs[index].build.itemSpent = false; board.theirs[index].chewedOn = false }
                        board.note("\(name)'s Cud Chew brought its \(now.build.item) back up.")
                    } else if now.build.itemSpent, now.build.item.hasSuffix("Berry") {
                        if mine { board.mine[index].chewedOn = true } else { board.theirs[index].chewedOn = true }
                    }
                }
                if hp <= 0 {
                    if mine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                    board.note("\(name) fainted.")
                }
            }
        }
        settle(mine: true)
        settle(mine: false)

        // A Wish comes down on whoever is standing in the spot now, which is
        // the point of it: the one that made it can be long gone.
        func landWish(mine: Bool) {
            var side = mine ? board.myScreens : board.theirScreens
            guard side.wishTurns > 0 else { return }
            side.wishTurns -= 1
            if side.wishTurns == 0 {
                let amount = side.wishAmount
                side.wishAmount = 0
                let count = Swift.min(board.activeCount, (mine ? board.mine : board.theirs).count)
                for index in 0..<count {
                    let who = mine ? board.mine[index] : board.theirs[index]
                    guard !who.fainted, who.hp < who.maxHP else { continue }
                    let gained = Swift.min(who.maxHP - who.hp, amount)
                    if mine { board.mine[index].hp += gained } else { board.theirs[index].hp += gained }
                    board.note("The wish came true and restored \(gained) to \(who.build.form.formLabel).")
                }
            }
            if mine { board.myScreens = side } else { board.theirScreens = side }
        }
        landWish(mine: true)
        landWish(mine: false)

        board.myTailwind = Swift.max(0, board.myTailwind - 1)
        board.theirTailwind = Swift.max(0, board.theirTailwind - 1)
        board.trickRoom = Swift.max(0, board.trickRoom - 1)
        if board.magicRoom > 0 {
            board.magicRoom -= 1
            if board.magicRoom == 0 { board.note("Magic Room wore off.") }
        }
        if board.wonderRoom > 0 {
            board.wonderRoom -= 1
            if board.wonderRoom == 0 { board.note("Wonder Room wore off.") }
        }
        // Weather and terrain run out. A clock at zero with something up is
        // an analysis board's field, left alone.
        if board.weatherTurns > 0 {
            board.weatherTurns -= 1
            if board.weatherTurns == 0 {
                let ended = board.field.weather
                board.field.weather = .none
                switch ended {
                case .sun: board.note("The sunlight faded.")
                case .rain: board.note("The rain stopped.")
                case .sand: board.note("The sandstorm subsided.")
                case .snow: board.note("The snow stopped.")
                case .none: break
                }
            }
        }
        if board.terrainTurns > 0 {
            board.terrainTurns -= 1
            if board.terrainTurns == 0 {
                let ended = board.field.terrain
                board.field.terrain = .none
                if ended != .none { board.note("The \(ended.rawValue.lowercased()) terrain disappeared.") }
            }
        }
        board.myScreens.tick()
        board.theirScreens.tick()

        // Symbiosis: a partner hands its own item across the moment this one
        // has nothing left to hold.
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let team = side ? board.mine : board.theirs
                let partner = index == 0 ? 1 : 0
                guard team.indices.contains(partner), !team[index].fainted, !team[partner].fainted,
                      team[partner].build.ability == "Symbiosis",
                      team[index].build.itemSpent, !team[partner].build.item.isEmpty,
                      !team[partner].build.itemSpent else { continue }
                let given = team[partner].build.item
                if side {
                    board.mine[index].build.item = given
                    board.mine[index].build.itemSpent = false
                    board.mine[partner].build.item = ""
                } else {
                    board.theirs[index].build.item = given
                    board.theirs[index].build.itemSpent = false
                    board.theirs[partner].build.item = ""
                }
                board.note("\(team[partner].build.form.formLabel)'s Symbiosis passed its \(given) to \(team[index].build.form.formLabel).")
            }
        }

        // Abilities that take something back from the weather, before the
        // seeds take theirs.
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let who = (side ? board.mine : board.theirs)[index]
                guard !who.fainted, who.hp < who.maxHP else { continue }
                let weather = board.field.weather
                let healing = (who.build.ability == "Rain Dish" && weather == .rain)
                    || (who.build.ability == "Ice Body" && weather == .snow)
                    || (who.build.ability == "Dry Skin" && weather == .rain)
                guard healing else { continue }
                let gained = Swift.min(who.maxHP - who.hp, Swift.max(1, who.maxHP / 16))
                if side { board.mine[index].hp += gained } else { board.theirs[index].hp += gained }
                board.note("\(who.build.form.formLabel)'s \(who.build.ability) took \(gained) back from the weather.")
            }
        }

        // Seeds drain across the field, to whoever is standing where the seed
        // was thrown from. A seeded Pokémon that has fainted drains nothing.
        for side in [true, false] {
            let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
            for index in 0..<count {
                let seeded = (side ? board.mine : board.theirs)[index]
                guard let from = seeded.seededFrom, !seeded.fainted else { continue }
                let taken = Swift.max(1, seeded.maxHP / 8)
                let name = seeded.build.form.formLabel
                if side { board.mine[index].hp = Swift.max(0, board.mine[index].hp - taken) }
                else { board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - taken) }
                var line = "\(name) had \(taken) drained by the seed."
                // Back to whoever is standing in the slot it came from.
                let other = side ? board.theirs : board.mine
                if other.indices.contains(from), !other[from].fainted {
                    let healed = Swift.min(other[from].maxHP - other[from].hp, taken)
                    if healed > 0 {
                        if side { board.theirs[from].hp += healed } else { board.mine[from].hp += healed }
                        line += " \(other[from].build.form.formLabel) took it back."
                    }
                }
                board.note(line)
                if (side ? board.mine : board.theirs)[index].fainted {
                    board.note("\(name) fainted.")
                }
            }
        }

        for index in board.mine.indices {
            board.mine[index].protectedLast = board.mine[index].isProtected
            if !board.mine[index].isProtected { board.mine[index].protectStreak = 0 }
            board.mine[index].enduring = false
            if board.mine[index].tauntedFor > 0 {
                board.mine[index].tauntedFor -= 1
                if board.mine[index].tauntedFor == 0 {
                    board.note("\(board.mine[index].build.form.formLabel) shook off the taunt.")
                }
            }
            if board.mine[index].lastMove.map({ board.mine[index].moves.indices.contains($0)
                && board.mine[index].moves[$0].name == "Ally Switch" }) != true {
                board.mine[index].switchStreak = 0
            }
            board.mine[index].justArrived = false
            // A Helping Hand is good for one move, not for the game.
            board.mine[index].helped = false
            if board.mine[index].asleepFor > 0 {
                // Early Bird sleeps through half of it.
                let quick = board.mine[index].build.ability == "Early Bird"
                board.mine[index].asleepFor -= quick ? 2 : 1
                if board.mine[index].asleepFor <= 0 {
                    board.mine[index].asleepFor = 0
                    board.mine[index].status = .none
                }
            }
        }
        for index in board.theirs.indices {
            board.theirs[index].protectedLast = board.theirs[index].isProtected
            if !board.theirs[index].isProtected { board.theirs[index].protectStreak = 0 }
            board.theirs[index].enduring = false
            if board.theirs[index].tauntedFor > 0 {
                board.theirs[index].tauntedFor -= 1
                if board.theirs[index].tauntedFor == 0 {
                    board.note("\(board.theirs[index].build.form.formLabel) shook off the taunt.")
                }
            }
            if board.theirs[index].lastMove.map({ board.theirs[index].moves.indices.contains($0)
                && board.theirs[index].moves[$0].name == "Ally Switch" }) != true {
                board.theirs[index].switchStreak = 0
            }
            board.theirs[index].justArrived = false
            // A Helping Hand is good for one move, not for the game.
            board.theirs[index].helped = false
            if board.theirs[index].asleepFor > 0 {
                // Early Bird sleeps through half of it.
                let quick = board.theirs[index].build.ability == "Early Bird"
                board.theirs[index].asleepFor -= quick ? 2 : 1
                if board.theirs[index].asleepFor <= 0 {
                    board.theirs[index].asleepFor = 0
                    board.theirs[index].status = .none
                }
            }
        }
    }

    /// Turn one Pokémon into its Mega, with whatever that brings with it.
    ///
    /// Only one per side per battle, which is the rule the whole format is
    /// built around, so evolving marks the rest of the team as having spent it.
    private static func megaEvolve(_ team: inout [Fighter], slot: Int,
                                   opposing: inout [Fighter], field: inout Field) {
        guard team.indices.contains(slot), let mega = team[slot].pendingMega,
              !team[slot].hasMegaEvolved,
              !team.contains(where: { $0.hasMegaEvolved }) else { return }
        let before = team[slot].build
        team[slot].build = Combatant(form: mega,
                                     ability: mega.abilities.first?.name ?? before.ability,
                                     item: before.item, sp: before.sp,
                                     alignment: before.alignment)
        team[slot].build.boosts = before.boosts
        team[slot].build.itemSpent = before.itemSpent
        team[slot].pendingMega = nil
        for index in team.indices { team[index].hasMegaEvolved = true }
        entryAbility(of: team[slot].build.ability, team: &team, slot: slot,
                     opposing: &opposing, field: &field)
    }

    /// What arriving — or evolving — does to the field and to the other side.
    /// What arriving does, and a line saying so — nil when the ability does
    /// nothing on the way in. Weather and terrain simply take the field, which
    /// is why the order two setters arrive in decides whose stays.
    @discardableResult
    static func entryAbility(of ability: String, team: inout [Fighter], slot: Int,
                                         opposing: inout [Fighter], field: inout Field) -> String? {
        let name = team.indices.contains(slot) ? team[slot].build.form.formLabel : "It"
        switch ability {
        case "Curious Medicine":
            // Wipes its own side's stat changes on the way in, which is a cost
            // as often as it is a cure.
            var cleared: [String] = []
            for index in team.indices.prefix(2)
            where !team[index].fainted && team[index].build.boosts.contains(where: { $0 != 0 }) {
                team[index].build.boosts = Array(repeating: 0, count: 6)
                cleared.append(team[index].build.form.formLabel)
            }
            guard !cleared.isEmpty else { return nil }
            return "\(name)'s Curious Medicine reset \(cleared.joined(separator: " and "))."
        case "Trace":
            // Takes an ability from across the field, which is why a Gardevoir
            // can walk in and suddenly have Intimidate. Not everything can be
            // copied; the ones that cannot are the ones tied to a particular
            // Pokémon being that Pokémon.
            let untraceable: Set<String> = [
                "Trace", "Illusion", "Multitype", "Stance Change", "Zen Mode",
                "Battle Bond", "Power Construct", "Schooling", "Disguise",
                "Zero to Hero", "Hunger Switch", "Comatose", "Imposter",
                "Neutralizing Gas", "Forecast", "Flower Gift", "Receiver",
            ]
            guard team.indices.contains(slot) else { return nil }
            let taken = opposing.prefix(2).first {
                !$0.fainted && !$0.build.ability.isEmpty
                    && !untraceable.contains($0.build.ability)
            }
            guard let taken else { return nil }
            team[slot].build.ability = taken.build.ability
            return "\(name)'s Trace copied \(taken.build.form.formLabel)'s \(taken.build.ability)."
        case "Intimidate":
            var cut: [String] = [], shrugged: [String] = [], rallied: [String] = []
            for index in opposing.indices.prefix(2) where !opposing[index].fainted {
                let other = opposing[index].build.form.formLabel
                switch opposing[index].build.ability {
                case "Clear Body", "Hyper Cutter", "Inner Focus", "White Smoke",
                     "Full Metal Body", "Own Tempo", "Oblivious", "Scrappy":
                    shrugged.append(other)
                case "Guard Dog", "Contrary":
                    // Turns the drop into a raise.
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.attack.rawValue] + 1)
                    rallied.append("\(other)'s \(opposing[index].build.ability) turned it into a raise")
                case "Defiant":
                    // The drop lands, then Defiant answers with two stages.
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.attack.rawValue] + 1)
                    rallied.append("\(other)'s Defiant answered with two stages of Attack")
                case "Competitive":
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.max(-6, opposing[index].build.boosts[Stat.attack.rawValue] - 1)
                    opposing[index].build.boosts[Stat.spAttack.rawValue] =
                        Swift.min(6, opposing[index].build.boosts[Stat.spAttack.rawValue] + 2)
                    cut.append(other)
                    rallied.append("\(other)'s Competitive answered with two stages of Special Attack")
                default:
                    opposing[index].build.boosts[Stat.attack.rawValue] =
                        Swift.max(-6, opposing[index].build.boosts[Stat.attack.rawValue] - 1)
                    cut.append(other)
                }
            }
            var parts: [String] = []
            if !cut.isEmpty { parts.append("cut \(cut.joined(separator: " and "))'s Attack") }
            if !shrugged.isEmpty { parts.append("\(shrugged.joined(separator: " and ")) shrugged it off") }
            parts += rallied
            var herbs: [String] = []
            for index in opposing.indices.prefix(2) {
                if let herb = whiteHerb(&opposing[index]) { herbs.append(herb) }
            }
            guard !parts.isEmpty else { return nil }
            return "\(name)'s Intimidate " + parts.joined(separator: "; ") + "."
                + (herbs.isEmpty ? "" : " " + herbs.joined(separator: " "))
        case "Drought":
            let same = field.weather == .sun
            field.weather = .sun
            return "\(name)'s Drought " + (same ? "kept the sunlight harsh." : "made the sunlight harsh.")
        case "Drizzle":
            let same = field.weather == .rain
            field.weather = .rain
            return "\(name)'s Drizzle " + (same ? "kept the rain falling." : "made it rain.")
        case "Sand Stream":
            let same = field.weather == .sand
            field.weather = .sand
            return "\(name)'s Sand Stream " + (same ? "kept the sandstorm up." : "whipped up a sandstorm.")
        case "Snow Warning":
            let same = field.weather == .snow
            field.weather = .snow
            return "\(name)'s Snow Warning " + (same ? "kept the snow falling." : "made it snow.")
        case "Hospitality":
            // A quarter of the partner's health, the moment it walks in.
            let partner = slot == 0 ? 1 : 0
            guard team.indices.contains(partner), !team[partner].fainted else { return nil }
            let healed = Swift.min(team[partner].maxHP - team[partner].hp, team[partner].maxHP / 4)
            guard healed > 0 else { return nil }
            team[partner].hp += healed
            return "\(name) brought \(team[partner].build.form.formLabel) \(healed) health."
        case "Electric Surge": field.terrain = .electric; return "\(name)'s Electric Surge charged the field."
        case "Grassy Surge":   field.terrain = .grassy;   return "\(name)'s Grassy Surge grew grass across the field."
        case "Misty Surge":    field.terrain = .misty;    return "\(name)'s Misty Surge covered the field in mist."
        case "Psychic Surge":  field.terrain = .psychic;  return "\(name)'s Psychic Surge made the field feel strange."
        default: return nil
        }
    }

    /// One pending action's Speed, as the board stands right now.
    private static func current(_ entry: (mine: Bool, slot: Int, choice: Choice,
                                          priority: Int, speed: Int),
                                board: Board) -> Int {
        let team = entry.mine ? board.mine : board.theirs
        guard team.indices.contains(entry.slot) else { return entry.speed }
        var value = speed(of: team[entry.slot],
                          tailwind: (entry.mine ? board.myTailwind : board.theirTailwind) > 0,
                          board: board)
        if team[entry.slot].status.halvesSpeed { value /= 2 }
        return value
    }

    private static func speed(of fighter: Fighter, tailwind: Bool, board: Board) -> Int {
        let base = fighter.build.speed(in: board.field)
        return tailwind ? base * 2 : base
    }

    /// Bring a benched Pokémon in, with whatever its entry does.
    ///
    /// Switching is most of competitive doubles and it is not merely a way out.
    /// The Pokémon coming in takes a free hit, because it does not act on the
    /// turn it arrives — that cost is paid by resolving switches first and then
    /// letting the attacks land on whoever is now standing there. And arriving
    /// is itself an action: Intimidate takes an Attack stage off both of them,
    /// and a weather or terrain setter takes the field back, which is why
    /// pivoting a Pelipper back in is a play rather than a retreat.
    /// Written against the board rather than against a borrowed array, because
    /// what walks in has to be charged for the hazards lying on its side of the
    /// field, and those live on the board.
    @discardableResult
    private static func swapIn(mine side: Bool, active: Int, bench: Int,
                               board: inout Board) -> String? {
        var team = side ? board.mine : board.theirs
        var opposing = side ? board.theirs : board.mine
        var field = board.field
        defer {
            if side { board.mine = team; board.theirs = opposing }
            else { board.theirs = team; board.mine = opposing }
            board.field = field
        }
        guard team.indices.contains(active), team.indices.contains(bench),
              !team[bench].fainted else { return nil }
        // Natural Cure: whatever it was carrying is left on the field.
        if team[active].build.ability == "Natural Cure", !team[active].fainted,
           team[active].status != .none {
            team[active].status = .none
            team[active].asleepFor = 0
        }
        // Regenerator heals a third on the way out, which is what makes a
        // Regenerator pivot free where another Pokémon's costs it the chip.
        if team[active].build.ability == "Regenerator", !team[active].fainted {
            team[active].hp = Swift.min(team[active].maxHP,
                                        team[active].hp + team[active].maxHP / 3)
        }
        // Everything the field did to it is left on the field. Stat stages
        // especially: they were surviving a switch, so a Pokémon could set up,
        // pivot out and come back later still at +2.
        team[active].charging = nil
        team[active].hidden = false
        team[active].protectStreak = 0
        team[active].confusedFor = 0
        team[active].encoredFor = 0
        team[active].tauntedFor = 0
        team[active].seededFrom = nil
        team[active].critStage = 0
        team[active].lastMove = nil
        team[active].build.boosts = Array(repeating: 0, count: 6)
        team[active].substitute = 0
        team[active].infatuatedWith = nil
        team[active].tormented = false
        team[active].cannotEscape = false
        team[active].aquaRing = false
        team[active].stockpile = 0
        team[active].build.typeOverride = nil
        team[active].build.statOverride = nil
        team.swapAt(active, bench)
        team[active].justArrived = true
        team[active].seen = true
        team[active].isProtected = false

        let said = entryAbility(of: team[active].build.ability, team: &team, slot: active,
                                opposing: &opposing, field: &field)
        // Hazards bite before the ability speaks, so write the board back now.
        if side { board.mine = team; board.theirs = opposing } else { board.theirs = team; board.mine = opposing }
        board.field = field
        board.takeHazards(mine: side, slot: active)
        team = side ? board.mine : board.theirs
        opposing = side ? board.theirs : board.mine
        field = board.field
        return said
    }

    private static func apply(_ choice: Choice, byMine: Bool, slot: Int,
                              to board: inout Board,
                              rolling: Bool = false) {
        let actor = byMine ? board.mine[slot] : board.theirs[slot]
        guard !actor.fainted else { return }
        let name = actor.build.form.formLabel
        if actor.flinched {
            board.note("\(name) flinched and could not move.")
            dropCharge(byMine: byMine, slot: slot, board: &board)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return
        }
        // Sleep and paralysis cost turns, which is the whole reason they are
        // worth a move slot.
        if actor.status == .sleep {
            board.note("\(name) is fast asleep.")
            dropCharge(byMine: byMine, slot: slot, board: &board)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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
                dropCharge(byMine: byMine, slot: slot, board: &board)
                markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
        }
        if actor.status == .paralysis, rolling, Double.random(in: 0...1, using: &TurnModel.dice) < 0.25 {
            board.note("\(name) is paralysed and cannot move.")
            dropCharge(byMine: byMine, slot: slot, board: &board)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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
                dropCharge(byMine: byMine, slot: slot, board: &board)
                markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
        }
        // Torment: it cannot use the same move twice running, which is what
        // stops something clicking one button all game.
        if actor.tormented, case .attack(let index, _) = choice, actor.lastMove == index {
            board.note("\(name) cannot use the same move twice in a row.")
            dropCharge(byMine: byMine, slot: slot, board: &board)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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
                    dropCharge(byMine: byMine, slot: slot, board: &board)
                    markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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
            remember(byMine: byMine, slot: slot, move: index, target: 0, board: &board)
            let held = tryProtect(label, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: !held)
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            remember(byMine: byMine, slot: slot, move: moveIndex, target: target, board: &board)
            // Taunted: nothing but attacks until it wears off.
            if !move.isDamaging, actor.tauntedFor > 0 {
                board.note("\(name) cannot use \(move.name) — it is still taunted.")
                markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            guard move.isDamaging else {
                let before = board.story.count
                support(move, byMine: byMine, slot: slot, target: target,
                        to: &board, rolling: rolling)
                // A support move that only had "but" to say for itself failed.
                let failed = board.story.dropFirst(before).contains { $0.hasPrefix("But ") || $0.contains("but it failed") }
                markFailed(byMine: byMine, slot: slot, board: &board, failed: failed)
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
                    applySelf(charge.boosts, toMine: byMine, slot: slot, board: &board)
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
                    dropCharge(byMine: byMine, slot: slot, board: &board, quietly: true)
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
                markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            // Quick Guard turns away anything that moves first, which is what
            // a Fake Out team is actually afraid of.
            if move.priority > 0, target < Choice.allyTarget, farScreens.quickGuard {
                board.note("Quick Guard blocked it.")
                markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            // Armor Tail and Queenly Majesty refuse priority outright: nothing
            // with increased priority can be aimed at that Pokémon or its
            // partner. It is the reason Farigiraf is on Trick Room teams — it
            // is what stops a Fake Out taking the setup turn away.
            // Psychic Terrain: nothing quick reaches anything standing on it.
            // It is why a Psychic Surge team can set up in front of a Fake Out.
            if move.priority > 0, target < Choice.allyTarget,
               board.field.terrain == .psychic,
               move.aim == .foe || move.aim == .spread {
                let defenders = byMine ? board.theirs : board.mine
                if let shielded = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    !defenders[$0].fainted && defenders[$0].build.grounded }) {
                    board.note("The Psychic Terrain refused it — \(defenders[shielded].build.form.formLabel) is standing on it, and nothing quick gets through.")
                    markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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
                    markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
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

            var totalDealt = 0
            var reached = 0
            for index in aimed {
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
                   Double.random(in: 0...100, using: &TurnModel.dice) > chanceToHit(move, attacker: actor,
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
                            change(paid, onMine: hitMine, slot: index, board: &board, because: who)
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
                    ? 1.0 : chanceToHit(move, attacker: actor, defender: defending[index],
                                        board: board) / 100
                let oneBlow: Int = rolling
                    ? Int.random(in: Swift.min(result.minDamage, result.maxDamage)
                                 ... Swift.max(result.minDamage, result.maxDamage),
                                 using: &TurnModel.dice)
                    : Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy).rounded())

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
                flee(ifNeeded: index, ofMine: hitMine, wasAt: defending[index].hp,
                     board: &board)
                if move.name == "Fake Out" {
                    flinch(onMine: hitMine, slot: index, board: &board)
                }
                if result.notes.contains(where: { $0.contains("Weakness Policy") }) {
                    applySelf([.attack: 2, .spAttack: 2], toMine: hitMine, slot: index,
                              board: &board)
                    if hitMine { board.mine[index].build.itemSpent = true }
                    else { board.theirs[index].build.itemSpent = true }
                }
                applyDrops(move.targetDrops, toMine: hitMine, slot: index, board: &board)
                secondary(of: move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                          rolling: rolling, board: &board)
                let after = hitMine ? board.mine[index] : board.theirs[index]
                if after.hp == 0 {
                    board.detail("\(hitName) fainted.")
                    // Moxie and its kin take something from the knockout.
                    switch actor.build.ability {
                    case "Moxie", "Chilling Neigh":
                        change([.attack: 1], onMine: byMine, slot: slot, board: &board,
                               because: actor.build.ability)
                    case "Grim Neigh", "Soul-Heart":
                        change([.spAttack: 1], onMine: byMine, slot: slot, board: &board,
                               because: actor.build.ability)
                    case "Beast Boost":
                        // Whichever of its stats is highest, which is the whole
                        // trick of it.
                        let build = actor.build
                        let best = [Stat.attack, .defense, .spAttack, .spDefense, .speed]
                            .max { build.stat($0) < build.stat($1) } ?? .attack
                        change([best: 1], onMine: byMine, slot: slot, board: &board, because: "Beast Boost")
                    default: break
                    }
                }
            }
            // A move that reached nobody failed: missed, blocked, or nothing
            // there to hit. Stomping Tantrum remembers, and a move that hurts
            // its user when it fails hurts its user now — High Jump Kick into
            // a Protect crashes just as it does into thin air.
            markFailed(byMine: byMine, slot: slot, board: &board, failed: reached == 0)
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
            if move.name == "Rapid Spin", sweepOwnHazards(byMine: byMine, board: &board) {
                board.note("\(name) spun the hazards away from its own side.")
            }
            applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
            // What the move takes off its user: Close Combat's defences,
            // Overheat's Special Attack. Missed entirely until now, so a
            // Sneasler could Close Combat all game at full Defence.
            applySelf(move.selfDrops.mapValues { -$0 }, toMine: byMine, slot: slot, board: &board)
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
            applySelf([.defense: 1], toMine: hitMine, slot: hit, board: &board)
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
                leave(byMine: byMine, slot: slot, board: &board)
            }
        }
        // Eject Button: the holder leaves the moment it is hit.
        if defender.build.item == "Eject Button", !defender.build.itemSpent, !defender.fainted {
            if hitMine { board.mine[hit].build.itemSpent = true }
            else { board.theirs[hit].build.itemSpent = true }
            board.note("\(defenderName)'s Eject Button took it out.")
            leave(byMine: hitMine, slot: hit, board: &board)
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
                change(answer, onMine: hitMine, slot: hit, board: &board, because: defender.build.ability)
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
            flinch(onMine: hitMine, slot: hit, board: &board, because: "the stench")
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
            change([.speed: -1], onMine: byMine, slot: slot, board: &board,
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

    /// Emergency Exit and Wimp Out: dropping below half health sends the
    /// Pokémon out to whoever is waiting, mid-turn, without asking.
    ///
    /// Golisopod runs it, which is most of why anyone in this format meets it,
    /// and it changes what a turn against one is worth: hit it hard and it
    /// leaves, hit it for less than half and it stays and hits back.
    private static func flee(ifNeeded slot: Int, ofMine mine: Bool, wasAt before: Int,
                             board: inout Board) {
        let team = mine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted,
              ["Emergency Exit", "Wimp Out"].contains(team[slot].build.ability) else { return }
        let now = team[slot].hp, maxHP = team[slot].maxHP
        // Crossed the line this hit, from at-or-above half to below it.
        guard before * 2 >= maxHP, now * 2 < maxHP else { return }
        guard let next = (board.activeCount..<team.count).first(where: { !team[$0].fainted })
        else { return }
        let name = team[slot].build.form.formLabel
        if mine { board.mine.swapAt(slot, next) } else { board.theirs.swapAt(slot, next) }
        let arrival = (mine ? board.mine : board.theirs)[slot].build.form.formLabel
        board.note("\(name)'s \(team[slot].build.ability) sent it out. \(arrival) came in.")
        board.landed(mine: mine, slot: slot)
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

    /// Stat stages a move takes off whatever it hit.
    /// Stat stages taken off a Pokémon by the other side: Icy Wind, Snarl, a
    /// Weakness Policy going off on the wrong one. The abilities that answer
    /// a drop from outside all live here: Clear Body refuses it, Contrary
    /// turns it round, Defiant and Competitive take it and hit back.
    private static func applyDrops(_ drops: [Stat: Int], toMine: Bool, slot: Int,
                                   board: inout Board) {
        guard !drops.isEmpty else { return }
        let team = toMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let ability = team[slot].build.ability
        // Big Pecks keeps its Defense where it is, and nothing else.
        if ability == "Big Pecks", drops.keys.contains(.defense), drops.count == 1 {
            board.note("\(name)'s Big Pecks kept its Defense where it was.")
            return
        }
        if ["Clear Body", "White Smoke", "Full Metal Body", "Mirror Armor"].contains(ability) {
            board.note("\(name)'s \(ability) kept its stats where they were.")
            return
        }
        // Flower Veil covers the Grass types on its own side, itself included.
        let partner = slot == 0 ? 1 : 0
        if team[slot].types.contains(.grass),
           team.indices.contains(partner), !team[partner].fainted,
           team[partner].build.ability == "Flower Veil" || ability == "Flower Veil" {
            board.note("\(name) is covered by Flower Veil; its stats stay where they are.")
            return
        }
        let deltas = Dictionary(uniqueKeysWithValues: drops.map { ($0.key, -$0.value) })
        change(deltas, onMine: toMine, slot: slot, board: &board)
        if ability == "Defiant" {
            change([.attack: 2], onMine: toMine, slot: slot, board: &board, because: "Defiant")
        } else if ability == "Competitive" {
            change([.spAttack: 2], onMine: toMine, slot: slot, board: &board, because: "Competitive")
        }
    }

    /// Stat stages a Pokémon gives itself, up or down: Swords Dance, Close
    /// Combat's cost, Weakness Policy. Nothing refuses these except Contrary,
    /// which reverses them — the whole reason Contrary Close Combat exists.
    private static func applySelf(_ boosts: [Stat: Int], toMine: Bool, slot: Int,
                                  board: inout Board) {
        change(boosts, onMine: toMine, slot: slot, board: &board)
        opportunist(after: boosts, onMine: toMine, board: &board)
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
            if let refused = refusesStatus(ailment, onMine: hitMine, slot: hit, board: board) {
                board.note("\(name)'s \(refused) kept it from being \(ailment.rawValue).")
                return
            }
            if board.field.terrain == .misty, !types.contains(.flying), defender.build.ability != "Levitate" {
                board.note("The mist kept \(name) from being \(ailment.rawValue).")
                return
            }
            if hitMine { board.mine[hit].status = ailment } else { board.theirs[hit].status = ailment }
            board.note("\(name) was \(ailment.rawValue)" + (chance < 100 ? " — the \(chance)% came up." : "."))
            synchronize(ailment, from: hitMine, slot: hit, onto: byMine, slot: slot, board: &board)
        case .flinch:
            // Only matters if it has yet to move this turn; the flag clears at
            // the turn's start either way. Inner Focus is handled inside.
            flinch(onMine: hitMine, slot: hit, board: &board,
                   because: chance < 100 ? "the \(chance)% came up" : nil)
        case .drops(let drops):
            applyDrops(drops, toMine: hitMine, slot: hit, board: &board)
        case .targetBoosts(let raises):
            applySelf(raises, toMine: hitMine, slot: hit, board: &board)
        case .selfBoosts(let raises):
            // Charge Beam, Meteor Mash, Ancient Power, Steel Wing: the payment
            // goes to whoever used the move, not to whoever was hit.
            applySelf(raises, toMine: byMine, slot: slot, board: &board)
        case .selfDrops(let drops):
            applyDrops(drops, toMine: byMine, slot: slot, board: &board)
        case .confuse:
            // Whether the confusion lands was settled above; `rolling` here
            // only decides how long it lasts, and a played turn should roll
            // that rather than always taking the two turns the search assumes.
            confuse(onMine: hitMine, slot: hit, board: &board, rolling: rolling, chance: chance)
        }
    }

    /// Leave a Pokémon confused for two to five turns, unless something on it
    /// or under it says no.
    private static func confuse(onMine: Bool, slot: Int, board: inout Board, rolling: Bool, chance: Int) {
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let target = team[slot]
        let name = target.build.form.formLabel
        if target.isConfused { return }
        if target.build.ability == "Own Tempo" {
            board.note("\(name)'s Own Tempo kept it clear-headed.")
            return
        }
        if board.field.terrain == .misty, !target.build.form.pokeTypes.contains(.flying),
           target.build.ability != "Levitate" {
            board.note("The mist kept \(name) from being confused.")
            return
        }
        // Two to five turns of it. The search takes the shortest, so it never
        // counts on more than the game guarantees.
        let turns = rolling ? Int.random(in: 2...5, using: &TurnModel.dice) : 2
        if onMine { board.mine[slot].confusedFor = turns } else { board.theirs[slot].confusedFor = turns }
        board.note("\(name) became confused" + (chance < 100 ? " — the \(chance)% came up." : "."))
    }

    /// White Herb: the moment any of the holder's stats sits below zero, the
    /// herb goes and the drops are undone. It is what turns Unburden on — the
    /// item is gone, so the Speed doubles — which is the whole Sneasler set.
    static func whiteHerb(_ fighter: inout Fighter) -> String? {
        guard fighter.build.item == "White Herb", !fighter.build.itemSpent,
              fighter.build.boosts.contains(where: { $0 < 0 }) else { return nil }
        for index in fighter.build.boosts.indices where fighter.build.boosts[index] < 0 {
            fighter.build.boosts[index] = 0
        }
        fighter.build.itemSpent = true
        let name = fighter.build.form.formLabel
        var said = "\(name)'s White Herb restored its stats."
        if fighter.build.ability == "Unburden" { said += " Its Unburden doubled its Speed." }
        return said
    }

    /// Note what a Pokémon used and where, for Encore; and if it is under an
    /// Encore, count that down.
    private static func remember(byMine: Bool, slot: Int, move: Int, target: Int, board: inout Board) {
        if byMine {
            board.mine[slot].lastMove = move; board.mine[slot].lastTarget = target
            if board.mine[slot].encoredFor > 0 {
                board.mine[slot].encoredFor -= 1
                if board.mine[slot].encoredFor == 0 { board.note("\(board.mine[slot].build.form.formLabel)'s Encore ended.") }
            }
        } else {
            board.theirs[slot].lastMove = move; board.theirs[slot].lastTarget = target
            if board.theirs[slot].encoredFor > 0 {
                board.theirs[slot].encoredFor -= 1
                if board.theirs[slot].encoredFor == 0 { board.note("\(board.theirs[slot].build.form.formLabel)'s Encore ended.") }
            }
        }
    }

    /// A Pokémon leaving the field under its own move — Parting Shot, and
    /// whatever else pivots. Whoever is waiting comes in and does what
    /// arriving does.
    private static func leave(byMine: Bool, slot: Int, board: inout Board) {
        let team = byMine ? board.mine : board.theirs
        guard let next = (board.activeCount..<team.count).first(where: { !team[$0].fainted }) else {
            board.note("\(team[slot].build.form.formLabel) had nowhere to go.")
            return
        }
        let leaving = team[slot].build.form.formLabel
        if byMine { board.mine.swapAt(slot, next) } else { board.theirs.swapAt(slot, next) }
        let arriving = (byMine ? board.mine : board.theirs)[slot].build.form.formLabel
        board.note("\(leaving) went out; \(arriving) came in.")
        board.landed(mine: byMine, slot: slot)
    }

    /// Whether a Pokémon can use the berry it is holding. An Unnerve on the
    /// other side is the whole of this: nothing eats while it is watching.
    static func canEatBerry(_ side: Bool, slot: Int, board: Board) -> Bool {
        let others = side ? board.theirs : board.mine
        for index in 0..<Swift.min(board.activeCount, others.count)
        where !others[index].fainted
            && ["Unnerve", "As One", "As One (Glastrier)", "As One (Spectrier)"]
                .contains(others[index].build.ability) {
            return false
        }
        return true
    }

    /// Synchronize: a burn, a poison or a paralysis goes straight back to
    /// whoever handed it over.
    private static func synchronize(_ ailment: Ailment, from side: Bool, slot victim: Int,
                                    onto other: Bool, slot giver: Int, board: inout Board) {
        let team = side ? board.mine : board.theirs
        guard team.indices.contains(victim),
              team[victim].build.ability == "Synchronize",
              [.burn, .poison, .badPoison, .paralysis].contains(ailment) else { return }
        let givers = other ? board.mine : board.theirs
        guard givers.indices.contains(giver), !givers[giver].fainted,
              givers[giver].status == .none else { return }
        if other { board.mine[giver].status = ailment } else { board.theirs[giver].status = ailment }
        board.note("\(team[victim].build.form.formLabel)'s Synchronize passed it back: "
                   + "\(givers[giver].build.form.formLabel) is \(ailment.rawValue).")
    }

    /// Make something flinch, and let a Steadfast take the Speed it is owed
    /// for the trouble.
    /// Make something flinch, if anything can.
    ///
    /// Inner Focus is checked here rather than at the call sites. It was
    /// guarded on the secondary-effect path only, so a Fake Out — the one move
    /// whose whole purpose is the flinch — went straight through the ability
    /// that exists to stop it.
    private static func flinch(onMine: Bool, slot: Int, board: inout Board, because: String? = nil) {
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        if team[slot].build.ability == "Inner Focus" {
            board.note("\(team[slot].build.form.formLabel)'s Inner Focus kept it going.")
            return
        }
        if onMine { board.mine[slot].flinched = true } else { board.theirs[slot].flinched = true }
        let name = team[slot].build.form.formLabel
        board.note("\(name) flinched" + (because.map { " — \($0)." } ?? "."))
        if team[slot].build.ability == "Steadfast" {
            change([.speed: 1], onMine: onMine, slot: slot, board: &board, because: "Steadfast")
        }
    }

    /// How likely a move is to land, once everything on both sides has had its
    /// say: the move's own accuracy, a Bright Powder, a Sand Veil in the sand,
    /// a Keen Eye refusing to be blinded. Kept in one place so the played roll
    /// and the search's average can never disagree.
    static func chanceToHit(_ move: Move, attacker: Fighter, defender: Fighter,
                            board: Board) -> Double {
        guard !move.neverMisses, move.accuracy > 0 else { return 100 }
        var chance = Double(move.accuracy)
        // No Guard makes everything land, from either side of it.
        if attacker.build.ability == "No Guard" || defender.build.ability == "No Guard" { return 100 }
        if attacker.build.ability == "Compound Eyes" { chance *= 1.3 }
        if attacker.build.ability == "Victory Star" { chance *= 1.1 }
        // A Wide Lens was being read when a set was scored and ignored when
        // the move was actually thrown, so the builder recommended it and the
        // battle pretended it was not there.
        if attacker.build.item == "Wide Lens" { chance *= 1.1 }
        if attacker.build.item == "Zoom Lens", defender.build.item != "" { chance *= 1.2 }
        // Nothing dodges a Keen Eye, and a Mold Breaker ignores the dodging
        // ability entirely.
        let blind = attacker.build.ability == "Keen Eye"
            || attacker.build.ability == "Mold Breaker" || attacker.build.ability == "Unaware"
        if !blind {
            if defender.build.item == "Bright Powder" { chance *= 0.9 }
            if defender.build.ability == "Sand Veil", board.field.weather == .sand { chance *= 0.8 }
            if defender.build.ability == "Snow Cloak", board.field.weather == .snow { chance *= 0.8 }
            if defender.build.ability == "Tangled Feet", defender.isConfused { chance *= 0.8 }
        }
        return Swift.max(1, Swift.min(100, chance))
    }

    /// Opportunist: whatever the other side just gained, it gains too.
    ///
    /// Called after a raise lands, and deliberately only for a raise on the
    /// far side — copying its own partner's would be a loop.
    private static func opportunist(after raised: [Stat: Int], onMine: Bool,
                                    board: inout Board) {
        let watchers = onMine ? board.theirs : board.mine
        let positive = raised.filter { $0.value > 0 }
        guard !positive.isEmpty else { return }
        for index in watchers.indices.prefix(board.activeCount)
        where !watchers[index].fainted && watchers[index].build.ability == "Opportunist" {
            change(positive, onMine: !onMine, slot: index, board: &board, because: "Opportunist")
        }
    }

    /// Sweep one side's own hazards away, and say whether there were any.
    ///
    /// Defog and Rapid Spin both do this; Rapid Spin does nothing else to the
    /// field, which is the whole reason a team picks one over the other.
    @discardableResult
    private static func sweepOwnHazards(byMine: Bool, board: inout Board) -> Bool {
        var own = byMine ? board.myScreens : board.theirScreens
        let had = own.spikes > 0 || own.toxicSpikes > 0 || own.stealthRock || own.stickyWeb
        own.spikes = 0; own.toxicSpikes = 0
        own.stealthRock = false; own.stickyWeb = false
        if byMine { board.myScreens = own } else { board.theirScreens = own }
        return had
    }

    /// An ability on that side that turns a condition away, and its name.
    ///
    /// Leaf Guard covers everything but only in the sun. Sweet Veil and Flower
    /// Veil cover the whole side, and only against sleep — a Pokémon does not
    /// have to be the one carrying it.
    private static func refusesStatus(_ ailment: Ailment, onMine: Bool, slot: Int,
                                      board: Board) -> String? {
        let side = onMine ? board.mine : board.theirs
        guard side.indices.contains(slot) else { return nil }
        if side[slot].build.ability == "Leaf Guard", board.field.weather == .sun {
            return "Leaf Guard"
        }
        if ailment == .sleep {
            // Sweet Veil covers the whole side; the other two are personal.
            for who in side.prefix(board.activeCount) where !who.fainted {
                if who.build.ability == "Sweet Veil" { return "Sweet Veil" }
            }
            if ["Vital Spirit", "Insomnia"].contains(side[slot].build.ability) {
                return side[slot].build.ability
            }
            if board.field.terrain == .electric, side[slot].build.grounded { return "Electric Terrain" }
        }
        return nil
    }

    /// The move index a choice picks, or -1 for anything that is not an attack.
    private static func pickedMove(_ choice: Choice) -> Int {
        if case .attack(let index, _) = choice { return index }
        if case .protectSelf(let index) = choice { return index }
        return -1
    }

    /// Whether a Pokémon's last move came off, for Stomping Tantrum.
    private static func markFailed(byMine: Bool, slot: Int, board: inout Board, failed: Bool) {
        if byMine, board.mine.indices.contains(slot) { board.mine[slot].lastMoveFailed = failed }
        if !byMine, board.theirs.indices.contains(slot) { board.theirs[slot].lastMoveFailed = failed }
    }

    @discardableResult
    private static func tryProtect(_ label: String?, byMine: Bool, slot: Int,
                                   board: inout Board, rolling: Bool) -> Bool {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return false }
        let fighter = team[slot]
        let name = fighter.build.form.formLabel
        let word = label ?? "Protect"
        let chance = fighter.protectChance
        // A played turn rolls it. The search asks for one branch at a time
        // and weighs them itself, so a 33% Protect is worth a third of a
        // Protect to it rather than nothing — which is what it is worth, and
        // is why a Gholdengo that has already protected is still not a free
        // Sucker Punch.
        let ruling = board.rulings[Board.flip("protect", byMine, slot)]
        let works = rolling ? Double.random(in: 0..<1, using: &TurnModel.dice) < chance : (ruling ?? (chance >= 0.5))
        if works {
            if byMine { board.mine[slot].isProtected = true; board.mine[slot].protectStreak += 1 }
            else { board.theirs[slot].isProtected = true; board.theirs[slot].protectStreak += 1 }
            board.note(chance < 1
                ? "\(name) used \(word) and braced — a \(Int((chance * 100).rounded()))% chance, and it held."
                : "\(name) used \(word) and braced.")
            return true
        } else {
            if byMine { board.mine[slot].protectStreak = 0 } else { board.theirs[slot].protectStreak = 0 }
            board.note("\(name) used \(word), but it failed — \(Int((chance * 100).rounded()))% after using it last turn.")
            return false
        }
    }

    /// A charge that will not be finished: the Pokémon was stopped, or the
    /// move is landing now.
    private static func dropCharge(byMine: Bool, slot: Int, board: inout Board, quietly: Bool = false) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), let charging = team[slot].charging else { return }
        if !quietly, team[slot].moves.indices.contains(charging) {
            board.note("\(team[slot].build.form.formLabel) lost its \(team[slot].moves[charging].name).")
        }
        if byMine { board.mine[slot].charging = nil; board.mine[slot].hidden = false }
        else { board.theirs[slot].charging = nil; board.theirs[slot].hidden = false }
    }

    /// Move a Pokémon's stages, through whatever its ability does to stage
    /// changes, and say what happened in one line.
    private static func change(_ deltas: [Stat: Int], onMine: Bool, slot: Int,
                               board: inout Board, because: String? = nil) {
        guard !deltas.isEmpty else { return }
        let team = onMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let ability = team[slot].build.ability
        var applied = deltas
        if ability == "Contrary" { applied = applied.mapValues { -$0 } }
        if ability == "Simple" { applied = applied.mapValues { $0 * 2 } }
        var rose: [String] = [], fell: [String] = []
        for (stat, amount) in applied.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let before = team[slot].build.boosts[stat.rawValue]
            let after = Swift.max(-6, Swift.min(6, before + amount))
            guard after != before else { continue }
            if onMine { board.mine[slot].build.boosts[stat.rawValue] = after }
            else { board.theirs[slot].build.boosts[stat.rawValue] = after }
            let word = abs(amount) >= 2 ? "\(stat.short) sharply" : stat.short
            if amount > 0 { rose.append(word) } else { fell.append(word) }
        }
        guard !rose.isEmpty || !fell.isEmpty else { return }
        var parts: [String] = []
        if !rose.isEmpty { parts.append("\(rose.joined(separator: " and ")) rose") }
        if !fell.isEmpty { parts.append("\(fell.joined(separator: " and ")) fell") }
        var line = "\(name)'s " + parts.joined(separator: "; ") + "."
        if let because { line = "\(name)'s \(because): " + parts.joined(separator: "; ") + "." }
        else if ability == "Contrary" { line = "\(name)'s Contrary turned it round: " + parts.joined(separator: "; ") + "." }
        else if ability == "Simple" { line = "\(name)'s Simple doubled it: " + parts.joined(separator: "; ") + "." }
        board.note(line)
        if !fell.isEmpty {
            let herb = onMine ? whiteHerb(&board.mine[slot]) : whiteHerb(&board.theirs[slot])
            if let herb { board.note(herb) }
        }
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
                applyDrops([.attack: 1, .spAttack: 1], toMine: !byMine, slot: index, board: &board)
            } else if far.indices.contains(index), far[index].isProtected {
                board.note("\(far[index].build.form.formLabel) protected itself.")
            }
            leave(byMine: byMine, slot: slot, board: &board)
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
            setNear { $0.hp += gained; $0.stockpile = 0
                      $0.build.boosts[Stat.defense.rawValue] -= held
                      $0.build.boosts[Stat.spDefense.rawValue] -= held }
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
            if let said = swapIn(mine: !byMine, active: index, bench: coming, board: &board) {
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
            if let said = swapIn(mine: byMine, active: slot, bench: coming, board: &board) {
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
            sweepOwnHazards(byMine: byMine, board: &board)
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
            applySelf(paid, toMine: byMine, slot: partner, board: &board)
            return
        }

        // Clangorous Soul spends a third of the bar to raise everything.
        if move.name == "Clangorous Soul" {
            let cost = team[slot].maxHP / 3
            guard team[slot].hp > cost else { board.note("But it failed."); return }
            setNear { $0.hp -= cost }
            applySelf([.attack: 1, .defense: 1, .spAttack: 1, .spDefense: 1, .speed: 1],
                      toMine: byMine, slot: slot, board: &board)
            return
        }

        // Acupressure raises one stat, chosen at random, by two.
        if move.name == "Acupressure" {
            let stats: [Stat] = [.attack, .defense, .spAttack, .spDefense, .speed]
            let picked = rolling ? (stats.randomElement(using: &TurnModel.dice) ?? .attack) : .attack
            applySelf([picked: 2], toMine: byMine, slot: slot, board: &board)
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
            applySelf([.defense: 2], toMine: byMine, slot: slot, board: &board)
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
                applySelf([.defense: 1, .spDefense: 1], toMine: byMine, slot: index, board: &board)
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
            leave(byMine: byMine, slot: slot, board: &board)
            return
        }

        // Howl boosts the whole side, not just the user. Matched on the
        // sentence rather than the name, and deliberately narrow: Coaching and
        // Gear Up read as "the user's allies" without the user, and are
        // already handled as ally-targeted moves further down.
        if move.effect.contains("of the user and its allies"), !move.selfBoosts.isEmpty {
            let boosts = move.selfBoosts
            let partner = slot == 0 ? 1 : 0
            applySelf(boosts, toMine: byMine, slot: slot, board: &board)
            let own = byMine ? board.mine : board.theirs
            if board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted {
                applySelf(boosts, toMine: byMine, slot: partner, board: &board)
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
                applySelf(move.targetBoosts, toMine: !byMine, slot: index, board: &board)
                confuse(onMine: !byMine, slot: index, board: &board, rolling: rolling, chance: 100)
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
            tryProtect(nil, byMine: byMine, slot: slot, board: &board, rolling: rolling)
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
            applySelf([.attack: 1, .defense: 1], toMine: byMine, slot: partner, board: &board)
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
                applyDrops(drops, toMine: !byMine, slot: index, board: &board)
            }
            return
        }
        if !move.selfBoosts.isEmpty {
            applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
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
                || board.field.terrain == .electric
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
            if let refused = refusesStatus(ailment, onMine: !byMine, slot: target, board: board) {
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
            synchronize(ailment, from: !byMine, slot: target, onto: byMine, slot: slot, board: &board)
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
