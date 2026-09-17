//  Strikes.swift
//  One action, resolved: from the moment a Pokemon is asked to move to the
//  last thing its move did.
//
//  This is the pipeline a move goes through. Can it be used at all -- a Fake
//  Out past its first turn cannot, a Sucker Punch into a Pokemon that is not
//  attacking cannot, a Taunted status move cannot. Who does it actually reach,
//  once a Follow Me has pulled it, a Protect has refused it, a Psychic Terrain
//  has turned it away, or the target it was aimed at has already gone down.
//  What it does to each of them: the damage, the contact effects coming back,
//  the secondary going off or being refused by a Covert Cloak. And what it
//  costs the user afterwards -- recoil, a Life Orb, the drop a Close Combat
//  takes on its own defences.
//
//  A status move leaves this pipeline at the point where damage would be
//  worked out and goes to SupportMoves instead, which knows each of them by
//  name. Everything else about the action -- its legality, its target, its
//  record -- is decided here first, the same way for both kinds.
//
//  `apply` is the action. `applySecondary` is one secondary effect of one hit.
//  They were both called `apply`, which is how the two of them ended up in one
//  file for so long.

import Foundation

enum Strikes {
    /// Abilities that stop priority moves reaching their side at all.
    static let priorityBlockers: Set<String> = ["Armor Tail", "Queenly Majesty", "Dazzling"]

    static func apply(_ choice: Choice, byMine: Bool, slot: Int,
                              to board: inout Board,
                              rolling: Bool = false) {
        let actor = byMine ? board.mine[slot] : board.theirs[slot]
        guard !actor.fainted else { return }
        let name = actor.build.form.formLabel
        guard canAct(choice, actor: actor, name: name, byMine: byMine, slot: slot,
                     board: &board, rolling: rolling) else { return }

        switch choice {
        case .pass:
            return
        case .swap:
            return
        case .protectSelf(let index):
            let label = actor.moves.indices.contains(index) ? actor.moves[index].name : "Protect"
            MoveHistory.remember(byMine: byMine, slot: slot, move: index, target: 0, board: &board)
            let held = Protection.tryProtect(label, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: !held)
        case .attack(let moveIndex, let target):
            guard actor.moves.indices.contains(moveIndex) else { return }
            let move = actor.moves[moveIndex]
            MoveHistory.remember(byMine: byMine, slot: slot, move: moveIndex, target: target, board: &board)
            // Taunted: nothing but attacks until it wears off.
            if !move.isDamaging, actor.tauntedFor > 0 {
                board.note("\(name) cannot use \(move.name) — it is still taunted.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return
            }
            guard move.isDamaging else {
                let before = board.story.count
                let followup = SupportMoves.support(move, byMine: byMine, slot: slot, target: target,
                                                    to: &board, rolling: rolling)
                // Instruct: the partner's last move, as an ordinary action, run
                // here so the status moves never have to reach back into this
                // pipeline. Before the failure check on purpose -- it always
                // was, when the replay ran inline -- so a replayed move that
                // had only "but" to say still marks the Instruct as failed.
                if case .replay(let choice, let replayMine, let replaySlot)? = followup {
                    apply(choice, byMine: replayMine, slot: replaySlot, to: &board, rolling: rolling)
                }
                // A support move that only had "but" to say for itself failed.
                let failed = board.story.dropFirst(before).contains { $0.hasPrefix("But ") || $0.contains("but it failed") }
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: failed)
                selfKO(move, byMine: byMine, slot: slot, board: &board)
                return
            }

            // Then the five phases, each a function that says what it did.
            guard declare(move, index: moveIndex, target: target, actor: actor, name: name,
                          byMine: byMine, slot: slot, board: &board) else { return }
            let farScreens = (target >= Choice.allyTarget ? byMine : !byMine)
                ? board.myScreens : board.theirScreens
            if fieldRefuses(move, target: target, farScreens: farScreens,
                            byMine: byMine, slot: slot, board: &board) { return }
            guard let aim = aim(move, at: target, actor: actor, name: name,
                                byMine: byMine, slot: slot, board: &board) else { return }

            var totalDealt = 0
            var reached = 0
            for (hitMine, index) in aim.aimedAt {
                if let dealt = strike(move, at: index, hitMine: hitMine, aim: aim,
                                      farScreens: farScreens, actor: actor, name: name,
                                      byMine: byMine, slot: slot, board: &board,
                                      rolling: rolling) {
                    reached += 1
                    totalDealt += dealt
                }
            }
            settle(move, actor: actor, name: name, aim: aim, totalDealt: totalDealt,
                   reached: reached, byMine: byMine, slot: slot, board: &board)
        }
    }

    /// Who a move is going to land on, once every redirection has had its say.
    struct Aim {
        /// Aimed at the user's own partner, for the techs that want it.
        let atAlly: Bool
        /// Which side the far targets are on.
        let hitMine: Bool
        let partner: Int
        /// The far-side slots, as the redirection left them.
        let aimed: [Int]
        /// Everyone it reaches, side by side -- the far side, and the user's
        /// own partner when the move hits all adjacent Pokemon.
        let aimedAt: [(hitMine: Bool, index: Int)]
        /// Dragon Darts with only one target reachable: both darts to it.
        let dartedTwice: Bool
    }

    // MARK: - The phases of an action

    /// Whether the Pokemon gets to act at all this turn.
    ///
    /// Flinched, asleep, frozen solid, fully paralysed, immobilised by love,
    /// tormented into repeating itself, hurt in its own confusion -- each of
    /// these costs the action and says so. A frozen Pokemon may thaw here and
    /// carry on. Every failure marks the move failed, for Stomping Tantrum,
    /// and drops any charge, because a wind-up interrupted is a wind-up lost.
    private static func canAct(_ choice: Choice, actor: Fighter, name: String,
                               byMine: Bool, slot: Int, board: inout Board,
                               rolling: Bool) -> Bool {
        if actor.flinched {
            board.note("\(name) flinched and could not move.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return false
        }
        // A disabled move cannot be used, and trying costs the turn. The
        // search sees that as a wasted turn and learns to pick something else,
        // which is the honest way round: the model refuses, rather than the
        // search quietly substituting a move nobody chose.
        if case .attack(let index, _) = choice, actor.disabled == index,
           actor.moves.indices.contains(index) {
            board.note("\(name)'s \(actor.moves[index].name) is disabled.")
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return false
        }
        // Sleep and paralysis cost turns, which is the whole reason they are
        // worth a move slot.
        if actor.status == .sleep {
            board.note("\(name) is fast asleep.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return false
        }
        // Frozen solid. One turn in five it thaws on its own, and a Fire move
        // or a move that defrosts its user thaws it outright. Blizzard has
        // frozen things since the reference table landed and nothing happened
        // when it did: the condition was inflictable and inert.
        if actor.status == .freeze {
            let thawsItself = actor.moves.indices.contains(pickedMove(choice))
                && (actor.moves[pickedMove(choice)].type == "Fire"
                    || actor.moves[pickedMove(choice)].flags["defrosts"] == true)
            let thaws = thawsItself
                || (rolling && Double.random(in: 0..<1, using: &Dice.source) < 0.2)
            if thaws {
                if byMine { board.mine[slot].status = .none } else { board.theirs[slot].status = .none }
                board.note("\(name) thawed out.")
            } else {
                board.note("\(name) is frozen solid.")
                MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return false
            }
        }
        if actor.status == .paralysis, rolling, Double.random(in: 0...1, using: &Dice.source) < 0.25 {
            board.note("\(name) is paralysed and cannot move.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return false
        }
        // Infatuation: half of its actions are lost while whatever it fell for
        // is still standing there. Like confusion, the search averages and
        // lets it act; a played turn rolls.
        if let loves = actor.infatuatedWith {
            let far = byMine ? board.theirs : board.mine
            if !far.indices.contains(loves) || far[loves].fainted {
                if byMine { board.mine[slot].infatuatedWith = nil }
                else { board.theirs[slot].infatuatedWith = nil }
            } else if rolling, Double.random(in: 0..<1, using: &Dice.source) < 0.5 {
                board.note("\(name) is immobilised by love.")
                MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return false
            }
        }
        // Torment: it cannot use the same move twice running, which is what
        // stops something clicking one button all game.
        if actor.tormented, case .attack(let index, _) = choice, actor.lastMove == index {
            board.note("\(name) cannot use the same move twice in a row.")
            MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return false
        }

        // Confusion: counted down each time it comes to act, and one action in
        // three goes into its own face — a typeless forty-power hit with its
        // own Attack against its own Defence. The search, which averages,
        // lets it act; a played turn rolls.
        if actor.confusedFor > 0 {
            if byMine { board.mine[slot].confusedFor -= 1 } else { board.theirs[slot].confusedFor -= 1 }
            if (byMine ? board.mine : board.theirs)[slot].confusedFor == 0 {
                board.note("\(name) snapped out of its confusion.")
            } else {
                board.note("\(name) is confused.")
                if rolling, Double.random(in: 0..<1, using: &Dice.source) < 1.0 / 3.0 {
                    let attack = Double(actor.build.stagedStat(.attack))
                    let defence = Double(actor.build.stagedStat(.defense))
                    let base = (2.0 * 50 / 5 + 2) * 40 * attack / defence / 50 + 2
                    let hurt = Swift.max(1, Int(base * Double.random(in: 0.85...1.0, using: &Dice.source)))
                    if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - hurt) }
                    else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - hurt) }
                    board.note("It hurt itself in its confusion for \(hurt).")
                    if (byMine ? board.mine : board.theirs)[slot].fainted { board.note("\(name) fainted.") }
                    MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board)
                    MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                    return false
                }
            }
        }
        return true
    }

    /// 1. Declare the move, and check it can be used at all.
    ///
    /// First Impression and Fake Out work on the turn the Pokemon arrives and
    /// never again. A two-turn move spends this turn winding up unless the
    /// weather waives it, and fires next turn. Returns whether the move goes on
    /// to be resolved this turn.
    private static func declare(_ move: Move, index moveIndex: Int, target: Int,
                                actor: Fighter, name: String, byMine: Bool, slot: Int,
                                board: inout Board) -> Bool {
        // A turn is resolved in the same five phases every time, and each
        // one says what it did. Declaring the move, then what the far side
        // brings to it, then the roll, then what it cost, in that order --
        // so the commentary is the computation rather than a summary of it.
        //
        // 1. Declare — and check it can be used at all. First Impression
        // and Fake Out work on the turn the Pokémon arrives and never
        // again, which is the whole cost of a 90 base power priority move.
        if move.drawbacks.firstTurnOnly, !actor.justArrived {
            board.note("\(name) used \(move.name), but it only works on the turn it comes in.")
            return false
        }
        // A two-turn move: this turn is the wind-up unless the weather
        // waives it, and the next turn is the hit. Electro Shot in rain
        // does both at once — the boost, then the beam.
        if let charge = move.charge {
            let firing = actor.charging == moveIndex
            let waived = charge.skipsIn != nil && board.field.weather == charge.skipsIn
            if !firing {
                board.note(waived
                    ? "\(name) used \(move.name). In the \(board.field.weather.rawValue.lowercased()) it needs no time to charge."
                    : (charge.hides ? "\(name) used \(move.name) and is out of reach."
                                    : "\(name) began charging \(move.name)."))
                StatChanges.applySelf(charge.boosts, toMine: byMine, slot: slot, board: &board)
                if !waived {
                    if byMine {
                        board.mine[slot].charging = moveIndex
                        board.mine[slot].chargingTarget = target
                        board.mine[slot].hidden = charge.hides
                    } else {
                        board.theirs[slot].charging = moveIndex
                        board.theirs[slot].chargingTarget = target
                        board.theirs[slot].hidden = charge.hides
                    }
                    return false
                }
            } else {
                MoveHistory.dropCharge(byMine: byMine, slot: slot, board: &board, quietly: true)
                board.note("\(name) unleashed \(move.name).")
            }
        } else {
            board.note("\(name) used \(move.name).")
        }
        return true
    }

    /// 2. The field: anything that stops the move before it starts.
    ///
    /// Wide Guard against a spread move, Quick Guard against priority, a
    /// Psychic Terrain under a grounded target, a Sucker Punch into something
    /// that is not attacking, an Armor Tail or Queenly Majesty on the far side.
    /// Returns true when the move is refused; it will already have said why.
    private static func fieldRefuses(_ move: Move, target: Int, farScreens: Screens,
                                     byMine: Bool, slot: Int, board: inout Board) -> Bool {
        // 2. The field: anything that stops it before it starts.
        if move.isSpread, farScreens.wideGuard {
            board.note("Wide Guard blocked it.")
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return true
        }
        // Quick Guard turns away anything that moves first, which is what
        // a Fake Out team is actually afraid of.
        if move.priority > 0, target < Choice.allyTarget, farScreens.quickGuard {
            board.note("Quick Guard blocked it.")
            MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
            return true
        }
        // Armor Tail and Queenly Majesty refuse priority outright: nothing
        // with increased priority can be aimed at that Pokémon or its
        // partner. It is the reason Farigiraf is on Trick Room teams — it
        // is what stops a Fake Out taking the setup turn away.
        // Psychic Terrain: nothing quick reaches anything standing on it.
        // It is why a Psychic Surge team can set up in front of a Fake Out.
        // The terrain only reaches what is standing on it. A Staraptor is
        // in the air, so a Fake Out gets to it however psychic the floor
        // is — and this used to refuse the move if *anything* on that side
        // was grounded, so the Staraptor was protected by its partner's
        // feet. The shield belongs to whoever the move is aimed at.
        if move.priority > 0, target < Choice.allyTarget,
           board.field.terrain == .psychic,
           move.aim == .foe || move.aim == .spread {
            let defenders = byMine ? board.theirs : board.mine
            let reachable = (0..<Swift.min(board.activeCount, defenders.count))
                .filter { !defenders[$0].fainted }
            // A spread move is refused only when there is nothing left for
            // it to hit; with one grounded and one not, it still lands on
            // the one in the air, and the loop below skips the other.
            let aimedAt = move.aim == .spread ? reachable
                : reachable.filter { $0 == target }
            if !aimedAt.isEmpty, aimedAt.allSatisfy({ defenders[$0].isGrounded }) {
                let who = defenders[aimedAt[0]].build.form.formLabel
                board.note("The Psychic Terrain refused it — \(who) is standing on it, and nothing quick gets through.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return true
            }
        }
        // Sucker Punch only lands on a Pokémon that is winding up to
        // attack and has not gone yet. Against a Protect, a status move or
        // something that has already moved, it does nothing at all.
        if move.id == "suckerpunch", target < Choice.allyTarget {
            let defenders = byMine ? board.theirs : board.mine
            let key = (byMine ? "t" : "m") + "\(target)"
            let attacking: Bool = {
                guard let choice = board.declared[key], !board.acted.contains(key),
                      defenders.indices.contains(target) else { return false }
                guard case .attack(let index, _) = choice,
                      defenders[target].moves.indices.contains(index) else { return false }
                return defenders[target].moves[index].isDamaging
            }()
            guard attacking else {
                board.note("But it failed — \(move.name) needs a target that is about to attack.")
                MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: true)
                return true
            }
        }
        if move.priority > 0, target < Choice.allyTarget, move.aim == .foe || move.aim == .spread {
            let defenders = byMine ? board.theirs : board.mine
            if let refused = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                !defenders[$0].fainted
                    && Strikes.priorityBlockers.contains(defenders[$0].build.ability) }) {
                board.note("\(defenders[refused].build.form.formLabel)'s "
                           + "\(defenders[refused].build.ability) refused it. "
                           + "Nothing with priority gets through.")
                return true
            }
        }
        return false
    }

    /// Who the move actually reaches.
    ///
    /// The slot it was aimed at, unless that Pokemon has gone down and it turns
    /// to the other; unless a Follow Me pulls it; unless it is Dragon Darts and
    /// splits. And, for a move that hits all adjacent Pokemon, the user's own
    /// partner as well -- which is what makes Earthquake cost something. Nil
    /// when there is nobody to hit at all.
    private static func aim(_ move: Move, at target: Int, actor: Fighter, name: String,
                            byMine: Bool, slot: Int, board: inout Board) -> Aim? {
        // Aimed at your own partner, for the techs that want it: the hit
        // lands on your side, with everything that follows from that.
        let atAlly = target >= Choice.allyTarget
        let hitMine = atAlly ? byMine : !byMine
        let partner = slot == 0 ? 1 : 0
        var aimed = move.isSpread ? [0, 1] : (atAlly ? [partner] : [target])
        if !move.isSpread, atAlly {
            let own = byMine ? board.mine : board.theirs
            if !own.indices.contains(partner) || partner >= board.activeCount || own[partner].fainted {
                board.note("But there was no one there to hit.")
                return nil
            }
        }
        if !move.isSpread, !atAlly {
            let defenders = hitMine ? board.mine : board.theirs
            // The target went down before this move's turn came: it turns
            // to whoever is left standing across the field. A Whimsicott on
            // one point of Focus Sash health is exactly who this finds.
            let gone = !defenders.indices.contains(target) || target >= board.activeCount
                || defenders[target].fainted
            if gone, let other = (0..<Swift.min(board.activeCount, defenders.count))
                .first(where: { $0 != target && !defenders[$0].fainted }) {
                aimed = [other]
                board.note("\(name)'s \(move.name) turned toward \(defenders[other].build.form.formLabel) instead.")
            }
            // Stalwart and Propeller Tail aim where they meant to; nothing
            // draws them off it.
            let ignoresRedirection = ["Stalwart", "Propeller Tail"].contains(actor.build.ability)
            if !ignoresRedirection,
               let pulled = (0..<Swift.min(board.activeCount, defenders.count)).first(where: {
                defenders[$0].drawingFire && !defenders[$0].fainted }), pulled != aimed[0] {
                aimed = [pulled]
                board.note("It was drawn to \(defenders[pulled].build.form.formLabel).")
            }
        }
        // Dragon Darts, and nothing else in the game. Its two darts go
        // one to each foe in a double battle rather than both to the one
        // it was aimed at — and when only one of them can be reached,
        // because the other is protecting or already down, both darts go
        // there instead. Aiming it at a Protect is how it ends up hitting
        // the partner twice.
        var dartedTwice = false
        if move.smartTarget == true, !atAlly, board.activeCount > 1 {
            let far = hitMine ? board.mine : board.theirs
            let reachable = (0..<Swift.min(board.activeCount, far.count)).filter {
                !far[$0].fainted && !far[$0].hidden
                    && !(far[$0].isProtected && move.isProtectable)
            }
            if reachable.count > 1 {
                aimed = reachable
                board.note("The darts split, one to each.")
            } else if let only = reachable.first {
                aimed = [only]
                dartedTwice = true
                if only != target { board.note("Both darts went to \(far[only].build.form.formLabel).") }
            }
        }

        // Who this actually lands on, side by side.
        //
        // `aimed` is the far side alone, and everything around this loop —
        // the redirection above it, the Liquid Ooze below — is written
        // against that, so it stays exactly as it was. What is added here
        // is the other half of a spread move nobody had modelled: Earthquake,
        // Surf and Discharge say "All Adjacent Pokemon", and the adjacent
        // Pokemon include your own partner.
        //
        // Leaving that out made Earthquake free. An engine that never pays
        // for hitting its own side will click it beside a grounded partner
        // all day, over-rate every Ground attacker on the team, and never
        // discover why real teams pair one with a Flying type, a Levitate
        // or an Air Balloon. The partner's own immunity is not special-cased
        // here: a Flying partner takes nothing because the damage calculator
        // says so, which is the right place for it to be said.
        var aimedAt: [(hitMine: Bool, index: Int)] = aimed.map { (hitMine, $0) }
        if move.isSpread, move.hitsAlly, !atAlly {
            let own = byMine ? board.mine : board.theirs
            if board.activeCount > 1, own.indices.contains(partner),
               partner < board.activeCount, !own[partner].fainted {
                aimedAt.append((byMine, partner))
            }
        }
        return Aim(atAlly: atAlly, hitMine: hitMine, partner: partner,
                   aimed: aimed, aimedAt: aimedAt, dartedTwice: dartedTwice)
    }


    /// One target, from the moment the move reaches for it to the last thing
    /// it did to it.
    ///
    /// Nil when the move never reached: a Protect, a Substitute-free miss, an
    /// ability that turns the whole kind of move away, a Pokemon out of reach.
    /// Otherwise the damage it landed -- which can be nought, for a hit that
    /// was absorbed, broke on a Substitute, or was a one-hit knockout that did
    /// not come up. The distinction is what Stomping Tantrum and a crashing
    /// High Jump Kick read: reached and did nothing is not the same as failed.
    private static func strike(_ move: Move, at index: Int, hitMine: Bool, aim: Aim,
                               farScreens: Screens, actor: Fighter, name: String,
                               byMine: Bool, slot: Int, board: inout Board,
                               rolling: Bool) -> Int? {
        let defending = hitMine ? board.mine : board.theirs
        guard defending.indices.contains(index), !defending[index].fainted else { return nil }
        let hitName = defending[index].build.form.formLabel
        if defending[index].hidden {
            board.note("\(hitName) is out of reach.")
            return nil
        }
        if defending[index].isProtected, move.isProtectable {
            board.detail("\(hitName) protected itself.")
            return nil
        }
        // Feint: through the Protect, and the Protect is gone — so the
        // partner's move, coming after, lands on an open target.
        if defending[index].isProtected, move.breaksProtect {
            if hitMine { board.mine[index].isProtected = false }
            else { board.theirs[index].isProtected = false }
            board.note("\(move.name) broke through \(hitName)'s protection.")
        }
        // Unseen Fist reaches through a Protect with anything that makes
        // contact; Piercing Drill does the same for a quarter damage.
        if defending[index].isProtected, move.isProtectable, move.makesContact,
           ["Unseen Fist", "Piercing Drill"].contains(actor.build.ability) {
            if hitMine { board.mine[index].isProtected = false }
            else { board.theirs[index].isProtected = false }
            board.note("\(actor.build.ability) reached through \(hitName)'s protection.")
        }

        // Protean and Libero make the user the move's type as it uses
        // it, which is a free same-type bonus on everything it throws.
        if ["Protean", "Libero"].contains(actor.build.ability),
           let became = PokeType(loose: move.type),
           (byMine ? board.mine : board.theirs)[slot].types != [became] {
            if byMine { board.mine[slot].build.typeOverride = [became] }
            else { board.theirs[slot].build.typeOverride = [became] }
            board.note("\(name) became a \(became.rawValue) type.")
        }

        // Abilities that refuse a whole kind of move outright. Mold
        // Breaker walks through all of them, which is what it is for.
        let breaker = ["Mold Breaker", "Turboblaze", "Teravolt"]
            .contains(actor.build.ability)
        if !breaker {
            let refuses: String?
            switch defending[index].build.ability {
            case "Soundproof"   where move.isSound:   refuses = "Soundproof"
            case "Bulletproof"  where move.isBullet:  refuses = "Bulletproof"
            case "Overcoat"     where move.isPowder:  refuses = "Overcoat"
            case "Wind Rider"   where move.isWind:    refuses = "Wind Rider"
            case "Dazzling", "Queenly Majesty", "Armor Tail":
                refuses = move.priority > 0 ? defending[index].build.ability : nil
            default: refuses = nil
            }
            if let refuses {
                board.note("\(hitName)'s \(refuses) turned it away.")
                return nil
            }
        }
        // A powder move does nothing to a Grass type, or to anything
        // wearing goggles.
        if move.isPowder, defending[index].types.contains(.grass)
            || defending[index].build.item == "Safety Goggles" {
            board.detail("It does not affect \(hitName).")
            return nil
        }

        // Accuracy is rolled for each one it reaches for: Muddy Water at
        // 85% can hit one of them and miss the other. The search's
        // averages were always per target; only the dice were not.
        if rolling, !move.neverMisses, move.accuracy > 0,
           Double.random(in: 0...100, using: &Dice.source) > Accuracy.chanceToHit(move, attacker: actor,
                                                    defender: defending[index],
                                                    board: board) {
            board.detail(aim.aimed.count > 1 ? "\(hitName) avoided it." : "It missed.")
            return nil
        }
        var defender = defending[index].build
        defender.atFullHP = defending[index].hp == defending[index].maxHP
        defender.status = defending[index].status
        var field = board.calcField
        field.helpingHand = actor.helped
        field.targetJustArrived = defending[index].justArrived
        // A Fairy Aura anywhere on the field powers up Fairy moves for
        // everybody, which is what makes it an aura.
        field.fairyAura = (board.mine + board.theirs)
            .prefix(board.activeCount * 2)
            .contains { !$0.fainted && $0.build.ability == "Fairy Aura" }
        // Analytic is paid for going after the target has already had
        // its turn, which is exactly what `acted` records.
        field.movingLast = board.acted.contains((hitMine ? "m" : "t") + "\(index)")
        // Friend Guard covers whoever is standing next to the holder.
        let ally = index == 0 ? 1 : 0
        let sameSide = hitMine ? board.mine : board.theirs
        field.friendGuarded = sameSide.indices.contains(ally) && ally < board.activeCount
            && !sameSide[ally].fainted && sameSide[ally].build.ability == "Friend Guard"
        // An Infiltrator is not stopped by what is hanging in the air
        // on the other side.
        field.screen = actor.build.ability == "Infiltrator" ? false : farScreens.blunt(move)
        // A critical hit, rolled at the move's own rate. The calculator
        // already knows what one does — half again, and it goes through
        // screens and the target's defensive boosts — it only needed
        // telling when one happened.
        // A move's own rate, raised by anything the user is carrying:
        // one stage is an eighth, two is a half, three is certain.
        // A Leek is two stages of crit ratio, for the one Pokémon that
        // can hold it usefully.
        var stage = actor.critStage
        if actor.build.item == "Leek",
           actor.build.form.species.contains("farfetch") { stage += 2 }
        if actor.build.item == "Razor Claw" || actor.build.item == "Scope Lens" { stage += 1 }
        if actor.build.ability == "Super Luck" { stage += 1 }
        // Merciless always crits a poisoned target, which is the
        // entire reason a Toxapex threatens anything.
        if actor.build.ability == "Merciless",
           [.poison, .badPoison].contains(defending[index].status) { stage = 3 }
        let rate = stage <= 0 ? move.critRate
            : (stage == 1 ? Swift.max(move.critRate, 12.5)
               : stage == 2 ? Swift.max(move.critRate, 50) : 100)
        // Shell Armor and Battle Armor cannot be hit critically, which
        // is the whole of both of them. A Mold Breaker ignores that.
        let armoured = ["Shell Armor", "Battle Armor"]
            .contains(defending[index].build.ability) && !breaker
        if rolling, rate > 0, !armoured,
           Double.random(in: 0..<100, using: &Dice.source) < rate {
            field.critical = true
        }
        board.lastWasCritical = field.critical
        // A Fire move thaws whatever it hits.
        if defending[index].status == .freeze,
           DamageCalc.fieldForm(of: move, in: field).type == .fire {
            if hitMine { board.mine[index].status = .none }
            else { board.theirs[index].status = .none }
            board.detail("\(hitName) was thawed out.")
        }
        var attacker = actor.build
        attacker.ignoresAbility = ["Mold Breaker", "Turboblaze", "Teravolt"]
            .contains(actor.build.ability)
        attacker.lowHP = actor.hp * 3 <= actor.maxHP
        attacker.status = actor.status
        // Electromorphosis stored a charge the last time it was hit;
        // the next Electric move it throws spends it.
        if actor.charged, DamageCalc.fieldForm(of: move, in: field).type == .electric {
            field.charged = true
            if byMine { board.mine[slot].charged = false }
            else { board.theirs[slot].charged = false }
        }
        // Steely Spirit pays for its partner's Steel moves too.
        let ourAlly = slot == 0 ? 1 : 0
        let ourSide = byMine ? board.mine : board.theirs
        field.alliedSteelySpirit = ourSide.indices.contains(ourAlly)
            && ourAlly < board.activeCount && !ourSide[ourAlly].fainted
            && ourSide[ourAlly].build.ability == "Steely Spirit"
        // Plus and Minus pay each other, and only each other.
        let pairing: Set<String> = ["Plus", "Minus"]
        field.paired = pairing.contains(actor.build.ability)
            && ourSide.indices.contains(ourAlly) && ourAlly < board.activeCount
            && !ourSide[ourAlly].fainted
            && pairing.contains(ourSide[ourAlly].build.ability)
        attacker.lastMoveFailed = actor.lastMoveFailed
        // Supreme Overlord and Last Respects count the fallen. Never
        // filled in before, so neither ever went off in a battle.
        attacker.fallenAllies = (byMine ? board.mine : board.theirs).filter(\.fainted).count
        let result = DamageCalc.calculate(attacker: attacker, defender: defender,
                                          move: move, field: field)

        // An absorbed hit is not merely a hit that did nothing. The
        // calculator already zeroes the damage; what it cannot do is
        // pay the ability out, because it has no board to pay into.
        if result.effectiveness == 0, !breaker,
           result.notes.contains(where: { $0.contains("absorbed") }) {
            let who = defending[index].build.ability
            let heals = ["Water Absorb", "Volt Absorb", "Dry Skin", "Earth Eater"]
            if heals.contains(who) {
                let back = Swift.max(1, defending[index].maxHP / 4)
                let gained = Swift.min(defending[index].maxHP - defending[index].hp, back)
                if gained > 0 {
                    if hitMine { board.mine[index].hp += gained }
                    else { board.theirs[index].hp += gained }
                    board.note("\(hitName)'s \(who) drank it in for \(gained).")
                } else {
                    board.note("\(hitName)'s \(who) absorbed it.")
                }
            } else {
                let paid: [Stat: Int]
                switch who {
                case "Sap Sipper":    paid = [.attack: 1]
                case "Motor Drive":   paid = [.speed: 1]
                case "Storm Drain", "Lightning Rod": paid = [.spAttack: 1]
                case "Flash Fire":    paid = [.spAttack: 1]
                default:              paid = [:]
                }
                if paid.isEmpty { board.note("\(hitName)'s \(who) absorbed it.") }
                else {
                    StatChanges.change(paid, onMine: hitMine, slot: index, board: &board, because: who)
                }
            }
            return 0
        }
        if field.critical { board.detail("A critical hit!") }

        // 3. What the far side brings to it. These are the calculator's
        // own notes, so the commentary cannot drift from the maths.
        for line in result.notes where worthSaying(line) {
            board.detail(line)
        }
        if actor.status.halvesPhysical, move.category == "Physical" {
            board.detail("\(name) is burned, so it hits softer.")
        }
        if result.effectiveness == 0 {
            board.detail("It does not affect \(hitName).")
            return 0
        }

        // 4. The roll.
        let accuracy = move.neverMisses || move.accuracy == 0
            ? 1.0 : Accuracy.chanceToHit(move, attacker: actor, defender: defending[index],
                                board: board) / 100
        // One blow, not the flurry. `calculate` already multiplies a
        // multi-hit move up by the strikes it assumes, because that is
        // what the calculator screen should show — so taking its total
        // as a single blow and multiplying by the blows again squared
        // the move. Bullet Seed was doing three times three.
        let whole: Int = rolling
            ? Int.random(in: Swift.min(result.minDamage, result.maxDamage)
                         ... Swift.max(result.minDamage, result.maxDamage),
                         using: &Dice.source)
            : Int((Double(result.minDamage + result.maxDamage) / 2 * accuracy).rounded())
        let oneBlow: Int = result.strikes > 1
            ? Swift.max(1, Int((Double(whole) / result.strikes).rounded()))
            : whole

        // How many times it lands. Parental Bond adds a second blow at
        // a quarter, which is the ability rather than the move, so the
        // two are counted together and the log says which is which.
        // A split dart is one blow each; both darts on one target is
        // the move's own two.
        var blows = move.blows(for: actor.build.ability, accuracy: accuracy,
                               rolling: rolling, using: &Dice.source)
        if move.smartTarget == true, board.activeCount > 1 {
            blows = aim.dartedTwice ? 2 : 1
        }
        // Parental Bond adds its own second blow, but not to a move
        // that already throws several and not to Dragon Darts, which
        // the reference marks as refusing it outright.
        let bonded = actor.build.ability == "Parental Bond"
            && move.isDamaging && !move.isSpread && blows == 1
            && move.smartTarget != true
        let dealt = Int((Double(oneBlow) * blows).rounded())
                + (bonded ? Swift.max(1, oneBlow / 4) : 0)
        if blows > 1 {
            board.detail(move.escalates
                         ? String(format: "%d blows, each harder than the last.",
                                  move.hits?.last ?? 0)
                         : "\(Int(blows.rounded())) hits, \(oneBlow) each.")
        }
        if bonded { board.detail("Parental Bond: a second blow at a quarter.") }

        // A one-hit knockout does exactly that, three times in ten,
        // and nothing at all the rest of the time. It is worked out
        // here rather than from power, because its listed power is 1.
        if move.isOHKO {
            let lands = rolling ? Double.random(in: 0..<1, using: &Dice.source) < 0.3 : false
            if defending[index].types.contains(.ice), move.id == "sheercold" {
                board.detail("It does not affect \(hitName).")
                return 0
            }
            if lands {
                if hitMine { board.mine[index].hp = 0 } else { board.theirs[index].hp = 0 }
                board.note("It is a one-hit knockout. \(hitName) fainted.")
                return defending[index].hp
            } else {
                board.note(rolling ? "But it missed."
                                   : "\(hitName) is looking at a one-hit knockout, three times in ten.")
            }
            return 0
        }

        // A Substitute takes the hit instead, and the Pokémon behind
        // it takes nothing at all — not the damage, not the stat drop,
        // not the status. Sound moves and an Infiltrator go through it.
        if defending[index].substitute > 0, !move.isSound,
           actor.build.ability != "Infiltrator" {
            let shell = defending[index].substitute
            let absorbed = Swift.min(shell, dealt)
            if hitMine { board.mine[index].substitute = shell - absorbed }
            else { board.theirs[index].substitute = shell - absorbed }
            board.note(absorbed >= shell
                       ? "\(hitName)'s substitute broke."
                       : "\(hitName)'s substitute took \(absorbed).")
            return 0
        }

        var landed = dealt
        var sashed = false
        if defending[index].enduring, dealt >= defending[index].hp {
            landed = defending[index].hp - 1
            board.detail("\(hitName) endured it.")
        }
        if defending[index].build.item == "Focus Sash",
           !defending[index].build.itemSpent,
           defending[index].hp == defending[index].maxHP,
           dealt >= defending[index].hp {
            landed = defending[index].hp - 1
            sashed = true
        }
        // A berry that halved the hit is a berry that has been eaten.
        let ateBerry = result.notes.contains { $0.contains("then is consumed") }
        if hitMine {
            board.mine[index].hp = Swift.max(0, board.mine[index].hp - landed)
            if sashed { board.mine[index].build.itemSpent = true }
            if ateBerry { board.mine[index].build.itemSpent = true }
        } else {
            board.theirs[index].hp = Swift.max(0, board.theirs[index].hp - landed)
            if sashed { board.theirs[index].build.itemSpent = true }
            if ateBerry { board.theirs[index].build.itemSpent = true }
        }
        let share = Int((Double(landed) / Double(Swift.max(1, defending[index].maxHP))
                         * 100).rounded())
        if result.effectiveness > 1 {
            board.detail("It is super effective. \(hitName) took \(landed) (\(share)%).")
        } else if result.effectiveness < 1 {
            board.detail("\(hitName) resists it — \(landed) (\(share)%).")
        } else {
            board.detail("\(hitName) took \(landed) (\(share)%).")
        }
        if sashed { board.detail("\(hitName) hung on with its Focus Sash.") }

        // 5. Afterwards: what the move does beyond the damage, and what
        // the target's own ability does back.
        contact(move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                wasAt: defending[index].hp, rolling: rolling, board: &board)
        Switching.flee(ifNeeded: index, ofMine: hitMine, wasAt: defending[index].hp,
             board: &board)
        // Fake Out used to flinch from here as well as through its
        // own secondary, which is how it carries the flinch in the
        // data: a hundred per cent, `kind: flinch`. Two paths for one
        // effect said "flinched" twice in the log, and — the part that
        // mattered — this one ran before the check that lets a Shield
        // Dust or a Covert Cloak refuse a secondary. So the item worn
        // specifically to stand in front of a Fake Out did not, which
        // is most of the reason anybody wears it.
        if result.notes.contains(where: { $0.contains("Weakness Policy") }) {
            StatChanges.applySelf([.attack: 2, .spAttack: 2], toMine: hitMine, slot: index,
                      board: &board)
            if hitMine { board.mine[index].build.itemSpent = true }
            else { board.theirs[index].build.itemSpent = true }
        }
        StatChanges.applyDrops(move.targetDrops, toMine: hitMine, slot: index, board: &board)
        secondary(of: move, byMine: byMine, hitMine: hitMine, slot: slot, hit: index,
                  rolling: rolling, board: &board)
        let after = hitMine ? board.mine[index] : board.theirs[index]
        if after.hp == 0 {
            board.detail("\(hitName) fainted.")
            // Destiny Bond: it takes whatever did it with it. Checked
            // before the knockout abilities below, because a Moxie
            // that is about to faint does not get its stage.
            if after.destinyBound, !(byMine ? board.mine : board.theirs)[slot].fainted {
                if byMine { board.mine[slot].hp = 0 } else { board.theirs[slot].hp = 0 }
                board.note("\(hitName)'s Destiny Bond took \(name) with it.")
            }
            // Moxie and its kin take something from the knockout.
            switch actor.build.ability {
            case "Moxie", "Chilling Neigh":
                StatChanges.change([.attack: 1], onMine: byMine, slot: slot, board: &board,
                       because: actor.build.ability)
            case "Grim Neigh", "Soul-Heart":
                StatChanges.change([.spAttack: 1], onMine: byMine, slot: slot, board: &board,
                       because: actor.build.ability)
            case "Beast Boost":
                // Whichever of its stats is highest, which is the whole
                // trick of it.
                let build = actor.build
                let best = [Stat.attack, .defense, .spAttack, .spDefense, .speed]
                    .max { build.stat($0) < build.stat($1) } ?? .attack
                StatChanges.change([best: 1], onMine: byMine, slot: slot, board: &board, because: "Beast Boost")
            default: break
            }
        }
        return landed
    }

    /// 5. Afterwards: what the action cost and gave back, once every target has
    /// been struck.
    ///
    /// A move that reached nobody failed, and a move that crashes when it fails
    /// crashes now. Drain moves take back a share of what they did, or lose it
    /// to a Liquid Ooze. Rapid Spin sweeps its own side. Then what the move does
    /// to its user: Close Combat's defences, Overheat's Special Attack, recoil,
    /// a Life Orb.
    private static func settle(_ move: Move, actor: Fighter, name: String, aim: Aim,
                               totalDealt: Int, reached: Int, byMine: Bool, slot: Int,
                               board: inout Board) {
        // A move that reached nobody failed: missed, blocked, or nothing
        // there to hit. Stomping Tantrum remembers, and a move that hurts
        // its user when it fails hurts its user now — High Jump Kick into
        // a Protect crashes just as it does into thin air.
        MoveHistory.markFailed(byMine: byMine, slot: slot, board: &board, failed: reached == 0)
        if reached == 0 {
            let costs = move.drawbacks
            if costs.crash > 0 {
                let lost = Swift.max(1, Int(Double(actor.maxHP) * costs.crash))
                if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                board.note("\(name) kept going and crashed.")
            }
            return
        }
        // What comes back: Leech Life and its kind restore a share of what
        // they took.
        if let share = move.drainShare, totalDealt > 0 {
            let team = byMine ? board.mine : board.theirs
            let far = aim.hitMine ? board.mine : board.theirs
            // Liquid Ooze turns a drain into a cost: what would have been
            // healed is taken off the attacker instead.
            let oozed = aim.aimed.contains { far.indices.contains($0)
                && far[$0].build.ability == "Liquid Ooze" }
            if !team[slot].fainted {
                let amount = Swift.max(1, Int(Double(totalDealt) * share))
                if oozed {
                    if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - amount) }
                    else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - amount) }
                    board.note("\(name) drank the Liquid Ooze and lost \(amount).")
                    if (byMine ? board.mine : board.theirs)[slot].fainted {
                        board.note("\(name) fainted.")
                    }
                } else {
                    let gained = Swift.min(team[slot].maxHP - team[slot].hp, amount)
                    if gained > 0 {
                        if byMine { board.mine[slot].hp += gained } else { board.theirs[slot].hp += gained }
                        board.note("\(name) drained \(gained) health back.")
                    }
                }
            }
        }
        // Rapid Spin clears its own side on the way past, which is a
        // damaging move doing something only a status move otherwise does.
        if move.name == "Rapid Spin", board.sweepHazards(mine: byMine) {
            board.note("\(name) spun the hazards away from its own side.")
        }
        StatChanges.applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
        // What the move takes off its user: Close Combat's defences,
        // Overheat's Special Attack. Missed entirely until now, so a
        // Sneasler could Close Combat all game at full Defence.
        StatChanges.applySelf(move.selfDrops.mapValues { -$0 }, toMine: byMine, slot: slot, board: &board)
        cost(of: move, dealt: totalDealt, byMine: byMine, slot: slot, board: &board)
    }

    /// Whether one of the calculator's notes is worth reading out.
    ///
    /// It keeps notes for everything it applies, including arithmetic nobody
    /// needs narrated. What belongs in a battle log is what the *other* side
    /// brought to the exchange, because that is the part a player did not know
    /// and has to learn.
    private static func worthSaying(_ note: String) -> Bool {
        let interesting = ["halves", "consumed", "Screen", "immune", "absorbed",
                           "Thick Fat", "Weakness Policy", "Wide Open", "Sturdy",
                           "Focus Sash", "at full HP", "Terrain", "Snow", "Aura Guard",
                           "Supreme Overlord", "Helping Hand", "Spread"]
        return interesting.contains { note.contains($0) }
    }

    /// What the target's ability does to whatever just touched it — and what
    /// the attacker's does to whatever it touched.
    ///
    /// Rough Skin and Iron Barbs take an eighth off anything that makes contact.
    /// Flame Body, Static and Poison Point give a contact attacker a condition
    /// three times in ten. Stamina raises Defense on every hit taken. Poison
    /// Touch works the other way round, poisoning what the attacker touches.
    /// None of it fired: an Incineroar could Flare Blitz a Garchomp all day and
    /// its Rough Skin never cost a point.
    private static func contact(_ move: Move, byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                                wasAt: Int, rolling: Bool, board: inout Board) {
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = hitMine ? board.mine : board.theirs
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit) else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        let attackerName = attacker.build.form.formLabel
        let defenderName = defender.build.form.formLabel

        // Stamina does not need contact: any hit raises Defense.
        if defender.build.ability == "Stamina", !defender.fainted {
            StatChanges.applySelf([.defense: 1], toMine: hitMine, slot: hit, board: &board)
        }
        // Rocky Helmet: a sixth of the attacker's health for touching it, which
        // is the item's whole job and the reason a physical attacker thinks
        // twice. Red Card sends the attacker out instead.
        if move.makesContact, !attacker.fainted {
            if defender.build.item == "Rocky Helmet", !defender.fainted {
                let lost = Swift.max(1, attacker.maxHP / 6)
                if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                board.note("\(attackerName) was hurt by \(defenderName)'s Rocky Helmet.")
            }
            if defender.build.item == "Red Card", !defender.build.itemSpent, !defender.fainted {
                if hitMine { board.mine[hit].build.itemSpent = true }
                else { board.theirs[hit].build.itemSpent = true }
                board.note("\(defenderName)'s Red Card sent \(attackerName) away.")
                Switching.leave(byMine: byMine, slot: slot, board: &board)
            }
        }
        // Eject Button: the holder leaves the moment it is hit.
        if defender.build.item == "Eject Button", !defender.build.itemSpent, !defender.fainted {
            if hitMine { board.mine[hit].build.itemSpent = true }
            else { board.theirs[hit].build.itemSpent = true }
            board.note("\(defenderName)'s Eject Button took it out.")
            Switching.leave(byMine: hitMine, slot: hit, board: &board)
            return
        }

        // Abilities that answer the kind of hit: Thermal Exchange takes Fire
        // and gives Attack, Justified the same for Dark, Rattled runs from
        // Bug, Ghost and Dark, Weak Armor trades Defence for Speed on any
        // physical hit, Berserk answers the hit that took it to half.
        if !defender.fainted {
            let hitType = DamageCalc.fieldForm(of: move, in: board.field).type
            var answer: [Stat: Int] = [:]
            switch defender.build.ability {
            case "Thermal Exchange" where hitType == .fire: answer = [.attack: 1]
            case "Justified" where hitType == .dark: answer = [.attack: 1]
            case "Rattled" where [.bug, .ghost, .dark].contains(hitType): answer = [.speed: 1]
            case "Weak Armor" where move.category == "Physical": answer = [.defense: -1, .speed: 2]
            case "Berserk" where wasAt * 2 > defender.maxHP && defender.hp * 2 <= defender.maxHP:
                answer = [.spAttack: 1]
            default: break
            }
            if !answer.isEmpty {
                StatChanges.change(answer, onMine: hitMine, slot: hit, board: &board, because: defender.build.ability)
            }
        }
        // Anger Point needs no contact: any critical hit takes it to the top.
        if defender.build.ability == "Anger Point", !defender.fainted, board.lastWasCritical,
           defender.build.boosts[Stat.attack.rawValue] < 6 {
            if hitMine { board.mine[hit].build.boosts[Stat.attack.rawValue] = 6 }
            else { board.theirs[hit].build.boosts[Stat.attack.rawValue] = 6 }
            board.note("\(defenderName)'s Anger Point maximised its Attack.")
        }

        // Long Reach means nothing it throws ever touches anything, which
        // turns off Rocky Helmet, Static, Rough Skin and the rest of them.
        let touched = move.makesContact && attacker.build.ability != "Long Reach"

        // Abilities that answer being hit at all, contact or not.
        if !defender.fainted, !attacker.fainted {
            switch defender.build.ability {
            case "Seed Sower" where board.field.terrain != .grassy:
                let before = board.field
                board.field.terrain = .grassy
                board.terrainTurns = 5
                board.fieldSettled(from: before)
                board.terrainSeeds()
                board.note("\(defenderName)'s Seed Sower turned the ground to grass.")
            case "Toxic Debris":
                var far = byMine ? board.myScreens : board.theirScreens
                if far.toxicSpikes < 2 {
                    far.toxicSpikes += 1
                    if byMine { board.myScreens = far } else { board.theirScreens = far }
                    board.note("\(defenderName) scattered toxic spikes.")
                }
            case "Electromorphosis":
                if hitMine { board.mine[hit].charged = true } else { board.theirs[hit].charged = true }
                board.note("\(defenderName) became charged.")
            case "Spicy Spray" where attacker.status == .none
                && !attacker.types.contains(.fire):
                if byMine { board.mine[slot].status = .burn } else { board.theirs[slot].status = .burn }
                board.note("\(defenderName)'s Spicy Spray burned \(attackerName).")
            default: break
            }
        }
        // Stench: one hit in ten makes the target flinch, from either side of
        // the field, which is the whole of it.
        if attacker.build.ability == "Stench", !defender.fainted, rolling,
           Double.random(in: 0..<1, using: &Dice.source) < 0.1 {
            Ailments.flinch(onMine: hitMine, slot: hit, board: &board, because: "the stench")
        }

        // Aftermath and Innards Out charge whoever landed the finishing hit.
        if defender.fainted, !attacker.fainted {
            var lost = 0
            if defender.build.ability == "Aftermath", touched { lost = attacker.maxHP / 4 }
            if defender.build.ability == "Innards Out" { lost = wasAt }
            if lost > 0 {
                if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
                else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
                board.note("\(attackerName) was hurt by \(defenderName)'s \(defender.build.ability).")
                if (byMine ? board.mine : board.theirs)[slot].fainted {
                    board.note("\(attackerName) fainted.")
                }
            }
        }

        guard touched, !attacker.fainted else { return }

        // Cute Charm: three in ten that whoever touched it falls for it, and
        // loses half its turns while it is still standing there.
        if defender.build.ability == "Cute Charm", !defender.fainted,
           attacker.infatuatedWith == nil, rolling,
           Double.random(in: 0..<1, using: &Dice.source) < 0.3 {
            if byMine { board.mine[slot].infatuatedWith = hit }
            else { board.theirs[slot].infatuatedWith = hit }
            board.note("\(attackerName) fell for \(defenderName)'s Cute Charm.")
        }
        // Pickpocket takes the item off whatever touched it, if its own hands
        // are empty.
        if defender.build.ability == "Pickpocket", !defender.fainted,
           defender.build.item.isEmpty, !attacker.build.item.isEmpty,
           attacker.build.ability != "Sticky Hold" {
            let taken = attacker.build.item
            if hitMine { board.mine[hit].build.item = taken; board.mine[hit].build.itemSpent = false }
            else { board.theirs[hit].build.item = taken; board.theirs[hit].build.itemSpent = false }
            if byMine { board.mine[slot].build.item = "" } else { board.theirs[slot].build.item = "" }
            board.note("\(defenderName) pickpocketed \(attackerName)'s \(taken).")
        }

        // Mummy spreads itself to whatever touches it; Wandering Spirit
        // trades instead. Both turn off whatever the attacker was relying on.
        if !defender.fainted, !attacker.fainted {
            let stubborn: Set<String> = ["Mummy", "Wandering Spirit", "Lingering Aroma",
                                         "Multitype", "Stance Change", "Disguise",
                                         "Zen Mode", "Battle Bond", "Comatose"]
            if ["Mummy", "Lingering Aroma"].contains(defender.build.ability),
               !stubborn.contains(attacker.build.ability) {
                let was = attacker.build.ability
                if byMine { board.mine[slot].build.ability = defender.build.ability }
                else { board.theirs[slot].build.ability = defender.build.ability }
                board.note("\(attackerName)'s \(was) became \(defender.build.ability).")
            } else if defender.build.ability == "Wandering Spirit",
                      !stubborn.contains(attacker.build.ability) {
                let theirs = attacker.build.ability
                if byMine { board.mine[slot].build.ability = "Wandering Spirit" }
                else { board.theirs[slot].build.ability = "Wandering Spirit" }
                if hitMine { board.mine[hit].build.ability = theirs }
                else { board.theirs[hit].build.ability = theirs }
                board.note("\(defenderName) and \(attackerName) traded abilities.")
            }
        }

        // Gooey and Tangling Hair take a stage of Speed off whatever touches
        // them, which is how a slow Pokémon stops being outrun.
        if ["Gooey", "Tangling Hair"].contains(defender.build.ability), !defender.fainted {
            StatChanges.change([.speed: -1], onMine: byMine, slot: slot, board: &board,
                   because: defender.build.ability)
        }
        // Magician takes the item off whatever it hits, if its own hands are
        // empty. Pickpocket is the same trade in the other direction.
        if attacker.build.ability == "Magician", attacker.build.item.isEmpty,
           !defender.build.item.isEmpty, !defender.fainted,
           defender.build.ability != "Sticky Hold" {
            let taken = defender.build.item
            if byMine { board.mine[slot].build.item = taken; board.mine[slot].build.itemSpent = false }
            else { board.theirs[slot].build.item = taken; board.theirs[slot].build.itemSpent = false }
            if hitMine { board.mine[hit].build.item = "" } else { board.theirs[hit].build.item = "" }
            board.note("\(attackerName)'s Magician took \(defenderName)'s \(taken).")
        }

        switch defender.build.ability {
        case "Rough Skin", "Iron Barbs":
            let lost = Swift.max(1, attacker.maxHP / 8)
            if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
            else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
            board.note("\(attackerName) is hurt by \(defenderName)'s \(defender.build.ability).")
        case "Effect Spore":
            // One in ten, and one of three things.
            guard rolling, Double.random(in: 0..<1, using: &Dice.source) < 0.3,
                  attacker.status == .none, !attacker.types.contains(.grass) else { break }
            let roll = Double.random(in: 0..<1, using: &Dice.source)
            let ailment: Ailment = roll < 0.34 ? .paralysis : roll < 0.67 ? .poison : .sleep
            if byMine { board.mine[slot].status = ailment; board.mine[slot].asleepFor = ailment == .sleep ? 2 : 0 }
            else { board.theirs[slot].status = ailment; board.theirs[slot].asleepFor = ailment == .sleep ? 2 : 0 }
            board.note("\(attackerName) was \(ailment.rawValue) by \(defenderName)'s Effect Spore.")
        case "Flame Body", "Static", "Poison Point":
            // Three in ten. A search averages, so it does not apply these at
            // all rather than applying them to everybody.
            guard rolling, Double.random(in: 0..<1, using: &Dice.source) < 0.3, attacker.status == .none else { break }
            let ailment: Ailment = defender.build.ability == "Flame Body" ? .burn
                : defender.build.ability == "Static" ? .paralysis : .poison
            let immune = (ailment == .burn && attacker.build.form.pokeTypes.contains(.fire))
                || (ailment == .paralysis && attacker.build.form.pokeTypes.contains(.electric))
                || (ailment == .poison && attacker.build.form.pokeTypes.contains(where: {
                    [.poison, .steel].contains($0) }))
            guard !immune else { break }
            if byMine { board.mine[slot].status = ailment } else { board.theirs[slot].status = ailment }
            board.note("\(defenderName)'s \(defender.build.ability) left \(attackerName) \(ailment.rawValue).")
        default:
            break
        }

        let poisonRoll: Bool
        if rolling { poisonRoll = Double.random(in: 0..<1, using: &Dice.source) < 0.3 }
        else { poisonRoll = board.rulings[Board.flip("poisontouch", byMine, slot)] ?? false }
        if attacker.build.ability == "Poison Touch", poisonRoll, !defender.fainted,
           defender.status == .none,
           !defender.types.contains(where: { [.poison, .steel].contains($0) }) {
            if hitMine { board.mine[hit].status = .poison } else { board.theirs[hit].status = .poison }
            board.note("\(attackerName)'s Poison Touch poisoned \(defenderName).")
        }
    }

    /// What using the move costs the Pokémon that used it.
    ///
    /// None of this was applied: Final Gambit did its damage and left the user
    /// standing, Flare Blitz and Wood Hammer were free, Steel Beam cost
    /// nothing, and a Life Orb was pure profit. The move ranker has priced all
    /// of these for a long time — it is why Steel Beam ranks below Iron Head —
    /// and the battle simply never charged them.
    private static func cost(of move: Move, dealt: Int, byMine: Bool, slot: Int,
                             board: inout Board) {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        let name = team[slot].build.form.formLabel
        let maxHP = team[slot].maxHP
        var lost = 0

        // Moves that end the user's game outright.
        if move.effect.contains("The user faints") {
            lost = team[slot].hp
            board.note("\(name) fainted using \(move.name).")
        } else {
            let costs = move.drawbacks
            if costs.recoil > 0, dealt > 0 {
                lost += Swift.max(1, Int(Double(dealt) * costs.recoil))
                board.note("\(name) is hurt by the recoil.")
            }
            if costs.selfDamage > 0 {
                lost += Swift.max(1, Int(Double(maxHP) * costs.selfDamage))
                board.note("\(name) pays for \(move.name) with its own health.")
            }
            // A Life Orb takes a tenth of maximum every time it lands a hit.
            if team[slot].build.item == "Life Orb", dealt > 0,
               team[slot].build.ability != "Sheer Force" {
                lost += Swift.max(1, maxHP / 10)
                board.note("\(name) is worn down by its Life Orb.")
            }
        }
        guard lost > 0 else { return }
        if byMine { board.mine[slot].hp = Swift.max(0, board.mine[slot].hp - lost) }
        else { board.theirs[slot].hp = Swift.max(0, board.theirs[slot].hp - lost) }
        let after = byMine ? board.mine[slot] : board.theirs[slot]
        if after.hp == 0, !move.effect.contains("The user faints") {
            board.note("\(name) fainted.")
        }
    }

    /// Protect, with the odds the game gives it: certain the first time, a
    /// third the next, a ninth after that, and back to certain the moment one
    /// fails or a turn goes by without one. A played turn rolls it; the search
    /// takes anything under even as a miss, so it never counts on a second
    /// Protect in a row — which is exactly the read a good player makes.
    /// What a hit does besides damage. A played turn rolls the chance; the
    /// search, which averages, applies only what is certain — Nuzzle's
    /// paralysis, not Scald's three-in-ten burn — the way it treats Flame
    /// Body. Serene Grace doubles the odds; Sheer Force trades them away.
    /// How likely a move's secondary effect is, once the user's ability has
    /// had its say. Sheer Force trades it away for power; Serene Grace doubles
    /// it. Worked out in one place because `outcomes` offers the branch and
    /// `secondary` takes it, and the two disagreeing would price a coin flip
    /// that never happens.
    static func secondaryChance(of move: Move, for fighter: Fighter) -> Int {
        guard let effect = move.secondaries.first else { return 0 }
        return chance(of: effect, for: fighter)
    }

    /// One secondary's chance, once the user's ability has had its say.
    static func chance(of effect: Move.Secondary, for fighter: Fighter) -> Int {
        if fighter.build.ability == "Sheer Force" { return 0 }
        if fighter.build.ability == "Serene Grace" { return Swift.min(100, effect.chance * 2) }
        return effect.chance
    }

    private static func secondary(of move: Move, byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                                  rolling: Bool, board: inout Board) {
        guard !move.secondaries.isEmpty else { return }
        let attackerTeam = byMine ? board.mine : board.theirs
        let defenderTeam = hitMine ? board.mine : board.theirs
        guard attackerTeam.indices.contains(slot), defenderTeam.indices.contains(hit),
              !defenderTeam[hit].fainted else { return }
        let attacker = attackerTeam[slot], defender = defenderTeam[hit]
        let name = defender.build.form.formLabel
        // Shield Dust and a Covert Cloak refuse every secondary effect aimed at
        // their holder, which is the whole point of both.
        if defender.build.ability == "Shield Dust" || defender.build.item == "Covert Cloak" {
            return
        }
        // Every secondary the move has, not the first one. Fire Fang, Ice Fang
        // and Thunder Fang each carry two, and Triple Arrows carries a stat
        // drop and a flinch at different odds; reading only the first meant
        // half of each of those moves never happened.
        for effect in move.secondaries {
            let chance = Strikes.chance(of: effect, for: attacker)
            guard chance > 0 else { continue }
            // A played turn rolls. The search takes the branch it was handed,
            // and falls back to "only what is certain" when it was handed none.
            let happens: Bool
            if rolling { happens = Double.random(in: 0..<100, using: &Dice.source) < Double(chance) }
            else if let ruled = board.rulings[Board.flip("secondary", byMine, slot)] { happens = ruled }
            else { happens = chance >= 100 }
            guard happens else { continue }
            applySecondary(effect, chance: chance, of: move, byMine: byMine, hitMine: hitMine,
                  slot: slot, hit: hit, name: name, rolling: rolling, board: &board)
        }
    }

    /// One secondary effect landing.
    static func applySecondary(_ effect: Move.Secondary, chance: Int, of move: Move,
                              byMine: Bool, hitMine: Bool, slot: Int, hit: Int,
                              name: String, rolling: Bool, board: inout Board) {
        let defenderTeam = hitMine ? board.mine : board.theirs
        let attackerTeam = byMine ? board.mine : board.theirs
        guard defenderTeam.indices.contains(hit), attackerTeam.indices.contains(slot) else { return }
        switch effect.kind {
        case .status(let ailment):
            Ailments.inflict(ailment, onMine: hitMine, slot: hit, byMine: byMine, bySlot: slot,
                             board: &board, rolling: rolling,
                             because: chance < 100 ? "the \(chance)% came up" : nil,
                             announceImmunity: false)
        case .flinch:
            // Only matters if it has yet to move this turn; the flag clears at
            // the turn's start either way. Inner Focus is handled inside.
            Ailments.flinch(onMine: hitMine, slot: hit, board: &board,
                   because: chance < 100 ? "the \(chance)% came up" : nil)
        case .drops(let drops):
            StatChanges.applyDrops(drops, toMine: hitMine, slot: hit, board: &board)
        case .targetBoosts(let raises):
            StatChanges.applySelf(raises, toMine: hitMine, slot: hit, board: &board)
        case .selfBoosts(let raises):
            // Charge Beam, Meteor Mash, Ancient Power, Steel Wing: the payment
            // goes to whoever used the move, not to whoever was hit.
            StatChanges.applySelf(raises, toMine: byMine, slot: slot, board: &board)
        case .selfDrops(let drops):
            StatChanges.applyDrops(drops, toMine: byMine, slot: slot, board: &board)
        case .confuse:
            // Whether the confusion lands was settled above; `rolling` here
            // only decides how long it lasts, and a played turn should roll
            // that rather than always taking the two turns the search assumes.
            Ailments.confuse(onMine: hitMine, slot: hit, board: &board, rolling: rolling, chance: chance)
        }
    }

    /// The move index a choice picks, or -1 for anything that is not an attack.
    private static func pickedMove(_ choice: Choice) -> Int {
        if case .attack(let index, _) = choice { return index }
        if case .protectSelf(let index) = choice { return index }
        return -1
    }

    /// The non-damaging moves that end the user's game: Memento, Healing Wish.
    private static func selfKO(_ move: Move, byMine: Bool, slot: Int,
                               board: inout Board) {
        guard move.effect.contains("The user faints") else { return }
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot), !team[slot].fainted else { return }
        // Damp refuses an explosion from anywhere on the field, including one
        // its own side set off.
        if let damp = (board.mine + board.theirs).prefix(board.activeCount * 2).first(where: {
            !$0.fainted && ["Damp"].contains($0.build.ability)
        }) {
            board.note("\(damp.build.form.formLabel)'s Damp stopped it going off.")
            return
        }
        if byMine { board.mine[slot].hp = 0 } else { board.theirs[slot].hp = 0 }
        board.note("\(team[slot].build.form.formLabel) fainted using \(move.name).")
    }
}
