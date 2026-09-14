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

    var fainted: Bool { hp <= 0 }
    var share: Double { maxHP > 0 ? max(0, Double(hp) / Double(maxHP)) : 0 }

    init(build: Combatant, moves: [Move], hp: Int? = nil) {
        self.build = build
        self.moves = moves
        self.maxHP = build.maxHP
        self.hp = hp ?? build.maxHP
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

    var myActive: ArraySlice<Fighter> { mine.prefix(2) }
    var theirActive: ArraySlice<Fighter> { theirs.prefix(2) }
}

@MainActor
extension Board {
    /// A board at the start of a game: two teams, the named leads out in front.
    ///
    /// Slots with nothing selected still need a set to fight with, so they get
    /// the same worth-ranked fallback the versus grid uses. A Pokémon with no
    /// moves is not a harmless one.
    init(mine myTeam: Team, theirs theirTeam: Team, store: Store,
         myLeads: [String] = [], theirLeads: [String] = [],
         field: Field = Field(isDoubles: true)) {
        func build(_ team: Team, leads: [String]) -> [Fighter] {
            let made: [(String, Fighter)] = team.slots.compactMap { slot in
                guard let form = slot.battleForm(in: store),
                      let combatant = slot.combatant(in: store) else { return nil }
                var moves = slot.moves.compactMap { store.move($0) }
                if !moves.contains(where: \.isDamaging) {
                    let pool = store.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
                    moves += pool.sorted {
                        store.moveValue($0, for: form, ability: combatant.ability, item: slot.item)
                            > store.moveValue($1, for: form, ability: combatant.ability, item: slot.item)
                    }.prefix(3)
                }
                return (form.id, Fighter(build: combatant, moves: moves))
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

    var isProtect: Bool { if case .protectSelf = self { return true }; return false }
    var isSwap: Bool { if case .swap = self { return true }; return false }
}

/// Both actives choosing at once, which is the unit a turn is actually played in.
struct Play: Hashable {
    var left: Choice
    var right: Choice
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
        case .swap: return 6
        case .protectSelf(let index), .attack(let index, _):
            return fighter.moves.indices.contains(index) ? fighter.moves[index].priority : 0
        }
    }

    /// Resolve one turn from both sides' choices.
    static func resolve(_ board: Board, mine: Play, theirs: Play, store: Store) -> Board {
        var out = board
        for index in out.mine.indices { out.mine[index].isProtected = false
                                        out.mine[index].flinched = false }
        for index in out.theirs.indices { out.theirs[index].isProtected = false
                                          out.theirs[index].flinched = false }

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
            apply(entry.choice, byMine: entry.mine, slot: entry.slot, to: &out, store: store)
        }

        // -- end of turn ------------------------------------------------------
        out.myTailwind = max(0, out.myTailwind - 1)
        out.theirTailwind = max(0, out.theirTailwind - 1)
        out.trickRoom = max(0, out.trickRoom - 1)
        for index in out.mine.indices {
            out.mine[index].protectedLast = out.mine[index].isProtected
            out.mine[index].justArrived = false
        }
        for index in out.theirs.indices {
            out.theirs[index].protectedLast = out.theirs[index].isProtected
            out.theirs[index].justArrived = false
        }
        return out
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

        switch team[active].build.ability {
        case "Intimidate":
            for index in opposing.indices.prefix(2) where !opposing[index].fainted {
                // The abilities that refuse a stat drop outright.
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

    private static func apply(_ choice: Choice, byMine: Bool, slot: Int,
                              to board: inout Board, store: Store) {
        let actor = byMine ? board.mine[slot] : board.theirs[slot]
        guard !actor.fainted, !actor.flinched else { return }

        switch choice {
        case .swap:
            return
        case .protectSelf:
            if byMine { board.mine[slot].isProtected = true }
            else { board.theirs[slot].isProtected = true }
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            guard move.isDamaging else {
                applyStatus(move, byMine: byMine, to: &board)
                return
            }
            let targets: [Int] = move.isSpread ? [0, 1] : [target]
            for index in targets {
                let defending = byMine ? board.theirs : board.mine
                guard defending.indices.contains(index), !defending[index].fainted else { continue }
                if defending[index].isProtected, move.isProtectable { continue }
                var defender = defending[index].build
                defender.atFullHP = defending[index].hp == defending[index].maxHP
                let result = DamageCalc.calculate(attacker: actor.build, defender: defender,
                                                  move: move, field: board.field)
                // Expected damage rather than the high roll: an equilibrium is
                // about what a line is worth on average, and the rest of the app
                // already answers the high-roll question.
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                let dealt = Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy)
                                .rounded())
                if byMine { board.theirs[index].hp = max(0, board.theirs[index].hp - dealt) }
                else { board.mine[index].hp = max(0, board.mine[index].hp - dealt) }
                // Fake Out only stops something that has not moved yet, which
                // is most of why it is clicked on the turn you switch in.
                if move.name == "Fake Out" {
                    if byMine { board.theirs[index].flinched = true }
                    else { board.mine[index].flinched = true }
                }
            }
        }
    }

    /// The status moves worth modelling for a single turn: the ones that change
    /// what the turn is worth rather than what the game is worth.
    private static func applyStatus(_ move: Move, byMine: Bool, to board: inout Board) {
        switch move.name {
        case "Tailwind":
            if byMine { board.myTailwind = 4 } else { board.theirTailwind = 4 }
        case "Trick Room":
            board.trickRoom = board.trickRoom > 0 ? 0 : 5
        default:
            break
        }
    }
}
