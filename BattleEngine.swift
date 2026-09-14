//  BattleEngine.swift
//  Searching the game rather than the turn.
//
//  TurnGame solves the turn in front of you and, with a second ply, checks the
//  answer against what follows. This goes further in the two directions that
//  actually separate a calculator from a player.
//
//  Depth. Each node is still a simultaneous-move matrix, so there is no
//  alternation to run alpha-beta against; what a chess engine does that *does*
//  apply is iterative deepening against a clock, ordering the moves it already
//  believes in first, and keeping a table of positions it has already valued.
//  Each cell of a node's matrix is scored by solving the position it leads to,
//  one ply shallower, until the clock runs out or the depth does.
//
//  Ignorance. The harder half, and the one that makes this a different game
//  from chess. Neither side can see:
//
//    · which four of the six the other brought, or which two lead
//    · what anything is holding, until the item goes off
//    · what the other four moves are, until they are clicked
//
//  Playing as though all of that were known produces confident nonsense --
//  it will happily "play around" a Focus Sash nobody can see. So the search
//  runs over a belief instead of a position: a handful of the most plausible
//  worlds, weighted by how likely each is, with the value averaged across them.
//  A line that is good in every world is genuinely good; one that is excellent
//  in a single world and a disaster in the rest is a gamble, and the spread
//  across worlds is what says which is which.
//
//  Beliefs come from measured usage rather than from assumption. When the
//  ladder says Whimsicott holds a Focus Sash 87% of the time, that is the prior
//  it plays against, and it collapses the moment the Sash is seen.

import Foundation

@MainActor
struct BattleEngine {
    let store: Store
    /// How long to think. Iterative deepening returns the best answer it
    /// reached rather than the one it was aiming for.
    var budget: TimeInterval = 0.6
    /// How many lines each side keeps at a node. Every extra one multiplies the
    /// work by itself at every level below.
    var beam = 4
    /// How many worlds to average over. Each is a guess at what they are hiding.
    var worlds = 3
    var maxDepth = 4

    // MARK: - What we do not know

    /// What is hidden, and what it is probably worth guessing.
    struct Belief {
        /// Items seen go off, so they stop being guesses.
        var revealedItems: [String: String] = [:]
        /// Which of theirs have actually appeared. The rest might not even be
        /// in their four.
        var seen: Set<String> = []
        /// How many they bring, so how many of the unseen ones are real.
        var bring = 4
    }

    /// The likeliest things a Pokémon could be holding, from measured usage.
    ///
    /// This is the prior a person plays against without thinking about it: you
    /// do not know a Whimsicott has a Focus Sash, you know 87% of them do and
    /// you play the turn accordingly.
    func itemOdds(for form: Form) -> [(item: String, chance: Double)] {
        let entry = store.data.usage.first {
            ($0.name == form.formLabel || $0.name == form.name) && $0.hasLiveData
        }
        if form.isMega || !form.megaStone.isEmpty {
            // A Mega has no choice: it holds its stone or it is not a Mega.
            return [(form.megaStone.isEmpty ? "Mega Stone" : form.megaStone, 1)]
        }
        guard let rows = entry?.itemUsage, !rows.isEmpty else {
            return [("Leftovers", 1)]
        }
        let total = rows.reduce(0.0) { $0 + $1.percent }
        guard total > 0 else { return [("Leftovers", 1)] }
        return rows.prefix(3).map { ($0.name, $0.percent / total) }
    }

    /// A handful of plausible versions of the board, with how likely each is.
    ///
    /// Only the unrevealed parts differ. The first world is always the most
    /// likely one, so a search that runs out of time has still looked at the
    /// version of events most worth looking at.
    func imagine(_ board: Board, belief: Belief) -> [(board: Board, chance: Double)] {
        // Each world remembers which back two it assumed, so the handful kept
        // at the end can be made to disagree about that and not only about
        // items — the likeliest three versions of a board otherwise all carry
        // the same bench and differ by a Sitrus Berry.
        var out: [(board: Board, chance: Double, bench: String)] = [(board, 1, "")]
        // Their back two, which nobody has seen. The truth on the board is
        // replaced by each of the likeliest pairs, so the search never plays
        // against a Pokémon it has no business knowing about.
        let hidden = board.theirUnseenBench
        let guesses = board.liveBenchGuesses
        if !hidden.isEmpty, !guesses.isEmpty {
            let shown = Set(board.theirs.filter(\.seen).map(\.build.form.id))
            var next: [(Board, Double, String)] = []
            for guess in guesses.prefix(worlds) {
                var copy = board
                let arriving = guess.fighters.filter { !shown.contains($0.build.form.id) }
                for (slot, fighter) in zip(hidden, arriving) { copy.theirs[slot] = fighter }
                next.append((copy, guess.chance, arriving.map(\.build.form.id).joined(separator: "+")))
            }
            out = next
        }
        // Their actives, whose items are the thing that changes a turn most.
        for slot in 0..<min(board.activeCount, board.theirs.count) {
            let fighter = board.theirs[slot]
            let id = fighter.build.form.id
            guard belief.revealedItems[id] == nil else { continue }
            let odds = itemOdds(for: fighter.build.form)
            guard odds.count > 1 else { continue }
            var next: [(Board, Double, String)] = []
            for (world, chance, bench) in out {
                for guess in odds.prefix(worlds) {
                    var copy = world
                    copy.theirs[slot].build.item = guess.item
                    copy.theirs[slot].build.itemSpent = false
                    next.append((copy, chance * guess.chance, bench))
                }
            }
            out = next
        }
        let ranked = out.sorted { $0.chance > $1.chance }
        // Likeliest first, then the best version of a *different* back two, so
        // a switch is judged against more than one idea of who is behind;
        // whatever room is left goes to the next likeliest of anything.
        var kept: [(board: Board, chance: Double)] = []
        var benches: Set<String> = []
        var used: Set<Int> = []
        for (index, world) in ranked.enumerated() where kept.count < worlds && benches.count < 2 {
            guard !benches.contains(world.bench) else { continue }
            benches.insert(world.bench); used.insert(index)
            kept.append((world.board, world.chance))
        }
        for (index, world) in ranked.enumerated() where kept.count < worlds && !used.contains(index) {
            used.insert(index)
            kept.append((world.board, world.chance))
        }
        return kept.sorted { $0.chance > $1.chance }
    }

    // MARK: - The search

    /// What came back, and how far it got.
    struct Result {
        let mix: [Double]
        let plays: [Play]
        let value: Double
        let depth: Int
        let nodes: Int
        /// The line it expects, this turn and the turns it looked at after.
        let principal: [String]
        /// How much the value moved between the shallowest and deepest pass. A
        /// line whose worth changes a lot with depth is one to distrust.
        let drift: Double
        /// Spread of the value across the worlds it imagined. Wide means the
        /// answer depends on something nobody can see.
        let uncertainty: Double
    }

    private final class Table {
        var values: [String: Double] = [:]
        /// The one-turn solution of each position seen, kept because the
        /// deeper passes use it to decide which lines are worth following.
        var shallow: [String: TurnGame.Solution] = [:]
        var nodes = 0
    }

    /// Think about the position for as long as the budget allows.
    func think(_ board: Board, belief: Belief = Belief()) -> Result {
        let deadline = Date().addingTimeInterval(budget)
        let table = Table()
        let versions = imagine(board, belief: belief)

        var best: Result?
        var shallowValue: Double?
        // Iterative deepening: a usable answer at every depth, and the deepest
        // one that finished before the clock ran out is the one returned.
        for depth in 1...maxDepth {
            var mixes: [[Double]] = []
            var plays: [Play] = []
            var values: [Double] = []
            var ranOut = false

            for (world, chance) in versions {
                guard Date() < deadline else { ranOut = true; break }
                var game = TurnGame(board: world, store: store)
                game.width = beam + 2
                let solved = solve(world, game: game, depth: depth,
                                   deadline: deadline, table: table)
                mixes.append(solved.mix)
                plays = solved.plays
                values.append(solved.value * chance)
            }
            // Out of time with nothing finished at this depth: stop, and return
            // whatever the last depth gave. Out of time with *some* worlds
            // finished: the first world is always the likeliest, so a partial
            // average over the worlds that did finish is a real answer and is
            // kept. This used to discard every finished world and hand back an
            // empty result whenever the machine was a little slow, which read
            // on screen as the engine having no opinion at all.
            if values.isEmpty || plays.isEmpty { break }
            let finishedAll = !ranOut

            // Average the mixes across worlds, weighted by how likely each is.
            let weight = versions.prefix(mixes.count).reduce(0) { $0 + $1.chance }
            var blended = [Double](repeating: 0, count: plays.count)
            for (index, mix) in mixes.enumerated() {
                let share = versions[index].chance / max(weight, 0.0001)
                for slot in 0..<min(blended.count, mix.count) {
                    blended[slot] += mix[slot] * share
                }
            }
            let total = blended.reduce(0, +)
            if total > 0 { blended = blended.map { $0 / total } }

            let value = values.reduce(0, +) / max(weight, 0.0001)
            let spread = values.count > 1
                ? (values.map { $0 / max(weight, 0.0001) }.max() ?? 0)
                  - (values.map { $0 / max(weight, 0.0001) }.min() ?? 0)
                : 0
            if shallowValue == nil { shallowValue = value }
            best = Result(mix: blended, plays: plays, value: value, depth: depth,
                          nodes: table.nodes,
                          principal: variation(board, plays: plays, mix: blended,
                                               depth: depth, table: table,
                                               deadline: deadline),
                          drift: value - (shallowValue ?? value),
                          uncertainty: spread)
            if !finishedAll { break }
        }
        return best ?? Result(mix: [1], plays: [Play(left: .pass, right: .pass)],
                              value: 0, depth: 0, nodes: 0, principal: [],
                              drift: 0, uncertainty: 0)
    }

    /// The one-turn solution of a position, computed once.
    private func shallow(_ board: Board, game: TurnGame, table: Table) -> TurnGame.Solution {
        let key = signature(board) + "#\(game.width)\(game.assumeMega)"
        if let known = table.shallow[key] { return known }
        let solved = game.solve(iterations: 900)
        table.shallow[key] = solved
        return solved
    }

    /// The lines worth following: the ones the one-turn equilibrium plays,
    /// likeliest first. Following the first few in list order instead — which
    /// is what this did — meant the deep search only ever considered attacking
    /// with both, and found switching and Protect exactly never.
    private func beamed(_ mix: [Double], count: Int) -> [Int] {
        Array(mix.indices.sorted { mix[$0] > mix[$1] || (mix[$0] == mix[$1] && $0 < $1) }
                .prefix(count))
    }

    /// One node: build the matrix, score each cell by looking deeper, solve.
    /// The mix comes back over every play the position offers, with zero on
    /// the ones the beam left out, so mixes from different worlds line up.
    private func solve(_ board: Board, game: TurnGame, depth: Int,
                       deadline: Date, table: Table)
        -> (mix: [Double], plays: [Play], value: Double) {
        // At the leaf, the turn's own equilibrium is the evaluation. Scoring a
        // position by counting health says a board where every line loses is
        // fine as long as nobody has been hit yet.
        let leaf = shallow(board, game: game, table: table)
        let mine = leaf.myPlays
        let theirs = leaf.theirPlays
        guard !mine.isEmpty, !theirs.isEmpty else { return ([1], [Play(left: .pass, right: .pass)], 0) }
        if depth <= 1 || Date() >= deadline {
            return (leaf.myMix, mine, leaf.value)
        }

        let myBeam = beamed(leaf.myMix, count: beam)
        let theirBeam = beamed(leaf.theirMix, count: beam)
        let keptMine = myBeam.map { mine[$0] }
        let keptTheirs = theirBeam.map { theirs[$0] }
        var payoff = [[Double]](repeating: [Double](repeating: 0, count: keptTheirs.count),
                                count: keptMine.count)
        for (i, my) in keptMine.enumerated() {
            for (j, their) in keptTheirs.enumerated() {
                // Weighed over every way the turn can come out; the search
                // then looks on from the likeliest of them.
                let settled = game.settle(my, their)
                var after = settled.likeliest
                after.fillGaps()
                table.nodes += 1
                let immediate = settled.expected
                // A side with nothing left has lost; no need to look further.
                if after.isOut(mine: false) { payoff[i][j] = immediate + 3; continue }
                if after.isOut(mine: true) { payoff[i][j] = immediate - 3; continue }

                let key = signature(after) + "@\(depth)"
                if let cached = table.values[key] {
                    payoff[i][j] = immediate + 0.75 * cached
                    continue
                }
                var next = TurnGame(board: after, store: store)
                next.width = beam
                next.assumeMega = true
                let deeper = solve(after, game: next, depth: depth - 1,
                                   deadline: deadline, table: table)
                table.values[key] = deeper.value
                // Discounted, because a turn in hand is worth more than one
                // promised, and the deeper the guess the softer it should land.
                payoff[i][j] = immediate + 0.75 * deeper.value
            }
        }
        let (beamMix, _, value) = TurnGame.equilibrium(payoff, iterations: 900)
        var mix = [Double](repeating: 0, count: mine.count)
        for (slot, index) in myBeam.enumerated() where slot < beamMix.count {
            mix[index] = beamMix[slot]
        }
        return (mix, mine, value)
    }

    /// Enough of a position to recognise it again. Everything a turn's answer
    /// depends on has to be in here, because a solution is now remembered by
    /// it: two boards that differ only in the weather, or in whether a
    /// Pokémon came in this turn, get different answers and must not share one.
    private func signature(_ board: Board) -> String {
        func side(_ team: [Fighter]) -> String {
            var out = ""
            for fighter in team {
                out += "\(fighter.build.form.id):\(fighter.hp):\(fighter.status)"
                out += fighter.justArrived ? "a" : fighter.protectedLast ? "p" : "-"
                out += fighter.pendingMega == nil ? "" : "m"
                out += "\(fighter.build.boosts)\(fighter.build.itemSpent ? "s" : ""),"
            }
            return out
        }
        return side(board.mine) + "|" + side(board.theirs)
            + "|\(board.field.weather)\(board.field.terrain)"
            + "\(board.myTailwind)\(board.theirTailwind)\(board.trickRoom)"
            + "\(board.myScreens.reflect)\(board.myScreens.lightScreen)\(board.myScreens.auroraVeil)"
            + "\(board.theirScreens.reflect)\(board.theirScreens.lightScreen)\(board.theirScreens.auroraVeil)"
    }

    /// The line it is actually expecting, written out.
    private func variation(_ board: Board, plays: [Play], mix: [Double], depth: Int,
                           table: Table, deadline: Date) -> [String] {
        guard let first = mix.indices.max(by: { mix[$0] < mix[$1] }),
              plays.indices.contains(first) else { return [] }
        var out: [String] = []
        var current = board
        var play = plays[first]
        for turn in 0..<min(depth, 3) {
            var game = TurnGame(board: current, store: store)
            game.width = turn == 0 ? beam + 2 : beam
            game.assumeMega = turn > 0
            let solved = shallow(current, game: game, table: table)
            let theirs = solved.theirPlays
            let theirBest = solved.theirMix.indices.max { solved.theirMix[$0] < solved.theirMix[$1] }
            let theirPlay = theirBest.flatMap { theirs.indices.contains($0) ? theirs[$0] : nil }
                ?? Play(left: .pass, right: .pass)
            out.append("Turn \(turn + 1): \(game.describe(play, mine: true))"
                       + " — they answer \(game.describe(theirPlay, mine: false))")
            var after = TurnModel.resolve(current, mine: play, theirs: theirPlay, store: store, narrating: false)
            after.fillGaps()
            if after.isOut(mine: true) || after.isOut(mine: false) { break }
            current = after
            var nextGame = TurnGame(board: current, store: store)
            nextGame.width = beam
            nextGame.assumeMega = true
            let nextSolved = shallow(current, game: nextGame, table: table)
            guard let pick = nextSolved.myMix.indices.max(by: {
                nextSolved.myMix[$0] < nextSolved.myMix[$1] }),
                nextSolved.myPlays.indices.contains(pick) else { break }
            play = nextSolved.myPlays[pick]
        }
        return out
    }
}
