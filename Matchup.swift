//  Matchup.swift
//  Team versus team.
//
//  The threat matrix answers "how do I fare against this one Pokémon". That is
//  not the same question as "how do I fare against this team", because a team
//  gets to choose which of its six leads and which four it brings. This file
//  works the grid: every one of mine against every one of theirs, both
//  directions, then aggregates it into who is carrying the matchup and who is
//  dead weight.

import Foundation

/// One cell of the grid: my Pokémon against theirs.
struct Duel: Identifiable {
    let mine: Form
    let theirs: Form
    /// Fraction of the opponent's HP my best move deals, on the high roll.
    let outgoing: Double
    /// Fraction of my HP their best move deals.
    let incoming: Double
    let mySpeed: Int
    let theirSpeed: Int
    let myBestMove: String
    let theirBestMove: String
    /// How much of that damage you can count on — accuracy, and what the move
    /// costs you to click. A 70% accurate "OHKO" is not an OHKO, and a Steel
    /// Beam that halves your own HP is not the same trade as an Iron Head.
    var myReliability: Double = 1
    var theirReliability: Double = 1
    /// Turns spent setting up or applying status before attacking starts.
    var mySetupTurns: Int = 0
    var theirSetupTurns: Int = 0

    var id: String { "\(mine.id)-vs-\(theirs.id)" }

    var effectiveOutgoing: Double { outgoing * myReliability }
    var effectiveIncoming: Double { incoming * theirReliability }

    var iAmFaster: Bool { mySpeed > theirSpeed }

    /// Turns this side needs to knock the other out, on the high roll,
    /// including any spent setting up or applying status first.
    var myTurnsToKO: Int {
        effectiveOutgoing > 0 ? mySetupTurns + Int(ceil(1 / effectiveOutgoing)) : 99
    }
    var theirTurnsToKO: Int {
        effectiveIncoming > 0 ? theirSetupTurns + Int(ceil(1 / effectiveIncoming)) : 99
    }

    /// Rough 1v1 verdict, respecting who moves first.
    ///
    /// Speed is not just a tie-break. It used to be consulted only when both
    /// sides scored a one-hit knockout; every other cell — which is most of
    /// them — compared raw damage ratios and ignored turn order entirely. That
    /// scored a two-hit race identically whether you moved first or last, which
    /// is the opposite of how those games go.
    ///
    /// Both sides are now raced: how many turns each needs, and who lands the
    /// last one. Moving first wins an equal race outright.
    var outcome: Outcome {
        // A one-hit knockout only counts if it happens on the first turn; a
        // setup turn means they get to act first whatever the damage says.
        let iKO = effectiveOutgoing >= 1.0 && mySetupTurns == 0
        let theyKO = effectiveIncoming >= 1.0 && theirSetupTurns == 0
        switch (iKO, theyKO) {
        case (true, true):
            // A genuine speed tie is a coin flip, not a loss. Scoring it as a
            // loss biased every mirror match negative.
            if mySpeed == theirSpeed { return .neutral }
            return iAmFaster ? .win : .loss
        case (true, false):  return .win
        case (false, true):  return .loss
        case (false, false):
            let mine = myTurnsToKO, theirs = theirTurnsToKO
            // Two clear turns ahead is a win, not merely an advantage.
            if mine + 2 <= theirs { return .win }
            if theirs + 2 <= mine { return .loss }
            if mine < theirs { return .favoured }
            if theirs < mine { return .against }
            // Same number of turns: whoever moves first lands the last hit.
            if mySpeed == theirSpeed { return .neutral }
            return iAmFaster ? .favoured : .against
        }
    }

    enum Outcome: String {
        case win = "Win"
        case favoured = "Favoured"
        case neutral = "Even"
        case against = "Against"
        case loss = "Loss"

        var score: Double {
            switch self {
            case .win: return 1.0
            case .favoured: return 0.5
            case .neutral: return 0.0
            case .against: return -0.5
            case .loss: return -1.0
            }
        }
    }
}

/// How one of my Pokémon does across their whole team.
struct MemberReport: Identifiable {
    let form: Form
    let duels: [Duel]
    var id: String { form.id }

    var wins: Int { duels.filter { $0.outcome == .win }.count }
    var losses: Int { duels.filter { $0.outcome == .loss }.count }
    var score: Double { duels.reduce(0) { $0 + $1.outcome.score } }

    /// Beats nothing and loses to most of it — the slot to cut.
    var isDeadWeight: Bool { wins == 0 && losses >= max(2, duels.count / 2) }
}

/// How one of *their* Pokémon does against my whole team.
struct OpposingReport: Identifiable {
    let form: Form
    let duels: [Duel]
    var id: String { form.id }

    /// My members that beat it.
    var answeredBy: [Form] { duels.filter { $0.outcome == .win }.map(\.mine) }
    var beats: [Form] { duels.filter { $0.outcome == .loss }.map(\.mine) }
    var isUnanswered: Bool { answeredBy.isEmpty }
    var threatScore: Double { duels.reduce(0) { $0 - $1.outcome.score } }
}

@MainActor
struct Matchup {
    let mine: Team
    let theirs: Team
    let store: Store
    var field: Field = Field()
    /// Speed control in effect for each side. Tailwind doubles Speed for four
    /// turns, which decides a large share of the one-on-ones — scoring without
    /// it made every support Pokémon look like a wasted slot.
    var myTailwind = false
    var theirTailwind = false
    var myTrickRoom = false

    /// Computed once at construction; every report below reads this array.
    ///
    /// A var rather than a let only because buildDuels() needs a fully
    /// initialised self to run — it is never written again after init.
    private(set) var duels: [Duel] = []

    init(mine: Team, theirs: Team, store: Store, field: Field = Field(),
         myTailwind: Bool = false, theirTailwind: Bool = false,
         myTrickRoom: Bool = false) {
        self.mine = mine
        self.theirs = theirs
        self.store = store
        self.field = field
        self.myTailwind = myTailwind
        self.theirTailwind = theirTailwind
        self.myTrickRoom = myTrickRoom
        self.duels = buildDuels()
    }

    /// Effective Speed for the comparison that decides who moves first.
    /// Trick Room inverts the order, so it is expressed by negating both sides.
    private func order(mine: Int, theirs: Int) -> (Int, Int) {
        let a = myTailwind ? mine * 2 : mine
        let b = theirTailwind ? theirs * 2 : theirs
        return myTrickRoom ? (-a, -b) : (a, b)
    }

    /// A representative build for a slot. Anything the paste or archetype left
    /// blank gets the obvious default rather than zero, so an unspecified team
    /// does not read as harmless.
    private func combatant(_ slot: TeamSlot, form: Form) -> Combatant {
        var c = Combatant(form: form,
                          ability: slot.ability.isEmpty
                            ? (form.abilities.first?.name ?? "") : slot.ability,
                          item: slot.item,
                          sp: slot.sp,
                          alignment: slot.alignment)
        if slot.sp.allSatisfy({ $0 == 0 }) {
            let physical = form.attack >= form.spAttack
            var sp = Array(repeating: 0, count: 6)
            sp[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
            sp[Stat.speed.rawValue] = 32
            c.sp = sp
        }
        return c
    }

    /// The slot's whole set, falling back to the form's best STAB when it has
    /// nothing selected. Status and setup moves are included deliberately —
    /// filtering to damage is what made Will-O-Wisp and Swords Dance worth zero.
    private func moves(_ slot: TeamSlot, form: Form) -> [Move] {
        let chosen = slot.moves.compactMap { store.move($0) }
        if chosen.contains(where: \.isDamaging) { return chosen }
        let learnable = store.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
        let stab = learnable.filter { form.types.contains($0.type) }
        let pool = stab.isEmpty ? learnable : stab
        // Ranked on what the move is worth, not its base power: otherwise the
        // fallback set is Giga Impact and Steel Beam every time.
        return Array(pool.sorted {
            store.quality(of: $0, ability: slot.ability, item: slot.item).expectedPower
                > store.quality(of: $1, ability: slot.ability, item: slot.item).expectedPower
        }.prefix(3))
    }

    private var myPairs: [(TeamSlot, Form)] {
        mine.slots.compactMap { slot in
            slot.form(in: store).map { (slot, $0) }
        }
    }

    private var theirPairs: [(TeamSlot, Form)] {
        theirs.slots.compactMap { slot in
            slot.form(in: store).map { (slot, $0) }
        }
    }

    // MARK: - Grid

    /// The whole grid, computed once.
    ///
    /// This used to be a computed property, and `verdict`, `memberReports` and
    /// `opposingReports` each re-ran it — so drawing the Versus screen worked the
    /// grid five or six times over.
    private func buildDuels() -> [Duel] {
        var out: [Duel] = []
        for (mySlot, myForm) in myPairs {
            let me = combatant(mySlot, form: myForm)
            let myMoves = moves(mySlot, form: myForm)
            for (theirSlot, theirForm) in theirPairs {
                let them = combatant(theirSlot, form: theirForm)
                let theirMoves = moves(theirSlot, form: theirForm)

                let speeds = order(mine: me.stat(.speed), theirs: them.stat(.speed))
                out.append(DuelEngine.duel(
                    mine: DuelEngine.Side(combatant: me, moves: myMoves, speed: speeds.0),
                    theirs: DuelEngine.Side(combatant: them, moves: theirMoves, speed: speeds.1),
                    field: field, store: store))
            }
        }
        return out
    }

    var memberReports: [MemberReport] {
        let all = duels
        return myPairs.map { _, form in
            MemberReport(form: form, duels: all.filter { $0.mine.id == form.id })
        }
    }

    var opposingReports: [OpposingReport] {
        let all = duels
        return theirPairs.map { _, form in
            OpposingReport(form: form, duels: all.filter { $0.theirs.id == form.id })
        }
        .sorted { $0.threatScore > $1.threatScore }
    }

    // MARK: - Verdict

    struct Verdict {
        /// −100 (losing badly) to +100 (winning comfortably).
        let score: Int
        let headline: String
        let winCount: Int
        let lossCount: Int
        let totalCells: Int
        let speedEdge: Int
        let unanswered: [Form]
        let deadWeight: [Form]
        let advice: [String]
    }

    var verdict: Verdict {
        let all = duels
        guard !all.isEmpty else {
            return Verdict(score: 0, headline: "Pick two teams to compare.",
                           winCount: 0, lossCount: 0, totalCells: 0, speedEdge: 0,
                           unanswered: [], deadWeight: [], advice: [])
        }

        let wins = all.filter { $0.outcome == .win }.count
        let losses = all.filter { $0.outcome == .loss }.count
        let raw = all.reduce(0.0) { $0 + $1.outcome.score } / Double(all.count)
        let score = Int((raw * 100).rounded())

        let faster = all.filter(\.iAmFaster).count
        let speedEdge = Int((Double(faster) / Double(all.count) * 100).rounded())

        let unanswered = opposingReports.filter(\.isUnanswered).map(\.form)
        let dead = memberReports.filter(\.isDeadWeight).map(\.form)

        var advice: [String] = []
        if let worst = opposingReports.first, worst.isUnanswered {
            advice.append("Nothing on your team beats \(worst.form.formLabel). That is the matchup.")
        }
        for form in dead.prefix(2) {
            advice.append("\(form.formLabel) beats none of their six — it is not earning its slot here.")
        }
        if speedEdge < 35 {
            advice.append("You are slower in \(100 - speedEdge)% of the one-on-ones. Tailwind or Trick Room is doing the work, not raw stats.")
        }
        if let star = memberReports.max(by: { $0.score < $1.score }), star.wins > 0 {
            advice.append("\(star.form.formLabel) carries this matchup with \(star.wins) winning matchups.")
        }
        // Terrain and weather flip a lot of these cells, so say so once.
        if field.terrain == .none && theirPairs.contains(where: { form in
            form.1.abilities.contains { $0.name.hasSuffix("Surge") }
        }) {
            advice.append("They have a terrain setter; re-run this with their terrain up to see the real numbers.")
        }

        let headline: String
        switch score {
        case 25...:      headline = "Favoured — you out-trade them across the board."
        case 8..<25:     headline = "Slight edge, but it turns on a few cells."
        case -8..<8:     headline = "Close. Lead choice and speed control decide it."
        case -25..<(-8): headline = "Uphill. They have answers you do not."
        default:         headline = "Losing matchup as built."
        }

        return Verdict(score: score, headline: headline, winCount: wins,
                       lossCount: losses, totalCells: all.count, speedEdge: speedEdge,
                       unanswered: unanswered, deadWeight: dead, advice: advice)
    }
}
