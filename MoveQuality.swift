//  MoveQuality.swift
//  What a move is actually worth, rather than what its base power says.
//
//  Ranking on base power alone is how an engine ends up recommending Steel Beam
//  over Iron Head: 140 against 80 looks decisive until you price in the 95%
//  accuracy and the half of your own HP it costs you every single time. Players
//  do not make that trade, and neither should the builder.
//
//  Three things get priced here, all read out of Serebii's effect text so the
//  model stays data-driven rather than a list of special cases:
//
//    1. Accuracy, twice over — once as plain expected value, and once more as a
//       consistency penalty, because a 70% move is worth less than 70% of a
//       100% move to anyone who has lost a game to Focus Blast.
//    2. Multi-hit maths, so Triple Axel is not ranked as a 20 BP move.
//    3. What the move costs its user: recoil, crash damage, guaranteed self
//       damage, stat drops, and being left Wide Open.
//
//  Abilities and items that undo those costs are respected — Rock Head cancels
//  recoil, Magic Guard cancels all of it, No Guard fixes accuracy, Contrary
//  turns Draco Meteor's drop into a reason to click it.

import Foundation

struct MoveQuality {
    /// Base power after multi-hit and variable-power effects are averaged.
    let rawPower: Double
    /// Chance the move does anything at all this turn.
    let hitChance: Double
    /// The preference for consistency, over and above expected value.
    let consistency: Double
    /// What the move costs its user, as a multiplier on its worth.
    let costFactor: Double
    let notes: [String]

    /// The number to rank on: base power you can actually count on.
    var expectedPower: Double { rawPower * hitChance * consistency * costFactor }

    /// A 0…1 scale to apply to a computed damage figure when scoring a matchup,
    /// so a 70% accurate "OHKO" does not count as a guaranteed one.
    var reliability: Double { min(1, hitChance * consistency * costFactor) }

    var isReliable: Bool { reliability >= 0.9 }

    /// How the raw number was discounted, for the UI to explain itself.
    var summary: String {
        notes.isEmpty ? "No drawbacks" : notes.joined(separator: " · ")
    }
}

extension Move {
    /// The self-inflicted costs and oddities parsed out of the effect text.
    struct Drawbacks {
        /// Fraction of the damage dealt taken back — Brave Bird, Head Smash.
        var recoil = 0.0
        /// Fraction of max HP taken unconditionally — Steel Beam.
        var selfDamage = 0.0
        /// Fraction of max HP taken on a miss — High Jump Kick.
        var crash = 0.0
        /// Stages the user loses, split because losing Sp. Atk hurts a
        /// wallbreaker far more than losing Defense does.
        var offensiveDrops = 0
        var otherDrops = 0
        /// Glaive Rush: everything hits you for double until you next act.
        var leavesOpen = false
        /// Sucker Punch and friends, which fail outright on the wrong read.
        var conditional = false
        /// First Impression and Fake Out: they work every time you send the
        /// Pokémon in, and never otherwise. That is a cost, but it is not the
        /// same cost as a prediction — it is timing you control completely.
        /// Charging them the read penalty scored a 100 BP priority move below
        /// an 85 BP neutral one, and the builder then wanted to cut it.
        var firstTurnOnly = false
        /// Outrage and Thrash: locked in for two or three turns, confused after.
        /// Far worse in doubles, where the target you were aimed at leaves.
        var rampaging = false
        /// (minimum, maximum) strikes, and whether a miss ends the sequence.
        var hits: (min: Int, max: Int, stopsOnMiss: Bool)?
        /// Triple Axel's 20/40/60 ramp.
        var escalating = false
        /// Fickle Beam's coin flip for double power.
        var doubleChance = 0.0
    }

    var drawbacks: Drawbacks {
        var out = Drawbacks()
        let text = effect

        if let fraction = Move.fraction(in: text, after: #"user takes ([\d/]+) of the damage dealt"#) {
            out.recoil = fraction
        }
        if let fraction = Move.fraction(
            in: text, after: #"After attacking the user takes damage equal to ([\d/]+) of its max HP"#) {
            out.selfDamage = fraction
        }
        if let fraction = Move.fraction(
            in: text, after: #"misses or fails the user takes damage equal to ([\d/]+) of its max HP"#) {
            out.crash = fraction
        }
        if text.contains("Wide Open") { out.leavesOpen = true }
        if text.contains("first move used by the user after it enters a battle") {
            out.firstTurnOnly = true
        } else if text.contains("This move fails unless") || text.contains("This move fails if") {
            out.conditional = true
        }
        if text.contains("Rampaging status") { out.rampaging = true }

        // "Lowers the user's Sp. Atk stat by 2 stages."
        if let phrase = Move.match(#"Lowers the user's ([A-Za-z. ,]+?) stats? by (\d+) stage"#, in: text),
           let amount = Int(phrase[2]) {
            for piece in phrase[1].components(separatedBy: ",")
                .flatMap({ $0.components(separatedBy: " and ") }) {
                switch piece.trimmingCharacters(in: .whitespaces) {
                case "Attack", "Sp. Atk": out.offensiveDrops += amount
                case "Defense", "Sp. Def", "Speed": out.otherDrops += amount
                default: break
                }
            }
        }

        let stopsOnMiss = text.contains("attack ends if the user misses")
            || text.contains("The attack ends if")
        if let phrase = Move.match(#"attacks (\d+) to (\d+) times"#, in: text),
           let low = Int(phrase[1]), let high = Int(phrase[2]) {
            out.hits = (low, high, stopsOnMiss)
        } else if text.contains("attacks twice in a row") {
            out.hits = (2, 2, stopsOnMiss)
        } else if let phrase = Move.match(#"attacks (\d+) times in a row"#, in: text),
                  let count = Int(phrase[1]) {
            out.hits = (count, count, stopsOnMiss)
        }
        if text.contains("first with a power of") { out.escalating = true }

        if let phrase = Move.match(#"(\d+)% chance of its power being doubled"#, in: text),
           let chance = Double(phrase[1]) {
            out.doubleChance = chance / 100
        }
        return out
    }

    /// Price the move for whoever is actually holding it.
    func quality(ability: String = "", item: String = "") -> MoveQuality {
        guard isDamaging, power > 0 else {
            return MoveQuality(rawPower: 0, hitChance: 1, consistency: 1,
                               costFactor: 1, notes: [])
        }
        var costs = drawbacks
        var notes: [String] = []

        // -- accuracy --------------------------------------------------------
        var accurate = neverMisses || accuracy == 0 ? 1.0 : Double(accuracy) / 100
        switch ability {
        case "No Guard":
            if accurate < 1 { notes.append("No Guard: never misses") }
            accurate = 1
        case "Compound Eyes": accurate = min(1, accurate * 1.3)
        case "Victory Star":  accurate = min(1, accurate * 1.1)
        case "Hustle" where category == "Physical": accurate *= 0.8
        default: break
        }
        if item == "Wide Lens" { accurate = min(1, accurate * 1.1) }
        if item == "Zoom Lens" { accurate = min(1, accurate * 1.2) }

        // -- what it costs the user -----------------------------------------
        switch ability {
        case "Magic Guard":
            if costs.recoil > 0 || costs.crash > 0 || costs.selfDamage > 0 {
                notes.append("Magic Guard: no self-damage")
            }
            costs.recoil = 0; costs.crash = 0; costs.selfDamage = 0
        case "Rock Head":
            if costs.recoil > 0 { notes.append("Rock Head: no recoil") }
            costs.recoil = 0
        default: break
        }
        if ability == "Reckless", costs.recoil > 0 {
            notes.append("Reckless: +20% for the recoil")
        }

        var cost = 1.0
        if costs.recoil > 0 {
            cost *= 1 - costs.recoil * 0.28
            notes.append(String(format: "%.0f%% recoil", costs.recoil * 100))
        }
        if costs.selfDamage > 0 {
            cost *= 1 - costs.selfDamage * 0.60
            notes.append(String(format: "costs %.0f%% of your own HP every time",
                                costs.selfDamage * 100))
        }
        if costs.crash > 0 {
            cost *= 1 - (1 - accurate) * costs.crash * 0.9
            notes.append(String(format: "%.0f%% crash damage on a miss", costs.crash * 100))
        }
        if costs.offensiveDrops > 0 || costs.otherDrops > 0 {
            if ability == "Contrary" {
                cost *= 1 + 0.075 * Double(costs.offensiveDrops + costs.otherDrops)
                notes.append("Contrary: the drop is a boost")
            } else {
                cost *= 1 - 0.075 * Double(costs.offensiveDrops)
                            - 0.04 * Double(costs.otherDrops)
                notes.append("drops your own stats")
            }
        }
        if costs.leavesOpen {
            cost *= 0.88
            notes.append("leaves you Wide Open")
        }
        if costs.conditional {
            cost *= 0.70
            notes.append("fails on the wrong read")
        }
        if costs.firstTurnOnly {
            // Available on the turn it switches in, and only then. Worth a
            // little less than an unconditional move, not a third less.
            cost *= 0.88
            notes.append("only on the turn it comes in")
        }
        if costs.rampaging {
            // Two or three turns locked into one move and confused afterwards,
            // with no Protect in between. In doubles that is close to unplayable.
            cost *= 0.55
            notes.append("locks you in, then confuses you")
        }

        // -- how much power actually lands -----------------------------------
        var raw = Double(power)
        if costs.doubleChance > 0 {
            raw *= 1 + costs.doubleChance
            notes.append(String(format: "%.0f%% chance of double power", costs.doubleChance * 100))
        }

        var connects = accurate
        if let hits = costs.hits {
            let skillLink = ability == "Skill Link"
            let loadedDice = item == "Loaded Dice"
            if costs.escalating {
                // 20 then 40 then 60, each needing its own accuracy roll.
                var total = 0.0
                var reaching = 1.0
                for strike in 1...hits.max {
                    reaching *= hits.stopsOnMiss ? accurate : 1
                    total += Double(power) * Double(strike) * reaching
                }
                raw = total
                connects = hits.stopsOnMiss ? 1 : accurate
            } else {
                let expected: Double
                if skillLink {
                    // Skill Link forces the maximum number of strikes; the
                    // accuracy roll still applies to the move as a whole.
                    expected = Double(hits.max)
                } else if hits.min == hits.max {
                    expected = Double(hits.min)
                } else if hits.stopsOnMiss {
                    // Each additional strike needs another accuracy roll.
                    var total = 0.0, reaching = 1.0
                    for _ in 1...hits.max { reaching *= accurate; total += reaching }
                    expected = total
                } else if loadedDice {
                    expected = Double(hits.max) - 0.5
                } else {
                    // The Gen 5+ 2-5 distribution averages 3.0.
                    expected = hits.max == 5 && hits.min == 2 ? 3.0
                             : Double(hits.min + hits.max) / 2
                }
                raw = Double(power) * expected
                connects = hits.stopsOnMiss && !skillLink ? 1 : accurate
                notes.append(String(format: "%.1f hits on average", expected))
            }
        }

        // Consistency is charged on the listed accuracy even when the expected
        // value already accounts for it, because the swing is the point.
        let consistency = 1 - 0.35 * (1 - accurate)
        if accurate < 1 {
            notes.insert(String(format: "%.0f%% accurate", accurate * 100), at: 0)
        }

        return MoveQuality(rawPower: raw, hitChance: connects,
                           consistency: consistency, costFactor: cost, notes: notes)
    }

    // MARK: - Regex helpers

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        guard let hit = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (0..<hit.numberOfRanges).map {
            hit.range(at: $0).location == NSNotFound ? "" : source.substring(with: hit.range(at: $0))
        }
    }

    /// "1/3" and "1/2" as numbers.
    private static func fraction(in text: String, after pattern: String) -> Double? {
        guard let phrase = match(pattern, in: text) else { return nil }
        let parts = phrase[1].split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        return parts[0] / parts[1]
    }
}
