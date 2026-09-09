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

    var id: String { "\(mine.id)-vs-\(theirs.id)" }

    var iAmFaster: Bool { mySpeed > theirSpeed }

    /// Rough 1v1 verdict, respecting who moves first.
    ///
    /// Speed decides ties: if we both OHKO, the faster one wins, which is why
    /// the base-151 Z Megas change so many of these cells.
    var outcome: Outcome {
        let iKO = outgoing >= 1.0
        let theyKO = incoming >= 1.0
        switch (iKO, theyKO) {
        case (true, true):
            // A genuine speed tie is a coin flip, not a loss. Scoring it as a
            // loss biased every mirror match negative.
            if mySpeed == theirSpeed { return .neutral }
            return iAmFaster ? .win : .loss
        case (true, false):  return .win
        case (false, true):  return .loss
        case (false, false):
            if outgoing >= incoming * 1.5 { return .favoured }
            if incoming >= outgoing * 1.5 { return .against }
            return .neutral
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

    /// A representative build for a slot. Anything the paste or archetype left
    /// blank gets the obvious default rather than zero, so an unspecified team
    /// does not read as harmless.
    private func combatant(_ slot: TeamSlot, form: Form) -> Combatant {
        var c = Combatant(form: form,
                          ability: slot.ability.isEmpty
                            ? (form.abilities.first?.name ?? "") : slot.ability,
                          item: slot.item,
                          sp: slot.sp,
                          alignment: slot.alignment,
                          teraType: slot.tera)
        if slot.sp.allSatisfy({ $0 == 0 }) {
            let physical = form.attack >= form.spAttack
            var sp = Array(repeating: 0, count: 6)
            sp[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
            sp[Stat.speed.rawValue] = 32
            c.sp = sp
        }
        return c
    }

    /// Damaging moves for a slot, falling back to the form's best STAB when the
    /// slot has none selected.
    private func moves(_ slot: TeamSlot, form: Form) -> [Move] {
        let chosen = slot.moves.compactMap { store.move($0) }.filter(\.isDamaging)
        if !chosen.isEmpty { return chosen }
        let learnable = store.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
        let stab = learnable.filter { form.types.contains($0.type) }
        let pool = stab.isEmpty ? learnable : stab
        return Array(pool.sorted { $0.power > $1.power }.prefix(3))
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

    var duels: [Duel] {
        var out: [Duel] = []
        for (mySlot, myForm) in myPairs {
            let me = combatant(mySlot, form: myForm)
            let myMoves = moves(mySlot, form: myForm)
            for (theirSlot, theirForm) in theirPairs {
                let them = combatant(theirSlot, form: theirForm)
                let theirMoves = moves(theirSlot, form: theirForm)

                var best = 0.0, bestName = "—"
                for move in myMoves {
                    let result = DamageCalc.calculate(attacker: me, defender: them,
                                                      move: move, field: field)
                    if result.maxPercent / 100 > best {
                        best = result.maxPercent / 100
                        bestName = move.name
                    }
                }
                var worst = 0.0, worstName = "—"
                for move in theirMoves {
                    let result = DamageCalc.calculate(attacker: them, defender: me,
                                                      move: move, field: field)
                    if result.maxPercent / 100 > worst {
                        worst = result.maxPercent / 100
                        worstName = move.name
                    }
                }

                out.append(Duel(mine: myForm, theirs: theirForm,
                                outgoing: best, incoming: worst,
                                mySpeed: me.stat(.speed), theirSpeed: them.stat(.speed),
                                myBestMove: bestName, theirBestMove: worstName))
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
