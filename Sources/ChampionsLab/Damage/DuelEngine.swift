//  DuelEngine.swift
//  One model for what happens when two Pokémon meet.
//
//  There used to be three copies of this — the Versus grid, the Analysis tab
//  and the anti-meta picks each worked out "who wins" their own way, and they
//  drifted: one priced moves for accuracy, one did not; one raced on Speed, one
//  ignored it. They all call this now, so a disagreement between two screens is
//  a bug rather than a difference of opinion.
//
//  What it models beyond raw damage:
//
//    · Survival items. Focus Sash cannot be knocked out from full, resist
//      berries halve one super-effective hit, Sitrus is worth a quarter of a
//      health bar across a fight. 32% of measured item slots are one of these,
//      and ignoring them made "guaranteed OHKO" wrong a lot of the time.
//    · Status. Will-O-Wisp halves a physical attacker for the rest of the game
//      and Thunder Wave halves Speed. Both were worth exactly zero before,
//      because every path filtered on isDamaging.
//    · Setup. Swords Dance is not free, but on something that survives a hit it
//      is usually better than attacking, and a setup sweeper was being scored
//      as though it never set up.
//
//    · Leaving. Switching resolves before any move, so a side that is losing a
//      cell normally walks out of it — and whether it walks out having done
//      something (U-turn, Parting Shot) or merely spent a turn is most of what
//      separates a bad matchup from a lost Pokémon. Only Mega Gengar's Shadow
//      Tag stops it, and it is the only trapping ability in the format.
//
//  It is still a one-turn-at-a-time race rather than a game tree. Each side
//  picks the line that wins the race soonest and the two are compared; nobody
//  predicts, and what a side switches *to* is a question about the team rather
//  than the cell, so Matchup answers that one.

import Foundation

@MainActor
enum DuelEngine {

    struct Side {
        var combatant: Combatant
        var moves: [Move]
        /// Overrides the raw Speed stat — Tailwind, Trick Room, paralysis.
        var speed: Int?
    }

    /// The line a side intends to take, and what it costs.
    struct Plan {
        /// Fraction of the opponent's effective HP removed per attacking turn.
        var damage = 0.0
        var reliability = 1.0
        var moveName = "—"
        /// Turns spent before attacking starts — a setup or status turn.
        var setupTurns = 0
        /// What this side does to the other: burn halves physical damage,
        /// paralysis halves Speed.
        var opposingDamageFactor = 1.0
        var opposingSpeedFactor = 1.0
        var note: String?

        /// Turns to knock the target out, including anything spent first.
        func turns(toRemove hp: Int) -> Int {
            let perHit = damage * reliability
            guard perHit > 0 else { return 99 }
            return setupTurns + Int(ceil(1 / perHit))
        }
    }

    // MARK: - Entry point

    /// A selected move that leaves the field after acting.
    ///
    /// Matched on what the move says it does rather than a list of names, so
    /// U-turn, Volt Switch, Flip Turn, Parting Shot, Baton Pass, Chilly
    /// Reception and Shed Tail are all found, and anything added to the dex
    /// later is found without an edit here.
    static func pivot(in moves: [Move]) -> Move? {
        moves.first { $0.effect.contains("switches out of battle to be replaced") }
    }

    /// The self-protecting moves. Named rather than matched on text, because
    /// the family is small, closed and easy to get wrong: Wide Guard and Quick
    /// Guard read almost identically and do something else entirely, and Endure
    /// leaves you on one health point rather than untouched.
    static var protectMoves: Set<String> { Move.protectMoves }

    static func protects(in moves: [Move]) -> Move? {
        moves.first { protectMoves.contains($0.name) }
    }

    static func duel(mine: Side, theirs: Side, field: Field, store: Store) -> Duel {
        let myAttack = bestAttack(mine, into: theirs, field: field, store: store)
        let theirAttack = bestAttack(theirs, into: mine, field: field, store: store)

        // Each side then asks whether a setup or status turn beats attacking.
        let myPlan = bestPlan(mine, into: theirs, attacking: myAttack,
                              incoming: theirAttack, field: field, store: store)
        let theirPlan = bestPlan(theirs, into: mine, attacking: theirAttack,
                                 incoming: myAttack, field: field, store: store)

        // Status each side lands on the other applies to the other's line.
        let myDamage = myPlan.damage
        let theirDamage = theirPlan.damage * myPlan.opposingDamageFactor

        // The caller may already have worked out the order — Tailwind, Trick
        // Room — in which case that wins. Otherwise ask the Pokémon, which
        // knows about its own Scarf and its own weather.
        let mySpeed = Int(Double(mine.speed ?? mine.combatant.speed(in: field))
                          * theirPlan.opposingSpeedFactor)
        let theirSpeed = Int(Double(theirs.speed ?? theirs.combatant.speed(in: field))
                             * myPlan.opposingSpeedFactor)

        var label = myPlan.moveName
        if let note = myPlan.note { label = "\(note) → \(myPlan.moveName)" }
        var theirLabel = theirPlan.moveName
        if let note = theirPlan.note { theirLabel = "\(note) → \(theirPlan.moveName)" }

        return Duel(mine: mine.combatant.form, theirs: theirs.combatant.form,
                    outgoing: myDamage, incoming: theirDamage,
                    mySpeed: mySpeed, theirSpeed: theirSpeed,
                    myBestMove: label, theirBestMove: theirLabel,
                    myReliability: myPlan.reliability,
                    theirReliability: theirPlan.reliability,
                    mySetupTurns: myPlan.setupTurns,
                    theirSetupTurns: theirPlan.setupTurns,
                    myPivot: pivot(in: mine.moves)?.name,
                    theirPivot: pivot(in: theirs.moves)?.name,
                    myProtect: protects(in: mine.moves)?.name,
                    theirProtect: protects(in: theirs.moves)?.name,
                    iAmTrapped: theirs.combatant.ability == "Shadow Tag",
                    theyAreTrapped: mine.combatant.ability == "Shadow Tag")
    }

    // MARK: - Attacking

    /// The attacking move worth the most, priced for accuracy and what it costs
    /// to click, and measured against the target's effective health rather than
    /// its raw maximum.
    static func bestAttack(_ side: Side, into target: Side,
                           field: Field, store: Store) -> Plan {
        var plan = Plan()
        let effective = Double(target.combatant.effectiveHP)
        for move in side.moves where move.isDamaging {
            let result = DamageCalc.calculate(attacker: side.combatant,
                                              defender: target.combatant,
                                              move: move, field: field)
            let quality = store.quality(of: move, ability: side.combatant.ability,
                                        item: side.combatant.item)
            let share = Double(result.maxDamage) / max(1, effective)
            if share * quality.reliability > plan.damage * plan.reliability {
                plan.damage = share
                plan.reliability = quality.reliability
                plan.moveName = move.name
            }
        }
        return plan
    }

    // MARK: - Setup and status

    /// Items that decide what a Pokémon is allowed to do with its turn.
    ///
    /// A Choice item locks you into the first move you pick, so a Choice
    /// attacker cannot Swords Dance and then attack — clicking the setup move
    /// means clicking it for the rest of the fight. An Assault Vest forbids
    /// status moves outright. Both were modelled only as stat multipliers, so a
    /// Choice Band sweeper was being credited with setup turns it can never
    /// take, and an Assault Vest wall with a Will-O-Wisp it cannot use.
    static func canSpendATurn(_ combatant: Combatant) -> Bool {
        !["Choice Band", "Choice Specs", "Choice Scarf", "Assault Vest"]
            .contains(combatant.item)
    }

    /// Whether spending a turn first beats attacking straight away.
    static func bestPlan(_ side: Side, into target: Side, attacking: Plan,
                         incoming: Plan, field: Field, store: Store) -> Plan {
        var best = attacking
        guard canSpendATurn(side.combatant) else { return best }
        // Turns it needs if it just attacks, and whether it lives to do more.
        let survivesAHit = incoming.damage * incoming.reliability < 1.0
        let baseTurns = attacking.turns(toRemove: target.combatant.effectiveHP)

        // -- setting up ------------------------------------------------------
        // Only worth considering if it survives the hit it will take doing so.
        if survivesAHit, baseTurns >= 2 {
            for move in side.moves where !move.isDamaging {
                let boosts = move.selfBoosts
                guard !boosts.isEmpty else { continue }
                let physical = side.combatant.form.attack >= side.combatant.form.spAttack
                let relevant = boosts[physical ? .attack : .spAttack] ?? 0
                guard relevant > 0 else { continue }
                var boosted = side
                boosted.combatant.boosts[(physical ? Stat.attack : .spAttack).rawValue] += relevant
                let after = bestAttack(boosted, into: target, field: field, store: store)
                var candidate = after
                candidate.setupTurns = attacking.setupTurns + 1
                candidate.note = move.name
                if candidate.turns(toRemove: target.combatant.effectiveHP)
                    < best.turns(toRemove: target.combatant.effectiveHP) {
                    best = candidate
                }
            }
        }

        // -- status ----------------------------------------------------------
        // A burn on a physical attacker is worth more than most attacking turns:
        // it halves everything they do for the rest of the game.
        for move in side.moves where !move.isDamaging || move.name == "Nuzzle" {
            guard let effect = status(of: move) else { continue }
            switch effect {
            case .burn:
                let theyArePhysical = target.combatant.form.attack
                    >= target.combatant.form.spAttack
                let immune = target.combatant.form.pokeTypes.contains(.fire)
                    || ["Water Veil", "Water Bubble", "Guts", "Flare Boost",
                        "Thermal Exchange"].contains(target.combatant.ability)
                guard theyArePhysical, !immune else { continue }
                var candidate = attacking
                candidate.setupTurns = attacking.setupTurns + 1
                candidate.opposingDamageFactor = 0.5
                candidate.note = move.name
                best = betterOf(best, candidate, target: target, incoming: incoming)
            case .paralysis:
                let immune = target.combatant.form.pokeTypes.contains(.electric)
                    || ["Limber", "Volt Absorb"].contains(target.combatant.ability)
                guard !immune else { continue }
                var candidate = attacking
                candidate.setupTurns = attacking.setupTurns + 1
                candidate.opposingSpeedFactor = 0.5
                candidate.note = move.name
                best = betterOf(best, candidate, target: target, incoming: incoming)
            case .sleep:
                // A sleeping Pokémon does nothing for a turn or two. Treated as
                // a large but not total reduction, since it wakes up.
                var candidate = attacking
                candidate.setupTurns = attacking.setupTurns + 1
                candidate.opposingDamageFactor = 0.4
                candidate.note = move.name
                best = betterOf(best, candidate, target: target, incoming: incoming)
            }
        }
        return best
    }

    /// Prefers the plan that wins the exchange, not merely the faster knockout:
    /// a burn turn costs tempo and buys survivability, so both sides count.
    private static func betterOf(_ current: Plan, _ candidate: Plan,
                                 target: Side, incoming: Plan) -> Plan {
        let hp = target.combatant.effectiveHP
        func value(_ plan: Plan) -> Double {
            let myTurns = Double(plan.turns(toRemove: hp))
            let theirEffective = incoming.damage * incoming.reliability
                * plan.opposingDamageFactor
            let theirTurns = theirEffective > 0 ? ceil(1 / theirEffective) : 99
            // Winning the race matters most; surviving longer breaks ties.
            return theirTurns - myTurns
        }
        return value(candidate) > value(current) ? candidate : current
    }

    private enum StatusEffect { case burn, paralysis, sleep }

    private static func status(of move: Move) -> StatusEffect? {
        let text = move.effect
        // Only guaranteed applications: "Burns the target." A 10% chance on a
        // damaging move is a bonus, not a plan.
        if text.hasPrefix("Burns the target") { return .burn }
        if text.hasPrefix("Paralyzes the target") { return .paralysis }
        if text.hasPrefix("Puts the target to sleep") { return .sleep }
        return nil
    }
}
