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
        let secondaries: [Secondary]
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
            // The dataset's list when it has one, which is every move in a
            // dataset built with the reference table. The sentence parser is
            // the fallback, and it can only ever produce one.
            if let data = move.secondaryData {
                secondaries = data.compactMap(\.parsed)
            } else {
                secondaries = [move.computedSecondary].compactMap { $0 }
            }
            healing = move.computedHealing
            drainShare = move.computedDrainShare

            // Where the dataset supplies an effect, the sentence parser's
            // version of the *same* effect is dropped, or the turn would apply
            // it twice — Icy Wind taking two stages of Speed rather than one.
            //
            // Only the matching kind is dropped. Close Combat's own Defence
            // loss is not a secondary in the reference table at all, so its
            // parsed value is the only one there is and has to stay.
            var suppliesDrops = false, suppliesSelfBoosts = false
            var suppliesSelfDrops = false, suppliesConfusion = false
            for effect in secondaries {
                switch effect.kind {
                case .drops:      suppliesDrops = true
                case .selfBoosts: suppliesSelfBoosts = true
                case .selfDrops:  suppliesSelfDrops = true
                case .confuse:    suppliesConfusion = true
                default: break
                }
            }
            targetDrops = suppliesDrops ? [:] : move.computedTargetDrops
            targetBoosts = move.computedTargetBoosts
            selfBoosts = suppliesSelfBoosts ? [:] : move.computedSelfBoosts
            selfDrops = suppliesSelfDrops ? [:] : move.computedSelfDrops
            confuses = suppliesConfusion ? false : move.computedConfuses
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
    var secondaries: [Secondary] { rules.secondaries }
    /// The first one, for the places that only need to know whether a move has
    /// any secondary effect at all.
    var secondary: Secondary? { rules.secondaries.first }
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

extension Move {
    /// Whether the model reads this move's text into something it acts on.
    ///
    /// The parity audit needs this to tell two very different failures apart.
    /// A move whose only effect is a 10% paralysis never fires for the audit,
    /// because the audit does not roll dice — but the model does carry it, and
    /// calling that a gap sends someone looking for a bug that is not there.
    /// A move whose text parses into nothing is the real gap: the model has no
    /// idea what it does and will play it as a blank.
    var parsesIntoARule: Bool {
        let r = rules
        if !r.secondaries.isEmpty || r.healing != nil || r.drainShare != nil { return true }
        if !r.targetDrops.isEmpty || !r.targetBoosts.isEmpty { return true }
        if !r.selfBoosts.isEmpty || !r.selfDrops.isEmpty { return true }
        if r.confuses || r.doublesAfterFailure || r.breaksProtect { return true }
        if r.charge != nil { return true }
        return false
    }
}

extension Move {
    /// Triple Axel and Triple Kick get stronger with each blow: 20, 40, 60
    /// and 10, 20, 30. Held by name because it is a function in the reference
    /// rather than a piece of data, and it is a closed set of two.
    var escalates: Bool { id == "tripleaxel" || id == "triplekick" }

    /// How much damage this lands, counted in blows.
    ///
    /// Not a hit count: a number to multiply one blow's damage by. Three
    /// separate things make those differ.
    ///
    /// A plain multi-hit move lands two to five times, weighted the way the
    /// game weights it — two and three are three times as likely as four and
    /// five — and its accuracy is rolled once for the whole attack.
    ///
    /// Population Bomb, Triple Axel and Triple Kick roll accuracy for *every*
    /// blow and stop at the first miss, so ten blows at 90% is about six, not
    /// ten. `accuracy` here is the chance one blow lands, and the caller has
    /// already applied it once, which is why the sum starts at the zeroth
    /// power.
    ///
    /// And the two Triples get stronger as they go, so their blows are worth
    /// one, two and three of the first rather than one each.
    func blows(for ability: String, accuracy: Double, rolling: Bool,
               using dice: inout RandomNumberGenerator) -> Double {
        guard let hits, hits.count == 2, hits[1] > 1 else { return 1 }
        let fewest = hits[0], most = hits[1]
        let perBlow = multiaccuracy == true

        // How many blows are thrown, before any of them can miss.
        let thrown: Int
        if ability == "Skill Link" || fewest == most {
            thrown = most
        } else if !rolling {
            // The average of the game's weighting, which for two-to-five is
            // exactly three. Kept as a whole number so escalation can use it.
            thrown = (fewest == 2 && most == 5) ? 3 : (fewest + most) / 2
        } else if fewest == 2 && most == 5 {
            let roll = Double.random(in: 0..<1, using: &dice)
            thrown = roll < 0.375 ? 2 : roll < 0.75 ? 3 : roll < 0.875 ? 4 : 5
        } else {
            thrown = Int.random(in: fewest...most, using: &dice)
        }

        /// What one blow is worth, the first being one.
        func worth(_ blow: Int) -> Double { escalates ? Double(blow) : 1 }

        guard perBlow else {
            return (1...Swift.max(1, thrown)).reduce(0) { $0 + worth($1) }
        }
        let chance = Swift.max(0, Swift.min(1, accuracy))
        guard rolling else {
            // Expected value. The caller applied one accuracy already, so the
            // first blow is certain here and each one after costs another.
            var total = 0.0
            for blow in 1...Swift.max(1, thrown) {
                total += worth(blow) * pow(chance, Double(blow - 1))
            }
            return total
        }
        // A played turn: the first blow has already landed, and each one after
        // has to be rolled for. The attack ends at the first miss.
        var total = worth(1)
        for blow in 2...Swift.max(2, thrown) where thrown >= blow {
            guard Double.random(in: 0..<1, using: &dice) < chance else { break }
            total += worth(blow)
        }
        return total
    }

    /// Guillotine, Fissure, Horn Drill, Sheer Cold. Their listed power is 1,
    /// so working them out from power makes them the weakest attacks in the
    /// game rather than the most dangerous.
    var isOHKO: Bool { effect.hasPrefix("Knocks out the target") }
}
