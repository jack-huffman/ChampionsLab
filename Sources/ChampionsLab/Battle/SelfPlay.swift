//  SelfPlay.swift
//  Playing a whole game out, with an engine in each chair.
//
//  This is the machinery behind `make duel`. It lives in the library rather
//  than in the tool because it is the only place that knows how to take a
//  position from the opening to somebody winning, and a test wants that too.

import Foundation

enum SelfPlay {
    enum Winner: Sendable { case mine, theirs, none }

    struct Outcome: Sendable {
        let winner: Winner
        let turns: Int
    }

    /// Six drawn from a pool, no repeats, with a plausible set on each.
    ///
    /// Not a good team — a good team is the team builder's job — but a legal
    /// and varied one, which is what an evaluation needs. Both engines face the
    /// same draws, so any weakness in the drawing hurts them equally.
    static func team<G: RandomNumberGenerator>(
        from pool: [Form], rules: Rulebook, using dice: inout G) -> Team {
        var out = Team()
        out.format = "doubles"
        var taken = Set<String>()
        var slots: [TeamSlot] = []
        var guard_ = 0
        while slots.count < 6, guard_ < 400 {
            guard_ += 1
            guard let form = pool.randomElement(using: &dice) else { break }
            // One of a species, the way a real list is built.
            if !taken.insert(form.species).inserted { continue }
            var slot = TeamSlot(formID: form.id)
            slot.ability = form.abilities.first?.name ?? ""
            slot.item = form.stone ?? "Leftovers"
            // Four damaging moves it can actually learn, plus Protect when it
            // has it: enough to make the turns mean something.
            let known = form.moves.compactMap { rules.move($0) }
            // Moves it can actually put its stat behind, for the same reason.
            let wants = form.attack >= form.spAttack ? "Physical" : "Special"
            let hits = known.filter { $0.isDamaging && $0.power >= 60 && $0.category == wants }
            var picked = (hits.isEmpty ? known.filter { $0.isDamaging && $0.power >= 60 } : hits)
                .sorted { $0.power > $1.power }.prefix(3).map(\.id)
            if let protect = known.first(where: { $0.name == "Protect" }) {
                picked.append(protect.id)
            }
            if picked.count < 4 {
                picked += known.filter { !picked.contains($0.id) }.prefix(4 - picked.count).map(\.id)
            }
            slot.moves = Array(picked.prefix(4))

            // Built towards whichever side it actually hits from. Putting every
            // Pokémon on Attack was fair, because both engines faced the same
            // teams, but it made half the field play like nothing anybody
            // brings — a Special Attack Pokémon with no Special Attack is not
            // a position worth learning from.
            let physical = form.attack >= form.spAttack
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.hp.rawValue] = 20
            sp[(physical ? Stat.attack : Stat.spAttack).rawValue] = 23
            sp[Stat.speed.rawValue] = 23
            slot.sp = sp
            slot.alignmentName = physical ? "Adamant" : "Modest"
            slots.append(slot)
        }
        out.slots = slots
        return out
    }

    /// A configuration in one of the two chairs.
    struct Seat: Sendable {
        let engine: BattleEngine
        let branchedRolls: Int
        init(engine: BattleEngine, branchedRolls: Int) {
            self.engine = engine
            self.branchedRolls = branchedRolls
        }
    }

    /// Play until one side has nothing left, or the clock runs out.
    ///
    /// Each side is asked for its move on its *own* view of the board, which
    /// for the far side means the board turned round. Neither is handed the
    /// other's hidden bench: the two-board solve already keeps that honest, and
    /// an evaluation that leaked it would be measuring the wrong thing.
    static func play(
        mine: Team, theirs: Team, rules: Rulebook,
        forMine: Seat, forTheirs: Seat,
        limit: Int = 40, dice: RandomNumberGenerator) -> Outcome {

        // The battle's own dice, not just the engine's play sampling. Handing
        // both halves of a mirrored pair the same stream is what lets the
        // mirroring cancel the luck as well as the draw.
        let wasDice = TurnModel.dice
        TurnModel.dice = dice
        defer { TurnModel.dice = wasDice }

        var board = Board(mine: mine, theirs: theirs, rules: rules,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        board.narrating = false
        board.sendOutLeads()

        for turn in 1...limit {
            if board.isOut(mine: false) { return Outcome(winner: .mine, turns: turn) }
            if board.isOut(mine: true) { return Outcome(winner: .theirs, turns: turn) }

            TurnModel.branchedRolls = forMine.branchedRolls
            let ours = choose(forMine.engine, on: board)
            TurnModel.branchedRolls = forTheirs.branchedRolls
            let theirsPlay = choose(forTheirs.engine, on: board.flipped)

            TurnModel.branchedRolls = forMine.branchedRolls
            board = TurnModel.resolve(board, mine: ours, theirs: theirsPlay, rolling: true)
            board.fillGaps()
        }
        // Nobody finished it. Whoever is further ahead on the board takes it,
        // because calling a clear lead a draw would hide a real difference.
        let standing = TurnModel.value(board)
        if standing > 0.25 { return Outcome(winner: .mine, turns: limit) }
        if standing < -0.25 { return Outcome(winner: .theirs, turns: limit) }
        return Outcome(winner: .none, turns: limit)
    }

    /// One play, sampled from the equilibrium the engine found.
    ///
    /// Sampled rather than taken at its most likely, because the equilibrium is
    /// a mix for a reason: always playing its favourite makes an engine
    /// readable, and two engines that both do it play a stranger game than
    /// either would against a person.
    private static func choose(_ engine: BattleEngine, on board: Board) -> Play {
        let thought = engine.think(board)
        guard !thought.plays.isEmpty else { return Play(left: .pass, right: .pass) }
        let total = thought.mix.reduce(0, +)
        guard total > 0 else { return thought.plays[0] }
        var roll = Double.random(in: 0..<total, using: &TurnModel.dice)
        for (index, weight) in thought.mix.enumerated() {
            roll -= weight
            if roll <= 0, thought.plays.indices.contains(index) { return thought.plays[index] }
        }
        return thought.plays[0]
    }
}
