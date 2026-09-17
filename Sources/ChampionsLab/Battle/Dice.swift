//  Dice.swift
//  The one thing in the battle model that is genuinely global.
//
//  A played turn rolls; the search branches on the roll instead and weighs the
//  branches. Both read from here, which is why games cannot share a thread and
//  why the lab shards across processes rather than across cores.
//
//  It is a file of its own because everything else in the model reached into
//  TurnModel for it, and that made the orchestrator look like a dependency of
//  every aspect it orchestrates. It was not; they only wanted the dice.

import Foundation

enum Dice {
    /// How many dice rolls beyond a repeat Protect the search will branch on.
    ///
    /// One, measured rather than guessed. Each extra flip doubles the boards a
    /// cell produces, and the search answers by reaching fewer positions in the
    /// half second it was measured over:
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
    /// The accuracy replay cannot settle this -- it reads 5.3 at every setting,
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
    /// time -- the app's on the main actor, the duel's in its own loop -- and
    /// the search never touches this at all, because a search does not roll.
    nonisolated(unsafe) static var source: RandomNumberGenerator = SystemRandomNumberGenerator()
}
