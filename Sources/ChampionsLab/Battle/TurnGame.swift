//  TurnGame.swift
//  Solving the turn, and saying what the answer means.
//
//  TurnModel plays a turn out. This builds every plausible turn, scores them
//  all, and solves the resulting matrix for its equilibrium.
//
//  The solver is regret matching, which is about forty lines and converges to
//  Nash on a two-player zero-sum game. That is the right guarantee here,
//  because the board score is mine-minus-theirs by construction: what I gain
//  you lose, so an equilibrium exists and is the strategy that cannot be
//  exploited however well you read me.
//
//  What matters is what falls out of it. An equilibrium mix is only the
//  headline; the useful part is the shape of each line:
//
//      · its worst case, which is what happens when they read you
//      · its best case, which is what you are playing for
//      · the gap between them, which is what "greedy" actually means
//
//  A line with a narrow gap is safe: it does roughly the same thing whatever
//  they do, and you can click it without thinking. A line with a wide gap is a
//  read, and the equilibrium says how often it is worth taking. That is the
//  decision a player is actually making on a turn, and no part of this app
//  could describe it before.

import Foundation

struct TurnGame {
    let board: Board
    /// How many choices each Pokémon is allowed to consider. Every one squares
    /// the size of the matrix, so this is the knob that decides whether a turn
    /// takes ten milliseconds or ten seconds.
    var width = 6
    /// Offer Mega Evolution as a fact rather than a choice: the stone-holder
    /// evolves the moment it attacks. The turn being played keeps both versions
    /// on the table, since holding the stone back so your weather lands second
    /// is a real play; but inside a search every node past the first was
    /// doubling both sides' lists to weigh a decision that is nearly always
    /// "yes", and that doubling is what kept the search from seeing past one
    /// turn.
    var assumeMega = false
    /// The board as the other side sees it: your unseen back two replaced by
    /// the pair they expect. Set it and their half of the matrix is solved on
    /// it, so their orders answer what they believe rather than what is
    /// actually on your bench. Nil on an analysis board, where both sixes are
    /// on the table anyway.
    var theirBelief: Board?

    /// `believingTheirs` turns the two-board solve on: their half is answered
    /// on what they can see. It costs a second matrix, so it is set where the
    /// answer becomes somebody's orders — the root of a search, the turn being
    /// played, the line on screen — and left off inside the recursion, where
    /// the difference is second order and the cost is a doubling.
    init(board: Board, believingTheirs: Bool = false) {
        self.board = board
        self.theirBelief = believingTheirs ? board.asTheySeeIt : nil
    }

    // MARK: - What each side can plausibly do

    /// The choices worth considering for one active Pokémon.
    ///
    /// Not every legal option: a Pokémon with four attacks and two targets has
    /// eight attacking choices and six of them are strictly worse versions of
    /// the other two. What survives is the best attack at each opponent, a
    /// spread move when it has one, Protect, and the one switch worth making.
    func choices(forMine mine: Bool, slot: Int) -> [Choice] {
        let team = mine ? board.mine : board.theirs
        let foes = mine ? board.theirs : board.mine
        guard slot < board.activeCount,
              team.indices.contains(slot), !team[slot].fainted else { return [] }
        let fighter = team[slot]
        // Halfway through a two-turn move, or under an Encore, there is
        // nothing to decide.
        if let charging = fighter.charging {
            return [.attack(move: charging, target: fighter.chargingTarget)]
        }
        if let encored = fighter.encored { return [encored] }
        // Nothing with priority gets past an Armor Tail, so there is no point
        // the search spending one of its few choices on it.
        // Nothing quick gets past an Armor Tail, and nothing quick reaches
        // anything standing on a Psychic Terrain, so there is no point the
        // search spending one of its few choices on a priority move.
        let priorityRefused = (0..<Swift.min(board.activeCount, foes.count)).contains {
            guard !foes[$0].fainted else { return false }
            return TurnModel.priorityBlockers.contains(foes[$0].build.ability)
                || (board.field.terrain == .psychic && foes[$0].build.grounded)
        }
        func allowed(_ move: Move) -> Bool {
            if move.drawbacks.firstTurnOnly, !fighter.justArrived { return false }
            if priorityRefused, move.priority > 0,
               move.aim == .foe || move.aim == .spread { return false }
            return true
        }

        // Kept apart by kind rather than in one list, because the list has to
        // be trimmed and trimming it in append order threw away Protect and
        // switching every time — which made a read about protecting produce the
        // same answer as a read about anything else, since neither was ever on
        // the table.
        var attacks: [Choice] = []
        var spread: [Choice] = []
        var guarding: [Choice] = []
        var setup: [Choice] = []
        var leaving: [Choice] = []
        // The hardest single hit at each opponent still standing.
        for target in 0..<min(2, foes.count) where !foes[target].fainted {
            var best: (index: Int, damage: Int)?
            for (index, move) in fighter.moves.enumerated()
            where move.isDamaging && !move.isSpread && allowed(move) {
                let result = DamageCalc.calculate(attacker: fighter.build,
                                                  defender: foes[target].build,
                                                  move: move, field: board.field)
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                let worth = Int(Double(result.maxDamage) * accuracy)
                if best == nil || worth > best!.damage { best = (index, worth) }
            }
            if let best { attacks.append(.attack(move: best.index, target: target)) }
        }
        // A spread move is a different decision, not a better version of one —
        // and it is the move that covers a switch, since whatever comes in is
        // standing in it.
        if let index = fighter.moves.firstIndex(where: {
            $0.isDamaging && $0.isSpread && allowed($0) }) {
            spread.append(.attack(move: index, target: 0))
        }
        // Protect, unless it was used last turn, when it mostly fails.
        // A second Protect in a row is a third as likely to hold, and worth
        // considering at a third: the Sucker Punch it might still blank is
        // real. A third in a row, at a ninth, is not worth a slot.
        if fighter.protectChance >= 0.3,
           let guard_ = fighter.moves.firstIndex(where: {
               Move.protectMoves.contains($0.name) }) {
            guarding.append(.protectSelf(move: guard_))
        }
        // Speed control, which is the whole turn on the teams that run it.
        if let control = fighter.moves.firstIndex(where: {
            ["Tailwind", "Trick Room"].contains($0.name) }) {
            let already = mine ? board.myTailwind : board.theirTailwind
            if already == 0 { setup.append(.attack(move: control, target: 0)) }
        }
        // Revival Blessing, once there is somebody to bring back. Each fallen
        // teammate is its own choice, since which one matters.
        for (index, move) in fighter.moves.enumerated() where move.aim == .party {
            for bench in 2..<team.count where team[bench].fainted {
                setup.append(.attack(move: index, target: bench))
            }
        }
        // Fake Out, which only exists on the turn it comes in.
        if fighter.justArrived, !priorityRefused,
           let fake = fighter.moves.firstIndex(where: { $0.name == "Fake Out" }),
           !attacks.contains(where: { if case .attack(let m, _) = $0 { return m == fake }
                                      return false }) {
            setup.append(.attack(move: fake, target: 0))
        }
        // One switch: the benched member that fares best against what is out.
        let benchStart = 2
        if team.count > benchStart {
            var best: (index: Int, score: Double)?
            for index in benchStart..<team.count where !team[index].fainted {
                var worst = 0.0
                for foe in foes.prefix(2) where !foe.fainted {
                    let result = DamageCalc.calculate(attacker: foe.build,
                                                      defender: team[index].build,
                                                      move: foe.moves.first(where: \.isDamaging)
                                                        ?? foe.moves.first!,
                                                      field: board.field)
                    worst = max(worst, Double(result.maxDamage) / Double(team[index].maxHP))
                }
                let score = -worst
                if best == nil || score > best!.score { best = (index, score) }
            }
            if let best { leaving.append(.swap(to: best.index)) }
        }

        // Assembled so that every kind of decision survives the trim: the two
        // targets, the option to refuse the turn, the option to leave, and then
        // whatever else fits.
        var out: [Choice] = []
        func take(_ group: [Choice], _ count: Int = 1) {
            for choice in group.prefix(count) where out.count < width && !out.contains(choice) {
                out.append(choice)
            }
        }
        take(attacks, 2)
        take(guarding)
        take(leaving)
        take(spread)
        take(setup)
        take(attacks, attacks.count)

        if out.isEmpty { out.append(.attack(move: 0, target: 0)) }
        return out
    }

    /// Every pair of choices one side can make.
    func plays(forMine mine: Bool) -> [Play] {
        let left = choices(forMine: mine, slot: 0)
        let right = choices(forMine: mine, slot: 1)
        // An empty slot still needs one entry so the matrix has a row, and in
        // singles the second slot is empty every turn.
        let leftOptions = left.isEmpty ? [Choice.pass] : left
        let rightOptions = right.isEmpty ? [Choice.pass] : right
        // Whether to Mega Evolve is part of the turn, so it is part of the
        // choice. Both versions are offered for whichever slot could: evolving
        // is nearly always right, but "nearly always" is not a thing a search
        // should assume, and the exception — holding it back so your weather
        // lands second — is exactly the sort of turn worth finding.
        let team = mine ? board.mine : board.theirs
        let spent = team.contains(where: \.hasMegaEvolved)
        var megaOptions: [Int?] = [nil]
        if !spent {
            for slot in 0..<min(board.activeCount, team.count)
            where team[slot].pendingMega != nil && !team[slot].fainted {
                megaOptions.append(slot)
            }
        }
        // The slot that evolves when evolving is taken as read.
        let assumed = megaOptions.count > 1 ? megaOptions[1] : nil

        var out: [Play] = []
        for a in leftOptions {
            for b in rightOptions {
                // Both switching to the same benched Pokémon is not a thing.
                if case .swap(let x) = a, case .swap(let y) = b, x == y { continue }
                if assumeMega {
                    // A Pokémon leaving the field does not evolve on the way out.
                    let leaving = assumed == 0 ? a.isSwap : assumed == 1 ? b.isSwap : true
                    out.append(Play(left: a, right: b, megaSlot: leaving ? nil : assumed))
                    continue
                }
                for mega in megaOptions {
                    if let mega, mega == 0, a.isSwap { continue }
                    if let mega, mega == 1, b.isSwap { continue }
                    out.append(Play(left: a, right: b, megaSlot: mega))
                }
            }
        }
        return out
    }

    // MARK: - The matrix

    struct Solution {
        let myPlays: [Play]
        let theirPlays: [Play]
        /// payoff[i][j] — what I get when I play i and they play j.
        let payoff: [[Double]]
        /// How often to make each play, if you do not want to be read.
        let myMix: [Double]
        let theirMix: [Double]
        /// What the turn is worth at equilibrium.
        let value: Double

        /// Everything about one of my lines, which is what a player reads.
        struct Line: Identifiable {
            let play: Play
            let weight: Double
            /// Against their equilibrium mix.
            let expected: Double
            /// If they answer it as well as they can, and as badly as they can.
            let worst: Double
            let best: Double
            var spread: Double { best - worst }
            var id: String { "\(play)" }
        }

        var lines: [Line] {
            myPlays.enumerated().map { index, play in
                let row = payoff[index]
                let expected = zip(row, theirMix).reduce(0) { $0 + $1.0 * $1.1 }
                return Line(play: play, weight: myMix[index], expected: expected,
                            worst: row.min() ?? 0, best: row.max() ?? 0)
            }
            .sorted { $0.weight > $1.weight }
        }
    }

    /// The most of an opponent's health this Pokémon could have taken off this
    /// turn, as a share of that opponent.
    private func offence(forMine mine: Bool, slot: Int) -> Double {
        let team = mine ? board.mine : board.theirs
        let foes = mine ? board.theirs : board.mine
        guard team.indices.contains(slot), !team[slot].fainted else { return 0 }
        var best = 0.0
        for move in team[slot].moves where move.isDamaging {
            for foe in foes.prefix(2) where !foe.fainted {
                let result = DamageCalc.calculate(attacker: team[slot].build,
                                                  defender: foe.build, move: move,
                                                  field: board.field)
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                let share = Double(result.minDamage + result.maxDamage) / 2 * accuracy
                    / Double(max(1, foe.maxHP))
                best = max(best, min(1, share))
            }
        }
        return best
    }

    /// What giving up a turn costs.
    ///
    /// A one-turn model overvalues Protect and, left alone, tells both sides to
    /// double-protect for ever: inside a single turn refusing damage is pure
    /// gain and declining to attack costs nothing. It costs plenty afterwards,
    /// because the game is a race and a turn spent defending is a turn not
    /// spent winning — which is exactly why double Protect loses games slowly
    /// rather than immediately, and exactly what a one-turn horizon cannot see.
    ///
    /// So a Protect is charged most of the damage it declined to deal. Not all
    /// of it: the turn is not simply lost, it buys information and it buys the
    /// partner a turn, which is why the move is on most sets in the first place.
    /// Settable so it can be turned off and measured, which is the only way to
    /// know whether the constant is earning its place or hiding a mistake.
    ///
    /// It earns it. The obvious suspicion was that this is a hand-tuned patch
    /// for a one-turn horizon and that looking a turn further would make it
    /// unnecessary. Measured across four teams against the same opponent, with
    /// the charge switched off, the share of their mix containing a Protect ran
    /// 52%, 14%, 100% and 0% at one ply and 62%, 0%, 100% and 0% at two — on one
    /// board a second ply made Protect *more* attractive, not less.
    ///
    /// Which makes sense: at the second ply the follow-up turn is scored
    /// statically too, so the same blind spot recurs one level down. The cost
    /// of giving up a turn only emerges from a horizon far deeper than is
    /// affordable here. So the charge is not scaffolding for a missing search;
    /// it is a correction the search cannot make.
    var tempoCost = 0.6

    /// The same, handing the main thread back as it fills the matrix.
    ///
    /// A cold solve is about a third of a second, nearly all of it in the two
    /// hundred and fifty-odd boards it plays out, and a third of a second in
    /// one piece is a visibly frozen window.
    func solveYielding(iterations: Int = 3000) async -> Solution {
        let myPlays = plays(forMine: true)
        let theirPlays = plays(forMine: false)
        let myOffence = [offence(forMine: true, slot: 0), offence(forMine: true, slot: 1)]
        let theirOffence = [offence(forMine: false, slot: 0), offence(forMine: false, slot: 1)]
        var payoff = [[Double]](repeating: [Double](repeating: 0, count: theirPlays.count),
                                count: myPlays.count)
        for (i, mine) in myPlays.enumerated() {
            await breathe("turn matrix")
            for (j, theirs) in theirPlays.enumerated() {
                payoff[i][j] = asWinChance(
                    settle(mine, theirs).expected
                        - forgone(mine, myOffence) + forgone(theirs, theirOffence),
                    reliability: reliability(of: mine, forMine: true))
            }
        }
        await breathe("turn solve")
        let (myMix, theirMix, value) = TurnGame.equilibrium(payoff, iterations: iterations)
        return Solution(myPlays: myPlays, theirPlays: theirPlays, payoff: payoff,
                        myMix: myMix, theirMix: theirMix, value: value)
    }

    /// What refusing the turn costs, in the units the board is scored in.
    ///
    /// Protecting and switching both give up the slot's attack, and only
    /// Protect was ever charged for it. The search sees the damage that did not
    /// happen either way, but the charge above that — the part the comment on
    /// `tempoCost` explains, a cost the horizon is too short to reach — applied
    /// to one and not the other. So the engine had a standing reason to prefer
    /// a switch to a Protect that had nothing to do with the position.
    ///
    /// It showed up the moment anybody counted. Against 1,128 real turn-one
    /// decisions the engine Protected half as often as people and switched
    /// nearly twice as often, which is one bias wearing two faces.
    ///
    /// A switch is charged a little less than a Protect: what comes in is
    /// standing there afterwards and may be better placed, where a Protect
    /// leaves the same Pokémon in the same spot.
    private func forgone(_ play: Play, _ offence: [Double]) -> Double {
        var total = 0.0
        if play.left.isProtect { total += offence[0] }
        else if play.left.isSwap { total += offence[0] * 0.7 }
        if play.right.isProtect { total += offence[1] }
        else if play.right.isSwap { total += offence[1] * 0.7 }
        return total * 0.65 * tempoCost
    }

    /// Build the matrix and solve it.
    ///
    /// Your half is solved on this board, which is the truth as you know it.
    /// Their half is solved on `theirBelief` when one is set — the same board
    /// with your unseen back two replaced by the pair they expect — so their
    /// orders are an answer to what they can see. Each side plays the
    /// equilibrium of its own view, which is what two players with different
    /// information actually do.
    func solve(iterations: Int = 3000) -> Solution {
        let myPlays = plays(forMine: true)
        let theirPlays = plays(forMine: false)
        let myOffence = [offence(forMine: true, slot: 0), offence(forMine: true, slot: 1)]
        let theirOffence = [offence(forMine: false, slot: 0), offence(forMine: false, slot: 1)]

        var payoff = [[Double]](repeating: [Double](repeating: 0, count: theirPlays.count),
                                count: myPlays.count)
        for (i, mine) in myPlays.enumerated() {
            for (j, theirs) in theirPlays.enumerated() {
                payoff[i][j] = asWinChance(
                    settle(mine, theirs).expected
                        - forgone(mine, myOffence) + forgone(theirs, theirOffence),
                    reliability: reliability(of: mine, forMine: true))
            }
        }
        let (myMix, ownTheirMix, ownValue) = TurnGame.equilibrium(payoff, iterations: iterations)
        guard let believed = believedMix(iterations: iterations),
              believed.count == theirPlays.count else {
            return Solution(myPlays: myPlays, theirPlays: theirPlays, payoff: payoff,
                            myMix: myMix, theirMix: ownTheirMix, value: ownValue)
        }
        // What the turn is worth is what your mix gets against the mix they
        // will actually play, not against the one they would play if they
        // could see your bench.
        var value = 0.0
        for (i, row) in payoff.enumerated() where myMix.indices.contains(i) {
            for (j, cell) in row.enumerated() where believed.indices.contains(j) {
                value += myMix[i] * believed[j] * cell
            }
        }
        return Solution(myPlays: myPlays, theirPlays: theirPlays, payoff: payoff,
                        myMix: myMix, theirMix: believed, value: value)
    }

    /// Their half of the matrix, solved on the board they can actually see.
    ///
    /// Both boards carry the same two Pokémon of theirs facing the same two of
    /// yours, so the two lists of their plays line up index for index. If that
    /// ever stops being true the mix is refused rather than mismatched.
    private func believedMix(iterations: Int) -> [Double]? {
        // Nothing to solve twice if their view of your side is your side.
        guard let believed = theirBelief,
              believed.mine.map(\.build.form.id) != board.mine.map(\.build.form.id)
        else { return nil }
        var game = TurnGame(board: believed)
        game.width = width
        game.tempoCost = tempoCost
        game.assumeMega = assumeMega
        game.theirBelief = nil                      // one level deep, never a loop
        guard game.plays(forMine: false) == plays(forMine: false) else { return nil }
        return game.solve(iterations: iterations).theirMix
    }

    /// Every way a cell of the matrix can come out, likeliest first. One
    /// board unless somebody is trying a Protect that might not hold.
    func outcomes(_ mine: Play, _ theirs: Play) -> [(board: Board, chance: Double)] {
        TurnModel.outcomes(board, mine: mine, theirs: theirs)
    }

    /// What a cell of the matrix is worth, over every way it can come out,
    /// and the likeliest of those boards for anything that has to look on
    /// from a single position.
    func settle(_ mine: Play, _ theirs: Play) -> (expected: Double, likeliest: Board) {
        let outcomes = TurnModel.outcomes(board, mine: mine, theirs: theirs)
        let before = TurnModel.value(board)
        let expected = outcomes.reduce(0) { $0 + $1.chance * (TurnModel.value($1.board) - before) }
        return (expected, outcomes[0].board)
    }

    /// The same cell, scored by how far it moves the chance of winning.
    ///
    /// Taken on the whole adjusted figure rather than on the raw one, so the
    /// tempo a Protect gives up is converted along with everything else and
    /// keeps meaning what it meant.
    ///
    /// `reliability` is how much of the gain is actually going to arrive — the
    /// accuracy of the moves being thrown. It matters because the search
    /// averages: a Stone Edge is scored as 80% of a knockout, which reads
    /// exactly like a guaranteed hit for 80% of the damage, and those are
    /// completely different bets. Splitting the gain back into the branch that
    /// lands and the branch that does not, and putting each through the curve
    /// separately, is what tells them apart — and it is the reason the curve
    /// was worth having:
    ///
    ///     "Using Stone Edge as a primary win condition is sub-optimal;
    ///      missing it effectively led to an immediate loss."
    ///
    /// Ahead, the miss branch costs more than the hit branch buys and the
    /// engine wants the sure thing. Behind, it is the other way round, which
    /// is when a real player takes the swing.
    func asWinChance(_ gain: Double, reliability: Double = 1) -> Double {
        guard board.myPlaysForWin else { return gain }
        let before = TurnModel.value(board)
        let now = TurnModel.winChance(before)
        guard reliability < 0.999, reliability > 0.05 else {
            return TurnModel.winChance(before + gain) - now
        }
        // `gain` is already thinned by accuracy, so dividing by it recovers
        // what landing would actually be worth.
        let landed = TurnModel.winChance(before + gain / reliability) - now
        let missed = TurnModel.winChance(before) - now
        return reliability * landed + (1 - reliability) * missed
    }

    /// How much of what a play promises is going to arrive.
    ///
    /// The worst accuracy among the attacks it throws rather than the product:
    /// two 80% moves on the same turn is not a 64% turn, it is two separate
    /// bets, and the one that decides the position is the one that matters.
    func reliability(of play: Play, forMine mine: Bool) -> Double {
        let team = mine ? board.mine : board.theirs
        var worst = 1.0
        for (slot, choice) in [play.left, play.right].enumerated() {
            guard case .attack(let index, _) = choice,
                  team.indices.contains(slot), !team[slot].fainted,
                  team[slot].moves.indices.contains(index) else { continue }
            let move = team[slot].moves[index]
            guard move.isDamaging, !move.neverMisses, move.accuracy > 0 else { continue }
            worst = Swift.min(worst, Double(move.accuracy) / 100)
        }
        return worst
    }

    // MARK: - Looking one turn further

    /// How many of each side's lines are carried into the second turn.
    ///
    /// A full second ply squares the work, which is unaffordable and mostly
    /// wasted: the lines nobody would play do not need their futures examined.
    /// Only the ones the first solve actually gives weight to are followed.
    var lookaheadWidth = 4

    /// Score a board by solving the turn that follows it, rather than by
    /// counting health.
    ///
    /// This is what a one-turn horizon cannot see. Setting Trick Room is a
    /// terrible turn and a winning game; Protecting takes no damage and gains
    /// nothing; switching gives up a turn to arrive somewhere better. All three
    /// are decisions about the *next* turn, and a model that stops at the end
    /// of this one has to be told about them by hand — which is exactly what
    /// the tempo charge on Protect is, a constant standing in for a turn nobody
    /// looked at.
    ///
    /// A second ply replaces the guess with a search. It is not cheap, so it is
    /// spent only on the lines that survived the first solve.
    func deepen(_ shallow: Solution, iterations: Int = 1500) -> Solution {
        let mineKept = shallow.myMix.indices
            .filter { shallow.myMix[$0] > 0.02 }
            .sorted { shallow.myMix[$0] > shallow.myMix[$1] }
            .prefix(lookaheadWidth)
        let theirsKept = shallow.theirMix.indices
            .filter { shallow.theirMix[$0] > 0.02 }
            .sorted { shallow.theirMix[$0] > shallow.theirMix[$1] }
            .prefix(lookaheadWidth)
        guard mineKept.count > 1, theirsKept.count > 1 else { return shallow }

        var payoff = [[Double]](
            repeating: [Double](repeating: 0, count: theirsKept.count),
            count: mineKept.count)
        for (i, myIndex) in mineKept.enumerated() {
            for (j, theirIndex) in theirsKept.enumerated() {
                let settled = settle(shallow.myPlays[myIndex], shallow.theirPlays[theirIndex])
                // The turn that follows, worth what its own equilibrium says.
                // A board where every line is bad is a bad board, whatever the
                // health bars say about it.
                var next = TurnGame(board: settled.likeliest)
                next.width = max(3, width - 2)
                let follow = next.solve(iterations: 600)
                // Where the turn left things, plus what the turn after is worth
                // from there, discounted: a turn in hand now is worth more than
                // one promised later, and the second solve is the less reliable
                // of the two.
                payoff[i][j] = settled.expected + 0.6 * follow.value
            }
        }
        let (myMix, theirMix, value) = TurnGame.equilibrium(payoff, iterations: iterations)
        return Solution(myPlays: mineKept.map { shallow.myPlays[$0] },
                        theirPlays: theirsKept.map { shallow.theirPlays[$0] },
                        payoff: payoff, myMix: myMix, theirMix: theirMix, value: value)
    }

    /// Solve the turn, then check the answer against what follows it.
    func solveDeep(iterations: Int = 3000) async -> (shallow: Solution, deep: Solution) {
        let shallow = await solveYielding(iterations: iterations)
        await breathe("lookahead")
        let deep = deepen(shallow)
        return (shallow, deep)
    }

    /// Where looking further changed the answer.
    func lookaheadNotes(shallow: Solution, deep: Solution) -> [String] {
        guard deep.myPlays.count > 1, shallow.lines.first != nil else { return [] }
        var out: [String] = []
        let shallowTop = shallow.lines.first!
        let deepTop = deep.lines.first!
        if deepTop.id != shallowTop.id {
            out.append("Looking a turn further changes the answer: \(describe(deepTop.play, mine: true)) rather than \(describe(shallowTop.play, mine: true)). The first is worth less this turn and more by the end of the next one.")
        } else {
            out.append("Looking a turn further agrees: \(describe(deepTop.play, mine: true)) is still the line.")
        }
        let drift = deep.value - shallow.value
        if abs(drift) > 0.1 {
            out.append(String(format: "The turn after is worth %+.2f more than this one alone suggests, so %@.",
                              drift,
                              drift > 0 ? "the position is better than the health bars say"
                                        : "this turn buys less than it looks like it does"))
        }
        return out
    }

    // MARK: - Saying what it means

    /// One Pokémon's choice, in words.
    func describe(_ choice: Choice, fighter: Fighter, foes: [Fighter],
                  team: [Fighter] = []) -> String {
        switch choice {
        case .attack(let index, let target):
            guard fighter.moves.indices.contains(index) else { return "attack" }
            let move = fighter.moves[index]
            if move.aim == .party {
                let who = team.indices.contains(target) ? team[target].build.form.formLabel : "a teammate"
                return "\(move.name) on \(who)"
            }
            if !move.isDamaging { return move.name }
            if move.isSpread { return "\(move.name) (both)" }
            if target >= Choice.allyTarget {
                let partner = team.firstIndex { $0.build.form.id == fighter.build.form.id }.map { $0 == 0 ? 1 : 0 } ?? 1
                let who = team.indices.contains(partner) ? team[partner].build.form.formLabel : "its partner"
                return "\(move.name) into its own \(who)"
            }
            let name = foes.indices.contains(target) ? foes[target].build.form.formLabel : "the other"
            if fighter.encoredFor > 0, fighter.lastMove == index { return "\(move.name) into \(name) (Encore)" }
            if let charge = move.charge {
                if fighter.charging == index { return "\(move.name) into \(name), firing" }
                if charge.skipsIn == nil || board.field.weather != charge.skipsIn {
                    return "charge \(move.name) at \(name)"
                }
            }
            return "\(move.name) into \(name)"
        case .protectSelf(let index):
            let name = fighter.moves.indices.contains(index) ? fighter.moves[index].name : "Protect"
            if fighter.protectStreak > 0 {
                return "\(name) (\(Int((fighter.protectChance * 100).rounded()))% to hold)"
            }
            return name
        case .swap(let bench):
            guard team.indices.contains(bench) else { return "switch out" }
            return "switch to \(team[bench].build.form.formLabel)"
        case .pass:
            return ""
        }
    }

    func describe(_ play: Play, mine: Bool) -> String {
        let team = mine ? board.mine : board.theirs
        let foes = mine ? board.theirs : board.mine
        guard team.count >= 2 else { return "—" }
        let front = Array(foes.prefix(board.activeCount))
        var first = describe(play.left, fighter: team[0], foes: front, team: team)
        if play.megaSlot == 0, let mega = team[0].pendingMega {
            first = "Mega Evolve into \(mega.formLabel), then \(first)"
        }
        guard board.activeCount > 1, team.count > 1, !play.right.isPass else { return first }
        var second = describe(play.right, fighter: team[1], foes: front, team: team)
        if play.megaSlot == 1, let mega = team[1].pendingMega {
            second = "Mega Evolve into \(mega.formLabel), then \(second)"
        }
        return second.isEmpty ? first : first + " and " + second
    }

    /// The turn in the sentences a player would use.
    ///
    /// The equilibrium mix is the headline and not the useful part. What a
    /// player is deciding is whether to take the line that cannot be punished
    /// or the one that wins more when the read is right, and that is a question
    /// about the gap between a line's worst case and its best.
    func read(_ solution: Solution) -> [String] {
        var out: [String] = []
        let ranked = solution.lines.filter { $0.weight > 0.01 }
        guard let top = ranked.first else { return out }

        // The line that cannot be punished: narrowest gap between best and
        // worst, among those the equilibrium actually plays.
        let safest = ranked.min { $0.spread < $1.spread }
        // The line with the most to gain, whatever it risks.
        let greediest = ranked.max { $0.best < $1.best }

        // Risk is about the worst case being bad, not about the range being
        // wide. A line worth +0.37 at its worst is not a gamble however much
        // better its best is, and calling it one is the sort of thing that
        // makes a reader stop believing the rest.
        let topNote: String
        if top.worst >= 0 {
            topNote = String(format: " It comes out ahead whatever they pick — %+.2f at worst.",
                             top.worst)
        } else if top.spread > 0.3 {
            topNote = String(format: " It is the risky line: %+.2f if they guess wrong, %+.2f if they guess right.",
                             top.best, top.worst)
        } else {
            topNote = ""
        }
        out.append(String(format: "Play %@ about %.0f%% of the time.%@",
                          describe(top.play, mine: true), top.weight * 100, topNote))
        if let safest, safest.spread < 0.15 {
            out.append("\(describe(safest.play, mine: true)) is the line that cannot be read: "
                       + String(format: "it is worth %+.2f whatever they pick, so it is what you click when you have no information.",
                                safest.expected))
        }
        // Only worth naming when it is a different line from the one already
        // described; otherwise the same play is explained twice.
        if let greediest, greediest.id != safest?.id, greediest.id != top.id,
           greediest.spread > 0.3, greediest.best > top.best + 0.1 {
            out.append(String(format: "%@ reaches further: %+.2f if they guess wrong, %+.2f if they guess right. The mix says take it about %.0f%% of the time — more once you have seen them protect, less before you have.",
                              describe(greediest.play, mine: true),
                              greediest.best, greediest.worst, greediest.weight * 100))
        }
        // What they are most likely to do, which is the other half of a read.
        if let theirIndex = solution.theirMix.indices.max(by: {
            solution.theirMix[$0] < solution.theirMix[$1] }),
           solution.theirMix[theirIndex] > 0.2 {
            out.append(String(format: "Their most likely answer is %@, about %.0f%% of the time.",
                              describe(solution.theirPlays[theirIndex], mine: false),
                              solution.theirMix[theirIndex] * 100))
        }
        out.append(solution.value > 0.05
            ? String(format: "The turn is worth %+.2f to you even played perfectly by both sides.", solution.value)
            : (solution.value < -0.05
               ? String(format: "The turn is worth %+.2f to you: there is no line that comes out ahead, so this is about losing it slowly.", solution.value)
               : "The turn is level at equilibrium, so it comes down to who reads whom."))
        return out
    }

    // MARK: - Regret matching

    /// The unexploitable mix for both sides of a zero-sum matrix.
    ///
    /// Regret matching: play in proportion to how much you wish, in hindsight,
    /// you had played each option more. Averaged over enough rounds that
    /// converges on Nash, and it needs no linear programming library.
    static func equilibrium(_ payoff: [[Double]], iterations: Int = 3000)
        -> (row: [Double], column: [Double], value: Double) {
        let rows = payoff.count
        let columns = payoff.first?.count ?? 0
        guard rows > 0, columns > 0 else { return ([], [], 0) }

        var rowRegret = [Double](repeating: 0, count: rows)
        var colRegret = [Double](repeating: 0, count: columns)
        var rowSum = [Double](repeating: 0, count: rows)
        var colSum = [Double](repeating: 0, count: columns)

        func fromRegret(_ regret: [Double]) -> [Double] {
            let positive = regret.map { max(0, $0) }
            let total = positive.reduce(0, +)
            guard total > 0 else {
                return [Double](repeating: 1 / Double(regret.count), count: regret.count)
            }
            return positive.map { $0 / total }
        }

        for _ in 0..<iterations {
            let rowStrategy = fromRegret(rowRegret)
            let colStrategy = fromRegret(colRegret)
            for index in 0..<rows { rowSum[index] += rowStrategy[index] }
            for index in 0..<columns { colSum[index] += colStrategy[index] }

            // What each of my options would have been worth against their mix.
            var rowUtility = [Double](repeating: 0, count: rows)
            for i in 0..<rows {
                var total = 0.0
                for j in 0..<columns { total += payoff[i][j] * colStrategy[j] }
                rowUtility[i] = total
            }
            let rowValue = zip(rowUtility, rowStrategy).reduce(0) { $0 + $1.0 * $1.1 }
            for i in 0..<rows { rowRegret[i] += rowUtility[i] - rowValue }

            // And theirs, on the other side of the same number.
            var colUtility = [Double](repeating: 0, count: columns)
            for j in 0..<columns {
                var total = 0.0
                for i in 0..<rows { total -= payoff[i][j] * rowStrategy[i] }
                colUtility[j] = total
            }
            let colValue = zip(colUtility, colStrategy).reduce(0) { $0 + $1.0 * $1.1 }
            for j in 0..<columns { colRegret[j] += colUtility[j] - colValue }
        }

        func normalised(_ sums: [Double]) -> [Double] {
            let total = sums.reduce(0, +)
            guard total > 0 else {
                return [Double](repeating: 1 / Double(sums.count), count: sums.count)
            }
            return sums.map { $0 / total }
        }
        let row = normalised(rowSum), column = normalised(colSum)
        var value = 0.0
        for i in 0..<rows {
            for j in 0..<columns { value += row[i] * column[j] * payoff[i][j] }
        }
        return (row, column, value)
    }
}
