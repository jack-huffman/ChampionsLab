//  MemberDetail.swift
//  Everything a run found out about one Pokémon, in one place.
//
//  The report knew all of this already and told it in three separate places:
//  the trade column said a Pokémon was losing, the threat card said what was
//  killing it, and the quiet-move list said which of its moves never got
//  clicked. Three cards, each sorted by its own thing, none of them answering
//  "so what is wrong with Whimsicott".
//
//  Nothing here is new data. It is the same run, gathered around the Pokémon
//  instead of around the statistic, which is the level a decision actually gets
//  made at: you do not change a trade ratio, you change a Pokémon's item, its
//  spread, or whether you bring it at all.

import SwiftUI

struct MemberDetail: View {
    let form: String
    let report: TeamLab.Report
    let team: Team
    var onClose: () -> Void

    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode

    private var record: TeamLab.Record { report.members[form] ?? TeamLab.Record() }

    /// The slot this Pokémon occupies, for the moves it was given as against
    /// the moves it reached for.
    private var slot: TeamSlot? {
        team.slots.first {
            $0.battleForm(in: store.rulebook).map(SelfPlay.recordLabel) == form
        }
    }

    private var resolved: Form? {
        slot?.battleForm(in: store.rulebook) ?? store.form(named: form)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if snapshotMode { inside } else { ScrollView { inside } }
        }
        .frame(width: 560, height: snapshotMode ? 1500 : 620)
        .background(Palette.canvas)
    }

    private var inside: some View {
        VStack(alignment: .leading, spacing: 14) {
            verdict
            moves
            kills
            fours
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let resolved { SpriteImage(form: resolved, side: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(form).font(.system(size: 15, weight: .semibold))
                Text("\(record.games) games, brought to "
                     + String(format: "%.0f%%", record.broughtShare * 100))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Done", action: onClose).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - What it did

    private var verdict: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 22) {
                    figure(String(format: "%.2f", record.trade), "trade",
                           tint: record.trade >= 1 ? Palette.good
                               : record.trade >= 0.7 ? Palette.warn : Palette.bad)
                    figure("\(record.knockouts)", "knockouts")
                    figure("\(record.faints)", "times fainted")
                    figure(String(format: "%.0f%%",
                                  Double(record.survived)
                                  / Double(Swift.max(1, record.brought)) * 100),
                           "survived when brought")
                }
                // Damage in and out. A Pokémon can trade badly and still be
                // earning its slot by soaking; this is where that shows.
                let dealt = record.damageDealt, taken = record.damageTaken
                if dealt + taken > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("damage").font(.system(size: 10))
                                .foregroundStyle(.tertiary).frame(width: 56, alignment: .leading)
                            Text("dealt \(dealt)").font(.system(size: 11))
                                .foregroundStyle(Palette.good)
                            Text("taken \(taken)").font(.system(size: 11))
                                .foregroundStyle(Palette.bad)
                            Spacer(minLength: 0)
                            Text(dealt >= taken ? "net positive" : "net negative")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                Capsule().fill(Palette.good)
                                    .frame(width: geo.size.width
                                           * Double(dealt) / Double(dealt + taken))
                                Capsule().fill(Palette.bad)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                Text(reading).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The finding as a sentence, because a table of numbers is not a verdict.
    private var reading: String {
        if record.brought == 0 { return "Never brought. The picker does not rate it." }
        if record.trade >= 1.4 {
            return "Carrying the team. Worth building the rest of the six around."
        }
        if record.trade >= 0.9 { return "Pulling its weight." }
        if record.broughtShare < 0.3 {
            return "Rarely brought, and losing the trade when it is. The first slot to "
                 + "reconsider."
        }
        return "Dying more than it kills. Either it is being asked to do the wrong job, "
             + "or it needs the bulk to survive what is listed below."
    }

    private func figure(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - What it reached for

    private var moves: some View {
        let used = record.moves.sorted { $0.value > $1.value }
        let carried = (slot?.moves ?? []).compactMap { store.move($0)?.name }
        let never = carried.filter { name in !used.contains { $0.key == name } }
        let total = used.reduce(0) { $0 + $1.value }
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "What it reached for",
                              subtitle: "Across every game it was brought to.")
                if used.isEmpty {
                    Text("It never got a move off.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(used, id: \.key) { move, count in
                    HStack(spacing: 8) {
                        Text(move).font(.system(size: 11))
                            .frame(width: 140, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            Capsule().fill(Palette.accent.opacity(0.7))
                                .frame(width: geo.size.width
                                       * Double(count) / Double(Swift.max(1, total)))
                        }
                        .frame(height: 5)
                        Text("\(count)").font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                if !never.isEmpty {
                    Text("Never used: " + never.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(Palette.warn)
                        .padding(.top, 2)
                    Text("A move that never gets clicked across this many games is a slot "
                         + "doing nothing.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - What takes it off the field

    @ViewBuilder private var kills: some View {
        let threats = report.worstThreats(against: form, least: 2).filter { $0.knockouts > 0 }
        if !threats.isEmpty {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "What takes it off the field",
                                  subtitle: "The Analyse tab builds this Pokémon's spread "
                                          + "against these rather than against the usage table.")
                    ForEach(threats.prefix(8)) { threat in
                        HStack(spacing: 8) {
                            Text("\(threat.attacker)'s \(threat.move)")
                                .font(.system(size: 11)).foregroundStyle(Palette.bad)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(threat.knockouts)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(threat.knockouts == 1 ? "time" : "times")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .frame(width: 36, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Whether to bring it

    @ViewBuilder private var fours: some View {
        let least = Swift.max(4, report.games / 40)
        let all = report.fours(least: least)
        let with = all.filter { $0.four.contains(form) }
        let without = all.filter { !$0.four.contains(form) }
        if !with.isEmpty, !without.isEmpty {
            let withRate = rate(with), withoutRate = rate(without)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Whether to bring it",
                                  subtitle: "How the fours that include it did against the "
                                          + "fours that did not.")
                    HStack(spacing: 22) {
                        figure(String(format: "%.0f%%", withRate * 100), "with it",
                               tint: withRate >= withoutRate ? Palette.good : Palette.bad)
                        figure(String(format: "%.0f%%", withoutRate * 100), "without it")
                        figure(String(format: "%+.0f", (withRate - withoutRate) * 100),
                               "difference",
                               tint: withRate >= withoutRate ? Palette.good : Palette.bad)
                    }
                    Text(withRate >= withoutRate
                         ? "The fours that bring it do better. Keep it in the four."
                         : "The fours that leave it behind do better. That is a reason to "
                           + "bring something else, not necessarily to cut it from the six.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(with.prefix(4), id: \.four) { row in
                        HStack(spacing: 8) {
                            Text(String(format: "%.0f%%",
                                        Double(row.wins) / Double(Swift.max(1, row.games)) * 100))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(width: 40, alignment: .trailing)
                            Text(row.four).font(.system(size: 10))
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("of \(row.games)").font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func rate(_ rows: [(four: String, wins: Int, games: Int)]) -> Double {
        let wins = rows.reduce(0) { $0 + $1.wins }
        let games = rows.reduce(0) { $0 + $1.games }
        return Double(wins) / Double(Swift.max(1, games))
    }
}
