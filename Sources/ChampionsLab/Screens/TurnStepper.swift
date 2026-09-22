//  TurnStepper.swift
//  The turn that just played, as it happened, one row a moment.
//
//  A turn resolves all at once and is shown as it happened; this is the way
//  to stop it and look. The rows read as the log does -- what happened, with
//  its reasons hung under it -- and appear at the bottom as each blow lands,
//  so the list grows with the turn. Clicking a row takes the field back to
//  that moment and plays the move again. Stepping through a turn is how you
//  learn why it went the way it did, which is the entire reason to play one
//  out rather than read a score.

import SwiftUI

struct TurnStepper: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var session: BattleSession
    @ObservedObject var playback: TurnPlayback
    /// A game between two people is played in real time: the rows appear
    /// as the turn plays and that is all -- no stepping back, no playing a
    /// step again, no Done. The Review and Log panels keep the record.
    var live = false
    private var replay: [Board.Step] { playback.replay }
    private var at: Int { playback.at }

    /// One thing that happened in a step, with the reasons for it. A step
    /// usually holds one; a move that faints something holds the faint too.
    private struct Moment: Identifiable {
        let id: Int
        let headline: String
        let details: [String]
    }

    var body: some View {
        // The turn shown is the one that just played -- or the one stopped
        // partway for a pivot, which has not been counted yet.
        let played = session.pivoting ? session.turn : session.turn - 1
        // The row lit is the step playing, or the one the field rests on.
        // Minus one before the turn begins: nothing lit, nothing listed.
        let lit = playback.focus ?? at
        let shown = Array(replay.prefix(max(playback.seen, lit + 1)))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                header(played)
                ScrollViewReader { proxy in
                    MaybeScroll {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                                row(step, index: index, lit: lit)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .onChange(of: playback.seen) { count in
                        guard let last = replay.indices.contains(count - 1) ? replay[count - 1] : nil else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: at) { current in
                        guard replay.indices.contains(current) else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(replay[current].id, anchor: .bottom) }
                    }
                    .onChange(of: playback.focus) { current in
                        guard let current, replay.indices.contains(current) else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(replay[current].id, anchor: .bottom) }
                    }
                }
                if let grade = session.grade {
                    Text(grade).font(.system(size: 10))
                        .foregroundStyle(grade.hasPrefix("That is")
                                         ? AnyShapeStyle(Palette.good)
                                         : AnyShapeStyle(Palette.warn))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The turn, where in it we are, and the way back and forward. Done puts
    /// the stepper away -- or, when someone has to come in, hands over to
    /// that choice.
    private func header(_ played: Int) -> some View {
        HStack(spacing: 10) {
            Text("TURN \(played)")
                .font(.system(size: 13, weight: .heavy)).kerning(0.8)
            Text("step \(Swift.max(0, at) + 1) of \(replay.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.accent.opacity(0.16)))
                .foregroundStyle(Palette.accent)
            if playback.task != nil {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text("playing").font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
            Spacer()
            if live { EmptyView() } else {
            Button { playback.replay(step: Swift.max(0, at) - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .controlSize(.small).disabled(at <= 0)
            .help("The step before, played again")
            Button { playback.replay(step: Swift.max(0, at) + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .controlSize(.small).disabled(Swift.max(0, at) + 1 >= replay.count)
            .help("The next step")
            Button(session.sending.isEmpty ? "Done" : "Who comes in") { session.stopReviewing() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help(session.sending.isEmpty ? "Back to giving orders"
                      : "On to choosing who comes in")
            }
        }
    }

    /// One step: who acted, what happened, and why -- the log's own shape.
    /// The row being shown on the field is lit; clicking any row shows it.
    private func row(_ step: Board.Step, index: Int, lit: Int) -> some View {
        let current = index == lit
        let moments = moments(of: step)
        return Button { if !live { playback.replay(step: index) } } label: {
            HStack(alignment: .top, spacing: 9) {
                marker(step, current: current)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(moments) { moment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(moment.headline)
                                .font(.system(size: 11, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? AnyShapeStyle(.primary)
                                                         : AnyShapeStyle(.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(moment.details.enumerated()), id: \.offset) { _, detail in
                                HStack(alignment: .top, spacing: 6) {
                                    Rectangle()
                                        .fill(current ? Palette.accent.opacity(0.45) : Palette.hairline)
                                        .frame(width: 2)
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if current, playback.task != nil {
                    ProgressView().controlSize(.mini).padding(.top, 1)
                } else if step.action != nil, !live {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(current ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Palette.accent.opacity(0.12) : Palette.surfaceRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(current ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(live)
        .id(step.id)
        .help(live ? "" : step.action == nil ? "Show the field at this moment"
              : "Show the field at this moment and play the move again")
    }

    /// Who the step belongs to: the sprite of the Pokemon that acted, ringed
    /// in its side's colour, or a glass for the end of the turn.
    @ViewBuilder
    private func marker(_ step: Board.Step, current: Bool) -> some View {
        if let action = step.action,
           let id = (action.byMine ? step.myForms : step.theirForms)[safe: action.slot],
           let form = store.formsByID[id] {
            SpriteImage(form: form, side: 26)
                .padding(2)
                .background(Circle().fill(Palette.surface))
                .overlay(Circle().strokeBorder(
                    (action.byMine ? Palette.accent : Palette.bad).opacity(current ? 0.9 : 0.45),
                    lineWidth: 1.5))
        } else {
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.surface))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    /// The step's lines, read the way the log reads them: a line is what
    /// happened, an indented line under it is why. A spread move says the
    /// same reason once per target, and once is enough.
    private func moments(of step: Board.Step) -> [Moment] {
        var out: [Moment] = []
        for line in step.text.split(separator: "\n", omittingEmptySubsequences: true) {
            let detail = line.hasPrefix("  ")
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if detail, let last = out.last {
                guard !last.details.contains(text) else { continue }
                out[out.count - 1] = Moment(id: last.id, headline: last.headline,
                                            details: last.details + [text])
            } else {
                out.append(Moment(id: out.count, headline: text, details: []))
            }
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
