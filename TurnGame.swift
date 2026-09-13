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

@MainActor
struct TurnGame {
    let board: Board
    let store: Store
    /// How many choices each Pokémon is allowed to consider. Every one squares
    /// the size of the matrix, so this is the knob that decides whether a turn
    /// takes ten milliseconds or ten seconds.
    var width = 4

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
        guard team.indices.contains(slot), !team[slot].fainted else { return [] }
        let fighter = team[slot]

        var out: [Choice] = []
        // The hardest single hit at each opponent still standing.
        for target in 0..<min(2, foes.count) where !foes[target].fainted {
            var best: (index: Int, damage: Int)?
            for (index, move) in fighter.moves.enumerated()
            where move.isDamaging && !move.isSpread {
                let result = DamageCalc.calculate(attacker: fighter.build,
                                                  defender: foes[target].build,
                                                  move: move, field: board.field)
                let accuracy = move.neverMisses || move.accuracy == 0
                    ? 1.0 : Double(move.accuracy) / 100
                let worth = Int(Double(result.maxDamage) * accuracy)
                if best == nil || worth > best!.damage { best = (index, worth) }
            }
            if let best { out.append(.attack(move: best.index, target: target)) }
        }
        // A spread move is a different decision, not a better version of one.
        if let spread = fighter.moves.firstIndex(where: { $0.isDamaging && $0.isSpread }) {
            out.append(.attack(move: spread, target: 0))
        }
        // Protect, unless it was used last turn, when it mostly fails.
        if !fighter.protectedLast,
           let guard_ = fighter.moves.firstIndex(where: {
               DuelEngine.protectMoves.contains($0.name) }) {
            out.append(.protectSelf(move: guard_))
        }
        // Speed control, which is the whole turn on the teams that run it.
        if let control = fighter.moves.firstIndex(where: {
            ["Tailwind", "Trick Room"].contains($0.name) }) {
            let already = mine ? board.myTailwind : board.theirTailwind
            if already == 0 { out.append(.attack(move: control, target: 0)) }
        }
        // Fake Out, which only exists on the turn it comes in.
        if fighter.justArrived,
           let fake = fighter.moves.firstIndex(where: { $0.name == "Fake Out" }),
           !out.contains(where: { if case .attack(let m, _) = $0 { return m == fake }
                                  return false }) {
            out.append(.attack(move: fake, target: 0))
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
            if let best { out.append(.swap(to: best.index)) }
        }

        if out.isEmpty { out.append(.attack(move: 0, target: 0)) }
        return Array(out.prefix(width))
    }

    /// Every pair of choices one side can make.
    func plays(forMine mine: Bool) -> [Play] {
        let left = choices(forMine: mine, slot: 0)
        let right = choices(forMine: mine, slot: 1)
        // A fainted or absent second slot still needs one entry so the matrix
        // has a row.
        let leftOptions = left.isEmpty ? [Choice.attack(move: 0, target: 0)] : left
        let rightOptions = right.isEmpty ? [Choice.attack(move: 0, target: 0)] : right
        var out: [Play] = []
        for a in leftOptions {
            for b in rightOptions {
                // Both switching to the same benched Pokémon is not a thing.
                if case .swap(let x) = a, case .swap(let y) = b, x == y { continue }
                out.append(Play(left: a, right: b))
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
    private static let tempoCost = 0.6

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
                let after = TurnModel.resolve(board, mine: mine, theirs: theirs, store: store)
                payoff[i][j] = TurnModel.value(after) - TurnModel.value(board)
                    - forgone(mine, myOffence) + forgone(theirs, theirOffence)
            }
        }
        await breathe("turn solve")
        let (myMix, theirMix, value) = TurnGame.equilibrium(payoff, iterations: iterations)
        return Solution(myPlays: myPlays, theirPlays: theirPlays, payoff: payoff,
                        myMix: myMix, theirMix: theirMix, value: value)
    }

    /// What a Protect costs its side, in the units the board is scored in.
    private func forgone(_ play: Play, _ offence: [Double]) -> Double {
        var total = 0.0
        if play.left.isProtect { total += offence[0] }
        if play.right.isProtect { total += offence[1] }
        return total * 0.65 * TurnGame.tempoCost
    }

    /// Build the matrix and solve it.
    func solve(iterations: Int = 3000) -> Solution {
        let myPlays = plays(forMine: true)
        let theirPlays = plays(forMine: false)
        let myOffence = [offence(forMine: true, slot: 0), offence(forMine: true, slot: 1)]
        let theirOffence = [offence(forMine: false, slot: 0), offence(forMine: false, slot: 1)]

        var payoff = [[Double]](repeating: [Double](repeating: 0, count: theirPlays.count),
                                count: myPlays.count)
        for (i, mine) in myPlays.enumerated() {
            for (j, theirs) in theirPlays.enumerated() {
                let after = TurnModel.resolve(board, mine: mine, theirs: theirs, store: store)
                payoff[i][j] = TurnModel.value(after) - TurnModel.value(board)
                    - forgone(mine, myOffence) + forgone(theirs, theirOffence)
            }
        }
        let (myMix, theirMix, value) = TurnGame.equilibrium(payoff, iterations: iterations)
        return Solution(myPlays: myPlays, theirPlays: theirPlays, payoff: payoff,
                        myMix: myMix, theirMix: theirMix, value: value)
    }

    // MARK: - Saying what it means

    /// One Pokémon's choice, in words.
    func describe(_ choice: Choice, fighter: Fighter, foes: [Fighter]) -> String {
        switch choice {
        case .attack(let index, let target):
            guard fighter.moves.indices.contains(index) else { return "attack" }
            let move = fighter.moves[index]
            if !move.isDamaging { return move.name }
            if move.isSpread { return "\(move.name) (both)" }
            let name = foes.indices.contains(target) ? foes[target].build.form.formLabel : "the other"
            return "\(move.name) into \(name)"
        case .protectSelf(let index):
            return fighter.moves.indices.contains(index) ? fighter.moves[index].name : "Protect"
        case .swap(let bench):
            return "switch to \(bench)"
        }
    }

    func describe(_ play: Play, mine: Bool) -> String {
        let team = mine ? board.mine : board.theirs
        let foes = mine ? board.theirs : board.mine
        guard team.count >= 2 else { return "—" }
        return "\(describe(play.left, fighter: team[0], foes: Array(foes.prefix(2))))"
            + " and \(describe(play.right, fighter: team[1], foes: Array(foes.prefix(2))))"
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
