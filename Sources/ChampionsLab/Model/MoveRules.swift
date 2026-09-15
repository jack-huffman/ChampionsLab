//  MoveRules.swift
//  Everything this project reads out of a move's printed text, parsed once.
//
//  The rules a move carries are written in its description, and reading them
//  from the text is what keeps the model honest — nobody has to remember that
//  Electro Shot skips its charging turn in rain, because the move says so. But
//  each of those questions is a regular expression, and the turn model asks
//  several of them about every move of every action of every cell of every
//  matrix. Profiling put a quarter of a turn's time in parsing text that had
//  not changed since the dex was generated.
//
//  So it is parsed once per move and kept. `Memo` owns the lock; the work
//  happens outside it, and a move's text never changes, so two threads racing
//  to parse the same one cost a few microseconds rather than a wrong answer.

import Foundation

extension Move {
    /// A move's rules, read off its text. Everything in here was a computed
    /// property; they are computed exactly once now and shared.
    struct Rules: Sendable {
        let aim: Aim
        let charge: Charge?
        let secondary: Secondary?
        let healing: Healing?
        let drainShare: Double?
        let targetDrops: [Stat: Int]
        let targetBoosts: [Stat: Int]
        let selfBoosts: [Stat: Int]
        let selfDrops: [Stat: Int]
        let confuses: Bool
        let doublesAfterFailure: Bool
        let breaksProtect: Bool
        let drawbacks: Drawbacks

        init(parsing move: Move) {
            aim = move.computedAim
            charge = move.computedCharge
            secondary = move.computedSecondary
            healing = move.computedHealing
            drainShare = move.computedDrainShare
            targetDrops = move.computedTargetDrops
            targetBoosts = move.computedTargetBoosts
            selfBoosts = move.computedSelfBoosts
            selfDrops = move.computedSelfDrops
            confuses = move.computedConfuses
            doublesAfterFailure = move.computedDoublesAfterFailure
            breaksProtect = move.computedBreaksProtect
            drawbacks = move.computeDrawbacks()
        }
    }

    private static let parsedRules = Memo<String, Rules>()

    /// This move's rules. Parsed on the first ask and kept: a move's text does
    /// not change, and the turn model asks constantly.
    var rules: Rules { Move.parsedRules.value(id) { Rules(parsing: self) } }

    var aim: Aim { rules.aim }
    var charge: Charge? { rules.charge }
    var secondary: Secondary? { rules.secondary }
    var healing: Healing? { rules.healing }
    var drainShare: Double? { rules.drainShare }
    var targetDrops: [Stat: Int] { rules.targetDrops }
    var targetBoosts: [Stat: Int] { rules.targetBoosts }
    var selfBoosts: [Stat: Int] { rules.selfBoosts }
    var selfDrops: [Stat: Int] { rules.selfDrops }
    var confuses: Bool { rules.confuses }
    var doublesAfterFailure: Bool { rules.doublesAfterFailure }
    var breaksProtect: Bool { rules.breaksProtect }
}
