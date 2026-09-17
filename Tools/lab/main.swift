//  Tools/lab/main.swift
//  Games at scale, with everything they did written down.
//
//      ./Tools/lab.sh                       the whole field, a few games each
//      ./Tools/lab.sh --games 600           more of them
//      ./Tools/lab.sh --team "Sun / Dual Mega"   one team against the field
//      ./Tools/lab.sh --budget 0.02         faster and shallower
//      ./Tools/lab.sh --vs "Big Six" "Dual Mega Rain"   two teams, head to head
//      ./Tools/lab.sh --team "Mega Bax" --line "A,B,C,D"     one line, pinned
//      ./Tools/lab.sh --team "Mega Bax" --compare "A,B,C,D" "A,B,E,F"
//                                            the main line against the other one
//      ./Tools/lab.sh --json out.json       the numbers, for something else
//
//  Why this exists.
//
//  `make accuracy` reads 1,455 real results and asks one question: given two
//  team lists, who won. It cannot see a turn, which is why it reported the
//  same 5.2 no matter what the battle model did — Double Hit at half damage,
//  burn at the wrong multiplier, Sticky Web doing nothing at all. Every one of
//  those was invisible to it.
//
//  `make duel` plays real games but only counts wins, so it answers "is engine
//  A better than engine B" and nothing else.
//
//  This plays real games — the same turn model, the same engine, the same
//  dice — and writes down what happened inside them. Who was brought, what
//  they used, what they killed, what killed them. That is the raw material for
//  every question worth asking:
//
//    * Which teams are actually good, and which are good only on paper.
//    * Which Pokémon on a team carry it, and which are passengers.
//    * Which moves never get chosen, which is a slot the team is wasting.
//    * Which Pokémon a team cannot beat, which is the hole in it.
//
//  On speed. The engine thinks for a time budget per decision, and that
//  budget is the whole cost of a game: a 12-turn game at 0.3s is about seven
//  seconds. The lab defaults to a much shorter budget because the question
//  here is about teams and moves rather than about deep play, and a shallow
//  engine still plays a real game. Raise it with --budget when the question
//  is about the engine itself.
//
//  On parallelism. `Dice.source` and `branchedRolls` are global, so two
//  games cannot share a process. The lab shards across child processes
//  instead: each runs a slice, writes its ledger as JSON, and the parent adds
//  them up. That needs no change to the engine and uses every core.

import Foundation

// MARK: - Arguments

func flag(_ name: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: name),
          at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}
func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

// MARK: - What a run adds up to

/// One Pokémon's record across every game it appeared in.
struct Record: Codable {
    var games = 0
    var wins = 0
    var brought = 0
    var survived = 0
    var faints = 0
    var knockouts = 0
    var damageDealt = 0
    var damageTaken = 0
    var moves: [String: Int] = [:]

    mutating func add(_ other: Record) {
        games += other.games; wins += other.wins
        brought += other.brought; survived += other.survived
        faints += other.faints; knockouts += other.knockouts
        damageDealt += other.damageDealt; damageTaken += other.damageTaken
        for (move, count) in other.moves { moves[move, default: 0] += count }
    }
}

/// One team's record, and each of its Pokémon.
struct TeamRecord: Codable {
    var name = ""
    var games = 0
    var wins = 0
    var draws = 0
    var turns = 0
    var members: [String: Record] = [:]
    /// Wins and games against each other team, which is where a hole shows.
    var against: [String: [Int]] = [:]
    /// What beat this team's Pokémon, by the opposing Pokémon that did it.
    var killedBy: [String: Int] = [:]
    /// Each four this team chose at preview, as [wins, games]. The point of a
    /// head-to-head: which of the fifteen fours actually wins, measured rather
    /// than ranked by the picker's own scoring.
    var brings: [String: [Int]] = [:]

    mutating func add(_ other: TeamRecord) {
        if name.isEmpty { name = other.name }
        games += other.games; wins += other.wins; draws += other.draws
        turns += other.turns
        for (form, record) in other.members {
            members[form, default: Record()].add(record)
        }
        for (foe, pair) in other.against {
            var mine = against[foe] ?? [0, 0]
            mine[0] += pair[0]; mine[1] += pair[1]
            against[foe] = mine
        }
        for (form, count) in other.killedBy { killedBy[form, default: 0] += count }
        for (four, pair) in other.brings {
            var mine = brings[four] ?? [0, 0]
            mine[0] += pair[0]; mine[1] += pair[1]
            brings[four] = mine
        }
    }
}

/// What the picker said against what happened.
///
/// Keyed by the rank the picker gave the four that was played, so it pools
/// across every pairing: if the ranking carries information, rank one should
/// win more often than rank eight over a few thousand games. Keyed by score
/// band as well, because a rank is only an order while a score claims a size.
struct Calibration: Codable {
    /// rank -> [wins, games]
    var byRank: [String: [Int]] = [:]
    /// score band, in tens -> [wins, games]
    var byScore: [String: [Int]] = [:]
    /// Every (pairing, rank) seen, so the best-four regret can be worked out.
    /// "team|foe|rank" -> [wins, games]
    var byPairing: [String: [Int]] = [:]

    mutating func add(_ other: Calibration) {
        func merge(_ into: inout [String: [Int]], _ from: [String: [Int]]) {
            for (key, pair) in from {
                var mine = into[key] ?? [0, 0]
                mine[0] += pair[0]; mine[1] += pair[1]
                into[key] = mine
            }
        }
        merge(&byRank, other.byRank)
        merge(&byScore, other.byScore)
        merge(&byPairing, other.byPairing)
    }

    mutating func note(rank: Int, score: Int, team: String, foe: String, won: Bool) {
        guard rank > 0 else { return }
        func bump(_ into: inout [String: [Int]], _ key: String) {
            var pair = into[key] ?? [0, 0]
            pair[0] += won ? 1 : 0
            pair[1] += 1
            into[key] = pair
        }
        bump(&byRank, "\(rank)")
        // Bands of ten, so a score of 37 and one of 34 are the same claim.
        bump(&byScore, "\(Int((Double(score) / 10).rounded(.down)) * 10)")
        bump(&byPairing, "\(team)|\(foe)|\(rank)")
    }
}

struct Report: Codable {
    var teams: [String: TeamRecord] = [:]
    var calibration = Calibration()
    /// Games won by whoever sat in the "mine" chair, and how many were decided.
    /// In an ordinary run this is 50% by construction — every pairing is played
    /// both ways round. In an A/B it is the record of the side being tested.
    var chairWins = 0
    var chairDecided = 0
    var games = 0
    var seconds = 0.0
    /// How many teams were available to draw from, which is not the same as
    /// how many actually got a game in a short run.
    var field = 0

    mutating func add(_ other: Report) {
        for (name, record) in other.teams { teams[name, default: TeamRecord()].add(record) }
        calibration.add(other.calibration)
        chairWins += other.chairWins
        chairDecided += other.chairDecided
        games += other.games
        field = Swift.max(field, other.field)
    }
}

// MARK: - Running games

@MainActor
func runShard(index: Int, of shards: Int, games: Int, budget: Double,
              focus: String?, versus: [String], spread: Int, abTest: Bool,
              stageTest: Bool, winTest: Bool, mineOnly: Bool, floorTest: Bool,
              crude: Bool, level: Bool, learnTest: Bool,
              lines: [[String]], seed: UInt64) -> Report {
    let store = Store.shared
    if let error = store.loadError { FileHandle.standardError.write(Data("dataset: \(error)\n".utf8)); exit(1) }
    let rules = store.rulebook
    // The published lists are built the way the app would build them, rather
    // than with one crude spread for everybody — otherwise a run against your
    // own registered teams is measuring your spreads against nobody's.
    var planner = SpreadPlanner(store: store)
    planner.field = Field(isDoubles: true)
    let field = SelfPlay.teams(from: store.data, rules: rules,
                               planner: crude ? nil : planner)
    // `--mine` puts the teams actually registered in the app on one side and
    // the published field on the other, which is the question an owner of a
    // team has: how does *this* do against what is out there.
    // `--level` throws your own spreads away too and rebuilds them the same
    // way, which answers the other question: how do the *teams* compare when
    // nobody has the advantage of a tuned build.
    var registered = mineOnly ? store.teams.filter { $0.slots.count >= 4 } : []
    if level {
        for index in registered.indices {
            for slot in registered[index].slots.indices {
                guard let form = registered[index].slots[slot].battleForm(in: rules) else { continue }
                let built = planner.plan(for: form,
                                         ability: registered[index].slots[slot].ability,
                                         item: registered[index].slots[slot].item)
                registered[index].slots[slot].sp = built.sp
                registered[index].slots[slot].alignmentName = built.alignment.name
            }
        }
    }
    let teams = mineOnly ? registered + field : field
    guard teams.count >= 2, !(mineOnly && registered.isEmpty) else {
        if mineOnly { FileHandle.standardError.write(Data("no registered teams\n".utf8)) }
        return Report()
    }

    let engine = BattleEngine(rules: rules, budget: budget)
    let seat = SelfPlay.Seat(engine: engine, branchedRolls: 1)

    // Every ordered pair, so both sides of a matchup get played. A pairing is
    // taken by this shard when its number falls in this shard's slice, which
    // spreads the work without the shards having to talk to each other.
    var pairings: [(Int, Int)] = []
    if versus.count == 2 {
        // A head-to-head. Both orderings, so neither team is always the one
        // whose four is chosen first.
        guard let a = teams.firstIndex(where: { $0.name == versus[0] }),
              let b = teams.firstIndex(where: { $0.name == versus[1] }) else {
            FileHandle.standardError.write(Data("no such team: \(versus.joined(separator: " / "))\n".utf8))
            exit(1)
        }
        pairings = [(a, b), (b, a)]
    } else if mineOnly {
        // Every registered team against every published one, both ways round,
        // so each spends equal time in each chair. `--team` narrows it to one
        // of yours, which is what makes a focused or line-pinned run land all
        // its games on the team being asked about rather than the first one.
        for a in 0..<registered.count where focus == nil || registered[a].name == focus {
            for b in registered.count..<teams.count {
                pairings.append((a, b))
                pairings.append((b, a))
            }
        }
    } else {
        for a in teams.indices {
            for b in teams.indices where a != b {
                if let focus, teams[a].name != focus && teams[b].name != focus { continue }
                pairings.append((a, b))
            }
        }
    }
    guard !pairings.isEmpty else { return Report() }

    // -- learning from your own record, measured on games it has not seen ----
    //
    // The app lets a team's measured record move the bring-four ranking. This
    // asks whether that is worth anything, and the only honest way to ask is a
    // split: learn the fours from one block of games, then judge on a second
    // block the learning has never met. Fitting and judging on the same games
    // is how the bring-rate prior looked like a clear win and turned out to be
    // mostly overfitting.
    var learned: [String: [String: (wins: Int, games: Int)]] = [:]
    if learnTest {
        var training: [String: [String: [Int]]] = [:]
        let trainingGames = Swift.max(40, games / 2)
        var trained = 0, at = 0
        while trained < trainingGames {
            let (a, b) = pairings[at % pairings.count]
            at += 1
            let dice = SplitMix64(seed: seed &+ UInt64(at) &* 0x9E37_79B9_7F4A_7C15)
            let ledger = SelfPlay.playLogged(
                mine: teams[a], theirs: teams[b], rules: rules,
                forMine: seat, forTheirs: seat, limit: 40, dice: dice, bringSpread: spread)
            for (name, picked, won) in [(teams[a].name, ledger.pickedMine, ledger.winner == .mine),
                                        (teams[b].name, ledger.pickedTheirs, ledger.winner == .theirs)]
            where !picked.isEmpty {
                let four = picked.sorted().joined(separator: " + ")
                var pair = training[name]?[four] ?? [0, 0]
                pair[0] += won ? 1 : 0; pair[1] += 1
                training[name, default: [:]][four] = pair
            }
            trained += 1
            if trained % 40 == 0 {
                FileHandle.standardError.write(
                    Data("    shard \(index): learning \(trained)/\(trainingGames)\n".utf8))
            }
        }
        for (name, fours) in training {
            learned[name] = fours.filter { $0.value[1] >= 8 }
                .mapValues { (wins: $0[0], games: $0[1]) }
        }
    }

    // With two lines given, the run alternates between them so both meet the
    // same opponents in the same conditions — otherwise the comparison is
    // partly a comparison of which half of the field each happened to draw.
    func lineFor(_ name: String, _ index: Int) -> [String]? {
        guard !lines.isEmpty, name == focus else { return nil }
        return lines[index % lines.count]
    }

    var report = Report()
    var played = 0
    // Start past the training block, so the judging games are ones the learning
    // has not already seen.
    var order = learnTest ? Swift.max(40, games / 2) : 0
    // Round-robin over the pairings until this shard has played its share.
    while played < games {
        let (a, b) = pairings[order % pairings.count]
        order += 1
        if (order - 1) % shards != index { continue }

        let dice = SplitMix64(seed: seed &+ UInt64(order) &* 0x9E37_79B9_7F4A_7C15)
        // In an A/B, only the side in the "mine" chair knows what its Pokémon
        // are worth. The pairings run both ways round, so each team spends
        // equal time in each chair and team strength cancels.
        let ledger = SelfPlay.playLogged(
            mine: teams[a], theirs: teams[b], rules: rules,
            forMine: seat, forTheirs: seat, limit: 40, dice: dice,
            bringSpread: spread,
            weightedMine: true, weightedTheirs: !abTest,
            stagesMine: true, stagesTheirs: !stageTest,
            forWinMine: true, forWinTheirs: !winTest,
            floorMine: floorTest ? 0.55 : Board.aliveFloor,
            floorTheirs: Board.aliveFloor,
            // Only the side in the "mine" chair gets its own history.
            measuredMine: learnTest ? (learned[teams[a].name] ?? [:]) : [:],
            measuredTheirs: [:],
            // A pinned line applies to whichever chair the focused team is in,
            // so both halves of the comparison get played from both sides.
            pinnedMine: lineFor(teams[a].name, played),
            pinnedTheirs: lineFor(teams[b].name, played))

        record(ledger, mine: teams[a].name, theirs: teams[b].name, into: &report)
        played += 1
        if played % 20 == 0 {
            FileHandle.standardError.write(Data("    shard \(index): \(played)/\(games)\n".utf8))
        }
    }
    report.games = played
    report.field = teams.count
    return report
}

/// Fold one game into the report, from both sides.
func record(_ ledger: SelfPlay.Ledger, mine: String, theirs: String, into report: inout Report) {
    func side(_ name: String, _ foe: String, _ tallies: [String: SelfPlay.Tally],
              picked: [String], won: Bool, drew: Bool) {
        var team = report.teams[name] ?? TeamRecord()
        team.name = name
        team.games += 1
        if won { team.wins += 1 }
        if drew { team.draws += 1 }
        team.turns += ledger.turns
        var pair = team.against[foe] ?? [0, 0]
        pair[0] += won ? 1 : 0
        pair[1] += 1
        team.against[foe] = pair
        if !picked.isEmpty {
            let four = picked.sorted().joined(separator: " + ")
            var seen = team.brings[four] ?? [0, 0]
            seen[0] += won ? 1 : 0
            seen[1] += 1
            team.brings[four] = seen
        }
        for (form, tally) in tallies {
            var record = team.members[form] ?? Record()
            record.games += 1
            if won { record.wins += 1 }
            record.brought += tally.brought
            record.survived += tally.survived
            record.faints += tally.faints
            record.knockouts += tally.knockouts
            record.damageDealt += tally.damageDealt
            record.damageTaken += tally.damageTaken
            for (move, count) in tally.moves { record.moves[move, default: 0] += count }
            team.members[form] = record
        }
        report.teams[name] = team
    }
    let drew = ledger.winner == .none
    side(mine, theirs, ledger.mine, picked: ledger.pickedMine,
         won: ledger.winner == .mine, drew: drew)
    side(theirs, mine, ledger.theirs, picked: ledger.pickedTheirs,
         won: ledger.winner == .theirs, drew: drew)
    if !drew {
        report.chairDecided += 1
        if ledger.winner == .mine { report.chairWins += 1 }
    }
    // A draw is not evidence either way about the four that was chosen.
    if !drew {
        report.calibration.note(rank: ledger.rankMine, score: ledger.scoreMine,
                                team: mine, foe: theirs, won: ledger.winner == .mine)
        report.calibration.note(rank: ledger.rankTheirs, score: ledger.scoreTheirs,
                                team: theirs, foe: mine, won: ledger.winner == .theirs)
    }
}

/// A small, fast, seedable generator. The system one cannot be seeded, and a
/// run that cannot be repeated is a run that cannot be debugged.
struct SplitMix64: RandomNumberGenerator {
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

// MARK: - The report, in words

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "   -" : String(format: "%4.0f%%", Double(part) / Double(whole) * 100)
}

/// Pad or trim to a width, counting characters rather than bytes.
///
/// `String(format: "%-34s", ...)` counts bytes, so a team name with an em
/// dash in it — and most of the tournament lists have one — came out both
/// misaligned and mojibaked.
func pad(_ text: String, _ width: Int) -> String {
    if text.count > width { return String(text.prefix(width - 1)) + "…" }
    return text + String(repeating: " ", count: width - text.count)
}

@MainActor
func describe(_ report: Report, focus: String?, seconds: Double,
              mineNames: Set<String> = []) {
    let teams = report.teams.values.sorted {
        let a = $0.games == 0 ? 0 : Double($0.wins) / Double($0.games)
        let b = $1.games == 0 ? 0 : Double($1.wins) / Double($1.games)
        return a > b
    }
    guard !teams.isEmpty else { print("no games"); return }

    print("\n== \(report.games) games in \(String(format: "%.1f", seconds))s "
          + "(\(String(format: "%.0f", Double(report.games) / Swift.max(0.001, seconds))) a second) ==\n")

    let field = Swift.max(report.field, teams.count)
    let thin = teams.map(\.games).min() ?? 0
    if thin < 8 {
        print("  Note: \(teams.count) of \(field) teams got a game, and the thinnest "
              + "has \(thin). A leaderboard over this field needs roughly "
              + "\(field * 12) games before it means anything — "
              + "try --games \(field * 12) --workers 6.\n")
    }
    if focus == nil {
        print("  how each team did")
        print("  " + String(repeating: "-", count: 62))
        for team in teams.prefix(18) {
            let rate = percent(team.wins, team.games)
            let turns = team.games == 0 ? 0 : Double(team.turns) / Double(team.games)
            print("  \(pad(team.name, 38)) \(rate)  \(pad("\(team.games)", 4)) games  "
                  + String(format: "%4.1f turns", turns))
        }
        if teams.count > 18 { print("  … and \(teams.count - 18) more") }
    }

    // With no focus, the top and bottom of the table are the two worth
    // spelling out: the best team says what is working and the worst says
    // what is not.
    if mineNames.isEmpty == false {
        for team in teams where mineNames.contains(team.name) { describeTeam(team) }
    } else if let focus {
        for team in teams where team.name == focus { describeTeam(team) }
    } else {
        if let best = teams.first { describeTeam(best) }
        if let worst = teams.last, teams.count > 1 { describeTeam(worst) }
    }

    // What the whole field never does. A move nobody ever chooses, across
    // every team that carries it, is either a bad move or a bad valuation of
    // one — and either is worth knowing.
    var chosen: [String: Int] = [:]
    for team in teams {
        for (_, record) in team.members {
            for (move, count) in record.moves { chosen[move, default: 0] += count }
        }
    }
    let quiet = chosen.filter { $0.value > 0 }.sorted { $0.value < $1.value }.prefix(10)
    if !quiet.isEmpty {
        print("\n  moves the engine reaches for least, across every team")
        print("  " + String(repeating: "-", count: 62))
        for (move, count) in quiet {
            print("  \(pad(move, 28)) \(pad("\(count)", 5)) uses")
        }
    }
}

/// Weighted evaluation against flat, everything else held equal.
///
/// Every game has exactly one engine that knows what its Pokémon are worth
/// against this opponent; the other prices them all alike, which is what the
/// engine did before. The pairings run both ways round, so each team spends
/// equal time in each chair and team strength cancels out — what is left is
/// the change.
@MainActor
func describeAB(_ report: Report, seconds: Double, what: String) {
    print("\n== \(what), against not ==\n")
    print("  \(report.games) games in \(String(format: "%.1f", seconds))s, "
          + "\(report.chairDecided) decided\n")
    guard report.chairDecided >= 20 else {
        print("  too few games — try --games 800 --workers 5")
        return
    }
    let rate = Double(report.chairWins) / Double(report.chairDecided)
    let error = (rate * (1 - rate) / Double(report.chairDecided)).squareRoot() * 1.96
    print(String(format: "  the engine that has it won %.1f%% of them, give or take %.1f",
                 rate * 100, error * 100))
    if abs(rate - 0.5) < error {
        print("\n  Inside the noise. On this evidence it is not earning its keep,")
        print("  which is worth knowing before it goes anywhere near the app.")
    } else if rate > 0.5 {
        print(String(format: "\n  Worth %.1f points to the side that has it.", (rate - 0.5) * 100))
    } else {
        print("\n  It plays *worse* weighted, which means the weights are wrong")
        print("  rather than merely useless. Do not ship them.")
    }
}

/// Two lines from the same six, weighed against each other.
///
/// A team usually has a main way of being played and an alternate, and which
/// is better into a given field is a question a picker cannot answer for you —
/// it keeps choosing for itself. Pinning both and alternating them across the
/// same opponents holds everything else still.
@MainActor
func describeLines(_ team: TeamRecord, lines: [[String]], seconds: Double) {
    print("\n== two lines, \(team.games) games, "
          + "\(String(format: "%.0f", seconds))s ==\n")
    print("  \(team.name)\n")

    var rows: [(line: [String], wins: Int, games: Int)] = []
    for line in lines {
        let key = line.sorted().joined(separator: " + ")
        let pair = team.brings[key] ?? [0, 0]
        rows.append((line, pair[0], pair[1]))
    }
    for row in rows where row.games == 0 {
        print("  Could not field: \(row.line.joined(separator: ", "))")
        print("  Check the names against the cards — they have to match exactly,")
        print("  Megas included.\n")
    }
    let playable = rows.filter { $0.games > 0 }
    guard playable.count == 2 else { return }

    for row in playable {
        let rate = Double(row.wins) / Double(row.games)
        let error = (rate * (1 - rate) / Double(row.games)).squareRoot() * 1.96
        print("    \(pad(row.line.joined(separator: ", "), 52))"
              + String(format: " %5.1f%% ± %.1f  of %d", rate * 100, error * 100, row.games))
        print("      leading \(row.line.prefix(2).joined(separator: " and "))")
    }

    let first = playable[0], second = playable[1]
    let a = Double(first.wins) / Double(first.games)
    let b = Double(second.wins) / Double(second.games)
    let error = ((a * (1 - a) / Double(first.games))
                 + (b * (1 - b) / Double(second.games))).squareRoot() * 1.96
    print(String(format: "\n  The gap is %.1f points, give or take %.1f.",
                 abs(a - b) * 100, error * 100))
    if abs(a - b) < error {
        print("  Inside the noise: on this evidence there is nothing to choose")
        print("  between them, which is itself worth knowing — it means the line")
        print("  can be picked on the matchup rather than on principle.")
    } else {
        let better = a > b ? first : second
        print("  \(better.line.joined(separator: ", ")) is the better line into this field.")
    }
}

/// Does the picker's ranking predict anything?
///
/// The bring-four picker ranks every four by a hand-written score and the app
/// shows the top of that list as advice. Nothing had ever checked it against a
/// game. This plays fours from all the way down the ranking and asks whether
/// the order holds up.
///
/// Read the rank table first. If the picker knows what it is doing, rank one
/// wins more than rank five and rank five more than rank ten. A flat table
/// means the ranking is noise, however confident the score looks.
@MainActor
func describeCalibration(_ report: Report, seconds: Double) {
    let cal = report.calibration
    print("\n== does the bring-four picker know what it is talking about? ==\n")
    print("  \(report.games) games in \(String(format: "%.1f", seconds))s\n")

    let ranks = cal.byRank.compactMap { key, pair -> (Int, Int, Int)? in
        guard let rank = Int(key), pair[1] >= 10 else { return nil }
        return (rank, pair[0], pair[1])
    }.sorted { $0.0 < $1.0 }
    guard !ranks.isEmpty else {
        print("  not enough games — try --games 2000 --spread 0")
        return
    }

    print("  how each rank the picker gave actually did")
    print("  " + String(repeating: "-", count: 62))
    for (rank, wins, games) in ranks {
        let rate = Double(wins) / Double(games)
        let bar = String(repeating: "#", count: Int((rate * 40).rounded()))
        print("    rank \(pad("\(rank)", 3)) \(percent(wins, games)) of \(pad("\(games)", 5)) \(bar)")
    }

    // The headline: what the picker's own favourite is worth against what a
    // four drawn from the bottom half is worth.
    let half = (ranks.map(\.0).max() ?? 1) / 2
    let top = ranks.filter { $0.0 == 1 }
    let low = ranks.filter { $0.0 > Swift.max(1, half) }
    let topWins = top.reduce(0) { $0 + $1.1 }, topGames = top.reduce(0) { $0 + $1.2 }
    let lowWins = low.reduce(0) { $0 + $1.1 }, lowGames = low.reduce(0) { $0 + $1.2 }
    if topGames >= 10 && lowGames >= 10 {
        let a = Double(topWins) / Double(topGames), b = Double(lowWins) / Double(lowGames)
        let error = ((a * (1 - a) / Double(topGames)) + (b * (1 - b) / Double(lowGames)))
            .squareRoot() * 1.96
        print(String(format: "\n  its favourite wins %.0f%%, a four from the bottom half %.0f%% — "
                     + "a gap of %.0f, give or take %.0f",
                     a * 100, b * 100, (a - b) * 100, error * 100))
        if abs(a - b) < error {
            print("  That gap is inside the noise: on this evidence the ranking is not")
            print("  telling you anything. More games, or the score needs work.")
        } else if a > b {
            print("  The ranking holds up: the top of the list really is better.")
        } else {
            print("  The ranking is upside down, which is worse than useless.")
        }
    }

    // What trusting the favourite costs, pairing by pairing.
    var regrets: [Double] = []
    var grouped: [String: [(rank: Int, rate: Double, games: Int)]] = [:]
    for (key, pair) in cal.byPairing where pair[1] >= 4 {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 3, let rank = Int(parts[2]) else { continue }
        grouped["\(parts[0])|\(parts[1])", default: []]
            .append((rank, Double(pair[0]) / Double(pair[1]), pair[1]))
    }
    for (_, rows) in grouped {
        guard rows.count >= 3, let mine = rows.first(where: { $0.rank == 1 }),
              let best = rows.max(by: { $0.rate < $1.rate }) else { continue }
        regrets.append(best.rate - mine.rate)
    }
    if !regrets.isEmpty {
        let mean = regrets.reduce(0, +) / Double(regrets.count)
        print(String(format: "\n  across %d matchups with enough games, the best four available won "
                     + "%.0f points more\n  than the one the picker recommended.",
                     regrets.count, mean * 100))
        print("  That is the ceiling on what a better picker could buy.")
    }

    let bands = cal.byScore.compactMap { key, pair -> (Int, Int, Int)? in
        guard let band = Int(key), pair[1] >= 10 else { return nil }
        return (band, pair[0], pair[1])
    }.sorted { $0.0 < $1.0 }
    if bands.count > 1 {
        print("\n  and by the score it gave, in bands of ten")
        print("  " + String(repeating: "-", count: 62))
        for (band, wins, games) in bands {
            let rate = Double(wins) / Double(games)
            let bar = String(repeating: "#", count: Int((rate * 40).rounded()))
            print("    \(pad("\(band)", 5)) \(percent(wins, games)) of \(pad("\(games)", 5)) \(bar)")
        }
        print("\n  A score that means something climbs down this table. One that does")
        print("  not is a number the app is showing with more confidence than it has.")
    }
}

/// Two teams, many games, and which four each should have brought.
@MainActor
func describeVersus(_ report: Report, versus: [String], seconds: Double) {
    guard let a = report.teams[versus[0]], let b = report.teams[versus[1]] else {
        print("no games"); return
    }
    print("\n== \(a.games) games, \(String(format: "%.1f", seconds))s "
          + "(\(String(format: "%.0f", Double(report.games) / Swift.max(0.001, seconds))) a second) ==\n")
    let turns = a.games == 0 ? 0 : Double(a.turns) / Double(a.games)
    print("  \(pad(versus[0], 38)) \(percent(a.wins, a.games)) of \(a.games)")
    print("  \(pad(versus[1], 38)) \(percent(b.wins, b.games)) of \(b.games)")
    if a.draws > 0 { print("  \(pad("went the distance", 38)) \(a.draws)") }
    print(String(format: "  %@ %.1f", pad("turns per game", 38), turns))

    // The margin, with the error on it. Two teams that are the same strength
    // will still come apart over a few hundred games, and this says by how
    // much before a difference is worth believing.
    let decided = a.games - a.draws
    if decided > 0 {
        let rate = Double(a.wins) / Double(decided)
        let error = (rate * (1 - rate) / Double(decided)).squareRoot() * 1.96
        print(String(format: "\n  %@ took %.0f%% of the decided games, give or take %.0f",
                     versus[0], rate * 100, error * 100))
        if error * 100 > abs(rate * 100 - 50) {
            print("  That is inside the noise. Run more games before believing it.")
        }
    }

    for (team, name) in [(a, versus[0]), (b, versus[1])] {
        let brings = team.brings.filter { $0.value[1] >= 3 }
            .sorted { Double($0.value[0]) / Double($0.value[1])
                      > Double($1.value[0]) / Double($1.value[1]) }
        guard !brings.isEmpty else { continue }
        print("\n  which four \(name) should bring")
        print("  " + String(repeating: "-", count: 62))
        for (four, pair) in brings.prefix(8) {
            print("    \(pad(four, 58)) \(percent(pair[0], pair[1])) of \(pair[1])")
        }
        if brings.count > 8 {
            let rest = brings.suffix(from: 8)
            print("    … \(rest.count) more, worst "
                  + "\(rest.last.map { "\($0.key) at \(percent($0.value[0], $0.value[1]))" } ?? "")")
        }
    }
    describeTeam(a)
    describeTeam(b)
}

@MainActor
func describeTeam(_ team: TeamRecord) {
    print("\n  \(team.name) — won \(percent(team.wins, team.games)) of \(team.games)")
    print("  " + String(repeating: "-", count: 62))

    // Who carries it. Knockouts against faints is the honest ratio: a Pokémon
    // that trades one for one is not carrying anything.
    let members = team.members.sorted { $0.value.knockouts > $1.value.knockouts }
    // Built with the same pads as the rows, so the columns cannot drift apart.
    print("    " + pad("Pokémon", 26) + " kept " + pad("KOs", 4) + " "
          + pad("lost", 5) + " " + pad("dealt", 7) + " " + pad("taken", 6))
    for (form, record) in members {
        print("    \(pad(form, 26)) \(percent(record.brought, record.games)) "
              + "\(pad("\(record.knockouts)", 4)) \(pad("\(record.faints)", 5)) "
              + "\(pad("\(record.damageDealt)", 7)) \(pad("\(record.damageTaken)", 6))")
    }

    // How many different fours actually work. A team with one good four is a
    // team with one plan, and "a good team will make things easier for you"
    // at preview means having several.
    let tried = team.brings.filter { $0.value[1] >= 5 }
    if tried.count >= 2 {
        let working = tried.filter { Double($0.value[0]) / Double($0.value[1]) >= 0.5 }.count
        print("    \(working) of \(tried.count) fours it brought won at least half their games")
    }

    // Moves it carries and never uses.
    var used: [String: Int] = [:]
    for (_, record) in team.members {
        for (move, count) in record.moves { used[move, default: 0] += count }
    }
    let rare = used.sorted { $0.value < $1.value }.prefix(5)
    if !rare.isEmpty {
        print("    least-used moves: "
              + rare.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
    }

    // What it cannot beat.
    let matchups = team.against.filter { $0.value[1] >= 2 }
        .sorted { Double($0.value[0]) / Double($0.value[1])
                  < Double($1.value[0]) / Double($1.value[1]) }
    if let worst = matchups.first {
        print("    worst matchup: \(worst.key) — won \(percent(worst.value[0], worst.value[1])) "
              + "of \(worst.value[1])")
    }
    if let best = matchups.last, matchups.count > 1 {
        print("    best matchup:  \(best.key) — won \(percent(best.value[0], best.value[1])) "
              + "of \(best.value[1])")
    }
}

// MARK: - Main

@MainActor
func main() {
    let games = Int(flag("--games") ?? "") ?? 120
    let budget = Double(flag("--budget") ?? "") ?? 0.03
    let focus = flag("--team")
    let seed = UInt64(flag("--seed") ?? "") ?? 20_260_915
    let workers = Swift.max(1, Int(flag("--workers") ?? "") ?? 4)
    // Two team names after --vs, e.g. --vs "Big Six" "Dual Mega Rain".
    var versus: [String] = []
    if let at = CommandLine.arguments.firstIndex(of: "--vs"), at + 2 < CommandLine.arguments.count {
        versus = [CommandLine.arguments[at + 1], CommandLine.arguments[at + 2]]
    }
    // How many of the ranked fours are in play. A head-to-head defaults to
    // spreading, because replaying one four a thousand times answers nothing
    // about which four to bring.
    // Calibration needs the whole ranking in play, bottom included: there is
    // nothing to compare the top against otherwise.
    let spread = Int(flag("--spread") ?? "")
        ?? (has("--calibrate") ? 0 : (versus.count == 2 ? 6 : 1))
    // Weighted evaluation against flat evaluation, everything else held equal.
    let abTest = has("--ab")
    // The same experiment for the stat-stage term in the evaluation.
    let stageTest = has("--ab-stages")
    // And for scoring a turn by the chance of winning rather than by material.
    let winTest = has("--ab-win")
    let mineOnly = has("--mine")
    // What a living Pokémon is worth before health is counted. The old 0.35
    // was never tuned; the argument is that a Pokémon on 1 HP still attacks
    // for full, so it should be higher.
    let floorTest = has("--ab-floor")
    // Keep the old crude spread, for comparing against earlier runs.
    let crude = has("--crude-spreads")
    // Level your own teams down to the same planned build as the field.
    let level = has("--level")
    // A line to pin, lead pair first, and optionally a second to weigh it
    // against. Names as they appear on the card: "Mega Charizard Y, Garchomp".
    func line(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var lines: [[String]] = []
    if let one = flag("--line") { lines = [line(one)] }
    if let at = CommandLine.arguments.firstIndex(of: "--compare"),
       at + 2 < CommandLine.arguments.count {
        lines = [line(CommandLine.arguments[at + 1]), line(CommandLine.arguments[at + 2])]
    }
    // Does a team's own measured record improve its bring, on games the record
    // has never seen?
    let learnTest = has("--ab-learned")
    let started = Date()

    // A child doing its slice: run it, print the JSON, done.
    if let shard = flag("--shard") {
        let parts = shard.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 else { exit(2) }
        let report = runShard(index: parts[0], of: parts[1], games: games, budget: budget,
                              focus: focus, versus: versus, spread: spread,
                              abTest: abTest, stageTest: stageTest,
                              winTest: winTest, mineOnly: mineOnly,
                              floorTest: floorTest, crude: crude, level: level,
                              learnTest: learnTest, lines: lines, seed: seed)
        let blob = try! JSONEncoder().encode(report)
        FileHandle.standardOutput.write(blob)
        return
    }

    print("==> lab: \(games) games, budget \(budget)s, \(workers) worker\(workers == 1 ? "" : "s")"
          + (mineOnly ? ", your teams against the field" : "")
          + (level ? ", everyone on planned spreads" : "")
          + (crude ? ", field on the old crude spread" : "")
          + (versus.count == 2 ? ", \(versus[0]) vs \(versus[1])" : "")
          + (focus.map { ", focused on \($0)" } ?? "")
          + (spread > 1 && lines.isEmpty ? ", drawing from the top \(spread) fours" : "")
          + (lines.count == 1 ? ", playing one pinned line" : "")
          + (lines.count == 2 ? ", two lines against each other" : ""))

    var report = Report()
    if workers == 1 {
        report = runShard(index: 0, of: 1, games: games, budget: budget, focus: focus,
                          versus: versus, spread: spread, abTest: abTest,
                          stageTest: stageTest, winTest: winTest,
                          mineOnly: mineOnly, floorTest: floorTest,
                          crude: crude, level: level, learnTest: learnTest,
                          lines: lines, seed: seed)
    } else {
        // Each child plays its own slice and hands back a ledger. Sharding by
        // process rather than by thread because the turn model's dice are
        // global; this needs no change to the engine and still uses the box.
        let each = Swift.max(1, games / workers)
        var children: [(Process, Pipe)] = []
        for index in 0..<workers {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            // A different seed per worker, or every shard plays the same games.
            var argv = ["--shard", "\(index)/\(workers)", "--games", "\(each)",
                        "--budget", "\(budget)", "--spread", "\(spread)",
                        "--seed", "\(seed &+ UInt64(index) &* 1_000_003)"]
            if let focus { argv += ["--team", focus] }
            if versus.count == 2 { argv += ["--vs", versus[0], versus[1]] }
            if has("--calibrate") { argv.append("--calibrate") }
            if abTest { argv.append("--ab") }
            if stageTest { argv.append("--ab-stages") }
            if winTest { argv.append("--ab-win") }
            if mineOnly { argv.append("--mine") }
            if floorTest { argv.append("--ab-floor") }
            if crude { argv.append("--crude-spreads") }
            if level { argv.append("--level") }
            if learnTest { argv.append("--ab-learned") }
            if lines.count == 1 { argv += ["--line", lines[0].joined(separator: ",")] }
            if lines.count == 2 {
                argv += ["--compare", lines[0].joined(separator: ","),
                         lines[1].joined(separator: ",")]
            }
            task.arguments = argv
            let pipe = Pipe()
            task.standardOutput = pipe
            do { try task.run() } catch {
                print("could not start worker \(index): \(error)"); exit(1)
            }
            children.append((task, pipe))
        }
        for (task, pipe) in children {
            let blob = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let piece = try? JSONDecoder().decode(Report.self, from: blob) {
                report.add(piece)
            }
        }
    }

    let seconds = Date().timeIntervalSince(started)
    report.seconds = seconds
    if lines.count == 2, let name = focus, let team = report.teams[name] {
        describeLines(team, lines: lines, seconds: seconds)
    } else if abTest || stageTest || winTest || floorTest || learnTest {
        describeAB(report, seconds: seconds,
                   what: learnTest ? "leaning on the team's own measured record"
                        : floorTest ? "valuing a Pokémon on 1 HP nearer to a healthy one"
                        : winTest ? "playing for the win rather than for material"
                        : stageTest ? "counting the stat stages on the board"
                                    : "knowing what your Pokémon are worth")
    }
    else if has("--calibrate") { describeCalibration(report, seconds: seconds) }
    else if versus.count == 2 { describeVersus(report, versus: versus, seconds: seconds) }
    else {
        describe(report, focus: focus, seconds: seconds,
                 mineNames: mineOnly ? Set(Store.shared.teams.map(\.name)) : [])
    }

    if let path = flag("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let blob = try? encoder.encode(report) {
            try? blob.write(to: URL(fileURLWithPath: path))
            print("\n  wrote \(path)")
        }
    }
}

MainActor.assumeIsolated { main() }
