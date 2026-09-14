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
enum Ailment: String {
    case none = "", burn = "burned", paralysis = "paralysed", poison = "poisoned"
    case badPoison = "badly poisoned", sleep = "asleep", freeze = "frozen"

    /// Whether it stops a physical attacker being one.
    var halvesPhysical: Bool { self == .burn }
    var halvesSpeed: Bool { self == .paralysis }
}

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
             theirTailwind: theirTailwind, trickRoom: trickRoom)
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
        func refill(_ team: inout [Fighter]) {
            for slot in 0..<min(activeCount, team.count) where team[slot].fainted {
                guard let next = (activeCount..<team.count).first(where: { !team[$0].fainted })
                else { continue }
                team.swapAt(slot, next)
                team[slot].justArrived = true
                team[slot].seen = true
            }
        }
        if fillMine { refill(&mine) }
        if fillTheirs { refill(&theirs) }
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
        mine[slot].justArrived = true
        mine[slot].seen = true
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
    static func opening(mine myTeam: Team, bringing: [String], theirs theirTeam: Team,
                        store: Store, singles: Bool) -> Board {
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

@MainActor
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
    static func resolve(_ board: Board, mine: Play, theirs: Play, store: Store,
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
        for (slot, choice) in myChoices.enumerated() {
            guard case .swap(let bench) = choice else { continue }
            swapIn(&out.mine, active: slot, bench: bench, opposing: &out.theirs,
                   field: &out.field)
        }
        for (slot, choice) in theirChoices.enumerated() {
            guard case .swap(let bench) = choice else { continue }
            swapIn(&out.theirs, active: slot, bench: bench, opposing: &out.mine,
                   field: &out.field)
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
        if let slot = mine.megaSlot, out.mine.indices.contains(slot),
           slot < out.activeCount, out.mine[slot].pendingMega != nil,
           !out.mine[slot].fainted, !out.mine.contains(where: \.hasMegaEvolved) {
            evolving.append((true, slot, speed(of: out.mine[slot],
                                               tailwind: out.myTailwind > 0, board: out)))
        }
        if let slot = theirs.megaSlot, out.theirs.indices.contains(slot),
           slot < out.activeCount, out.theirs[slot].pendingMega != nil,
           !out.theirs[slot].fainted, !out.theirs.contains(where: \.hasMegaEvolved) {
            evolving.append((false, slot, speed(of: out.theirs[slot],
                                                tailwind: out.theirTailwind > 0, board: out)))
        }
        // Trick Room does not invert this: Mega Evolution is worked out on raw
        // Speed regardless of what is on the field.
        for entry in evolving.sorted(by: { $0.speed > $1.speed }) {
            if entry.mine {
                megaEvolve(&out.mine, slot: entry.slot, opposing: &out.theirs,
                           field: &out.field)
            } else {
                megaEvolve(&out.theirs, slot: entry.slot, opposing: &out.mine,
                           field: &out.field)
            }
        }

        // -- everything else, in order ---------------------------------------
        var entries: [(mine: Bool, slot: Int, choice: Choice, priority: Int, speed: Int)] = []
        for (slot, choice) in myChoices.enumerated() where !choice.isSwap {
            guard out.mine.indices.contains(slot), !out.mine[slot].fainted else { continue }
            entries.append((true, slot, choice, priority(of: choice, for: out.mine[slot]),
                            speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, choice) in theirChoices.enumerated() where !choice.isSwap {
            guard out.theirs.indices.contains(slot), !out.theirs[slot].fainted else { continue }
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
            apply(entry.choice, byMine: entry.mine, slot: entry.slot, to: &out,
                  store: store, rolling: rolling)
            out.closeStep()
        }

        // The residuals together, since they land together.
        out.beginStep()
        endOfTurn(&out, rolling: rolling)
        out.closeStep()

        return out
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
        board.myScreens.tick()
        board.theirScreens.tick()
        for index in board.mine.indices {
            board.mine[index].protectedLast = board.mine[index].isProtected
            board.mine[index].justArrived = false
            if board.mine[index].asleepFor > 0 {
                board.mine[index].asleepFor -= 1
                if board.mine[index].asleepFor == 0 { board.mine[index].status = .none }
            }
        }
        for index in board.theirs.indices {
            board.theirs[index].protectedLast = board.theirs[index].isProtected
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
    private static func entryAbility(of ability: String, team: inout [Fighter], slot: Int,
                                     opposing: inout [Fighter], field: inout Field) {
        switch ability {
        case "Intimidate":
            for index in opposing.indices.prefix(2) where !opposing[index].fainted {
                if ["Clear Body", "Hyper Cutter", "Inner Focus", "White Smoke",
                    "Full Metal Body", "Own Tempo", "Oblivious", "Scrappy",
                    "Guard Dog"].contains(opposing[index].build.ability) { continue }
                opposing[index].build.boosts[Stat.attack.rawValue] =
                    max(-6, opposing[index].build.boosts[Stat.attack.rawValue] - 1)
            }
        case "Drought":        field.weather = .sun
        case "Drizzle":        field.weather = .rain
        case "Sand Stream":    field.weather = .sand
        case "Snow Warning":   field.weather = .snow
        case "Electric Surge": field.terrain = .electric
        case "Grassy Surge":   field.terrain = .grassy
        case "Misty Surge":    field.terrain = .misty
        case "Psychic Surge":  field.terrain = .psychic
        default: break
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
    private static func swapIn(_ team: inout [Fighter], active: Int, bench: Int,
                               opposing: inout [Fighter], field: inout Field) {
        guard team.indices.contains(active), team.indices.contains(bench),
              !team[bench].fainted else { return }
        // Regenerator heals a third on the way out, which is what makes a
        // Regenerator pivot free where another Pokémon's costs it the chip.
        if team[active].build.ability == "Regenerator", !team[active].fainted {
            team[active].hp = Swift.min(team[active].maxHP,
                                        team[active].hp + team[active].maxHP / 3)
        }
        team.swapAt(active, bench)
        team[active].justArrived = true
        team[active].seen = true
        team[active].isProtected = false

        entryAbility(of: team[active].build.ability, team: &team, slot: active,
                     opposing: &opposing, field: &field)
    }

    private static func apply(_ choice: Choice, byMine: Bool, slot: Int,
                              to board: inout Board, store: Store,
                              rolling: Bool = false) {
        let actor = byMine ? board.mine[slot] : board.theirs[slot]
        guard !actor.fainted else { return }
        let name = actor.build.form.formLabel
        if actor.flinched {
            board.note("\(name) flinched and could not move.")
            return
        }
        // Sleep and paralysis cost turns, which is the whole reason they are
        // worth a move slot.
        if actor.status == .sleep {
            board.note("\(name) is fast asleep.")
            return
        }
        if actor.status == .paralysis, rolling, Double.random(in: 0...1) < 0.25 {
            board.note("\(name) is paralysed and cannot move.")
            return
        }

        switch choice {
        case .pass:
            return
        case .swap:
            return
        case .protectSelf(let index):
            let label = actor.moves.indices.contains(index) ? actor.moves[index].name : "Protect"
            if byMine { board.mine[slot].isProtected = true }
            else { board.theirs[slot].isProtected = true }
            board.note("\(name) used \(label) and braced.")
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            guard move.isDamaging else {
                support(move, byMine: byMine, slot: slot, target: target,
                        to: &board, rolling: rolling)
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
            board.note("\(name) used \(move.name).")

            // 2. The field: anything that stops it before it starts.
            let farScreens = byMine ? board.theirScreens : board.myScreens
            if move.isSpread, farScreens.wideGuard {
                board.note("Wide Guard blocked it.")
                return
            }
            // Armor Tail and Queenly Majesty refuse priority outright: nothing
            // with increased priority can be aimed at that Pokémon or its
            // partner. It is the reason Farigiraf is on Trick Room teams — it
            // is what stops a Fake Out taking the setup turn away.
            if move.priority > 0, move.aim == .foe || move.aim == .spread {
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

            var aimed = move.isSpread ? [0, 1] : [target]
            if !move.isSpread {
                let defenders = byMine ? board.theirs : board.mine
                if let pulled = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    defenders[$0].drawingFire && !defenders[$0].fainted }), pulled != target {
                    aimed = [pulled]
                    board.note("It was drawn to \(defenders[pulled].build.form.formLabel).")
                }
            }
            if rolling, !move.neverMisses, move.accuracy > 0,
               Double.random(in: 0...100) > Double(move.accuracy) {
                board.note("It missed.")
                // A move that hurts you when it misses hurts you when it misses.
                let costs = move.drawbacks
                if costs.crash > 0 {
                    let maxHP = actor.maxHP
                    let lost = Swift.max(1, Int(Double(maxHP) * costs.crash))
                    if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                    else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                    board.note("\(name) kept going and crashed.")
                }
                return
            }

            var totalDealt = 0
            for index in aimed {
                let defending = byMine ? board.theirs : board.mine
                guard defending.indices.contains(index), !defending[index].fainted else { continue }
                let hitName = defending[index].build.form.formLabel
                if defending[index].isProtected, move.isProtectable {
                    board.note("\(hitName) protected itself.")
                    continue
                }
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
                if byMine {
                    board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - landed)
                    if sashed { board.theirs[index].build.itemSpent = true }
                    if ateBerry { board.theirs[index].build.itemSpent = true }
                } else {
                    board.mine[index].hp = Swift.max(0, board.mine[index].hp - landed)
                    if sashed { board.mine[index].build.itemSpent = true }
                    if ateBerry { board.mine[index].build.itemSpent = true }
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
                contact(move, byMine: byMine, slot: slot, hit: index, rolling: rolling,
                        board: &board)
                flee(ifNeeded: index, ofMine: !byMine, wasAt: defending[index].hp,
                     board: &board)
                if move.name == "Fake Out" {
                    if byMine { board.theirs[index].flinched = true }
                    else { board.mine[index].flinched = true }
                    board.note("\(hitName) flinched.")
                }
                if result.notes.contains(where: { $0.contains("Weakness Policy") }) {
                    applySelf([.attack: 2, .spAttack: 2], toMine: !byMine, slot: index,
                              board: &board)
                    if byMine { board.theirs[index].build.itemSpent = true }
                    else { board.mine[index].build.itemSpent = true }
                }
                applyDrops(move.targetDrops, toMine: !byMine, slot: index, board: &board)
                let after = byMine ? board.theirs[index] : board.mine[index]
                if after.hp == 0 { board.note("\(hitName) fainted.") }
            }
            applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
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
    private static func contact(_ move: Move, byMine: Bool, slot: Int, hit: Int,
                                rolling: Bool, board: inout Board) {
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = byMine ? board.theirs : board.mine
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit) else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        let attackerName = attacker.build.form.formLabel
        let defenderName = defender.build.form.formLabel

        // Stamina does not need contact: any hit raises Defense.
        if defender.build.ability == "Stamina", !defender.fainted {
            applySelf([.defense: 1], toMine: !byMine, slot: hit, board: &board)
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
            if byMine { board.theirs[hit].status = .poison } else { board.mine[hit].status = .poison }
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
        if mine {
            board.mine.swapAt(slot, next)
            board.mine[slot].justArrived = true
            board.mine[slot].seen = true
        } else {
            board.theirs.swapAt(slot, next)
            board.theirs[slot].justArrived = true
            board.theirs[slot].seen = true
        }
        let arrival = (mine ? board.mine : board.theirs)[slot].build.form.formLabel
        board.note("\(name)'s \(team[slot].build.ability) sent it out. \(arrival) came in.")
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
    private static func applyDrops(_ drops: [Stat: Int], toMine: Bool, slot: Int,
                                   board: inout Board) {
        guard !drops.isEmpty else { return }
        let team = toMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        if ["Clear Body", "White Smoke", "Full Metal Body"].contains(team[slot].build.ability) {
            return
        }
        for (stat, amount) in drops {
            if toMine {
                board.mine[slot].build.boosts[stat.rawValue] =
                    Swift.max(-6, board.mine[slot].build.boosts[stat.rawValue] - amount)
            } else {
                board.theirs[slot].build.boosts[stat.rawValue] =
                    Swift.max(-6, board.theirs[slot].build.boosts[stat.rawValue] - amount)
            }
        }
        let names = drops.keys.map(\.short).sorted().joined(separator: " and ")
        board.note("\(team[slot].build.form.formLabel)'s \(names) fell.")
    }

    private static func applySelf(_ boosts: [Stat: Int], toMine: Bool, slot: Int,
                                  board: inout Board) {
        guard !boosts.isEmpty else { return }
        let team = toMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        for (stat, amount) in boosts {
            if toMine {
                board.mine[slot].build.boosts[stat.rawValue] =
                    Swift.min(6, board.mine[slot].build.boosts[stat.rawValue] + amount)
            } else {
                board.theirs[slot].build.boosts[stat.rawValue] =
                    Swift.min(6, board.theirs[slot].build.boosts[stat.rawValue] + amount)
            }
        }
        let names = boosts.keys.map(\.short).sorted().joined(separator: " and ")
        board.note("\(team[slot].build.form.formLabel)'s \(names) rose.")
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

        // Protect and its family arrive here whenever the move was picked as a
        // move rather than through the dedicated choice, which is how the
        // interface offers it and how the search sometimes picks it.
        if DuelEngine.protectMoves.contains(move.name) {
            if byMine { board.mine[slot].isProtected = true }
            else { board.theirs[slot].isProtected = true }
            board.note("\(name) braced itself.")
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
            board.field.weather = weather
            board.note("The weather turned.")
            return
        }
        if let terrain: Terrain = ["Grassy Terrain": .grassy, "Electric Terrain": .electric,
                                   "Misty Terrain": .misty,
                                   "Psychic Terrain": .psychic][move.name] {
            board.field.terrain = terrain
            board.note("The ground shifted.")
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
