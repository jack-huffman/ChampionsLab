//  TurnExplainer.swift
//  What happened in a turn, and why it happened that way.
//
//  The log says what happened. The review says whether your line was the one
//  the engine wanted. Neither says *why* — and "why" is where nearly every
//  argument about a turn actually lives: why did that move go first, why did
//  that do so much less than expected, why did my setup not happen.
//
//  The order and its reasons come from TurnOrder.billing, which calls the same
//  priority and Speed the turn itself calls. That matters more than it looks:
//  an explanation worked out separately from the thing it explains is an
//  explanation that can be wrong, and a wrong one is worse than none, because
//  it gets believed. The damage breakdown is the calculator's own notes, for
//  the same reason.

import SwiftUI

struct TurnExplainer: View {
    let review: BattleView.TurnReview
    let rules: Rulebook
    var onClose: () -> Void

    @Environment(\.snapshotMode) private var snapshotMode

    private var order: [TurnOrder.Billing] {
        TurnOrder.billing(review.before, mine: review.minePlay, theirs: review.theirPlay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if snapshotMode { inside } else { ScrollView { inside } }
        }
        .frame(width: 620, height: snapshotMode ? 1500 : 660)
        .background(Palette.canvas)
    }

    private var inside: some View {
        VStack(alignment: .leading, spacing: 14) {
            whoWentFirst
            whatItDid
            whatHappened
            wasItRight
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn \(review.turn)").font(.system(size: 15, weight: .semibold))
                Text("\(review.yours)  against  \(review.theirs)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            Button("Done", action: onClose).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - The order

    private var whoWentFirst: some View {
        let acts = order
        let inverted = review.before.trickRoom > 0
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Who went first",
                              subtitle: "Priority decides it outright; Speed only breaks a tie "
                                      + "inside the same bracket."
                                      + (inverted ? " Trick Room is up, so slower acts first."
                                                  : ""))
                ForEach(Array(acts.enumerated()), id: \.offset) { index, act in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary).frame(width: 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(act.who)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(act.mine ? Palette.accent : Palette.bad)
                                Text(act.what).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                Text(act.bracket == 0 ? "priority 0"
                                     : "priority \(act.bracket > 0 ? "+" : "")\(act.bracket)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(act.bracket > 0 ? Palette.good : Palette.dim)
                                Text("·").foregroundStyle(.quaternary)
                                Text("\(act.speed) Speed")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(act.becauseOfPriority + act.becauseOfSpeed, id: \.self) { why in
                                Text("— " + why)
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let winner = acts.first, acts.count > 1 {
                    let next = acts[1]
                    Text(verdict(winner, over: next, inverted: inverted))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The sentence somebody actually wants: not the numbers again, but which
    /// of the two rules settled it.
    private func verdict(_ first: TurnOrder.Billing, over second: TurnOrder.Billing,
                         inverted: Bool) -> String {
        if first.bracket != second.bracket {
            return "\(first.who) moved first on priority — \(first.bracket) against "
                 + "\(second.bracket). Speed was never consulted; a priority bracket is "
                 + "settled before it matters how fast anything is."
        }
        return "Same bracket, so it came down to Speed: \(first.speed) against "
             + "\(second.speed)\(inverted ? ", and Trick Room means the slower one goes first" : "")."
    }

    // MARK: - The damage

    /// Every damaging action, recalculated against the board as it stood, for
    /// the multipliers that made the number what it was.
    private var whatItDid: some View {
        let hits = damageNotes()
        return Group {
            if !hits.isEmpty {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Why the numbers came out that size",
                                      subtitle: "The calculator's own working, against the board "
                                              + "as it stood at the start of the turn.")
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(hit.headline).font(.system(size: 11, weight: .medium))
                                    Spacer(minLength: 0)
                                    Text(hit.range).font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                if !hit.effectiveness.isEmpty {
                                    Text(hit.effectiveness)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(hit.superEffective ? Palette.good
                                                         : Palette.warn)
                                }
                                ForEach(hit.notes, id: \.self) { note in
                                    Text("— " + note)
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Hit {
        let headline: String
        let range: String
        let effectiveness: String
        let superEffective: Bool
        let notes: [String]
    }

    private func damageNotes() -> [Hit] {
        var out: [Hit] = []
        let board = review.before
        for act in order {
            let team = act.mine ? board.mine : board.theirs
            let foes = act.mine ? board.theirs : board.mine
            guard team.indices.contains(act.slot) else { continue }
            guard case .attack(let index, let target) = plays(act) else { continue }
            guard team[act.slot].moves.indices.contains(index) else { continue }
            let move = team[act.slot].moves[index]
            guard move.isDamaging else { continue }
            let aimed = move.isSpread ? Array(0..<Swift.min(board.activeCount, foes.count))
                                      : [target]
            for slot in aimed where foes.indices.contains(slot) && !foes[slot].fainted {
                let result = DamageCalc.calculate(attacker: team[act.slot].build,
                                                  defender: foes[slot].build,
                                                  move: move, field: board.field)
                guard result.maxDamage > 0 || !result.notes.isEmpty else { continue }
                let share = Double(result.maxDamage) / Double(Swift.max(1, foes[slot].maxHP))
                // Both sides run the same Pokémon often enough that "Charizard's
                // Solar Beam into Charizard" is a row you will actually see, and
                // it does not say which is which. Whose it is, but only where
                // the names collide — every other row is shorter without it.
                var attacker = team[act.slot].build.form.formLabel
                var defender = foes[slot].build.form.formLabel
                if attacker == defender {
                    attacker = (act.mine ? "your " : "their ") + attacker
                    defender = (act.mine ? "their " : "your ") + defender
                }
                out.append(Hit(
                    headline: "\(attacker)'s \(move.name) into \(defender)",
                    range: "\(result.minDamage)–\(result.maxDamage)"
                         + String(format: " (%.0f%%)", share * 100),
                    effectiveness: label(result.effectiveness),
                    superEffective: result.effectiveness > 1,
                    notes: result.notes))
            }
        }
        return out
    }

    private func plays(_ act: TurnOrder.Billing) -> Choice {
        let play = act.mine ? review.minePlay : review.theirPlay
        return act.slot == 0 ? play.left : play.right
    }

    private func label(_ effectiveness: Double) -> String {
        switch effectiveness {
        case 0: return "It does not affect it at all."
        case ..<0.5: return "Barely scratches it — a quarter."
        case ..<1: return "Resisted — half."
        case 1: return ""
        case ..<4: return "Super effective — double."
        default: return "Four times."
        }
    }

    // MARK: - The events, and the verdict

    private var whatHappened: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "What happened",
                              subtitle: "The turn as the model resolved it, in order.")
                if review.told.isEmpty {
                    Text("Nothing was recorded for this turn.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(Array(review.told.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var wasItRight: some View {
        let lost = review.lost
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Was it the right call",
                              subtitle: "Both lines scored against the mix they were actually "
                                      + "playing — judging a choice against what they happened "
                                      + "to do would reward luck.")
                HStack(spacing: 22) {
                    figure(String(format: "%.2f", review.played), "your line")
                    figure(String(format: "%.2f", review.best), "the best one",
                           tint: lost > 0.05 ? Palette.good : .primary)
                    if lost > 0.005 {
                        figure(String(format: "−%.2f", lost), "gave up", tint: Palette.bad)
                    }
                }
                Text(lost <= 0.02
                     ? "That is the line the engine wanted."
                     : "The engine preferred \(review.bestLine).")
                    .font(.system(size: 11))
                    .foregroundStyle(lost <= 0.02 ? Palette.good : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if lost > 0.02 {
                    Text("A gap under about a tenth is noise — several lines are usually "
                         + "fine and the engine had to pick one. A gap much past that is a "
                         + "turn worth playing again.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}
