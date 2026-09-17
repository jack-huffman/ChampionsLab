//  MatchupTree.swift
//  One matchup, every decision you could make in it, laid out as a tree.
//
//  The lab plays thousands of games and tells you what happened on average.
//  This asks a different question: given these two fours on this field, what
//  were your actual options, and which of them win? An average cannot answer
//  that, because an average has already thrown away the decisions.
//
//  What exhausting everything would cost, since that is the first thing anyone
//  asks and the numbers decide the design. Measured on a real four against
//  four: you have twenty-four legal plays a turn, they have thirty-five, and
//  one turn resolves in about a fifth of a millisecond.
//
//      both sides, 1 turn          840 nodes        0.2 seconds
//      both sides, 2 turns     705,600 nodes        2.6 minutes
//      both sides, 3 turns   592,704,000 nodes       36 hours
//      both sides, 4 turns   497,871,360,000        3.5 years
//
//  So the wall is turn three and games run to fifteen. And that table is only
//  the decisions: every attack also branches over sixteen damage rolls, a
//  critical hit, an accuracy check and any secondary effect, which is another
//  factor of a thousand or so per turn. Exhausting *everything* does not get
//  through turn one.
//
//  Two cuts make it tractable without giving up the thing worth having:
//
//    * Only your side branches. Theirs answers at equilibrium — the reply the
//      solver says is their best — which drops 840 a turn to 24. You still see
//      every decision you could make; you simply do not enumerate their
//      thirty-five answers to each of yours. For "which of my decisions won
//      this", that is the right cut, and it keeps the opponent honest instead
//      of letting you win against a strawman.
//
//    * The dice are sampled, not enumerated. This is not only cheaper, it is
//      what you want: "this line wins 61%" is a statement that has already
//      averaged over the rolls.
//
//  Turn one is the exception, and gets the full treatment: all 840 joint plays
//  including every one of their answers, because it costs a fifth of a second
//  and turn one is where leads, Fake Out, Protect and speed control are decided.
//
//  The cost then sits in the internal nodes rather than the leaves — each one
//  solves a turn matrix, which is those 840 resolutions — so depth three is
//  around a thousand nodes and fifteen seconds, and depth four is
//  twenty-four times that.
//
//  What the numbers on a line mean, and what they do not.
//
//  A line's figure is the board evaluation three turns in. That is a horizon,
//  not a forecast. Measured on one real matchup: the tree rated eight openings
//  between 19% and 53%, and playing them out put every one of them between 0%
//  and 12% — the whole matchup was lost and nothing three turns deep could see
//  it. The ordering was only half right too, with an opening the tree rated 47%
//  winning none of twenty-four and one it rated 19% doing as well as the best.
//
//  So the tree is for *finding* candidate lines and for showing which turns
//  have a lot riding on them. It is not for putting a number on a game. That is
//  what the playouts are for, and it is why they exist: the openings are played
//  properly and reported next to a baseline of the same matchup played straight
//  through, so a reader can see both what the opening is worth and whether the
//  matchup was ever winnable.

import Foundation

enum MatchupTree {
    /// One turn along a line: what you did, what they did back, and where it
    /// left you.
    struct Step: Sendable, Hashable {
        let mine: String
        let theirs: String
        /// Your chance of winning from the position this turn produced.
        let winChance: Double
        /// The play itself, so a line can be replayed rather than only read.
        let play: Play
    }

    /// A complete line of play, from the opening turn to wherever it stopped.
    struct Path: Sendable, Identifiable {
        var steps: [Step]
        /// The estimate at the end of the line, from the board evaluation.
        var estimate: Double
        var games: Int = 0
        /// Whether the line ended because the game did rather than because the
        /// search ran out of depth.
        var decided: Bool = false

        var id: String { steps.map(\.mine).joined(separator: " > ") }
        /// The opening this line commits to, which is the part of it that can
        /// be measured.
        var opening: String { steps.first?.mine ?? "" }
    }

    /// One opening, played out properly.
    ///
    /// Why the openings and not the lines. A line is three specific turns, and
    /// three specific turns is not a thing you can replay: the dice are fresh
    /// every game, so the board diverges after turn one, and the stored play is
    /// a *move index* — on a board that has diverged, index two is a different
    /// move against a different target. Forcing it anyway produced lines the
    /// tree scored at 46% and the replay scored at 8%, which was measuring the
    /// forcing rather than the line.
    ///
    /// Turn one has no such problem. The board is the same every game, so "make
    /// this play, then play well" is a real question with a real answer, and it
    /// is the decision most worth having an answer for.
    struct Opening: Sendable, Identifiable {
        let play: String
        /// What the tree thinks, from the best line beginning this way.
        let estimate: Double
        /// What it did, over real games.
        let measured: Double
        let games: Int
        var id: String { play }
        /// How far the estimate was out. Large either way is worth knowing.
        var drift: Double { measured - estimate }
    }

    /// One decision point, and what each option was worth.
    ///
    /// This is the blunder cost. A turn where the best play is worth 61% and
    /// the second best 59% is a turn where it barely matters what you do; one
    /// where they are 61% and 34% is the turn the game is decided on, and
    /// knowing which is which is most of what preparation is.
    struct Decision: Sendable, Identifiable {
        /// How many turns in, counting from one.
        let turn: Int
        /// The line that led here, so the decision can be placed.
        let after: [String]
        /// Every option, best first, with its worth against their equilibrium.
        let options: [Option]

        struct Option: Sendable, Hashable {
            let play: String
            let winChance: Double
            /// The worst they could do to it, if they read it exactly right.
            let ifRead: Double
        }

        var id: String { "\(turn)-" + after.joined(separator: ">") }

        /// What the turn is worth getting right: the best option against the
        /// worst one.
        ///
        /// Best against *second* best was the first thing tried and it is the
        /// wrong question. The top two plays are nearly always within a point
        /// of each other — that is what it means for a position to have more
        /// than one reasonable move — so it reported every turn as trivial.
        /// What a player needs to know is how much there is to lose here, and
        /// that is the distance down to the bottom of the list.
        var swing: Double {
            guard let best = options.first, let worst = options.last else { return 0 }
            return best.winChance - worst.winChance
        }

        /// How close the decision is at the top. Small means several plays are
        /// fine and the turn is not worth agonising over; large means there is
        /// one move.
        var margin: Double {
            guard options.count > 1 else { return 0 }
            return options[0].winChance - options[1].winChance
        }
    }

    /// Turn one in full: every play of yours against every answer of theirs.
    struct Matrix: Sendable {
        var mine: [String] = []
        var theirs: [String] = []
        /// winChance[i][j] — where you end up playing i into their j.
        var winChance: [[Double]] = []
        /// How often the solver says to make each of your plays.
        var myMix: [Double] = []
        var theirMix: [Double] = []
    }

    struct Report: Sendable {
        var mine = ""
        var theirs = ""
        var myLead: [String] = []
        var theirLead: [String] = []
        var depth = 0
        var matrix = Matrix()
        /// Every line the tree reached, best first.
        var paths: [Path] = []
        var decisions: [Decision] = []
        var leaves = 0
        var nodes = 0
        var seconds = 0.0
        /// Each opening, played out. Empty unless playouts were asked for.
        var openings: [Opening] = []
        /// The same matchup played straight through by the engine, as a mark to
        /// read the openings against. Without it "this opening wins 34%" says
        /// nothing: the question is always 34% against what.
        var baseline: Double?
        var baselineGames = 0

        var best: [Path] { Array(paths.prefix(12)) }
        var worst: [Path] { Array(paths.suffix(12).reversed()) }
        /// The turns most worth getting right: where the gap between playing
        /// well and playing badly is widest.
        var pivotal: [Decision] { decisions.sorted { $0.swing > $1.swing } }

        /// Turns with one right answer, where the second best play is a real
        /// step down. Different from `pivotal`: a turn can have a lot riding on
        /// it and several ways to play it well.
        var forced: [Decision] { decisions.sorted { $0.margin > $1.margin } }
    }

    struct Progress: Sendable {
        let nodes: Int
        let of: Int
        let stage: String
    }

    /// Walk the tree.
    ///
    /// `mine` and `theirs` are the fours already chosen, lead pair first: the
    /// board takes the first two as the actives and the rest as the bench, so
    /// picking the four and the lead is done by ordering the slots rather than
    /// by a separate argument.
    ///
    /// `playouts` replays the most and least promising lines for a real win
    /// rate rather than an estimate. Nothing else in the tree is played out —
    /// that is the hybrid, and it puts the expensive measurement where it will
    /// change somebody's mind.
    static func explore(mine: Team, theirs: Team, rules: Rulebook,
                        field: Field = Field(isDoubles: true),
                        depth: Int = 3, playouts: Int = 0,
                        playoutNodes: Int = BattleEngine.Nodes.turn,
                        replay: Int = 8,
                        progress: ((Progress) -> Void)? = nil,
                        shouldStop: () -> Bool = { false }) -> Report {
        var report = Report()
        report.mine = mine.name
        report.theirs = theirs.name
        report.depth = depth
        guard mine.slots.count >= 2, theirs.slots.count >= 2 else { return report }
        let started = Date()

        let root = Board(mine: mine, theirs: theirs, rules: rules,
                         field: field, alreadyEvolved: false)
        report.myLead = root.mine.prefix(2).map { $0.build.form.formLabel }
        report.theirLead = root.theirs.prefix(2).map { $0.build.form.formLabel }

        // Roughly how many internal nodes there are, for something to show.
        var expected = 0, run = 1
        for _ in 0..<depth { run *= 24; expected += run / 24 }
        var seen = 0

        // -- turn one, in full -------------------------------------------
        //
        // The only turn that gets both sides enumerated. It is affordable and
        // it is the turn most worth seeing whole.
        let opening = TurnGame(board: root)
        let solved = opening.solve()
        report.matrix.mine = solved.myPlays.map { opening.describe($0, mine: true) }
        report.matrix.theirs = solved.theirPlays.map { opening.describe($0, mine: false) }
        report.matrix.myMix = solved.myMix
        report.matrix.theirMix = solved.theirMix
        report.matrix.winChance = solved.payoff.map { row in
            row.map { Evaluation.winChance($0) }
        }

        // -- the tree ----------------------------------------------------
        var paths: [Path] = []
        var decisions: [Decision] = []

        func walk(_ board: Board, _ steps: [Step], _ left: Int) {
            if shouldStop() { return }
            // A finished game is a leaf whatever the depth says, and it is the
            // most informative kind: the line actually resolved.
            if board.isOut(mine: false) || board.isOut(mine: true) || left == 0 {
                let value = Evaluation.value(board)
                paths.append(Path(steps: steps, estimate: Evaluation.winChance(value),
                                  decided: board.isOut(mine: false) || board.isOut(mine: true)))
                return
            }
            let game = TurnGame(board: board)
            let here = game.solve()
            seen += 1
            if seen % 8 == 0 {
                progress?(Progress(nodes: seen, of: Swift.max(1, expected), stage: "searching"))
            }
            guard !here.myPlays.isEmpty, !here.theirPlays.isEmpty else {
                paths.append(Path(steps: steps,
                                  estimate: Evaluation.winChance(Evaluation.value(board))))
                return
            }
            // Their answer: the play their own equilibrium leans on hardest.
            // Not a fixed choice they are stuck with — it is what the solver
            // says is their best reply to the mix you are actually playing —
            // but it is one answer rather than thirty-five, which is the whole
            // reason this finishes.
            let reply = here.theirMix.enumerated().max { $0.element < $1.element }?.offset ?? 0
            let theirPlay = here.theirPlays[reply]
            let theirText = game.describe(theirPlay, mine: false)

            decisions.append(Decision(
                turn: steps.count + 1,
                after: steps.map(\.mine),
                options: here.lines.map { line in
                    Decision.Option(play: game.describe(line.play, mine: true),
                                    winChance: Evaluation.winChance(line.expected),
                                    ifRead: Evaluation.winChance(line.worst))
                }.sorted { $0.winChance > $1.winChance }))

            for play in here.myPlays {
                if shouldStop() { return }
                let next = TurnModel.resolve(board, mine: play, theirs: theirPlay)
                let step = Step(mine: game.describe(play, mine: true), theirs: theirText,
                                winChance: Evaluation.winChance(Evaluation.value(next)),
                                play: play)
                walk(next, steps + [step], left - 1)
            }
        }
        walk(root, [], depth)

        report.nodes = seen
        report.leaves = paths.count
        paths.sort { $0.estimate > $1.estimate }

        // -- and the openings, played for real ---------------------------
        //
        // The tree's numbers are the board evaluation at the end of a line,
        // which is a guess made by the same function the search trusts at its
        // horizon. For turn one that guess can be checked, so check it.
        if playouts > 0 {
            let engine = BattleEngine(rules: rules, nodes: playoutNodes)
            // Best first, and only as many as asked: measuring all twenty-four
            // openings at a useful number of games is a long wait for detail
            // nobody reads past the top of.
            var bestByOpening: [String: Double] = [:]
            var playByOpening: [String: Play] = [:]
            for path in paths {
                guard let step = path.steps.first else { continue }
                if bestByOpening[step.mine] == nil || path.estimate > bestByOpening[step.mine]! {
                    bestByOpening[step.mine] = path.estimate
                }
                playByOpening[step.mine] = step.play
            }
            let ranked = bestByOpening.sorted { $0.value > $1.value }
            let wanted = replay >= ranked.count ? ranked
                : Array(ranked.prefix(Swift.max(1, replay - replay / 3))
                        + ranked.suffix(replay / 3))

            for (index, entry) in wanted.enumerated() {
                if shouldStop() { break }
                progress?(Progress(nodes: index, of: wanted.count + 1, stage: "playing openings"))
                guard let play = playByOpening[entry.key] else { continue }
                var wins = 0, played = 0
                for game in 0..<playouts {
                    if shouldStop() { break }
                    Dice.source = TeamLab.SplitMix(
                        seed: 0x5EED &+ UInt64(game) &* 0x9E37_79B9_7F4A_7C15)
                    if playOut(from: root, forcing: [play], engine: engine, limit: 40) == true {
                        wins += 1
                    }
                    played += 1
                }
                guard played > 0 else { continue }
                report.openings.append(Opening(play: entry.key, estimate: entry.value,
                                               measured: Double(wins) / Double(played),
                                               games: played))
            }
            report.openings.sort { $0.measured > $1.measured }

            // The same matchup with nothing forced, so the openings have
            // something to be better or worse than.
            if !shouldStop() {
                progress?(Progress(nodes: wanted.count, of: wanted.count + 1,
                                   stage: "playing openings"))
                var wins = 0, played = 0
                for game in 0..<playouts {
                    if shouldStop() { break }
                    Dice.source = TeamLab.SplitMix(
                        seed: 0xBA5E &+ UInt64(game) &* 0x9E37_79B9_7F4A_7C15)
                    if playOut(from: root, forcing: [], engine: engine, limit: 40) == true {
                        wins += 1
                    }
                    played += 1
                }
                if played > 0 {
                    report.baseline = Double(wins) / Double(played)
                    report.baselineGames = played
                }
            }
        }

        report.paths = paths
        report.decisions = decisions
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    /// Commit to an opening, then play properly.
    ///
    /// `forcing` is applied from turn one onwards and is in practice one play
    /// long. Anything past the first turn would be forcing a decision made for
    /// a board this game has not got — the dice are fresh, so it diverges
    /// immediately, and a stored play is a move *index*, which on a different
    /// board is a different move at a different target.
    ///
    /// Nil when nobody finished inside the limit and neither side is clearly
    /// ahead — the same standard the lab uses.
    private static func playOut(from start: Board, forcing: [Play],
                                engine: BattleEngine, limit: Int) -> Bool? {
        var board = start
        for turn in 0..<limit {
            if board.isOut(mine: false) { return true }
            if board.isOut(mine: true) { return false }
            let mine = turn < forcing.count ? forcing[turn] : pick(engine.think(board))
            let theirs = pick(engine.think(board.flipped))
            board = TurnModel.resolve(board, mine: mine, theirs: theirs, rolling: true)
            board.fillGaps()
        }
        let standing = Evaluation.value(board)
        if standing > 0.25 { return true }
        if standing < -0.25 { return false }
        return nil
    }

    /// One play drawn from the engine's mix, the way self-play draws it.
    private static func pick(_ thought: BattleEngine.Result) -> Play {
        guard !thought.plays.isEmpty else { return Play(left: .pass, right: .pass) }
        let total = thought.mix.reduce(0, +)
        guard total > 0 else { return thought.plays[0] }
        var roll = Double.random(in: 0..<total, using: &Dice.source)
        for (index, weight) in thought.mix.enumerated() {
            roll -= weight
            if roll <= 0, thought.plays.indices.contains(index) { return thought.plays[index] }
        }
        return thought.plays[0]
    }
}
