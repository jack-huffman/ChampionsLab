//  TurnRead.swift
//  What a read on your opponent is actually worth.
//
//  TurnGame solves the turn for its equilibrium, which is the mix that cannot
//  be exploited however well somebody reads you. That is the right answer when
//  you know nothing about the person across the table, and it is emphatically
//  not what strong players do once they know something. Equilibrium is a floor.
//  Winning comes from leaving it deliberately.
//
//  So this is the other half. Given a tendency you believe an opponent has —
//  they protect too much, they never switch, they always aim at the biggest
//  threat — it works out the line that punishes it, what punishing it is worth,
//  and, the part nobody ever says out loud, what it costs when the read is
//  wrong. Acting on a read makes you exploitable in turn; that is the trade,
//  and it should be a number rather than a feeling.
//
//  It also answers the question underneath all of it: is this a turn where
//  reading them matters at all? Some turns play themselves — every line is
//  worth about the same and information buys nothing. Others swing a whole
//  Pokemon on a guess. The value of knowing their choice in advance separates
//  the two, and tells you which turns to spend your attention on.

import Foundation

extension TurnGame {

    /// A tendency you think you have spotted.
    ///
    /// Deliberately the shapes people actually describe out loud, rather than a
    /// probability distribution nobody could fill in honestly.
    enum Read: String, CaseIterable, Identifiable {
        case protectsOften = "They protect more than they should"
        case neverProtects = "They never protect"
        case alwaysAttacks = "They always attack, never set up"
        case switchesOut   = "They switch out of bad matchups"
        case goesForTheBig = "They always aim at the biggest threat"

        var id: String { rawValue }

        var shorthand: String {
            switch self {
            case .protectsOften: return "protects too much"
            case .neverProtects: return "never protects"
            case .alwaysAttacks: return "always attacks"
            case .switchesOut:   return "switches a lot"
            case .goesForTheBig: return "aims at the biggest threat"
            }
        }

        /// The same, after "they": "if they aim at", not "if they aims at".
        var afterThey: String {
            switch self {
            case .protectsOften: return "protect too much"
            case .neverProtects: return "never protect"
            case .alwaysAttacks: return "always attack"
            case .switchesOut:   return "switch a lot"
            case .goesForTheBig: return "aim at the biggest threat"
            }
        }
    }

    /// Whether one of their plays fits the tendency.
    private func fits(_ play: Play, _ read: Read, biggest: Int) -> Bool {
        func targets(_ choice: Choice) -> Int? {
            if case .attack(_, let target) = choice { return target }
            return nil
        }
        switch read {
        case .protectsOften: return play.left.isProtect || play.right.isProtect
        case .neverProtects: return !play.left.isProtect && !play.right.isProtect
        case .alwaysAttacks: return !play.left.isProtect && !play.right.isProtect
            && !play.left.isSwap && !play.right.isSwap
        case .switchesOut:   return play.left.isSwap || play.right.isSwap
        case .goesForTheBig:
            return targets(play.left) == biggest || targets(play.right) == biggest
        }
    }

    /// Which of mine they would call the biggest threat: the one that takes the
    /// most off them in a turn.
    private var biggestThreat: Int {
        var best = 0
        var bestShare = -1.0
        for slot in 0..<min(2, board.mine.count) {
            let share = board.mine[slot].moves
                .filter(\.isDamaging)
                .map { move -> Double in
                    board.theirs.prefix(2).map { foe in
                        Double(DamageCalc.calculate(attacker: board.mine[slot].build,
                                                    defender: foe.build, move: move,
                                                    field: board.field).maxDamage)
                            / Double(max(1, foe.maxHP))
                    }.max() ?? 0
                }
                .max() ?? 0
            if share > bestShare { bestShare = share; best = slot }
        }
        return best
    }

    /// Their distribution once the tendency is believed.
    ///
    /// A blend rather than a replacement: at strength zero this is the
    /// equilibrium and at one they always do the thing. Anything in between is
    /// how sure you are, which is the honest way to hold a read.
    func mix(_ solution: Solution, assuming read: Read, strength: Double) -> [Double] {
        let biggest = biggestThreat
        let matching = solution.theirPlays.map { fits($0, read, biggest: biggest) }
        let count = matching.filter { $0 }.count
        guard count > 0, count < solution.theirPlays.count else { return solution.theirMix }
        let share = 1.0 / Double(count)
        let pull = min(1, max(0, strength))
        return solution.theirMix.enumerated().map { index, base in
            (1 - pull) * base + pull * (matching[index] ? share : 0)
        }
    }

    /// The best single line against a given distribution, and what it is worth.
    func bestResponse(_ solution: Solution, to theirs: [Double]) -> (index: Int, value: Double) {
        var best = 0, bestValue = -Double.infinity
        for i in solution.payoff.indices {
            let value = zip(solution.payoff[i], theirs).reduce(0) { $0 + $1.0 * $1.1 }
            if value > bestValue { bestValue = value; best = i }
        }
        return (best, bestValue)
    }

    /// What acting on a read gains, and what it costs when the read is wrong.
    struct Exploit: Identifiable {
        let read: Read
        let play: Play
        let label: String
        /// Worth of the punishing line against the tendency.
        let against: Double
        /// Worth of playing the equilibrium instead, against that same tendency.
        let equilibrium: Double
        /// Worth of the punishing line if the read is wrong and they are at
        /// equilibrium after all.
        let ifWrong: Double
        /// Worth of the equilibrium line when the read is wrong, which is the
        /// thing being given up.
        let safeIfWrong: Double

        var gain: Double { against - equilibrium }
        var cost: Double { safeIfWrong - ifWrong }
        /// Worth taking when it gains more than it risks.
        var worthIt: Bool { gain > cost }
        var id: String { read.rawValue }
    }

    func exploits(_ solution: Solution, strength: Double = 0.75) -> [Exploit] {
        // What the equilibrium line is worth, for comparison. Chosen once.
        let equilibriumIndex = solution.myMix.indices.max {
            solution.myMix[$0] < solution.myMix[$1] } ?? 0
        func worth(_ row: Int, against mix: [Double]) -> Double {
            zip(solution.payoff[row], mix).reduce(0) { $0 + $1.0 * $1.1 }
        }
        return Read.allCases.compactMap { read in
            let tilted = mix(solution, assuming: read, strength: strength)
            guard tilted != solution.theirMix else { return nil }
            let response = bestResponse(solution, to: tilted)
            guard response.index != equilibriumIndex else { return nil }
            return Exploit(read: read,
                           play: solution.myPlays[response.index],
                           label: describe(solution.myPlays[response.index], mine: true),
                           against: response.value,
                           equilibrium: worth(equilibriumIndex, against: tilted),
                           ifWrong: worth(response.index, against: solution.theirMix),
                           safeIfWrong: worth(equilibriumIndex, against: solution.theirMix))
        }
        .sorted { $0.gain > $1.gain }
    }

    /// What their choice is worth knowing before you commit.
    struct Tell: Identifiable {
        let play: Play
        let label: String
        /// How likely they are to do it at equilibrium.
        let likelihood: Double
        /// What knowing it in advance would be worth over playing the mix.
        let worthKnowing: Double
        var id: String { label }
    }

    /// The turn's information value, and where it is concentrated.
    ///
    /// Some turns play themselves — every line is worth about the same and
    /// there is nothing to read. Others turn a whole Pokemon on a guess. The
    /// difference is what knowing their choice in advance would buy, and it is
    /// the number that says whether to spend your attention here.
    func tells(_ solution: Solution) -> (value: Double, top: [Tell]) {
        var total = 0.0
        var out: [Tell] = []
        for (j, play) in solution.theirPlays.enumerated() {
            let best = solution.payoff.indices.map { solution.payoff[$0][j] }.max() ?? 0
            total += solution.theirMix[j] * best
            guard solution.theirMix[j] > 0.01 else { continue }
            out.append(Tell(play: play, label: describe(play, mine: false),
                            likelihood: solution.theirMix[j],
                            worthKnowing: best - solution.value))
        }
        return (total - solution.value, out.sorted { $0.worthKnowing > $1.worthKnowing })
    }

    /// The reading half of the turn, in sentences.
    func readingNotes(_ solution: Solution) -> [String] {
        var out: [String] = []
        let information = tells(solution)
        if information.value < 0.08 {
            out.append(String(format: "Knowing their choice in advance would be worth only %+.2f. This turn plays itself — save the read for one that matters.", information.value))
        } else {
            out.append(String(format: "Knowing their choice in advance is worth %+.2f, so this is a turn where the read decides it.", information.value))
        }
        if let sharpest = information.top.first, sharpest.worthKnowing > 0.1 {
            out.append(String(format: "The thing to watch for is %@ — they do it about %.0f%% of the time, and spotting it is worth %+.2f.",
                              sharpest.label, sharpest.likelihood * 100, sharpest.worthKnowing))
        }
        // When every tendency points at the same line, that line is not an
        // exploit — it is simply the best move, and calling it five separate
        // reads would be five findings where there is one. Saying so is more
        // useful than the list: it means stop guessing and click it.
        let worthwhile = exploits(solution).filter { $0.gain > 0.05 }
        let distinct = Set(worthwhile.map(\.label))
        if distinct.count == 1, worthwhile.count >= 3, let only = worthwhile.first {
            out.append(String(format: "No read changes the answer here: %@ is the best response to every tendency they might have, worth %+.2f. Play it and save the guessing for a turn that needs it.",
                              only.label, only.against))
        } else {
            var said = Set<String>()
            for exploit in worthwhile {
                guard said.insert(exploit.label).inserted else { continue }
                out.append(String(format: "If they %@: %@ punishes it for %+.2f, %+.2f better than playing the mix. Being wrong costs %.2f, so it is %@.",
                                  exploit.read.afterThey, exploit.label, exploit.against,
                                  exploit.gain, exploit.cost,
                                  exploit.worthIt ? "worth taking" : "not worth it yet"))
                if said.count >= 2 { break }
            }
        }
        return out
    }
}
