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

    /// The teams people actually registered, turned into something playable.
    ///
    /// The first version of this drew six Pokémon from the usage table and gave
    /// each one its three strongest attacks. It was fair — both engines faced
    /// the same draws — but it produced damage races, and a damage race is a
    /// position where thinking harder barely helps. That is a bad place to
    /// measure an engine from.
    ///
    /// The dataset already carries a hundred and twelve real lists, with the
    /// items, abilities and movesets their owners chose: Fake Out, U-turn,
    /// Tailwind, Choice Scarf, the support moves that make a turn a decision
    /// rather than an exchange. Those are the games worth learning from.
    ///
    /// Stat spreads are the one thing a registered list never publishes, so
    /// they are still worked out here — towards whichever side the Pokémon
    /// actually attacks from.
    static func teams(from dataset: Dataset, rules: Rulebook) -> [Team] {
        dataset.metaTeams.compactMap { entry -> Team? in
            var out = Team()
            out.format = entry.format.isEmpty ? "doubles" : entry.format
            out.name = entry.name
            out.slots = entry.members.compactMap { member -> TeamSlot? in
                guard let form = rules.forms.first(where: {
                    $0.formLabel == member.form || $0.name == member.form
                }) else { return nil }
                var slot = TeamSlot(formID: form.id)
                slot.item = member.item
                slot.ability = member.ability.isEmpty
                    ? (form.abilities.first?.name ?? "") : member.ability
                slot.moves = member.moves.compactMap { name in
                    rules.moves.values.first { $0.name == name }?.id
                }
                if slot.moves.isEmpty { return nil }
                let physical = form.attack >= form.spAttack
                var sp = Array(repeating: 0, count: 6)
                sp[Stat.hp.rawValue] = 20
                sp[(physical ? Stat.attack : Stat.spAttack).rawValue] = 23
                sp[Stat.speed.rawValue] = 23
                slot.sp = sp
                slot.alignmentName = member.nature ?? (physical ? "Adamant" : "Modest")
                return slot
            }
            // A list that lost most of itself to a form or move this dataset
            // does not carry is not a game worth playing.
            return out.slots.count >= 4 ? out : nil
        }
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
