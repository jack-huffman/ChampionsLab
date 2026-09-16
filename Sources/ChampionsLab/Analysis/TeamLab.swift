//  TeamLab.swift
//  Thousands of real games, played to find out what a team actually does.
//
//  The matchup grid answers "who beats whom on paper". This answers the
//  question paper cannot: put the team on the field a few thousand times
//  against the field it will meet, and write down what happened.
//
//  What comes out is the sort of thing that is invisible until it is counted:
//
//    * A Pokémon that dies twice for every knockout it takes. Its type chart
//      looks fine; it is still losing the team games.
//    * The four that wins 53% and the four that wins 19%, from the same six.
//      That is a team-preview decision worth more than any rebuild.
//    * The move nobody ever chooses, which is a slot doing nothing.
//    * The team you have never beaten.
//
//  Every game is the real turn model with the real engine in both chairs, the
//  same one the battle screen plays. No shortcuts and no scoring function
//  standing in for a game — the only difference is that nobody is watching.

import Foundation

enum TeamLab {
    /// One Pokémon's record across every game it appeared in.
    struct Record: Codable, Sendable {
        var games = 0
        var brought = 0
        var survived = 0
        var faints = 0
        var knockouts = 0
        var damageDealt = 0
        var damageTaken = 0
        var moves: [String: Int] = [:]

        /// Knockouts against faints. Around one is an even trade; a Pokémon
        /// well under it is costing more than it brings, whatever its typing
        /// says.
        var trade: Double { Double(knockouts) / Double(Swift.max(1, faints)) }
        var broughtShare: Double { Double(brought) / Double(Swift.max(1, games)) }
    }

    /// What a run found out.
    struct Report: Codable, Sendable {
        var team = ""
        var games = 0
        var wins = 0
        var draws = 0
        var turns = 0
        var members: [String: Record] = [:]
        /// Each four the picker chose, as [wins, games].
        var brings: [String: [Int]] = [:]
        /// Each opposing team, as [wins, games].
        var against: [String: [Int]] = [:]
        var seconds: Double = 0
        /// How many separate runs went into this. Evidence accumulates: four
        /// hundred games on Monday and four hundred on Tuesday is eight
        /// hundred games of the same team, and throwing the first away because
        /// the second finished would be a strange way to learn anything.
        var runs = 1

        /// Add another run of the same team to this one.
        ///
        /// Only ever called where the team is known to be unchanged — the
        /// stamp on the stored entry is what establishes that — because
        /// pooling games from two different teams would produce a number that
        /// describes neither.
        func merged(with other: Report) -> Report {
            var out = self
            out.games += other.games
            out.wins += other.wins
            out.draws += other.draws
            out.turns += other.turns
            out.seconds += other.seconds
            out.runs += other.runs
            for (form, record) in other.members {
                var mine = out.members[form] ?? Record()
                mine.games += record.games
                mine.brought += record.brought
                mine.survived += record.survived
                mine.faints += record.faints
                mine.knockouts += record.knockouts
                mine.damageDealt += record.damageDealt
                mine.damageTaken += record.damageTaken
                for (move, count) in record.moves { mine.moves[move, default: 0] += count }
                out.members[form] = mine
            }
            for (four, pair) in other.brings {
                var mine = out.brings[four] ?? [0, 0]
                mine[0] += pair[0]; mine[1] += pair[1]
                out.brings[four] = mine
            }
            for (foe, pair) in other.against {
                var mine = out.against[foe] ?? [0, 0]
                mine[0] += pair[0]; mine[1] += pair[1]
                out.against[foe] = mine
            }
            return out
        }

        var winRate: Double { Double(wins) / Double(Swift.max(1, games)) }
        var turnsPerGame: Double { Double(turns) / Double(Swift.max(1, games)) }

        /// Members that actually played, worst trade first — which is the
        /// order somebody wanting to improve the team should read them in.
        var byTrade: [(form: String, record: Record)] {
            members.filter { $0.value.games >= Swift.max(4, games / 20) }
                .sorted { $0.value.trade < $1.value.trade }
                .map { (form: $0.key, record: $0.value) }
        }

        /// Fours with enough games behind them to mean something.
        func fours(least: Int) -> [(four: String, wins: Int, games: Int)] {
            brings.filter { $0.value[1] >= least }
                .sorted { Double($0.value[0]) / Double($0.value[1])
                          > Double($1.value[0]) / Double($1.value[1]) }
                .map { (four: $0.key, wins: $0.value[0], games: $0.value[1]) }
        }

        func matchups(least: Int) -> [(foe: String, wins: Int, games: Int)] {
            against.filter { $0.value[1] >= least }
                .sorted { Double($0.value[0]) / Double($0.value[1])
                          < Double($1.value[0]) / Double($1.value[1]) }
                .map { (foe: $0.key, wins: $0.value[0], games: $0.value[1]) }
        }

        /// Moves the team carries and the engine never reaches for.
        var quietMoves: [(move: String, uses: Int)] {
            var used: [String: Int] = [:]
            for (_, record) in members {
                for (move, count) in record.moves { used[move, default: 0] += count }
            }
            return used.sorted { $0.value < $1.value }.map { (move: $0.key, uses: $0.value) }
        }
    }

    /// How far along a run is, for something to show while it works.
    struct Progress: Sendable {
        let played: Int
        let of: Int
        let wins: Int
        let against: String
    }

    /// Play `games` of one team against a field, and write down all of it.
    ///
    /// Opponents are cycled rather than drawn at random, so a run of any
    /// length covers the field evenly instead of over-sampling whoever the
    /// dice liked. Each pairing is played from both chairs for the same
    /// reason the harness does it: the chair is worth something on its own and
    /// splitting it evenly takes it out of the answer.
    ///
    /// `shouldStop` is checked between games. The caller owns the cancelling;
    /// this only promises to notice.
    ///
    /// `resumeFrom` is how many games of this team are already on record, and
    /// it matters more than it looks. Both the dice and the opponent cycle are
    /// driven off the game's position in the sequence, so starting every run at
    /// zero would replay the identical games — and pooling a run with a copy of
    /// itself is not eight hundred games of evidence, it is four hundred games
    /// counted twice. Carrying the count forward makes a second run genuinely
    /// new games, and continues around the field rather than restarting at the
    /// same opponent.
    static func run(team: Team, against field: [Team], rules: Rulebook,
                    games: Int, budget: Double, seed: UInt64 = 20_260_915,
                    resumeFrom: Int = 0,
                    progress: ((Progress) -> Void)? = nil,
                    shouldStop: () -> Bool = { false }) -> Report {
        var report = Report()
        report.team = team.name
        guard !field.isEmpty, team.slots.count >= 4 else { return report }
        let started = Date()
        let engine = BattleEngine(rules: rules, budget: budget)
        let seat = SelfPlay.Seat(engine: engine, branchedRolls: 1)

        var played = 0
        var order = resumeFrom
        while played < games {
            if shouldStop() { break }
            let foe = field[(order / 2) % field.count]
            let mineFirst = order % 2 == 0
            order += 1

            let dice = SplitMix(seed: seed &+ UInt64(order) &* 0x9E37_79B9_7F4A_7C15)
            let ledger = SelfPlay.playLogged(
                mine: mineFirst ? team : foe, theirs: mineFirst ? foe : team,
                rules: rules, forMine: seat, forTheirs: seat,
                limit: 40, dice: dice,
                // Several of the ranked fours, so the report can say which one
                // works rather than replaying the picker's favourite forever.
                bringSpread: 6)

            let won = mineFirst ? ledger.winner == .mine : ledger.winner == .theirs
            let drew = ledger.winner == .none
            let mineTallies = mineFirst ? ledger.mine : ledger.theirs
            let picked = mineFirst ? ledger.pickedMine : ledger.pickedTheirs

            report.games += 1
            if won { report.wins += 1 }
            if drew { report.draws += 1 }
            report.turns += ledger.turns
            var pair = report.against[foe.name] ?? [0, 0]
            pair[0] += won ? 1 : 0; pair[1] += 1
            report.against[foe.name] = pair
            if !picked.isEmpty {
                let four = picked.sorted().joined(separator: " + ")
                var seen = report.brings[four] ?? [0, 0]
                seen[0] += won ? 1 : 0; seen[1] += 1
                report.brings[four] = seen
            }
            for (form, tally) in mineTallies {
                var record = report.members[form] ?? Record()
                record.games += 1
                record.brought += tally.brought
                record.survived += tally.survived
                record.faints += tally.faints
                record.knockouts += tally.knockouts
                record.damageDealt += tally.damageDealt
                record.damageTaken += tally.damageTaken
                for (move, count) in tally.moves { record.moves[move, default: 0] += count }
                report.members[form] = record
            }

            played += 1
            if played % 10 == 0 || played == games {
                progress?(Progress(played: played, of: games,
                                   wins: report.wins, against: foe.name))
            }
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    /// A small seedable generator, so a run can be repeated exactly.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
