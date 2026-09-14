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
    /// Wide Guard, which lasts the turn rather than five of them.
    var wideGuard = false

    var any: Bool { reflect > 0 || lightScreen > 0 || auroraVeil > 0 }
    mutating func tick() {
        reflect = max(0, reflect - 1)
        lightScreen = max(0, lightScreen - 1)
        auroraVeil = max(0, auroraVeil - 1)
        wideGuard = false
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

    /// Benched slots of theirs that have not shown themselves yet.
    var theirUnseenBench: [Int] {
        (activeCount..<theirs.count).filter { !theirs[$0].seen && !theirs[$0].fainted }
    }

    /// The guesses still possible given what has since been seen: one of the
    /// pair walking on rules out every pair it was not in.
    var liveBenchGuesses: [BenchGuess] {
        // Only what was ever in doubt counts as evidence: a lead that fainted
        // and slid to the bench has been seen, but it was never a guess.
        let pool = Set(theirBenchGuesses.flatMap { $0.fighters.map(\.build.form.id) })
        let shown = Set(theirs.filter { $0.seen && pool.contains($0.build.form.id) }
                            .map(\.build.form.id))
        let consistent = theirBenchGuesses.filter { guess in
            shown.isSubset(of: Set(guess.fighters.map(\.build.form.id)))
        }
        let total = consistent.reduce(0) { $0 + $1.chance }
        guard total > 0 else { return [] }
        return consistent.map { BenchGuess(fighters: $0.fighters, chance: $0.chance / total) }
    }

    /// Each Pokémon that might be in their back, with the chance it is there.
    var theirBenchCandidates: [(fighter: Fighter, chance: Double)] {
        let shown = Set(theirs.filter(\.seen).map(\.build.form.id))
        var chance: [String: Double] = [:]
        var fighter: [String: Fighter] = [:]
        for guess in liveBenchGuesses {
            for member in guess.fighters where !shown.contains(member.build.form.id) {
                chance[member.build.form.id, default: 0] += guess.chance
                fighter[member.build.form.id] = member
            }
        }
        return chance.keys.compactMap { id in fighter[id].map { ($0, chance[id]!) } }
            .sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.build.form.formLabel < $1.0.build.form.formLabel) }
    }

    /// Whether anything on their side is still a guess.
    var hidesTheirBench: Bool { !theirUnseenBench.isEmpty && !liveBenchGuesses.isEmpty }
    var field: Field
    /// Turns left on each side's speed control.
    var myTailwind = 0
    var theirTailwind = 0
    var trickRoom = 0
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

    /// How a repeat Protect is to come out this turn, when the search wants to
    /// see one branch rather than roll: "m0" is your left slot, "t1" their
    /// right. Cleared once the turn has been played.
    var protectRulings: [String: Bool] = [:]

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

    /// A Pokémon has just reached the field: it is seen, it can Fake Out, and
    /// whatever it does on arrival happens now.
    mutating func landed(mine side: Bool, slot: Int) {
        let before = field
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

@MainActor
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
    init(mine myTeam: Team, theirs theirTeam: Team, store: Store,
         myLeads: [String] = [], theirLeads: [String] = [],
         field: Field = Field(isDoubles: true),
         alreadyEvolved: Bool = true) {
        func build(_ team: Team, leads: [String]) -> [Fighter] {
            let made: [(String, Fighter)] = team.slots.compactMap { slot in
                guard let registered = slot.form(in: store),
                      let evolved = slot.battleForm(in: store),
                      let combatant = slot.combatant(in: store) else { return nil }
                let mega = slot.megaEvolution(in: store)
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
                var moves = slot.moves.compactMap { store.move($0) }
                if !moves.contains(where: \.isDamaging) {
                    let pool = store.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
                    moves += pool.sorted {
                        store.moveValue($0, for: form, ability: combatant.ability, item: slot.item)
                            > store.moveValue($1, for: form, ability: combatant.ability, item: slot.item)
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
                        store: Store, singles: Bool, sendOut: Bool = true) -> Board {
        let bring = singles ? 3 : 4
        let leadCount = singles ? 1 : 2
        let field = Field(isDoubles: !singles)

        var brought = myTeam
        brought.slots = bringing.compactMap { id in myTeam.slots.first { $0.formID == id } }
        if brought.slots.count < leadCount { brought = myTeam }

        // They choose their own four the same way, against your six.
        let theirGrid = Matchup(mine: theirTeam, theirs: myTeam, store: store, field: field)
        let picker = BringFour(matchup: theirGrid, store: store, bring: bring)
        var theirBrought = theirTeam
        if let plan = picker.plans.first {
            theirBrought.slots = plan.bring.compactMap { form in
                theirTeam.slots.first { $0.battleForm(in: store)?.id == form.id }
            }
        }
        if theirBrought.slots.count < leadCount { theirBrought = theirTeam }

        var board = Board(mine: brought, theirs: theirBrought, store: store,
                          field: field, alreadyEvolved: false)
        board.activeCount = leadCount
        if sendOut { board.sendOutLeads() }

        // Every Pokémon on their six as a fighter, so a guess can be played.
        let whole = Board(mine: brought, theirs: theirTeam, store: store,
                          field: field, alreadyEvolved: false)
        // A fighter stands as what was registered; the grid rates what it
        // fights as. For a stone-holder those are different Pokémon, and
        // matching them by id silently dropped every pair with a Mega in it.
        var fightsAs: [String: Form] = [:]
        for slot in theirTeam.slots {
            if let registered = slot.form(in: store), let battle = slot.battleForm(in: store) {
                fightsAs[registered.id] = battle
            }
        }
        let leadIDs = Set(board.theirs.prefix(leadCount).map(\.build.form.id))
        let leadForms = leadIDs.compactMap { fightsAs[$0] }
        let rest = whole.theirs.filter { !leadIDs.contains($0.build.form.id) }
        let behind = bring - leadCount
        guard rest.count > behind, !leadForms.isEmpty else { return board }

        var guesses: [BenchGuess] = []
        var weights: [Double] = []
        for pair in Board.choose(rest, behind) {
            let forms = pair.compactMap { fightsAs[$0.build.form.id] }
            guard forms.count == pair.count, forms.filter(\.isMega).count + leadForms.filter(\.isMega).count <= 1
            else { continue }
            // How much this four costs you, which is how much they like it.
            let edge = theirGrid.rate(bringing: leadForms + forms, against: theirGrid.theirForms).score
            guesses.append(BenchGuess(fighters: pair, chance: 0))
            weights.append(Double(edge))
        }
        guard !guesses.isEmpty else { return board }
        // A soft preference: the best pair is likeliest, not certain. Twelve
        // points of edge is one factor of e.
        let top = weights.max() ?? 0
        let raw = weights.map { exp(($0 - top) / 12) }
        let total = raw.reduce(0, +)
        board.theirBenchGuesses = zip(guesses, raw).map {
            BenchGuess(fighters: $0.fighters, chance: $1 / total)
        }.sorted { $0.chance > $1.chance }
        return board
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
        // Speed control is a real asset and the turn that sets it looks like a
        // wasted one without this.
        out += Double(board.myTailwind - board.theirTailwind) * 0.12
        return out
    }

    private static func priority(of choice: Choice, for fighter: Fighter) -> Int {
        switch choice {
        case .pass: return -99
        case .swap: return 6
        case .protectSelf(let index), .attack(let index, _):
            return fighter.moves.indices.contains(index) ? fighter.moves[index].priority : 0
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
                  out.mine[slot].charging == nil else { continue }
            leaving.append((true, slot, bench,
                            speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, choice) in theirChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.theirs.indices.contains(slot), out.theirs.indices.contains(bench),
                  !out.theirs[bench].fainted, !out.theirs[slot].fainted,
                  out.theirs[slot].charging == nil else { continue }
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
                let said = swapIn(&out.mine, active: entry.slot, bench: entry.bench,
                                  opposing: &out.theirs, field: &out.field)
                if let said { out.note(said) }
            } else {
                out.note("They switched \(out.theirs[entry.slot].build.form.formLabel) out for \(out.theirs[entry.bench].build.form.formLabel).")
                let said = swapIn(&out.theirs, active: entry.slot, bench: entry.bench,
                                  opposing: &out.mine, field: &out.field)
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
            return choice
        }
        var entries: [(mine: Bool, slot: Int, choice: Choice, priority: Int, speed: Int)] = []
        for (slot, given) in myChoices.enumerated() {
            guard out.mine.indices.contains(slot), !out.mine[slot].fainted else { continue }
            let choice = forced(out.mine[slot], given)
            guard !choice.isSwap else { continue }
            entries.append((true, slot, choice, priority(of: choice, for: out.mine[slot]),
                            speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, given) in theirChoices.enumerated() {
            guard out.theirs.indices.contains(slot), !out.theirs[slot].fainted else { continue }
            let choice = forced(out.theirs[slot], given)
            guard !choice.isSwap else { continue }
            entries.append((false, slot, choice, priority(of: choice, for: out.theirs[slot]),
                            speed(of: out.theirs[slot], tailwind: out.theirTailwind > 0, board: out)))
        }

        // Chosen one at a time rather than sorted once, because Speed is
        // re-checked before every action and things change mid-turn. A
        // Prankster Whimsicott putting up Tailwind goes first on priority, and
        // its partner — who has not moved yet — is twice as fast from that
        // moment, which can move it ahead of something it was behind. Sorting
        // the whole turn up front makes that impossible.
        var pending = entries
        while !pending.isEmpty {
            let inverted = out.trickRoom > 0
            var choice = 0
            for index in pending.indices.dropFirst() {
                let a = pending[index], b = pending[choice]
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
            // One action, one step: whatever it does to however many.
            out.beginStep()
            apply(entry.choice, byMine: entry.mine, slot: entry.slot, to: &out, rolling: rolling)
            out.closeStep()
        }

        // The residuals together, since they land together.
        out.beginStep()
        endOfTurn(&out, rolling: rolling)
        out.closeStep()
        out.protectRulings = [:]

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
        func consider(_ choice: Choice, fighter: Fighter, key: String) {
            guard !fighter.fainted, fighter.protectStreak > 0 else { return }
            switch choice {
            case .protectSelf:
                chancy.append((key, fighter.protectChance))
            case .attack(let index, _):
                if fighter.moves.indices.contains(index),
                   Move.protectMoves.contains(fighter.moves[index].name) {
                    chancy.append((key, fighter.protectChance))
                }
            default: break
            }
        }
        if board.mine.indices.contains(0) { consider(mine.left, fighter: board.mine[0], key: "m0") }
        if board.mine.indices.contains(1), board.activeCount > 1 { consider(mine.right, fighter: board.mine[1], key: "m1") }
        if board.theirs.indices.contains(0) { consider(theirs.left, fighter: board.theirs[0], key: "t0") }
        if board.theirs.indices.contains(1), board.activeCount > 1 { consider(theirs.right, fighter: board.theirs[1], key: "t1") }
        guard !chancy.isEmpty else {
            return [(resolve(board, mine: mine, theirs: theirs, narrating: false), 1)]
        }
        var out: [(board: Board, chance: Double)] = []
        for mask in 0..<(1 << chancy.count) {
            var ruled = board
            var chance = 1.0
            for (bit, entry) in chancy.enumerated() {
                let holds = mask & (1 << bit) != 0
                ruled.protectRulings[entry.key] = holds
                chance *= holds ? entry.chance : 1 - entry.chance
            }
            out.append((resolve(ruled, mine: mine, theirs: theirs, narrating: false), chance))
        }
        return out.sorted { $0.chance > $1.chance }
    }

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
                let types = who.build.form.pokeTypes
                var hp = who.hp

                if board.field.weather == .sand,
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
                case .burn:
                    hp -= Swift.max(1, maxHP / 16)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt by its burn.")
                case .poison, .badPoison:
                    hp -= Swift.max(1, maxHP / 8)
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) is hurt by poison.")
                default: break
                }
                if who.build.item == "Leftovers", hp < maxHP, hp > 0 {
                    hp = Swift.min(maxHP, hp + Swift.max(1, maxHP / 16))
                    if mine { board.mine[index].hp = hp } else { board.theirs[index].hp = hp }
                    board.note("\(name) restores a little with its Leftovers.")
                }
                if who.build.item == "Sitrus Berry", !who.build.itemSpent,
                   hp > 0, hp <= maxHP / 2 {
                    hp = Swift.min(maxHP, hp + maxHP / 4)
                    if mine {
                        board.mine[index].hp = hp; board.mine[index].build.itemSpent = true
                    } else {
                        board.theirs[index].hp = hp; board.theirs[index].build.itemSpent = true
                    }
                    board.note("\(name) eats its Sitrus Berry.")
                }
                if hp <= 0 {
                    if mine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                    board.note("\(name) fainted.")
                }
            }
        }
        settle(mine: true)
        settle(mine: false)

        board.myTailwind = Swift.max(0, board.myTailwind - 1)
        board.theirTailwind = Swift.max(0, board.theirTailwind - 1)
        board.trickRoom = Swift.max(0, board.trickRoom - 1)
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
        for index in board.mine.indices {
            board.mine[index].protectedLast = board.mine[index].isProtected
            if !board.mine[index].isProtected { board.mine[index].protectStreak = 0 }
            board.mine[index].justArrived = false
            if board.mine[index].asleepFor > 0 {
                board.mine[index].asleepFor -= 1
                if board.mine[index].asleepFor == 0 { board.mine[index].status = .none }
            }
        }
        for index in board.theirs.indices {
            board.theirs[index].protectedLast = board.theirs[index].isProtected
            if !board.theirs[index].isProtected { board.theirs[index].protectStreak = 0 }
            board.theirs[index].justArrived = false
            if board.theirs[index].asleepFor > 0 {
                board.theirs[index].asleepFor -= 1
                if board.theirs[index].asleepFor == 0 { board.theirs[index].status = .none }
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
    @discardableResult
    private static func swapIn(_ team: inout [Fighter], active: Int, bench: Int,
                               opposing: inout [Fighter], field: inout Field) -> String? {
        guard team.indices.contains(active), team.indices.contains(bench),
              !team[bench].fainted else { return nil }
        // Regenerator heals a third on the way out, which is what makes a
        // Regenerator pivot free where another Pokémon's costs it the chip.
        if team[active].build.ability == "Regenerator", !team[active].fainted {
            team[active].hp = Swift.min(team[active].maxHP,
                                        team[active].hp + team[active].maxHP / 3)
        }
        team[active].charging = nil
        team[active].hidden = false
        team[active].protectStreak = 0
        team[active].confusedFor = 0
        team.swapAt(active, bench)
        team[active].justArrived = true
        team[active].seen = true
        team[active].isProtected = false

        return entryAbility(of: team[active].build.ability, team: &team, slot: active,
                            opposing: &opposing, field: &field)
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
        if actor.status == .paralysis, rolling, Double.random(in: 0...1) < 0.25 {
            board.note("\(name) is paralysed and cannot move.")
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
                if rolling, Double.random(in: 0..<1) < 1.0 / 3.0 {
                    let attack = Double(actor.build.stagedStat(.attack))
                    let defence = Double(actor.build.stagedStat(.defense))
                    let base = (2.0 * 50 / 5 + 2) * 40 * attack / defence / 50 + 2
                    let hurt = Swift.max(1, Int(base * Double.random(in: 0.85...1.0)))
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
            let held = tryProtect(label, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            markFailed(byMine: byMine, slot: slot, board: &board, failed: !held)
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
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
                return
            }
            // Armor Tail and Queenly Majesty refuse priority outright: nothing
            // with increased priority can be aimed at that Pokémon or its
            // partner. It is the reason Farigiraf is on Trick Room teams — it
            // is what stops a Fake Out taking the setup turn away.
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
                if let pulled = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    defenders[$0].drawingFire && !defenders[$0].fainted }), pulled != aimed[0] {
                    aimed = [pulled]
                    board.note("It was drawn to \(defenders[pulled].build.form.formLabel).")
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
                    board.note("\(hitName) protected itself.")
                    continue
                }
                // Feint: through the Protect, and the Protect is gone — so the
                // partner's move, coming after, lands on an open target.
                if defending[index].isProtected, move.breaksProtect {
                    if hitMine { board.mine[index].isProtected = false }
                    else { board.theirs[index].isProtected = false }
                    board.note("\(move.name) broke through \(hitName)'s protection.")
                }
                // Accuracy is rolled for each one it reaches for: Muddy Water at
                // 85% can hit one of them and miss the other. The search's
                // averages were always per target; only the dice were not.
                if rolling, !move.neverMisses, move.accuracy > 0,
                   Double.random(in: 0...100) > Double(move.accuracy) {
                    board.note(aimed.count > 1 ? "\(hitName) avoided it." : "It missed.")
                    continue
                }
                reached += 1
                var defender = defending[index].build
                defender.atFullHP = defending[index].hp == defending[index].maxHP
                var field = board.field
                field.screen = farScreens.blunt(move)
                // A critical hit, rolled at the move's own rate. The calculator
                // already knows what one does — half again, and it goes through
                // screens and the target's defensive boosts — it only needed
                // telling when one happened.
                if rolling, move.critRate > 0,
                   Double.random(in: 0..<100) < move.critRate {
                    field.critical = true
                }
                var attacker = actor.build
                attacker.lowHP = actor.hp * 3 <= actor.maxHP
                attacker.lastMoveFailed = actor.lastMoveFailed
                // Supreme Overlord and Last Respects count the fallen. Never
                // filled in before, so neither ever went off in a battle.
                attacker.fallenAllies = (byMine ? board.mine : board.theirs).filter(\.fainted).count
                if actor.status.halvesPhysical, move.category == "Physical" {
                    attacker.boosts[Stat.attack.rawValue] -= 1
                }
                let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                                  move: move, field: field)
                if field.critical { board.note("  A critical hit!") }

                // 3. What the far side brings to it. These are the calculator's
                // own notes, so the commentary cannot drift from the maths.
                for line in result.notes where worthSaying(line) {
                    board.note("  \(line)")
                }
                if actor.status.halvesPhysical, move.category == "Physical" {
                    board.note("  \(name) is burned, so it hits softer.")
                }
                if result.effectiveness == 0 {
                    board.note("It does not affect \(hitName).")
                    continue
                }

                // 4. The roll.
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                let dealt: Int = rolling
                    ? Int.random(in: Swift.min(result.minDamage, result.maxDamage)
                                 ... Swift.max(result.minDamage, result.maxDamage))
                    : Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy).rounded())

                var landed = dealt
                var sashed = false
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
                    board.note("It is super effective. \(hitName) took \(landed) (\(share)%).")
                } else if result.effectiveness < 1 {
                    board.note("\(hitName) resists it — \(landed) (\(share)%).")
                } else {
                    board.note("\(hitName) took \(landed) (\(share)%).")
                }
                if sashed { board.note("\(hitName) hung on with its Focus Sash.") }

                // 5. Afterwards: what the move does beyond the damage, and what
                // the target's own ability does back.
                contact(move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                        wasAt: defending[index].hp, rolling: rolling, board: &board)
                flee(ifNeeded: index, ofMine: hitMine, wasAt: defending[index].hp,
                     board: &board)
                if move.name == "Fake Out" {
                    if hitMine { board.mine[index].flinched = true }
                    else { board.theirs[index].flinched = true }
                    board.note("\(hitName) flinched.")
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
                if after.hp == 0 { board.note("\(hitName) fainted.") }
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
                if !team[slot].fainted {
                    let gained = Swift.min(team[slot].maxHP - team[slot].hp,
                                           Swift.max(1, Int(Double(totalDealt) * share)))
                    if gained > 0 {
                        if byMine { board.mine[slot].hp += gained } else { board.theirs[slot].hp += gained }
                        board.note("\(name) drained \(gained) health back.")
                    }
                }
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
        guard move.makesContact, !attacker.fainted else { return }

        switch defender.build.ability {
        case "Rough Skin", "Iron Barbs":
            let lost = Swift.max(1, attacker.maxHP / 8)
            if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
            else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
            board.note("\(attackerName) is hurt by \(defenderName)'s \(defender.build.ability).")
        case "Flame Body", "Static", "Poison Point":
            // Three in ten. A search averages, so it does not apply these at
            // all rather than applying them to everybody.
            guard rolling, Double.random(in: 0..<1) < 0.3, attacker.status == .none else { break }
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

        if attacker.build.ability == "Poison Touch", rolling, !defender.fainted,
           defender.status == .none,
           Double.random(in: 0..<1) < 0.3,
           !defender.build.form.pokeTypes.contains(where: { [.poison, .steel].contains($0) }) {
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
        if ["Clear Body", "White Smoke", "Full Metal Body", "Mirror Armor"].contains(ability) {
            board.note("\(name)'s \(ability) kept its stats where they were.")
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
    private static func secondary(of move: Move, byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                                  rolling: Bool, board: inout Board) {
        guard let effect = move.secondary else { return }
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = hitMine ? board.mine : board.theirs
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit),
              !defenderTeam[hit].fainted else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        if attacker.build.ability == "Sheer Force" { return }
        var chance = effect.chance
        if attacker.build.ability == "Serene Grace" { chance = Swift.min(100, chance * 2) }
        let happens = rolling ? Double.random(in: 0..<100) < Double(chance) : chance >= 100
        guard happens else { return }
        let name = defender.build.form.formLabel
        switch effect.kind {
        case .status(let ailment):
            guard defender.status == .none else { return }
            let types = defender.build.form.pokeTypes
            let immune: Bool
            switch ailment {
            case .burn: immune = types.contains(.fire) || defender.build.ability == "Thermal Exchange"
                || defender.build.ability == "Water Veil" || defender.build.ability == "Water Bubble"
            case .paralysis: immune = types.contains(.electric) || defender.build.ability == "Limber"
            case .poison, .badPoison: immune = types.contains(where: { [.poison, .steel].contains($0) })
                || defender.build.ability == "Immunity"
            case .freeze: immune = types.contains(.ice)
            case .sleep, .none: immune = true
            }
            if immune { return }
            if board.field.terrain == .misty, !types.contains(.flying), defender.build.ability != "Levitate" {
                board.note("The mist kept \(name) from being \(ailment.rawValue).")
                return
            }
            if hitMine { board.mine[hit].status = ailment } else { board.theirs[hit].status = ailment }
            board.note("\(name) was \(ailment.rawValue)" + (chance < 100 ? " — the \(chance)% came up." : "."))
        case .flinch:
            // Only matters if it has yet to move this turn; the flag clears at
            // the turn's start either way.
            guard defender.build.ability != "Inner Focus" else { return }
            if hitMine { board.mine[hit].flinched = true } else { board.theirs[hit].flinched = true }
            board.note("\(name) flinched" + (chance < 100 ? " — the \(chance)% came up." : "."))
        case .drops(let drops):
            applyDrops(drops, toMine: hitMine, slot: hit, board: &board)
        case .confuse:
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
        let turns = rolling ? Int.random(in: 2...5) : 2
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
        let ruling = board.protectRulings[(byMine ? "m" : "t") + "\(slot)"]
        let works = rolling ? Double.random(in: 0..<1) < chance : (ruling ?? (chance >= 0.5))
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
        case "Reflect":
            if byMine { board.myScreens.reflect = 5 } else { board.theirScreens.reflect = 5 }
            board.note("Reflect went up.")
            return
        case "Light Screen":
            if byMine { board.myScreens.lightScreen = 5 }
            else { board.theirScreens.lightScreen = 5 }
            board.note("Light Screen went up.")
            return
        case "Aurora Veil":
            if byMine { board.myScreens.auroraVeil = 5 }
            else { board.theirScreens.auroraVeil = 5 }
            board.note("Aurora Veil went up.")
            return
        case "Helping Hand":
            // Its whole effect is on a partner's move this turn, and the turn
            // order here means the partner may already have gone. Counted as a
            // boost to the ally so the rest of the turn sees it.
            let ally = slot == 0 ? 1 : 0
            applySelf([.attack: 1, .spAttack: 1], toMine: byMine, slot: ally, board: &board)
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
            case .burn: immune = victim.build.form.pokeTypes.contains(.fire)
                || ["Water Veil", "Water Bubble", "Thermal Exchange"].contains(victim.build.ability)
            case .paralysis: immune = victim.build.form.pokeTypes.contains(.electric)
                || ["Limber"].contains(victim.build.ability)
            case .poison, .badPoison:
                immune = victim.build.form.pokeTypes.contains(where: { [.poison, .steel].contains($0) })
                    || ["Immunity"].contains(victim.build.ability)
            case .sleep: immune = ["Insomnia", "Vital Spirit"].contains(victim.build.ability)
                || board.field.terrain == .electric
            default: immune = false
            }
            if immune {
                board.note("\(victim.build.form.formLabel) is not affected.")
                return
            }
            if byMine {
                board.theirs[target].status = ailment
                if ailment == .sleep { board.theirs[target].asleepFor = rolling
                    ? Int.random(in: 1...3) : 2 }
            } else {
                board.mine[target].status = ailment
                if ailment == .sleep { board.mine[target].asleepFor = rolling
                    ? Int.random(in: 1...3) : 2 }
            }
            board.note("\(victim.build.form.formLabel) is \(ailment.rawValue).")
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
        if byMine { board.mine[slot].hp = 0 } else { board.theirs[slot].hp = 0 }
        board.note("\(team[slot].build.form.formLabel) fainted using \(move.name).")
    }
}
