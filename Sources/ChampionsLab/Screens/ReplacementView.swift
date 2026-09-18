//  ReplacementView.swift
//  Something of yours went down, or went out under its own move; who comes in.
//
//  The game asks this and it matters: whoever arrives takes whatever lands
//  next turn without acting first, so it is a choice between what answers what
//  is out and what survives arriving. Both halves are worked out and the
//  better of them named, but the pick stays yours. Once every gap has one, the
//  replacements go in together in Speed order alongside theirs, and the session
//  thinks about the new position.

import SwiftUI

struct ReplacementView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    @ObservedObject var session: BattleSession
    let board: Board
    private var log: [String] { get { session.log } nonmutating set { session.log = newValue } }
    private var sending: [Int] { get { session.sending } nonmutating set { session.sending = newValue } }
    private var chosenSends: [(slot: Int, bench: Int)] { get { session.chosenSends } nonmutating set { session.chosenSends = newValue } }

    /// Who comes in, with a reason rather than a shrug.
    ///
    /// The game asks this and it matters: whoever arrives takes whatever lands
    /// next turn without acting first, so it is a choice between what answers
    /// what is out and what survives arriving. Both halves are worked out and
    /// the better of them named, but the pick stays yours.
    var body: some View {
        let slot = sending.first { gap in !chosenSends.contains { $0.slot == gap } } ?? sending.first ?? 0
        let options = (board.activeCount..<board.mine.count)
            .filter { index in !board.mine[index].fainted && !chosenSends.contains { $0.bench == index } }
            .map { (index: $0, reading: BattleSession.sendInReading(board, bench: $0)) }
            .sorted { $0.reading.score > $1.reading.score }
        let theyToo = (0..<min(board.activeCount, board.theirs.count)).contains { board.theirs[$0].fainted }
        // A pivot -- U-turn, Parting Shot, an Eject Button -- stopped the
        // turn partway; the rest of it plays once somebody has come in.
        let pivoting = session.pivoting
        let leaving = board.mine.indices.contains(slot) ? board.mine[slot].build.form.formLabel : "It"
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: pivoting ? "Who comes in?" : sending.count > 1 ? "Send two in" : "Send one in",
                              subtitle: pivoting
                                ? "\(leaving) is coming back under its own move. The rest of the turn plays out once someone has taken its place, and whoever comes in takes whatever is still to land."
                                : (theyToo
                                ? "They lost one too. Both sides send in at once, and the faster arrives first — its ability going off before the slower one even lands. "
                                : "")
                                + "Whoever comes arrives without acting, so it takes whatever lands next turn.")
                if let best = options.first {
                    Text("Suggested: \(board.mine[best.index].build.form.formLabel) — "
                         + best.reading.why)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { rank, option in
                        Button {
                            if pivoting {
                                session.resumeTurn(bench: option.index)
                                return
                            }
                            chosenSends.append((slot: slot, bench: option.index))
                            guard chosenSends.count >= sending.count else { return }
                            if session.link != nil {
                                session.sendReplacements(chosenSends)
                                return
                            }
                            var next = board
                            next.story = []
                            next.replaceFallen(mine: chosenSends)
                            log.append(contentsOf: next.story)
                            session.board = next
                            sending = next.gapsOfMine
                            chosenSends = []
                            if sending.isEmpty {
                                // The turn is answered; the field shows the new position.
                                session.playback.finish()
                                session.think()
                            }
                        } label: {
                            HStack(spacing: 9) {
                                SpriteImage(form: board.mine[option.index].build.form, side: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(board.mine[option.index].build.form.formLabel)
                                            .font(.system(size: 12, weight: .medium))
                                        if rank == 0 {
                                            Text("BEST")
                                                .font(.system(size: 8, weight: .bold)).kerning(0.4)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Palette.accent.opacity(0.2))
                                                .foregroundStyle(Palette.accent)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(option.reading.why)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rank == 0 ? Palette.accent.opacity(0.12) : Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                rank == 0 ? Palette.accent.opacity(0.5) : Palette.hairline,
                                lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

}
