//  TurnModel.swift
//  One turn, played.
//
//  `resolve` is the whole of it: switches first, because a pivot pays for
//  itself by taking a hit on arrival; then Mega Evolution; then every action
//  in the order TurnOrder gives, each handed to Strikes and each recorded as a
//  step the screen can play back; then Residuals closing the turn. It decides
//  nothing about any of those on its own -- it is the order they happen in,
//  and the one place that order is written.
//
//  `outcomes` is the same turn for the search: every way it can come out when
//  a Protect might not hold, with how likely each is, so a second Protect in a
//  row is priced at a third of a first rather than at nothing or at
//  everything.
//
//  The dice live here because they are the one thing in the model that is
//  genuinely global -- a played turn rolls them, the search branches on them,
//  and games cannot share a thread because of them.

import Foundation

// MARK: - Playing it out

enum TurnModel {

    /// Resolve one turn from both sides' choices.
    /// Play a turn out.
    ///
    /// `rolling` is the difference between a simulation and an evaluation. The
    /// search wants the average — an equilibrium is about what a line is worth
    /// across every way it could go — so it leaves this off and every hit lands
    /// for its expected damage. A battle somebody is watching wants the dice:
    /// the roll, the miss, the burn that did or did not take.
    static func resolve(_ board: Board, mine: Play, theirs: Play,
                        rolling: Bool = false, narrating: Bool = true) -> Board {
        var out = board
        out.story = []
        out.steps = []
        out.narrating = narrating
        for index in out.mine.indices { out.mine[index].isProtected = false
                                        out.mine[index].flinched = false
                                        out.mine[index].arrivedThisTurn = false
                                        out.mine[index].drawingFire = false }
        for index in out.theirs.indices { out.theirs[index].isProtected = false
                                          out.theirs[index].flinched = false
                                          out.theirs[index].arrivedThisTurn = false
                                          out.theirs[index].drawingFire = false }

        let myChoices = [mine.left, mine.right]
        let theirChoices = [theirs.left, theirs.right]

        // Mean Look holds something in place, and so does a Shadow Tag or an
        // Arena Trap across the field. A Ghost walks out of any of it, and so
        // does anything holding a Shed Shell.
        func heldInPlace(_ who: Fighter, by others: [Fighter], board: Board) -> Bool {
            if who.types.contains(.ghost) || who.build.item == "Shed Shell"
                || who.build.ability == "Run Away" { return false }
            if who.cannotEscape { return true }
            let grounded = who.isGrounded
            for other in others.prefix(board.activeCount) where !other.fainted {
                switch other.build.ability {
                case "Shadow Tag": if who.build.ability != "Shadow Tag" { return true }
                case "Arena Trap": if grounded { return true }
                case "Magnet Pull": if who.types.contains(.steel) { return true }
                default: break
                }
            }
            return false
        }

        // -- switches, which resolve before anything else --------------------
        // In turn order — the faster Pokémon leaves first, Trick Room turning
        // that round — and each one its own step, with whatever the arrival
        // did in the same step. Said out loud, because a silent switch reads
        // as a Pokémon that did nothing, which is exactly what a switch is
        // meant to look like to the other player and exactly what a log must
        // not let it be.
        var leaving: [(mine: Bool, slot: Int, bench: Int, speed: Int)] = []
        for (slot, choice) in myChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.mine.indices.contains(slot), out.mine.indices.contains(bench),
                  !out.mine[bench].fainted, !out.mine[slot].fainted,
                  out.mine[slot].charging == nil,
                  !heldInPlace(out.mine[slot], by: out.theirs, board: out) else { continue }
            leaving.append((true, slot, bench,
                            TurnOrder.speed(of: out.mine[slot], tailwind: out.myTailwind > 0, board: out)))
        }
        for (slot, choice) in theirChoices.enumerated() {
            guard case .swap(let bench) = choice,
                  out.theirs.indices.contains(slot), out.theirs.indices.contains(bench),
                  !out.theirs[bench].fainted, !out.theirs[slot].fainted,
                  out.theirs[slot].charging == nil,
                  !heldInPlace(out.theirs[slot], by: out.mine, board: out) else { continue }
            leaving.append((false, slot, bench,
                            TurnOrder.speed(of: out.theirs[slot], tailwind: out.theirTailwind > 0, board: out)))
        }
        let inverted = out.trickRoom > 0
        leaving.sort { a, b in
            if a.speed != b.speed { return inverted ? a.speed < b.speed : a.speed > b.speed }
            return a.mine && !b.mine
        }
        for entry in leaving {
            out.beginStep(Board.Action(byMine: entry.mine, slot: entry.slot,
                                       move: "", category: "Switch", type: ""))
            if entry.mine {
                out.note("You switched \(out.mine[entry.slot].build.form.formLabel) out for \(out.mine[entry.bench].build.form.formLabel).")
                let said = Switching.swapIn(mine: true, active: entry.slot, bench: entry.bench, board: &out)
                if let said { out.note(said) }
            } else {
                out.note("They switched \(out.theirs[entry.slot].build.form.formLabel) out for \(out.theirs[entry.bench].build.form.formLabel).")
                let said = Switching.swapIn(mine: false, active: entry.slot, bench: entry.bench, board: &out)
                if let said { out.note(said) }
            }
            out.closeStep()
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
        // A Pokémon evolves with the move it picks, so one that was switched
        // in this turn — or switched out — does not.
        if let slot = mine.megaSlot, out.mine.indices.contains(slot),
           slot < out.activeCount, out.mine[slot].pendingMega != nil,
           !(slot == 0 ? mine.left : mine.right).isSwap,
           !out.mine[slot].fainted, !out.mine.contains(where: \.hasMegaEvolved) {
            evolving.append((true, slot, TurnOrder.speed(of: out.mine[slot],
                                               tailwind: out.myTailwind > 0, board: out)))
        }
        if let slot = theirs.megaSlot, out.theirs.indices.contains(slot),
           slot < out.activeCount, out.theirs[slot].pendingMega != nil,
           !(slot == 0 ? theirs.left : theirs.right).isSwap,
           !out.theirs[slot].fainted, !out.theirs.contains(where: \.hasMegaEvolved) {
            evolving.append((false, slot, TurnOrder.speed(of: out.theirs[slot],
                                                tailwind: out.theirTailwind > 0, board: out)))
        }
        // Trick Room does not invert this: Mega Evolution is worked out on raw
        // Speed regardless of what is on the field.
        for entry in evolving.sorted(by: { $0.speed > $1.speed }) {
            let before = out.field
            if entry.mine {
                Switching.megaEvolve(&out.mine, slot: entry.slot, opposing: &out.theirs,
                           field: &out.field)
            } else {
                Switching.megaEvolve(&out.theirs, slot: entry.slot, opposing: &out.mine,
                           field: &out.field)
            }
            out.fieldSettled(from: before)
        }

        // -- everything else, in order ---------------------------------------
        // Who acts, in what order. TurnOrder owns that decision — the
        // bracket, After You and Quash, the Trick Room inversion, the re-read
        // of Speed between actions — so that anything wanting to *describe*
        // the order walks the same code rather than a second opinion of it.
        var pending = TurnOrder.declare(&out, mine: myChoices, theirs: theirChoices,
                                        rolling: rolling)
        // What everyone is about to do, before anyone does it.
        for entry in pending {
            out.declared[(entry.mine ? "m" : "t") + "\(entry.slot)"] = entry.choice
        }

        finish(&out, pending: &pending, rolling: rolling)
        return out
    }

    /// The turn picked up where a pivot stopped it: the chosen Pokemon comes
    /// in for the one that left, and the actions still waiting play out,
    /// then the end of the turn. The story and the steps carry on from where
    /// they were, so the screen shows one turn.
    static func resume(_ board: Board, sendingIn bench: Int, rolling: Bool = false) -> Board {
        var out = board
        guard let pivot = out.pendingPivot, var pending = out.paused else { return out }
        out.pendingPivot = nil
        out.paused = nil
        out.beginStep(Board.Action(byMine: pivot.mine, slot: pivot.slot,
                                   move: "", category: "Switch", type: ""))
        Switching.arrive(byMine: pivot.mine, slot: pivot.slot, bench: bench, board: &out,
                         carrying: pivot.carrying, announcingLeaving: false)
        out.closeStep()
        finish(&out, pending: &pending, rolling: rolling)
        return out
    }

    /// The actions in order, then the end of the turn -- or a stop partway,
    /// with what is left kept on the board, when one of yours pivots in a
    /// played turn and the screen has to ask who comes in.
    private static func finish(_ out: inout Board, pending: inout [TurnOrder.Entry], rolling: Bool) {
        while let entry = TurnOrder.next(from: &pending, board: out) {
            // One action, one step: whatever it does to however many. What it
            // is held to is checked now, not when the turn was queued: an
            // Encore that landed a moment ago already applies.
            let actor = (entry.mine ? out.mine : out.theirs)[entry.slot]
            if entry.mine {
                out.mine[entry.slot].goesNext = false; out.mine[entry.slot].goesLast = false
            } else {
                out.theirs[entry.slot].goesNext = false; out.theirs[entry.slot].goesLast = false
            }
            out.acted.insert((entry.mine ? "m" : "t") + "\(entry.slot)")
            // What is actually played, not what was asked for: an Encore or a
            // Choice lock substitutes a different move, and the screen should
            // draw the one that happens.
            let playing = TurnOrder.forced(actor, entry.choice)
            out.beginStep(Board.Action(played: playing, by: actor,
                                       byMine: entry.mine, slot: entry.slot))
            Strikes.apply(playing, byMine: entry.mine, slot: entry.slot, to: &out, rolling: rolling)
            out.closeStep()
            if out.pendingPivot != nil {
                out.paused = pending
                return
            }
        }

        // The residuals together, since they land together.
        out.beginStep()
        Residuals.endOfTurn(&out, rolling: rolling)
        out.closeStep()
        out.rulings = [:]
        out.declared = [:]
        out.acted = []
    }

    /// Every way the turn can come out when somebody is trying a Protect
    /// that might not hold, with how likely each is. One board when nobody
    /// is; two when one Pokémon is on a repeat Protect; four when both are.
    /// The search weighs these rather than betting on either branch, so a
    /// second Protect in a row is worth exactly a third of a first one.
    static func outcomes(_ board: Board, mine: Play, theirs: Play)
        -> [(board: Board, chance: Double)] {
        var chancy: [(key: String, chance: Double)] = []

        /// A repeat Protect, which gets a third of the chance of the one before.
        func considerProtect(_ choice: Choice, fighter: Fighter, mine side: Bool, slot: Int) {
            guard !fighter.fainted, fighter.protectStreak > 0 else { return }
            switch choice {
            case .protectSelf:
                chancy.append((Board.flip("protect", side, slot), fighter.protectChance))
            case .attack(let index, _):
                if fighter.moves.indices.contains(index),
                   Move.protectMoves.contains(fighter.moves[index].name) {
                    chancy.append((Board.flip("protect", side, slot), fighter.protectChance))
                }
            default: break
            }
        }

        // Everything else that turns on a dice roll. Collected separately from
        // Protect because these are common — seventy-five legal moves carry a
        // sub-100% secondary — and branching all of them at once would square
        // the cost of a solve. Only the most likely few are followed.
        var rolls: [(key: String, chance: Double)] = []
        func considerRolls(_ choice: Choice, fighter: Fighter, mine side: Bool, slot: Int) {
            guard !fighter.fainted else { return }
            if !choice.isPass {
                if fighter.build.ability == "Quick Draw" {
                    rolls.append((Board.flip("quickclaw", side, slot), 0.3))
                } else if fighter.build.item == "Quick Claw" {
                    rolls.append((Board.flip("quickclaw", side, slot), 0.2))
                }
            }
            guard case .attack(let index, _) = choice,
                  fighter.moves.indices.contains(index) else { return }
            let move = fighter.moves[index]
            let chance = Strikes.secondaryChance(of: move, for: fighter)
            if chance > 0, chance < 100 {
                rolls.append((Board.flip("secondary", side, slot), Double(chance) / 100))
            }
            if fighter.build.ability == "Poison Touch", move.makesContact, move.isDamaging {
                rolls.append((Board.flip("poisontouch", side, slot), 0.3))
            }
        }

        let actors: [(Choice, Fighter, Bool, Int)?] = [
            board.mine.indices.contains(0) ? (mine.left, board.mine[0], true, 0) : nil,
            board.mine.indices.contains(1) && board.activeCount > 1 ? (mine.right, board.mine[1], true, 1) : nil,
            board.theirs.indices.contains(0) ? (theirs.left, board.theirs[0], false, 0) : nil,
            board.theirs.indices.contains(1) && board.activeCount > 1 ? (theirs.right, board.theirs[1], false, 1) : nil,
        ]
        for case let (choice, fighter, side, slot)? in actors {
            considerProtect(choice, fighter: fighter, mine: side, slot: slot)
            considerRolls(choice, fighter: fighter, mine: side, slot: slot)
        }

        // The cap. Each extra coin flip doubles the number of boards, and this
        // runs once per cell of a matrix that is often 35 by 19, so the whole
        // solve is doubled with it. The likeliest flips are the ones worth
        // following; the rest fall back to "only what is certain", which is
        // where every one of them was before.
        rolls.sort { $0.chance > $1.chance }
        chancy += rolls.prefix(Dice.branchedRolls)

        guard !chancy.isEmpty else {
            return [(resolve(board, mine: mine, theirs: theirs, narrating: false), 1)]
        }
        var out: [(board: Board, chance: Double)] = []
        for mask in 0..<(1 << chancy.count) {
            var ruled = board
            var chance = 1.0
            for (bit, entry) in chancy.enumerated() {
                let holds = mask & (1 << bit) != 0
                ruled.rulings[entry.key] = holds
                chance *= holds ? entry.chance : 1 - entry.chance
            }
            out.append((resolve(ruled, mine: mine, theirs: theirs, narrating: false), chance))
        }
        return out.sorted { $0.chance > $1.chance }
    }

}
