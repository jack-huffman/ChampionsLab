//  SupportMoves.swift
//  The status moves, each of which is its own rule.
//
//  A damaging move is described by its data -- power, type, accuracy, the
//  secondary it carries -- and the same pipeline resolves all nine hundred of
//  them. A status move is not like that. Trick Room reverses the order for
//  five turns; Leech Seed plants something that drains every turn; Parting
//  Shot drops two stats and leaves; Haze wipes every stage on the field.
//  There is no schema for "what a status move does" because each one does a
//  different thing, and so each is written down by name.
//
//  That is why this file is the size it is, and why it is one file: eighty-odd
//  rules that share nothing but the shape of their entry. It used to sit in
//  the same namespace as the damage pipeline, where a rule about Trick Room
//  and a rule about critical hits were forty lines apart. Here a status move
//  is found by its name and nothing else lives alongside it.
//
//  What a status move does *not* do by itself: decide whether it can be used,
//  who it reaches, or whether a Protect stops it. That is settled in Strikes
//  before the move gets here, the same way it is for a damaging move.

import Foundation

enum SupportMoves {
    /// What a non-damaging move actually does.
    ///
    /// Eleven per cent of the move slots on real team lists were landing here
    /// and doing nothing at all: Follow Me, Rage Powder, Wide Guard, Swords
    /// Dance, Nasty Plot, Calm Mind, Will-O-Wisp, Encore, the screens. Two of
    /// those are the entire reason a doubles support Pokémon exists, so a third
    /// of the format could be brought to a battle and simply not play.
    ///
    /// Read from what each move says rather than from a list of names, wherever
    /// the sentence is regular enough to trust.
    /// What a status move asks the pipeline to do after it, if anything.
    ///
    /// Only Instruct has an answer: it makes the partner use its last move
    /// again, which is an ordinary action and has to run through the ordinary
    /// action pipeline. It used to call straight back into Strikes for that,
    /// which made the status moves depend on the damage pipeline and the
    /// damage pipeline depend on the status moves. Handing the request back
    /// up is the same behaviour without the loop.
    enum Followup {
        case replay(Choice, byMine: Bool, slot: Int)
    }

    /// What every status move is handed: the setup `support` did once, so the
    /// helpers below and the sections that use them read the same things.
    ///
    /// `team` is the user's side as it stood when the move began -- a snapshot,
    /// as it always was -- and `name` is the user's, for the log.
    struct Cast {
        let move: Move
        let byMine: Bool
        let slot: Int
        let target: Int
        let rolling: Bool
        let team: [Fighter]
        let name: String

        /// Aimed at the caster's own partner rather than across the field.
        /// A Skill Swap, a Trick, a Guard Split are all things you do to your
        /// own side as readily as to theirs, and the screen offers the
        /// partner as a target; `Choice.allyTarget` is how that arrives.
        var atAlly: Bool { target >= Choice.allyTarget }
        /// Which side the move is aimed at.
        var targetsMine: Bool { atAlly ? byMine : !byMine }
        /// The slot on that side. An ally target names the partner, whose
        /// slot is the other one.
        var targetSlot: Int { atAlly ? (slot == 0 ? 1 : 0) : target }
    }

    /// The slot this move is aimed at, if it can be reached: not down, not
    /// protecting, not behind a Substitute. Says why when it cannot. The
    /// side is whichever the move was pointed at -- across the field
    /// ordinarily, the caster's own partner for an ally target, which used
    /// to fall through to the first opponent instead.
    static func reachableTarget(_ cast: Cast, board: inout Board) -> Int? {
        let far = cast.targetsMine ? board.mine : board.theirs
        let index = far.indices.contains(cast.targetSlot) && cast.targetSlot < board.activeCount
            ? cast.targetSlot : 0
        guard far.indices.contains(index), !far[index].fainted else { return nil }
        if far[index].isProtected {
            board.note("\(far[index].build.form.formLabel) protected itself.")
            return nil
        }
        if far[index].substitute > 0 {
            board.note("\(far[index].build.form.formLabel)'s substitute took it.")
            return nil
        }
        return index
    }

    /// The name of what the move is aimed at, on whichever side that is.
    static func farName(_ cast: Cast, _ index: Int, board: Board) -> String {
        (cast.targetsMine ? board.mine : board.theirs)[index].build.form.formLabel
    }

    /// Write a changed fighter back to the side the move is aimed at.
    static func setFar(_ cast: Cast, _ index: Int, board: inout Board,
                       _ change: (inout Fighter) -> Void) {
        if cast.targetsMine { change(&board.mine[index]) } else { change(&board.theirs[index]) }
    }

    static func setNear(_ cast: Cast, board: inout Board, _ change: (inout Fighter) -> Void) {
        if cast.byMine { change(&board.mine[cast.slot]) } else { change(&board.theirs[cast.slot]) }
    }

    @discardableResult
    static func support(_ move: Move, byMine: Bool, slot: Int, target: Int,
                        to board: inout Board, rolling: Bool) -> Followup? {
        let team = byMine ? board.mine : board.theirs
        guard team.indices.contains(slot) else { return nil }
        let name = team[slot].build.form.formLabel
        let cast = Cast(move: move, byMine: byMine, slot: slot, target: target,
                        rolling: rolling, team: team, name: name)
        board.note("\(name) used \(move.name).")

        // What the other side can refuse outright. A Prankster's status move
        // does not work on a Dark type — the one thing that keeps a
        // Whimsicott's Encore off a Kingambit — and a Good as Gold refuses
        // every status move there is.
        if move.aim == .foe, !cast.atAlly {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            if far.indices.contains(index), !far[index].fainted {
                let who = far[index].build.form.formLabel
                if far[index].build.ability == "Good as Gold" {
                    board.note("But \(who)'s Good as Gold refused it outright.")
                    return nil
                }
                if team[slot].build.ability == "Prankster",
                   far[index].build.form.pokeTypes.contains(.dark) {
                    board.note("But it does not affect \(who) — a Dark type shrugs off a Prankster's tricks.")
                    return nil
                }
            }
        }

        // Healing: Recover and its kind give back a share of the bar, to the
        // user, the partner, or both; Rest gives back all of it and two turns.
        if let healing = move.healing {
            var share = healing.share
            if healing.sunlit {
                switch board.field.weather {
                case .sun: share = 2.0 / 3.0
                case .none: break
                default: share = 0.25
                }
            }
            let partner = slot == 0 ? 1 : 0
            var receivers: [Int] = []
            switch healing.whom {
            case .user: receivers = [slot]
            case .partner: receivers = [partner]
            case .both: receivers = [slot, partner]
            }
            var anyone = false
            for who in receivers where team.indices.contains(who) && who < board.activeCount && !team[who].fainted {
                let maxHP = team[who].maxHP
                let gained = Swift.min(maxHP - team[who].hp, Swift.max(1, Int(Double(maxHP) * share)))
                guard gained > 0 else {
                    board.note("\(team[who].build.form.formLabel)'s health is already full.")
                    continue
                }
                if byMine { board.mine[who].hp += gained } else { board.theirs[who].hp += gained }
                board.note("\(team[who].build.form.formLabel) recovered \(gained) health"
                           + (share == 1 ? " and fell asleep." : "."))
                anyone = true
            }
            if move.name == "Rest", anyone {
                if byMine { board.mine[slot].status = .sleep; board.mine[slot].asleepFor = 2 }
                else { board.theirs[slot].status = .sleep; board.theirs[slot].asleepFor = 2 }
            }
            if !anyone { board.note("But it failed.") }
            return nil
        }

        // Parting Shot: the drops land and then the user leaves, which is the
        // whole point of it — a free switch that costs them two stages.
        if move.name == "Parting Shot" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            if far.indices.contains(index), !far[index].fainted, !far[index].isProtected {
                StatChanges.applyDrops([.attack: 1, .spAttack: 1], toMine: !byMine, slot: index, board: &board)
            } else if far.indices.contains(index), far[index].isProtected {
                board.note("\(far[index].build.form.formLabel) protected itself.")
            }
            Switching.leave(byMine: byMine, slot: slot, board: &board)
            return nil
        }
        // Each section knows its own moves by name and answers for them, or
        // hands on to the next. The order is the order they were written in.
        let sections: [(Cast, inout Board) -> Outcome?] = [
            reachingAcross,
            labelling,
            layingOnASide,
            settingClocks,
            settingUp,
            movingTheQueue,
            sweeping,
            rewriting,
            items,
            payingTheSide,
            trapping,
            benchAndPosition,
            hijackingActions,
            protecting,
            weatherAndTerrain,
        ]
        for section in sections {
            if let outcome = section(cast, &board) {
                pivotIfItLeaves(cast, &board)
                return outcome.followup
            }
        }
        // Teleport does nothing but leave, and a move nobody answers for is
        // still a pivot if the table says so.
        if move.pivots { pivotIfItLeaves(cast, &board) } else { board.note("Nothing came of it.") }
        return nil
    }

    /// The user leaves after a status pivot -- Teleport, Baton Pass, Shed
    /// Tail, and Parting Shot and Chilly Reception when their own sections
    /// have not already sent it on its way.
    private static func pivotIfItLeaves(_ cast: Cast, _ board: inout Board) {
        guard cast.move.pivots else { return }
        Switching.leave(byMine: cast.byMine, slot: cast.slot, board: &board)
    }

    /// What a section says about a move: handled, with whatever it asks the
    /// pipeline to do afterwards -- or nothing, meaning not one of mine.
    enum Outcome {
        case handled(Followup?)
        var followup: Followup? {
            switch self { case .handled(let followup): return followup }
        }
    }

    // MARK: - The ones that reach across and rearrange something

    private static func reachingAcross(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        //
        // Each of these was a move slot on a real team list that did nothing
        // at all. They are grouped here because they share a shape: find the
        // Pokémon on the other side, check it can be reached, then move a
        // number, a name or an object from one side to the other.


        // Trick and Switcheroo: the two held items change hands. The point is
        // to hand something a Choice Scarf and take its berry.
        if move.name == "Trick" || move.name == "Switcheroo" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            let theirs = far[index].build.item
            let ours = team[slot].build.item
            guard !(theirs.isEmpty && ours.isEmpty) else { board.note("But it failed."); return .handled(nil) }
            if far[index].build.ability == "Sticky Hold" {
                board.note("\(farName(cast, index, board: board))'s Sticky Hold kept hold of it.")
                return .handled(nil)
            }
            setFar(cast, index, board: &board) { $0.build.item = ours; $0.build.itemSpent = false }
            setNear(cast, board: &board) { $0.build.item = theirs; $0.build.itemSpent = false }
            board.note("\(name) swapped items with \(farName(cast, index, board: board)):"
                       + " \(ours.isEmpty ? "nothing" : ours) for \(theirs.isEmpty ? "nothing" : theirs).")
            return .handled(nil)
        }

        // Skill Swap trades abilities; Worry Seed replaces the target's with
        // Insomnia, which is how a sleep team gets turned off.
        if move.name == "Skill Swap" || move.name == "Worry Seed" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            let had = far[index].build.ability
            if move.name == "Worry Seed" {
                guard had != "Insomnia" else { board.note("But it failed."); return .handled(nil) }
                setFar(cast, index, board: &board) { $0.build.ability = "Insomnia" }
                board.note("\(farName(cast, index, board: board))'s ability became Insomnia.")
                if far[index].status == .sleep {
                    setFar(cast, index, board: &board) { $0.status = .none; $0.asleepFor = 0 }
                    board.note("\(farName(cast, index, board: board)) woke up.")
                }
            } else {
                let ours = team[slot].build.ability
                setFar(cast, index, board: &board) { $0.build.ability = ours }
                setNear(cast, board: &board) { $0.build.ability = had }
                board.note("\(name) and \(farName(cast, index, board: board)) swapped abilities:"
                           + " \(ours) for \(had).")
            }
            return .handled(nil)
        }

        // Spite takes four Power Points off whatever the target used last.
        //
        // It is the patient way to beat something you cannot break: a wall
        // holding a Leftovers wins a stall war by outlasting you, and Spite
        // answers by shortening the war rather than by trying to win it. It
        // fails when the target has not moved yet, or when the move it used
        // has already run dry -- there is nothing there to take.
        if move.name == "Spite" {
            guard let index = reachableTarget(cast, board: &board) else {
                board.note("But it failed."); return .handled(nil)
            }
            let far = cast.targetsMine ? board.mine : board.theirs
            guard let last = far[index].lastMove, far[index].moves.indices.contains(last),
                  far[index].pp(at: last) > 0 else {
                board.note("But it failed."); return .handled(nil)
            }
            let who = far[index].build.form.formLabel
            let what = far[index].moves[last].name
            let took = MoveLegality.drain(last, byMine: cast.targetsMine, slot: index,
                                          amount: 4, board: &board)
            board.note("\(who)'s \(what) lost \(took) Power Point\(took == 1 ? "" : "s").")
            return .handled(nil)
        }

        // Soak makes the target a pure Water type, which is how a Ground type
        // stops being immune to Thunderbolt.
        if move.name == "Soak" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            setFar(cast, index, board: &board) { $0.build.typeOverride = [.water] }
            board.note("\(farName(cast, index, board: board)) became a Water type.")
            return .handled(nil)
        }

        // Psych Up copies the target's stat changes; Guard Swap and Power Swap
        // trade one pair of them; Heart Swap trades all six.
        if ["Psych Up", "Guard Swap", "Power Swap", "Heart Swap"].contains(move.name) {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            var ourBoosts = team[slot].build.boosts
            var theirBoosts = far[index].build.boosts
            switch move.name {
            case "Psych Up":
                ourBoosts = theirBoosts
                board.note("\(name) copied \(farName(cast, index, board: board))'s stat changes.")
            case "Heart Swap":
                swap(&ourBoosts, &theirBoosts)
                board.note("\(name) and \(farName(cast, index, board: board)) traded every stat change.")
            default:
                let pair: [Stat] = move.name == "Guard Swap" ? [.defense, .spDefense]
                                                             : [.attack, .spAttack]
                for stat in pair {
                    let keep = ourBoosts[stat.rawValue]
                    ourBoosts[stat.rawValue] = theirBoosts[stat.rawValue]
                    theirBoosts[stat.rawValue] = keep
                }
                board.note("\(name) and \(farName(cast, index, board: board)) traded their"
                           + " \(move.name == "Guard Swap" ? "defensive" : "offensive") stat changes.")
            }
            setNear(cast, board: &board) { $0.build.boosts = ourBoosts }
            setFar(cast, index, board: &board) { $0.build.boosts = theirBoosts }
            return .handled(nil)
        }

        // Pain Split averages the two health bars, which is what lets
        // something on its last legs drag a healthy attacker down with it.
        if move.name == "Pain Split" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            let shared = (team[slot].hp + far[index].hp) / 2
            setNear(cast, board: &board) { $0.hp = Swift.min($0.maxHP, shared) }
            setFar(cast, index, board: &board) { $0.hp = Swift.min($0.maxHP, shared) }
            board.note("\(name) and \(farName(cast, index, board: board)) split their health, \(shared) each.")
            return .handled(nil)
        }

        // Guard Split and Power Split average the raw stats rather than the
        // stages, so a wall hands half its bulk to whatever it touches.
        if move.name == "Guard Split" || move.name == "Power Split" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let pair: [Stat] = move.name == "Guard Split" ? [.defense, .spDefense]
                                                          : [.attack, .spAttack]
            let far = cast.targetsMine ? board.mine : board.theirs
            for stat in pair {
                let averaged = (team[slot].build.stat(stat) + far[index].build.stat(stat)) / 2
                setNear(cast, board: &board) { $0.build.statOverride = ($0.build.statOverride ?? [:]).merging([stat.rawValue: averaged]) { _, new in new } }
                setFar(cast, index, board: &board) { $0.build.statOverride = ($0.build.statOverride ?? [:]).merging([stat.rawValue: averaged]) { _, new in new } }
            }
            board.note("\(name) and \(farName(cast, index, board: board)) split their"
                       + " \(move.name == "Guard Split" ? "defences" : "attacking power").")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that stick a label on something

    private static func labelling(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let name = cast.name
        if move.name == "Attract" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = byMine ? board.theirs : board.mine
            guard far[index].infatuatedWith == nil,
                  !["Oblivious", "Aroma Veil"].contains(far[index].build.ability) else {
                board.note("But it failed."); return .handled(nil)
            }
            setFar(cast, index, board: &board) { $0.infatuatedWith = slot }
            board.note("\(farName(cast, index, board: board)) fell in love with \(name).")
            return .handled(nil)
        }

        if move.name == "Torment" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].tormented, far[index].build.ability != "Aroma Veil" else {
                board.note("But it failed."); return .handled(nil)
            }
            setFar(cast, index, board: &board) { $0.tormented = true }
            board.note("\(farName(cast, index, board: board)) cannot use the same move twice in a row.")
            return .handled(nil)
        }

        if move.name == "Mean Look" || move.name == "Block" || move.name == "Spider Web" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].cannotEscape, !far[index].types.contains(.ghost) else {
                board.note("But it failed."); return .handled(nil)
            }
            setFar(cast, index, board: &board) { $0.cannotEscape = true }
            board.note("\(farName(cast, index, board: board)) can no longer escape.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that put something on a side of the field

    private static func layingOnASide(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        if ["Spikes", "Toxic Spikes", "Stealth Rock", "Sticky Web"].contains(move.name) {
            // Hazards go on the *other* side, and stay until something clears
            // them. They are the price of every pivot after this turn.
            var far = byMine ? board.theirScreens : board.myScreens
            let placed: Bool
            switch move.name {
            case "Sticky Web":   placed = !far.stickyWeb; far.stickyWeb = true
            case "Spikes":       placed = far.spikes < 3; far.spikes = Swift.min(3, far.spikes + 1)
            case "Toxic Spikes": placed = far.toxicSpikes < 2; far.toxicSpikes = Swift.min(2, far.toxicSpikes + 1)
            default:             placed = !far.stealthRock; far.stealthRock = true
            }
            guard placed else { board.note("But it failed."); return .handled(nil) }
            if byMine { board.theirScreens = far } else { board.myScreens = far }
            board.note("\(move.name) settled around the other side of the field.")
            return .handled(nil)
        }

        if move.name == "Safeguard" {
            var own = byMine ? board.myScreens : board.theirScreens
            guard own.safeguard == 0 else { board.note("But it failed."); return .handled(nil) }
            own.safeguard = 5
            if byMine { board.myScreens = own } else { board.theirScreens = own }
            board.note("A veil settled over \(byMine ? "your" : "their") side for five turns.")
            return .handled(nil)
        }

        if move.name == "Wish" {
            var own = byMine ? board.myScreens : board.theirScreens
            guard own.wishTurns == 0 else { board.note("But it failed."); return .handled(nil) }
            own.wishAmount = Swift.max(1, team[slot].maxHP / 2)
            own.wishTurns = 2
            if byMine { board.myScreens = own } else { board.theirScreens = own }
            board.note("\(name) made a wish. Help arrives next turn.")
            return .handled(nil)
        }

        if move.name == "Aqua Ring" {
            guard !team[slot].aquaRing else { board.note("But it failed."); return .handled(nil) }
            setNear(cast, board: &board) { $0.aquaRing = true }
            board.note("\(name) surrounded itself with a veil of water.")
            return .handled(nil)
        }

        if move.name == "Magic Room" || move.name == "Wonder Room" {
            let running = move.name == "Magic Room" ? board.magicRoom : board.wonderRoom
            let turns = running > 0 ? 0 : 5
            if move.name == "Magic Room" { board.magicRoom = turns } else { board.wonderRoom = turns }
            board.note(turns > 0
                       ? "\(move.name) twisted the field for five turns."
                       : "\(move.name) ended.")
            return .handled(nil)
        }
        return nil
    }
    // MARK: - The ones that set a clock or a flag the turn reads later

    /// Perish Song, Yawn, Disable, Destiny Bond, Octolock: each marks somebody, and the end of
    /// a turn -- or a knockout -- reads the mark. None of them does its work now.
    private static func settingClocks(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let target = cast.target
        let team = cast.team
        let name = cast.name
        //
        // Every one of these turned up in the replay corpus. They are grouped
        // because they share a shape: each sets a clock or a flag on somebody
        // and the turn loop reads it later, rather than doing its work now.

        // Perish Song takes everybody, both sides, the user included. Three
        // turns later whatever is still standing faints, which is why it is
        // the answer to a Pokémon that cannot otherwise be beaten — and why
        // the side that sang it has to have a plan for its own two.
        if move.name == "Perish Song" {
            // A sound move, so Soundproof is deaf to it. Everything else on
            // the field is caught, including the singer's own side.
            var caught: [String] = []
            for index in 0..<Swift.min(board.activeCount, board.mine.count)
            where !board.mine[index].fainted && board.mine[index].perishIn == 0
                    && !board.mine[index].isSoundproof {
                board.mine[index].perishIn = 3
                caught.append(board.mine[index].build.form.formLabel)
            }
            for index in 0..<Swift.min(board.activeCount, board.theirs.count)
            where !board.theirs[index].fainted && board.theirs[index].perishIn == 0
                    && !board.theirs[index].isSoundproof {
                board.theirs[index].perishIn = 3
                caught.append(board.theirs[index].build.form.formLabel)
            }
            guard !caught.isEmpty else { board.note("But it failed."); return .handled(nil) }
            board.note("All around, the song took hold: \(caught.joined(separator: ", ")) "
                       + "will faint in three turns.")
            return .handled(nil)
        }

        // Yawn does not put anything to sleep. It makes it drowsy, and the
        // sleep arrives at the end of the following turn, which is the point:
        // the other side gets one turn to switch out of it.
        if move.name == "Yawn" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else {
                board.note("But it failed."); return .handled(nil)
            }
            let who = far[index].build.form.formLabel
            guard far[index].status == .none, far[index].drowsyFor == 0 else {
                board.note("But \(who) cannot be made drowsy."); return .handled(nil)
            }
            if byMine { board.theirs[index].drowsyFor = 2 } else { board.mine[index].drowsyFor = 2 }
            board.note("\(who) grew drowsy. It will fall asleep at the end of next turn.")
            return .handled(nil)
        }

        // Disable shuts off whatever the target used last, for four turns. A
        // Pokémon with one attack and three support moves is a different
        // Pokémon once the attack is gone.
        if move.name == "Disable" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted,
                  let last = far[index].lastMove, far[index].moves.indices.contains(last),
                  far[index].disabled == nil else {
                board.note("But it failed."); return .handled(nil)
            }
            let who = far[index].build.form.formLabel
            let what = far[index].moves[last].name
            if byMine { board.theirs[index].disabled = last; board.theirs[index].disabledFor = 4 }
            else { board.mine[index].disabled = last; board.mine[index].disabledFor = 4 }
            board.note("\(who)'s \(what) was disabled for four turns.")
            return .handled(nil)
        }

        // Destiny Bond takes whatever kills it down too. It fails if used
        // twice running, which is what stops it being a free answer to
        // everything: the model already tracks a repeated move for Protect.
        if move.name == "Destiny Bond" {
            guard !team[slot].destinyBound else { board.note("But it failed."); return .handled(nil) }
            setNear(cast, board: &board) { $0.destinyBound = true }
            board.note("\(name) is trying to take its attacker with it.")
            return .handled(nil)
        }

        // Octolock holds the target in place and grinds a stage of each
        // defence off it every turn it stays there.
        if move.name == "Octolock" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted,
                  !far[index].octolocked else {
                board.note("But it failed."); return .handled(nil)
            }
            let who = far[index].build.form.formLabel
            if byMine { board.theirs[index].octolocked = true; board.theirs[index].cannotEscape = true }
            else { board.mine[index].octolocked = true; board.mine[index].cannotEscape = true }
            board.note("\(who) can no longer escape, and its guard is being worn down.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that build the user up

    /// Coil, Belly Drum, Stockpile and Swallow, Substitute, and the two that leave carrying
    /// what was built -- Shed Tail its shell, Baton Pass its stages.
    private static func settingUp(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        // Coil raises Attack, Defense and accuracy. This model keeps no
        // accuracy stage — it is a deliberate omission, not an oversight, and
        // is noted where the omission is made — so two thirds of Coil lands
        // and the third is recorded here rather than pretended.
        if move.name == "Coil" {
            StatChanges.change([.attack: 1, .defense: 1], onMine: byMine, slot: slot, board: &board)
            return .handled(nil)
        }

        // Shed Tail buys a switch with half the bar: the substitute stays
        // behind for whatever comes in, which is the difference between it
        // and an ordinary pivot.
        if move.name == "Shed Tail" {
            let cost = team[slot].maxHP / 2
            let shell = team[slot].maxHP / 4
            let own = byMine ? board.mine : board.theirs
            let somebodyWaiting = (board.activeCount..<own.count).contains { !own[$0].fainted }
            guard team[slot].hp > cost, team[slot].substitute == 0, somebodyWaiting else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.hp -= cost }
            board.note("\(name) gave up half its health to leave a substitute worth \(shell).")
            // The shell belongs to the slot, not to the Pokemon that made it:
            // whoever is chosen to come in stands behind it.
            Switching.leave(byMine: byMine, slot: slot, board: &board,
                            carrying: Board.Carried(substitute: shell))
            return .handled(nil)
        }

        // Substitute: a quarter of the bar becomes a shell that eats damage
        // and status until it breaks.
        if move.name == "Substitute" {
            let cost = team[slot].maxHP / 4
            guard team[slot].hp > cost, team[slot].substitute == 0 else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.hp -= cost; $0.substitute = cost }
            board.note("\(name) put up a substitute worth \(cost).")
            return .handled(nil)
        }

        // Belly Drum spends half the bar to go straight to the top.
        if move.name == "Belly Drum" {
            let cost = team[slot].maxHP / 2
            guard team[slot].hp > cost, team[slot].build.boosts[Stat.attack.rawValue] < 6 else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.hp -= cost; $0.build.boosts[Stat.attack.rawValue] = 6 }
            board.note("\(name) cut its health to maximise its Attack.")
            return .handled(nil)
        }

        // Stockpile holds a charge; Swallow spends the lot for health.
        if move.name == "Stockpile" {
            guard team[slot].stockpile < 3 else { board.note("But it failed."); return .handled(nil) }
            setNear(cast, board: &board) { $0.stockpile += 1
                      $0.build.boosts[Stat.defense.rawValue] = Swift.min(6, $0.build.boosts[Stat.defense.rawValue] + 1)
                      $0.build.boosts[Stat.spDefense.rawValue] = Swift.min(6, $0.build.boosts[Stat.spDefense.rawValue] + 1) }
            board.note("\(name) stockpiled \(team[slot].stockpile + 1).")
            return .handled(nil)
        }

        if move.name == "Swallow" {
            let held = team[slot].stockpile
            guard held > 0 else { board.note("But it failed."); return .handled(nil) }
            let share = held == 1 ? 0.25 : held == 2 ? 0.5 : 1.0
            let gained = Swift.min(team[slot].maxHP - team[slot].hp,
                                   Swift.max(1, Int(Double(team[slot].maxHP) * share)))
            // Clamped, like every other stage change: three stages off a
            // Defense already at the bottom is not a place a stage can be, and
            // the damage step has no multiplier for -9.
            setNear(cast, board: &board) { $0.hp += gained; $0.stockpile = 0
                      $0.build.boosts[Stat.defense.rawValue] =
                          Swift.max(-6, $0.build.boosts[Stat.defense.rawValue] - held)
                      $0.build.boosts[Stat.spDefense.rawValue] =
                          Swift.max(-6, $0.build.boosts[Stat.spDefense.rawValue] - held) }
            board.note("\(name) swallowed \(held) and recovered \(gained) health.")
            return .handled(nil)
        }

        // Baton Pass leaves, but hands everything it built up to whoever comes
        // in. That is the whole move: the stages survive the switch that
        // normally wipes them.
        if move.name == "Baton Pass" {
            let own = byMine ? board.mine : board.theirs
            guard (board.activeCount..<own.count).contains(where: { !own[$0].fainted }) else {
                board.note("But it failed."); return .handled(nil)
            }
            board.note("\(name) passed the baton.")
            Switching.leave(byMine: byMine, slot: slot, board: &board,
                            carrying: Board.Carried(boosts: own[slot].build.boosts,
                                                    substitute: own[slot].substitute,
                                                    aquaRing: own[slot].aquaRing))
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that change who acts, or when

    /// Instruct makes the partner go again; Roar and Whirlwind drag the target out for
    /// something else; After You and Quash move the target to the front or the back.
    private static func movingTheQueue(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let rolling = cast.rolling
        let name = cast.name
        // Instruct makes the partner take its last move again, which is how a
        // Trick Room team gets two Earthquakes out of one Pokémon. It is a
        // second use of a move that has already happened, so it runs through
        // the ordinary move path rather than being special-cased: whatever the
        // move does, it does again.
        if move.name == "Instruct" {
            let ally = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(ally), !own[ally].fainted,
                  let last = own[ally].lastMove, own[ally].moves.indices.contains(last)
            else { board.note("But there was nothing to instruct."); return .handled(nil) }
            let again = own[ally].moves[last]
            // What cannot be instructed. A charging move is mid-wind-up and
            // repeating it would finish it twice; Instruct itself would send
            // the two of them back and forth for the rest of the game.
            guard own[ally].charging == nil, again.name != "Instruct" else {
                board.note("But \(own[ally].build.form.formLabel) could not be instructed.")
                return .handled(nil)
            }
            board.note("\(name) had \(own[ally].build.form.formLabel) use \(again.name) again.")
            return .handled(.replay(.attack(move: last, target: own[ally].lastTarget), byMine: byMine, slot: ally))
        }

        // Roar and Whirlwind drag the target out and something else in, which
        // is how a setup sweeper gets undone: every stage it earned goes with
        // it. They move last on purpose — their priority is -6 — so what they
        // undo is whatever just happened.
        if move.name == "Roar" || move.name == "Whirlwind" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = byMine ? board.theirs : board.mine
            guard !far[index].build.ability.isEmpty || true else { return .handled(nil) }
            if far[index].build.ability == "Suction Cups" {
                board.note("\(farName(cast, index, board: board))'s Suction Cups held it in place.")
                return .handled(nil)
            }
            // The search cannot roll, so it drags in the first one standing.
            // A played turn picks at random, which is what the move does.
            let bench = (board.activeCount..<far.count).filter { !far[$0].fainted }
            guard let coming = rolling ? bench.randomElement() : bench.first else {
                board.note("But there was no one to drag in.")
                return .handled(nil)
            }
            let arriving = far[coming].build.form.formLabel
            board.note("\(farName(cast, index, board: board)) was dragged out, and \(arriving) took its place.")
            if let said = Switching.swapIn(mine: !byMine, active: index, bench: coming, board: &board) {
                board.note(said)
            }
            return .handled(nil)
        }

        // After You hands the target the next action. The turn order was fixed
        // before anything moved, so this marks the target and the order is
        // rebuilt around the mark.
        if move.name == "After You" || move.name == "Quash" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            if move.name == "After You" {
                setFar(cast, index, board: &board) { $0.goesNext = true }
                board.note("\(farName(cast, index, board: board)) will move next.")
            } else {
                setFar(cast, index, board: &board) { $0.goesLast = true }
                board.note("\(farName(cast, index, board: board)) was sent to the back of the queue.")
            }
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that sweep the field

    /// Haze takes every stage on both sides; Defog and Court Change take what is lying on
    /// the floor and hanging in the air.
    private static func sweeping(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        // Haze wipes every stat change on both sides, which is the answer to
        // anything that has spent the game setting up.
        if move.name == "Haze" {
            for index in board.mine.indices { board.mine[index].build.boosts = Array(repeating: 0, count: Stage.width) }
            for index in board.theirs.indices { board.theirs[index].build.boosts = Array(repeating: 0, count: Stage.width) }
            board.note("A haze settled and every stat change went with it.")
            return .handled(nil)
        }

        // Defog and Rapid Spin both clear the floor, and the difference
        // between them is the whole reason a team picks one.
        //
        // Defog takes the target's screens and hazards, the user's own hazards
        // but not its screens, and the terrain. Rapid Spin takes only the
        // user's own hazards, and hits something besides.
        //
        // Serebii's Champions text for Defog says "on the target Pokémon's
        // side of battle" and stops there, which reads like a deliberate
        // restriction until you notice the same sentence never mentions Sticky
        // Web — a move that is legal here, and that Rapid Spin's own
        // description does name. The list is incomplete rather than narrow.
        if move.name == "Defog" {
            board.sweepHazards(mine: byMine)
            var far = byMine ? board.theirScreens : board.myScreens
            far.reflect = 0; far.lightScreen = 0; far.auroraVeil = 0
            far.safeguard = 0
            far.spikes = 0; far.toxicSpikes = 0
            far.stealthRock = false; far.stickyWeb = false
            if byMine { board.theirScreens = far } else { board.myScreens = far }
            let hadTerrain = board.field.terrain != .none
            board.field.terrain = .none
            board.terrainTurns = 0
            board.note(hadTerrain ? "The field and the terrain were swept away."
                                  : "The field was swept clear.")
            return .handled(nil)
        }

        // Court Change hands the other side everything on yours and takes
        // everything on theirs, hazards included.
        if move.name == "Court Change" {
            swap(&board.myScreens, &board.theirScreens)
            board.note("The two sides of the field traded places.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that rewrite what a Pokemon is

    /// Its ability, its types, a stat, or its stages turned upside down.
    private static func rewriting(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        // Topsy-Turvy turns the target's stat changes upside down, which is
        // the cheapest answer to a Belly Drum there is.
        if move.name == "Topsy-Turvy" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            guard far[index].build.boosts.contains(where: { $0 != 0 }) else {
                board.note("But it failed."); return .handled(nil)
            }
            setFar(cast, index, board: &board) { $0.build.boosts = $0.build.boosts.map { -$0 } }
            board.note("\(farName(cast, index, board: board))'s stat changes were turned upside down.")
            return .handled(nil)
        }

        // Entrainment hands the target the user's ability; Role Play takes the
        // target's; Simple Beam makes it Simple; Gastro Acid takes it away.
        if ["Entrainment", "Role Play", "Simple Beam", "Gastro Acid"].contains(move.name) {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            switch move.name {
            case "Entrainment":
                setFar(cast, index, board: &board) { $0.build.ability = team[slot].build.ability }
                board.note("\(farName(cast, index, board: board)) took on \(name)'s \(team[slot].build.ability).")
            case "Role Play":
                let taken = far[index].build.ability
                setNear(cast, board: &board) { $0.build.ability = taken }
                board.note("\(name) copied \(farName(cast, index, board: board))'s \(taken).")
            case "Simple Beam":
                setFar(cast, index, board: &board) { $0.build.ability = "Simple" }
                board.note("\(farName(cast, index, board: board))'s ability became Simple.")
            default:
                setFar(cast, index, board: &board) { $0.build.ability = "" }
                board.note("\(farName(cast, index, board: board))'s ability was suppressed.")
            }
            return .handled(nil)
        }

        // Reflect Type and Magic Powder rewrite a typing.
        if move.name == "Reflect Type" || move.name == "Magic Powder" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            if move.name == "Magic Powder" {
                setFar(cast, index, board: &board) { $0.build.typeOverride = [.psychic] }
                board.note("\(farName(cast, index, board: board)) became a Psychic type.")
            } else {
                let far = cast.targetsMine ? board.mine : board.theirs
                let copied = far[index].types
                setNear(cast, board: &board) { $0.build.typeOverride = copied }
                board.note("\(name) took on \(farName(cast, index, board: board))'s typing.")
            }
            return .handled(nil)
        }

        // Speed Swap and Power Trick move a stat rather than a stage.
        if move.name == "Speed Swap" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let far = cast.targetsMine ? board.mine : board.theirs
            let ours = team[slot].build.stat(.speed), theirs = far[index].build.stat(.speed)
            setNear(cast, board: &board) { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.speed.rawValue: theirs]) { _, new in new } }
            setFar(cast, index, board: &board) { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.speed.rawValue: ours]) { _, new in new } }
            board.note("\(name) and \(farName(cast, index, board: board)) swapped Speed.")
            return .handled(nil)
        }

        if move.name == "Power Trick" {
            let attack = team[slot].build.stat(.attack)
            let defense = team[slot].build.stat(.defense)
            setNear(cast, board: &board) { $0.build.statOverride = ($0.build.statOverride ?? [:])
                .merging([Stat.attack.rawValue: defense,
                          Stat.defense.rawValue: attack]) { _, new in new } }
            board.note("\(name) swapped its Attack and Defense.")
            return .handled(nil)
        }

        // Forest's Curse and Trick-or-Treat add a type rather than replace one.
        if move.name == "Forest's Curse" || move.name == "Trick-or-Treat" {
            guard let index = reachableTarget(cast, board: &board) else { board.note("But it failed."); return .handled(nil) }
            let added: PokeType = move.name == "Forest's Curse" ? .grass : .ghost
            let far = cast.targetsMine ? board.mine : board.theirs
            guard !far[index].types.contains(added) else { board.note("But it failed."); return .handled(nil) }
            let now = far[index].types + [added]
            setFar(cast, index, board: &board) { $0.build.typeOverride = now }
            board.note("\(farName(cast, index, board: board)) became part \(added.rawValue).")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that touch held items

    /// Taking them away, eating them, bringing them back.
    private static func items(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        // Corrosive Gas takes everybody's item; Teatime makes everybody eat.
        if move.name == "Corrosive Gas" {
            var taken: [String] = []
            for index in board.mine.indices.prefix(board.activeCount)
            where !board.mine[index].fainted && !board.mine[index].build.item.isEmpty {
                taken.append(board.mine[index].build.form.formLabel)
                board.mine[index].build.item = ""
            }
            for index in board.theirs.indices.prefix(board.activeCount)
            where !board.theirs[index].fainted && !board.theirs[index].build.item.isEmpty {
                taken.append(board.theirs[index].build.form.formLabel)
                board.theirs[index].build.item = ""
            }
            board.note(taken.isEmpty ? "But nobody was holding anything."
                                     : "The gas took \(taken.joined(separator: ", "))'s items.")
            return .handled(nil)
        }

        // Recycle brings back what it ate; Stuff Cheeks eats it now and takes
        // two stages of Defense for it; Teatime makes everybody eat at once.
        if move.name == "Recycle" {
            guard team[slot].build.itemSpent, !team[slot].build.item.isEmpty else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.build.itemSpent = false }
            board.note("\(name) found its \(team[slot].build.item) again.")
            return .handled(nil)
        }

        if move.name == "Stuff Cheeks" {
            guard team[slot].build.item.hasSuffix("Berry"), !team[slot].build.itemSpent else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.build.itemSpent = true
                      $0.hp = Swift.min($0.maxHP, $0.hp + $0.maxHP / 4) }
            StatChanges.applySelf([.defense: 2], toMine: byMine, slot: slot, board: &board)
            board.note("\(name) stuffed its cheeks with its \(team[slot].build.item).")
            return .handled(nil)
        }

        if move.name == "Teatime" {
            var ate: [String] = []
            for side in [true, false] {
                let count = Swift.min(board.activeCount, (side ? board.mine : board.theirs).count)
                for index in 0..<count {
                    let who = side ? board.mine[index] : board.theirs[index]
                    guard !who.fainted, who.build.item.hasSuffix("Berry"),
                          !who.build.itemSpent else { continue }
                    if side {
                        board.mine[index].build.itemSpent = true
                        board.mine[index].hp = Swift.min(who.maxHP, who.hp + who.maxHP / 4)
                    } else {
                        board.theirs[index].build.itemSpent = true
                        board.theirs[index].hp = Swift.min(who.maxHP, who.hp + who.maxHP / 4)
                    }
                    ate.append(who.build.form.formLabel)
                }
            }
            board.note(ate.isEmpty ? "But nobody had a berry."
                                   : "Teatime: \(ate.joined(separator: ", ")) ate up.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that pay the user's own side

    /// The partner, the whole side, or the user itself, in stages or in health.
    private static func payingTheSide(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let rolling = cast.rolling
        let team = cast.team
        // Decorate and Aromatic Mist pay the partner.
        if move.name == "Decorate" || move.name == "Aromatic Mist" {
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to help."); return .handled(nil)
            }
            let paid: [Stage: Int] = move.name == "Decorate" ? [.attack: 2, .spAttack: 2]
                                                              : [.spDefense: 1]
            StatChanges.applySelf(paid, toMine: byMine, slot: partner, board: &board)
            return .handled(nil)
        }

        // Clangorous Soul spends a third of the bar to raise everything.
        if move.name == "Clangorous Soul" {
            let cost = team[slot].maxHP / 3
            guard team[slot].hp > cost else { board.note("But it failed."); return .handled(nil) }
            setNear(cast, board: &board) { $0.hp -= cost }
            StatChanges.applySelf([.attack: 1, .defense: 1, .spAttack: 1, .spDefense: 1, .speed: 1],
                      toMine: byMine, slot: slot, board: &board)
            return .handled(nil)
        }

        // Acupressure raises one stat, chosen at random, by two.
        if move.name == "Acupressure" {
            let stats: [Stage] = [.attack, .defense, .spAttack, .spDefense, .speed,
                                  .accuracy, .evasion]
            let picked = rolling ? (stats.randomElement(using: &Dice.source) ?? .attack) : .attack
            StatChanges.applySelf([picked: 2], toMine: byMine, slot: slot, board: &board)
            return .handled(nil)
        }

        // Heal Bell clears the whole side, bench included.
        if move.name == "Heal Bell" || move.name == "Aromatherapy" {
            var cured = 0
            for index in (byMine ? board.mine : board.theirs).indices {
                let carrying = (byMine ? board.mine : board.theirs)[index].status != .none
                guard carrying else { continue }
                if byMine { board.mine[index].status = .none; board.mine[index].asleepFor = 0 }
                else { board.theirs[index].status = .none; board.theirs[index].asleepFor = 0 }
                cured += 1
            }
            board.note(cured == 0 ? "But nobody was ill."
                                  : "A bell rang and cleared \(cured) of them up.")
            return .handled(nil)
        }

        // Magnetic Flux pays whichever of its side is carrying Plus or Minus.
        if move.name == "Magnetic Flux" {
            let pairing: Set<String> = ["Plus", "Minus"]
            var paid = 0
            for index in (byMine ? board.mine : board.theirs).indices.prefix(board.activeCount) {
                let who = (byMine ? board.mine : board.theirs)[index]
                guard !who.fainted, pairing.contains(who.build.ability) else { continue }
                StatChanges.applySelf([.defense: 1, .spDefense: 1], toMine: byMine, slot: index, board: &board)
                paid += 1
            }
            if paid == 0 { board.note("But nobody was carrying Plus or Minus.") }
            return .handled(nil)
        }

        // Howl boosts the whole side, not just the user. Matched on the
        // sentence rather than the name, and deliberately narrow: Coaching and
        // Gear Up read as "the user's allies" without the user, and are
        // already handled as ally-targeted moves further down.
        if move.effect.contains("of the user and its allies"), !move.selfBoosts.isEmpty {
            let boosts = move.selfBoosts
            let partner = slot == 0 ? 1 : 0
            StatChanges.applySelf(boosts, toMine: byMine, slot: slot, board: &board)
            let own = byMine ? board.mine : board.theirs
            if board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted {
                StatChanges.applySelf(boosts, toMine: byMine, slot: partner, board: &board)
            }
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that hold something in place

    /// Ingrain roots the user; Fairy Lock holds everybody.
    private static func trapping(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let slot = cast.slot
        let team = cast.team
        let name = cast.name
        // Ingrain roots it: health back every turn, and it cannot leave.
        if move.name == "Ingrain" {
            guard !team[slot].aquaRing || !team[slot].cannotEscape else {
                board.note("But it failed."); return .handled(nil)
            }
            setNear(cast, board: &board) { $0.aquaRing = true; $0.cannotEscape = true }
            board.note("\(name) planted its roots.")
            return .handled(nil)
        }

        // Fairy Lock holds everybody in place.
        if move.name == "Fairy Lock" {
            for index in board.mine.indices.prefix(board.activeCount) {
                board.mine[index].cannotEscape = true
            }
            for index in board.theirs.indices.prefix(board.activeCount) {
                board.theirs[index].cannotEscape = true
            }
            board.note("Nobody can leave the field.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that move somebody on or off the field

    /// Chilly Reception leaves behind a snowfall, Ally Switch trades places, Revival
    /// Blessing brings one back from the bench at half.
    private static func benchAndPosition(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let target = cast.target
        let rolling = cast.rolling
        let team = cast.team
        let name = cast.name
        // Chilly Reception puts snow up and leaves, which is the joke and also
        // a very good pivot.
        if move.name == "Chilly Reception" {
            let before = board.field
            board.field.weather = .snow
            board.weatherTurns = 5
            board.fieldSettled(from: before)
            board.note("\(name) told a terrible joke, and it began to snow.")
            Switching.leave(byMine: byMine, slot: slot, board: &board)
            return .handled(nil)
        }

        // Ally Switch: the two of yours trade places, which is how a Pokémon
        // steps out of the way of something aimed at where it was standing.
        // Like Protect, doing it again is a third as likely to work.
        if move.name == "Ally Switch" {
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to switch with.")
                return .handled(nil)
            }
            let chance = pow(1.0 / 3.0, Double(own[slot].switchStreak))
            guard rolling ? Double.random(in: 0..<1, using: &Dice.source) < chance : chance >= 0.5 else {
                if byMine { board.mine[slot].switchStreak = 0 } else { board.theirs[slot].switchStreak = 0 }
                board.note("But it failed — \(Int((chance * 100).rounded()))% after using it last turn.")
                return .handled(nil)
            }
            if byMine {
                board.mine.swapAt(slot, partner)
                board.mine[partner].switchStreak += 1
            } else {
                board.theirs.swapAt(slot, partner)
                board.theirs[partner].switchStreak += 1
            }
            board.note("\(name) and \(own[partner].build.form.formLabel) traded places.")
            return .handled(nil)
        }

        // Revival Blessing: the target is one of the user's own fallen, not
        // anything across the field. It comes back to the bench at half.
        if move.aim == .party {
            let bench = (board.activeCount..<team.count)
            let chosen = bench.contains(target) && team[target].fainted
                ? target : bench.first { team[$0].fainted }
            guard let chosen else {
                board.note("But nobody on \(byMine ? "your" : "their") side had fainted.")
                return .handled(nil)
            }
            let half = Swift.max(1, team[chosen].maxHP / 2)
            if byMine {
                board.mine[chosen].hp = half; board.mine[chosen].status = .none
            } else {
                board.theirs[chosen].hp = half; board.theirs[chosen].status = .none
            }
            board.note("\(team[chosen].build.form.formLabel) was revived to half its health.")
            return .handled(nil)
        }
        return nil
    }

    // MARK: - The ones that take over what the target does next

    /// Encore holds it to its last move; Confuse Ray, Swagger and Flatter make a third of
    /// its actions its own problem.
    private static func hijackingActions(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let target = cast.target
        let rolling = cast.rolling
        // Encore: the target repeats whatever it last used for its next three
        // turns. It fails on a Pokémon that has not moved yet, and cannot hold
        // one to an Encore of its own.
        if move.name == "Encore" {
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return .handled(nil) }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return .handled(nil) }
            guard let last = far[index].lastMove, far[index].moves.indices.contains(last),
                  far[index].moves[last].name != "Encore" else {
                board.note("But \(who) had nothing to repeat.")
                return .handled(nil)
            }
            if byMine { board.theirs[index].encoredFor = 3 } else { board.mine[index].encoredFor = 3 }
            board.note("\(who) received an Encore: it has to keep using \(far[index].moves[last].name).")
            return .handled(nil)
        }

        // Confuse Ray, Swagger, Flatter: aimed across the field, and the raise
        // Swagger hands over comes with the confusion that makes it a trap.
        if move.confuses {
            let far = byMine ? board.theirs : board.mine
            let everyone = move.effect.lowercased().contains("confuses all other")
            let hits = everyone
                ? Array(0..<Swift.min(board.activeCount, far.count))
                : [far.indices.contains(target) && target < board.activeCount ? target
                   : (0..<Swift.min(board.activeCount, far.count)).first { !far[$0].fainted } ?? 0]
            for index in hits where far.indices.contains(index) && !far[index].fainted {
                if far[index].isProtected {
                    board.note("\(far[index].build.form.formLabel) protected itself.")
                    continue
                }
                StatChanges.applySelf(move.targetBoosts, toMine: !byMine, slot: index, board: &board)
                Ailments.confuse(onMine: !byMine, slot: index, board: &board, rolling: rolling, chance: 100)
            }
            return .handled(nil)
        }
        return nil
    }


    // MARK: - Protect and its family

    private static func protecting(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let target = cast.target
        let rolling = cast.rolling
        let team = cast.team
        let name = cast.name

        // Protect and its family arrive here whenever the move was picked as a
        // move rather than through the dedicated choice, which is how the
        // interface offers it and how the search sometimes picks it.
        if Move.protectMoves.contains(move.name) {
            Protection.tryProtect(nil, byMine: byMine, slot: slot, board: &board, rolling: rolling)
            return .handled(nil)
        }

        switch move.name {
        case "Tailwind":
            if byMine { board.myTailwind = 4 } else { board.theirTailwind = 4 }
            board.note("The wind picked up behind \(byMine ? "you" : "them").")
            return .handled(nil)
        case "Trick Room":
            board.trickRoom = board.trickRoom > 0 ? 0 : 5
            board.note(board.trickRoom > 0
                               ? "The dimensions twisted." : "The twisted dimensions returned.")
            return .handled(nil)
        case "Follow Me", "Rage Powder":
            if byMine { board.mine[slot].drawingFire = true }
            else { board.theirs[slot].drawingFire = true }
            board.note("\(name) drew attention to itself.")
            return .handled(nil)
        case "Wide Guard":
            if byMine { board.myScreens.wideGuard = true }
            else { board.theirScreens.wideGuard = true }
            board.note("A wide barrier went up.")
            return .handled(nil)
        case "Quick Guard":
            if byMine { board.myScreens.quickGuard = true }
            else { board.theirScreens.quickGuard = true }
            board.note("A quick barrier went up.")
            return .handled(nil)
        case "Coaching":
            // The partner's Attack and Defence, which is what makes it a
            // doubles move rather than a wasted turn.
            let partner = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                board.note("But there was no one to coach.")
                return .handled(nil)
            }
            StatChanges.applySelf([.attack: 1, .defense: 1], toMine: byMine, slot: partner, board: &board)
            return .handled(nil)
        case "Focus Energy", "Dragon Cheer":
            // Focus Energy is the user's own; Dragon Cheer is the partner's,
            // and worth twice as much to a Dragon.
            if move.name == "Focus Energy" {
                if byMine { board.mine[slot].critStage += 2 } else { board.theirs[slot].critStage += 2 }
                board.note("\(name) is getting fired up.")
            } else {
                let partner = slot == 0 ? 1 : 0
                let own = byMine ? board.mine : board.theirs
                guard board.activeCount > 1, own.indices.contains(partner), !own[partner].fainted else {
                    board.note("But there was no one to cheer for.")
                    return .handled(nil)
                }
                let dragon = own[partner].build.form.pokeTypes.contains(.dragon) ? 2 : 1
                if byMine { board.mine[partner].critStage += dragon }
                else { board.theirs[partner].critStage += dragon }
                board.note("\(own[partner].build.form.formLabel) was cheered on.")
            }
            return .handled(nil)
        case "Endure":
            if byMine { board.mine[slot].enduring = true } else { board.theirs[slot].enduring = true }
            board.note("\(name) braced to survive whatever comes.")
            return .handled(nil)
        case "Leech Seed":
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return .handled(nil) }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return .handled(nil) }
            if far[index].build.form.pokeTypes.contains(.grass) {
                board.note("\(who) is a Grass type; the seed found nowhere to take hold.")
                return .handled(nil)
            }
            if far[index].seededFrom != nil { board.note("\(who) is already seeded."); return .handled(nil) }
            if byMine { board.theirs[index].seededFrom = slot } else { board.mine[index].seededFrom = slot }
            board.note("\(who) was seeded.")
            return .handled(nil)
        case "Imprison":
            // Everything this one knows is sealed off across the field for as
            // long as it stands there -- not the moves it uses, the moves it
            // has. It fails outright when the other side knows none of them,
            // which is what stops it being a free turn against a team it
            // shares nothing with. Where it bites is the mirror: two Trick
            // Rooms, two Protects, two Fake Outs, and only one side may click.
            guard MoveLegality.imprisonWouldHold(byMine: byMine, slot: slot, board: board) else {
                board.note("But it failed.")
                return .handled(nil)
            }
            if byMine { board.mine[slot].imprisoning = true }
            else { board.theirs[slot].imprisoning = true }
            board.note("\(name) sealed away its opponents' moves.")
            return .handled(nil)
        case "Taunt":
            let far = byMine ? board.theirs : board.mine
            let index = far.indices.contains(target) && target < board.activeCount ? target : 0
            guard far.indices.contains(index), !far[index].fainted else { return .handled(nil) }
            let who = far[index].build.form.formLabel
            if far[index].isProtected { board.note("\(who) protected itself."); return .handled(nil) }
            if far[index].build.ability == "Oblivious" || far[index].build.ability == "Aroma Veil" {
                board.note("\(who)'s \(far[index].build.ability) ignored it.")
                return .handled(nil)
            }
            if byMine { board.theirs[index].tauntedFor = 3 } else { board.mine[index].tauntedFor = 3 }
            board.note("\(who) was taunted: nothing but attacks for three turns.")
            return .handled(nil)
        case "Reflect", "Light Screen", "Aurora Veil":
            // A Light Clay lengthens all three, not just Reflect. It was only
            // being read for Reflect, so a Light Clay Light Screen — which is
            // most of them — quietly ran the standard five turns.
            let turns = team[slot].build.item == "Light Clay" ? 8 : 5
            if byMine {
                switch move.name {
                case "Reflect":      board.myScreens.reflect = turns
                case "Light Screen": board.myScreens.lightScreen = turns
                default:             board.myScreens.auroraVeil = turns
                }
            } else {
                switch move.name {
                case "Reflect":      board.theirScreens.reflect = turns
                case "Light Screen": board.theirScreens.lightScreen = turns
                default:             board.theirScreens.auroraVeil = turns
                }
            }
            board.note("\(move.name) went up for \(turns) turns.")
            return .handled(nil)
        case "Helping Hand":
            // Half again on the partner's move this turn, and nothing after it.
            //
            // This used to raise the partner's Attack and Special Attack by a
            // stage instead, on the reasoning that the partner may already have
            // moved and a stat change is at least visible. That was wrong twice
            // over: a stage is 50% of the *stat* rather than of the move's
            // power, so it compounds differently with screens and items, and a
            // stage does not go away at the end of the turn. A Helping Hand
            // that leaves its partner permanently stronger is a different move.
            let ally = slot == 0 ? 1 : 0
            let own = byMine ? board.mine : board.theirs
            guard board.activeCount > 1, own.indices.contains(ally), !own[ally].fainted else {
                board.note("But there was no one to help.")
                return .handled(nil)
            }
            if byMine { board.mine[ally].helped = true } else { board.theirs[ally].helped = true }
            board.note("\(name) lent \(own[ally].build.form.formLabel) a hand.")
            return .handled(nil)
        default:
            break
        }
        return nil
    }

    // MARK: - Weather and terrain

    private static func weatherAndTerrain(_ cast: Cast, board: inout Board) -> Outcome? {
        let move = cast.move
        let byMine = cast.byMine
        let slot = cast.slot
        let target = cast.target
        let rolling = cast.rolling

        // Weather and terrain, which any of several moves set.
        if let weather = FieldSetters.weather(setBy: move.name) {
            let before = board.field
            board.field.weather = weather
            board.fieldSettled(from: before)
            // Setting what is already up does not restart the clock; in the
            // game the move simply fails.
            if before.weather == weather { board.note("But the \(weather.rawValue.lowercased()) was already up.") }
            else { board.note("The weather turned to \(weather.rawValue.lowercased()) for five turns.") }
            return .handled(nil)
        }
        if let terrain = FieldSetters.terrain(setBy: move.name) {
            let before = board.field
            board.field.terrain = terrain
            board.fieldSettled(from: before)
            board.terrainSeeds()
            if before.terrain == terrain { board.note("But the terrain was already \(terrain.rawValue.lowercased()).") }
            else { board.note("\(terrain.rawValue) Terrain covered the field for five turns.") }
            return .handled(nil)
        }

        // Anything that says it lowers a stat, or raises one of the user's.
        //
        // Aimed wherever it was aimed, which is not always across the field.
        // Lowering your own partner's Attack is a real thing people do: a
        // Charm on a Contrary Staraptor is two stages *up*, and the whole
        // reason the tech exists. This read `byMine ? theirs : mine` and sent
        // the drop at slot 100 of the wrong side, where there is nobody, so
        // the move did nothing at all and said nothing about it.
        let drops = move.targetDrops
        if !drops.isEmpty {
            let atMine = cast.targetsMine
            let defending = atMine ? board.mine : board.theirs
            for index in (move.isSpread ? [0, 1] : [cast.targetSlot]) {
                guard defending.indices.contains(index), index < board.activeCount,
                      !defending[index].fainted, !defending[index].isProtected else { continue }
                StatChanges.applyDrops(drops, toMine: atMine, slot: index, board: &board,
                                       fromOpponent: !cast.atAlly)
            }
            return .handled(nil)
        }
        if !move.selfBoosts.isEmpty {
            StatChanges.applySelf(move.selfBoosts, toMine: byMine, slot: slot, board: &board)
            return .handled(nil)
        }

        // And the conditions, which are worth a move slot precisely because
        // they last.
        let ailment: Ailment? = move.effect.hasPrefix("Burns the target") ? .burn
            : move.effect.hasPrefix("Paralyzes the target") ? .paralysis
            : move.effect.hasPrefix("Puts the target to sleep") ? .sleep
            : move.effect.hasPrefix("Poisons the target") ? .poison
            : move.effect.hasPrefix("Badly poisons the target") ? .badPoison : nil
        if let ailment {
            let defending = byMine ? board.theirs : board.mine
            guard defending.indices.contains(target), !defending[target].fainted,
                  !defending[target].isProtected,
                  defending[target].status == .none else {
                board.note("It had no effect.")
                return .handled(nil)
            }
            // One door for every status condition, whatever caused it. This
            // used to carry its own copy of the immunity table -- without the
            // Misty Terrain check, so a Will-O-Wisp went through the terrain
            // that exists to stop it.
            Ailments.inflict(ailment, onMine: !byMine, slot: target, byMine: byMine, bySlot: slot,
                             board: &board, rolling: rolling)
            return .handled(nil)
        }
        return nil
    }

}
