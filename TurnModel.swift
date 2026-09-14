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

    var myActive: ArraySlice<Fighter> { mine.prefix(activeCount) }
    var theirActive: ArraySlice<Fighter> { theirs.prefix(activeCount) }

    /// Whether a side has anything left to send out.
    func isOut(mine side: Bool) -> Bool {
        (side ? mine : theirs).allSatisfy(\.fainted)
    }

    /// Bring the next healthy Pokémon forward into an empty slot. Replacing a
    /// fainted Pokémon is not a turn, it happens at the end of one.
    mutating func fillGaps() {
        func refill(_ team: inout [Fighter]) {
            for slot in 0..<min(activeCount, team.count) where team[slot].fainted {
                guard let next = (activeCount..<team.count).first(where: { !team[$0].fainted })
                else { continue }
                team.swapAt(slot, next)
                team[slot].justArrived = true
            }
        }
        refill(&mine)
        refill(&theirs)
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
        self.init(mine: build(myTeam, leads: myLeads),
                  theirs: build(theirTeam, leads: theirLeads),
                  field: field)
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

    /// The order the four actions resolve in.
    ///
    /// Priority first, then Speed, and Trick Room inverts the Speed half only.
    /// Switching is not in here: it happens before any of it.
    private static func order(_ entries: [(mine: Bool, slot: Int, choice: Choice,
                                           priority: Int, speed: Int)],
                              trickRoom: Bool) -> [(mine: Bool, slot: Int, choice: Choice)] {
        entries.sorted { first, second in
            if first.priority != second.priority { return first.priority > second.priority }
            if first.speed != second.speed {
                return trickRoom ? first.speed < second.speed : first.speed > second.speed
            }
            // A genuine tie is a coin flip in the game. Resolved consistently
            // here so the matrix is deterministic, and noted as a limit.
            return first.mine && !second.mine
        }
        .map { (mine: $0.mine, slot: $0.slot, choice: $0.choice) }
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
                        rolling: Bool = false) -> Board {
        var out = board
        out.story = []
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

        for entry in order(entries, trickRoom: out.trickRoom > 0) {
            apply(entry.choice, byMine: entry.mine, slot: entry.slot, to: &out,
                  store: store, rolling: rolling)
        }

        endOfTurn(&out, rolling: rolling)

        return out
    }

    /// Everything that happens after both sides have acted.
    ///
    /// Weather chips, berries and Leftovers fire, burn and poison take their
    /// cut, and the clocks tick. None of it existed: a sandstorm did nothing, a
    /// Sitrus Berry never healed, a Focus Sash worked every turn for ever
    /// because nothing ever marked it as used.
    private static func endOfTurn(_ board: inout Board, rolling: Bool) {
        func settle(_ team: inout [Fighter], active: Int, mine: Bool) {
            for index in 0..<min(active, team.count) where !team[index].fainted {
                let name = team[index].build.form.formLabel
                let max = team[index].maxHP
                let types = team[index].build.form.pokeTypes

                // Weather, which only some types stand in.
                if board.field.weather == .sand,
                   !types.contains(where: { [.rock, .ground, .steel].contains($0) }) {
                    team[index].hp -= Swift.max(1, max / 16)
                    board.story.append("The sandstorm buffets \(name).")
                }
                // Grassy Terrain heals whatever is standing on the ground.
                if board.field.terrain == .grassy, !types.contains(.flying),
                   team[index].build.ability != "Levitate", team[index].hp < max {
                    team[index].hp = Swift.min(max, team[index].hp + Swift.max(1, max / 16))
                    board.story.append("Grassy Terrain tops \(name) up.")
                }
                switch team[index].status {
                case .burn:
                    team[index].hp -= Swift.max(1, max / 16)
                    board.story.append("\(name) is hurt by its burn.")
                case .poison:
                    team[index].hp -= Swift.max(1, max / 8)
                    board.story.append("\(name) is hurt by poison.")
                default: break
                }
                // Items that fire on their own.
                if team[index].build.item == "Leftovers", team[index].hp < max,
                   team[index].hp > 0 {
                    team[index].hp = Swift.min(max, team[index].hp + Swift.max(1, max / 16))
                    board.story.append("\(name) restores a little with its Leftovers.")
                }
                if team[index].build.item == "Sitrus Berry", !team[index].build.itemSpent,
                   team[index].hp > 0, team[index].hp <= max / 2 {
                    team[index].hp = Swift.min(max, team[index].hp + max / 4)
                    team[index].build.itemSpent = true
                    board.story.append("\(name) eats its Sitrus Berry.")
                }
                if team[index].hp <= 0 {
                    team[index].hp = 0
                    board.story.append("\(name) fainted.")
                }
            }
        }
        settle(&board.mine, active: board.activeCount, mine: true)
        settle(&board.theirs, active: board.activeCount, mine: false)

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
        team.swapAt(active, bench)
        team[active].justArrived = true
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
            board.story.append("\(name) flinched and could not move.")
            return
        }
        // Sleep and paralysis cost turns, which is the whole reason they are
        // worth a move slot.
        if actor.status == .sleep {
            board.story.append("\(name) is fast asleep.")
            return
        }
        if actor.status == .paralysis, rolling, Double.random(in: 0...1) < 0.25 {
            board.story.append("\(name) is paralysed and cannot move.")
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
            board.story.append("\(name) used \(label) and braced.")
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            guard move.isDamaging else {
                support(move, byMine: byMine, slot: slot, target: target,
                        to: &board, rolling: rolling)
                return
            }
            board.story.append("\(name) used \(move.name).")

            // Wide Guard turns a spread move away from the whole side.
            let theirScreens = byMine ? board.theirScreens : board.myScreens
            if move.isSpread, theirScreens.wideGuard {
                board.story.append("Wide Guard blocked it.")
                return
            }
            // Redirection: a single-target move goes where the powder is.
            var aimed = move.isSpread ? [0, 1] : [target]
            if !move.isSpread {
                let defenders = byMine ? board.theirs : board.mine
                if let pulled = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                    defenders[$0].drawingFire && !defenders[$0].fainted }), pulled != target {
                    aimed = [pulled]
                    board.story.append("It was drawn to \(defenders[pulled].build.form.formLabel).")
                }
            }

            if rolling, !move.neverMisses, move.accuracy > 0,
               Double.random(in: 0...100) > Double(move.accuracy) {
                board.story.append("It missed.")
                return
            }

            for index in aimed {
                let defending = byMine ? board.theirs : board.mine
                guard defending.indices.contains(index), !defending[index].fainted else { continue }
                let hitName = defending[index].build.form.formLabel
                if defending[index].isProtected, move.isProtectable {
                    board.story.append("\(hitName) protected itself.")
                    continue
                }
                var defender = defending[index].build
                defender.atFullHP = defending[index].hp == defending[index].maxHP
                // Screens belong to the side being hit, and a burn halves what a
                // physical attacker does.
                var field = board.field
                field.screen = (byMine ? board.theirScreens : board.myScreens).blunt(move)
                var attacker = actor.build
                if actor.status.halvesPhysical, move.category == "Physical" {
                    attacker.boosts[Stat.attack.rawValue] -= 1
                }
                let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                                  move: move, field: field)
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                // Rolling for a battle, averaging for a search.
                let dealt: Int = rolling
                    ? Int.random(in: Swift.min(result.minDamage, result.maxDamage)
                                 ... Swift.max(result.minDamage, result.maxDamage))
                    : Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy).rounded())

                var landed = dealt
                var spent = false
                // A Focus Sash is used once, and only from full health.
                if defending[index].build.item == "Focus Sash",
                   !defending[index].build.itemSpent,
                   defending[index].hp == defending[index].maxHP,
                   dealt >= defending[index].hp {
                    landed = defending[index].hp - 1
                    spent = true
                }
                if byMine {
                    board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - landed)
                    if spent {
                        board.theirs[index].build.itemSpent = true
                        board.story.append("\(hitName) hung on with its Focus Sash.")
                    }
                } else {
                    board.mine[index].hp = Swift.max(0, board.mine[index].hp - landed)
                    if spent {
                        board.mine[index].build.itemSpent = true
                        board.story.append("\(hitName) hung on with its Focus Sash.")
                    }
                }
                if result.effectiveness > 1 {
                    board.story.append("It is super effective on \(hitName) — \(landed).")
                } else if result.effectiveness < 1 && result.effectiveness > 0 {
                    board.story.append("\(hitName) resists it — \(landed).")
                } else {
                    board.story.append("\(hitName) took \(landed).")
                }
                if move.name == "Fake Out" {
                    if byMine { board.theirs[index].flinched = true }
                    else { board.mine[index].flinched = true }
                    board.story.append("\(hitName) flinched.")
                }
                // Anything the move takes off the target.
                applyDrops(move.targetDrops, toMine: !byMine, slot: index, board: &board)
            }
            // And anything it does to the user.
            applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
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
        board.story.append("\(team[slot].build.form.formLabel)'s \(names) fell.")
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
        board.story.append("\(team[slot].build.form.formLabel)'s \(names) rose.")
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
        board.story.append("\(name) used \(move.name).")

        // Protect and its family arrive here whenever the move was picked as a
        // move rather than through the dedicated choice, which is how the
        // interface offers it and how the search sometimes picks it.
        if DuelEngine.protectMoves.contains(move.name) {
            if byMine { board.mine[slot].isProtected = true }
            else { board.theirs[slot].isProtected = true }
            board.story.append("\(name) braced itself.")
            return
        }

        switch move.name {
        case "Tailwind":
            if byMine { board.myTailwind = 4 } else { board.theirTailwind = 4 }
            board.story.append("The wind picked up behind \(byMine ? "you" : "them").")
            return
        case "Trick Room":
            board.trickRoom = board.trickRoom > 0 ? 0 : 5
            board.story.append(board.trickRoom > 0
                               ? "The dimensions twisted." : "The twisted dimensions returned.")
            return
        case "Follow Me", "Rage Powder":
            if byMine { board.mine[slot].drawingFire = true }
            else { board.theirs[slot].drawingFire = true }
            board.story.append("\(name) drew attention to itself.")
            return
        case "Wide Guard":
            if byMine { board.myScreens.wideGuard = true }
            else { board.theirScreens.wideGuard = true }
            board.story.append("A wide barrier went up.")
            return
        case "Reflect":
            if byMine { board.myScreens.reflect = 5 } else { board.theirScreens.reflect = 5 }
            board.story.append("Reflect went up.")
            return
        case "Light Screen":
            if byMine { board.myScreens.lightScreen = 5 }
            else { board.theirScreens.lightScreen = 5 }
            board.story.append("Light Screen went up.")
            return
        case "Aurora Veil":
            if byMine { board.myScreens.auroraVeil = 5 }
            else { board.theirScreens.auroraVeil = 5 }
            board.story.append("Aurora Veil went up.")
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
            board.story.append("The weather turned.")
            return
        }
        if let terrain: Terrain = ["Grassy Terrain": .grassy, "Electric Terrain": .electric,
                                   "Misty Terrain": .misty,
                                   "Psychic Terrain": .psychic][move.name] {
            board.field.terrain = terrain
            board.story.append("The ground shifted.")
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
                board.story.append("It had no effect.")
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
                board.story.append("\(victim.build.form.formLabel) is not affected.")
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
            board.story.append("\(victim.build.form.formLabel) is \(ailment.rawValue).")
            return
        }
        board.story.append("Nothing came of it.")
    }
}
