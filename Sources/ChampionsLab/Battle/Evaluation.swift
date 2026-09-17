//  Evaluation.swift
//  What a position is worth, standing still.
//
//  The search looks a few turns ahead and then has to stop and ask how things
//  stand. This is the answer: health weighed by what each Pokemon is worth,
//  stat stages priced by what they do to damage, speed control and a Trick
//  Room credited to whoever they favour, and the whole thing bent through a
//  curve so that a lead reads as a chance of winning rather than a score.
//
//  The curve is the part that changes how the engine plays. Flat value made
//  it indifferent to variance; through the curve, a side that is ahead grows
//  cautious because a slip costs more than a gain is worth, and a side that
//  is behind takes the coin flip — which is how the position is actually
//  played by people who play it well.

import Foundation

enum Evaluation {
    /// What a board is worth to the side that owns `mine`.
    ///
    /// Deliberately simple, and zero-sum by construction so the matrix has an
    /// equilibrium. Staying alive is worth a lot more than the last third of a
    /// health bar: a Pokémon on one point still gets to act, still threatens,
    /// still has to be answered, and a model that values only health throws
    /// bodies away for chip damage.
    static func value(_ board: Board) -> Double {
        func side(_ team: [Fighter], _ worth: [String: Double], _ countStages: Bool,
                  _ floor: Double) -> Double {
            team.reduce(0) { total, fighter in
                guard !fighter.fainted else { return total }
                // Only a Pokémon that has stood on the field carries a weight.
                // One still on the bench is worth exactly one, whoever it is.
                //
                // This is the hidden-information rule. Weights are looked up by
                // form, so weighting a Pokémon the other side has never seen
                // would let its *identity* move the value of the board — and
                // there are solve paths that fall back to the true board, so it
                // is not enough to strip the weights from their view alone.
                //
                // Worth is around one, so a side with no weights scores exactly
                // as it did before there were any.
                let weight = fighter.seen ? (worth[fighter.build.form.id] ?? 1) : 1
                return total + weight * (floor + (1 - floor) * fighter.share)
                    + (countStages ? stages(fighter) : 0)
            }
        }
        // Both sides weighed, which is what lets the engine prefer to knock out
        // the Pokémon that actually threatens it. Only what has been seen
        // carries a weight, which is where the hidden-information rule is kept.
        var out = side(board.mine, board.myWorth, board.myCountsStages, board.myAliveFloor)
            - side(board.theirs, board.theirWorth, board.theirCountsStages, board.theirAliveFloor)
        out += speedControl(board.myTailwind, under: board.trickRoom)
            - speedControl(board.theirTailwind, under: board.trickRoom)
        out += trickRoomEdge(board)
        return out
    }

    /// What the stat stages on a Pokémon are worth.
    ///
    /// They were worth nothing at all, which made every disruption move look
    /// like a wasted turn. An Intimidate, a Snarl, an Icy Wind, a Parting Shot
    /// — the whole way a support Pokémon earns its slot — showed up only as
    /// whatever damage the search happened to see inside its horizon, and at a
    /// short budget that horizon is a turn or two. So the engine would not pay
    /// a turn to take an attacker's Attack away, and could not see why anybody
    /// would cycle an Intimidate in and out to keep doing it.
    ///
    /// Priced off the damage multiplier a stage actually produces rather than
    /// counted flat, because the two are not the same shape: +1 is half again,
    /// while −1 is a third off. A stage on the attacking stat a Pokémon does
    /// not use is worth almost nothing, which is why the two are told apart.
    private static func stages(_ fighter: Fighter) -> Double {
        let boosts = fighter.build.boosts
        guard boosts.count >= 6, boosts.contains(where: { $0 != 0 }) else { return 0 }
        func multiplier(_ stage: Int) -> Double {
            stage >= 0 ? Double(2 + stage) / 2 : 2 / Double(2 - stage)
        }
        func worth(_ stat: Stat, _ scale: Double) -> Double {
            let stage = boosts[stat.rawValue]
            guard stage != 0 else { return 0 }
            return (multiplier(stage) - 1) * scale
        }
        // Whichever side it actually attacks from. The other is nearly idle:
        // a Special Attack drop on a Rillaboom costs it almost nothing.
        let physical = fighter.build.form.attack >= fighter.build.form.spAttack
        var out = worth(physical ? .attack : .spAttack, 0.16)
        out += worth(physical ? .spAttack : .attack, 0.03)
        // Taking a hit is worth about what landing one is.
        out += worth(.defense, 0.11)
        out += worth(.spDefense, 0.11)
        // Speed only pays when it changes who goes first, which this cannot
        // see from here, so it is priced low and honestly.
        out += worth(.speed, 0.07)
        return Swift.max(-0.9, Swift.min(0.9, out))
    }

    /// A position's material margin, turned into a chance of winning from it.
    ///
    /// Material is linear and winning is not, and the difference is the whole
    /// of how a good player handles risk. Strong players say it plainly:
    ///
    ///     "When you're ahead, only predict if being right wins the game
    ///      outright and being wrong doesn't throw your lead. When you're
    ///      behind, predict when no safe play covers all their options and
    ///      losing without a read is otherwise inevitable."
    ///
    /// An engine maximising material cannot do either, because material is
    /// risk-neutral: it plays a position it is winning by three exactly as it
    /// plays one it is losing by three, and a coin flip worth ±1 looks the same
    /// from both. Scoring a turn by how far it moves this curve instead makes
    /// the engine cautious when it is ahead and willing when it is behind —
    /// not as a rule bolted on, but because that is what the curve does. It is
    /// flat out at the ends, so at +3 another point of material buys almost no
    /// extra chance of winning while a slip costs a great deal, and at −3 the
    /// reverse.
    ///
    /// The slope is set so a one-Pokémon lead reads as roughly two chances in
    /// three, which is about where a real game with a Pokémon in hand sits.
    static func winChance(_ value: Double) -> Double {
        1 / (1 + exp(-value * 0.72))
    }

    /// What a Trick Room is worth, and to whom.
    ///
    /// It was worth nothing. The room reverses the order, so the engine saw
    /// its effect inside the search — the slow Pokémon moving first — and
    /// nothing at all about having it up. Setting one therefore looked like a
    /// spent turn, and running one down looked like no achievement, which is
    /// the opposite of how a game around Trick Room is actually played:
    ///
    ///     "Your goal is to minimise the number of turns where your opponent
    ///      can actually benefit from Trick Room."
    ///
    /// Credited to whichever side is slower on the field, because that is the
    /// side it is for, and scaled by the turns left — a room with one turn on
    /// it is nearly spent.
    private static func trickRoomEdge(_ board: Board) -> Double {
        guard board.trickRoom > 0 else { return 0 }
        func speed(_ team: [Fighter]) -> Int {
            let up = team.prefix(board.activeCount).filter { !$0.fainted }
            guard !up.isEmpty else { return 0 }
            return up.reduce(0) { $0 + $1.build.speed(in: board.field) } / up.count
        }
        let mine = speed(board.mine), theirs = speed(board.theirs)
        guard mine != theirs else { return 0 }
        // Half a Pokémon at its fullest, falling away as the room runs out.
        let turns = Swift.min(4, board.trickRoom)
        let worth = 0.13 * Double(turns)
        return mine < theirs ? worth : -worth
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
}
