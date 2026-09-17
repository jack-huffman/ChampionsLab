//  TurnStepper.swift
//  Back and forward through the turn that just played.
//
//  A turn resolves all at once and is shown as it happened; this is the way
//  to stop it and look. Stepping through a turn is how you learn why it went
//  the way it did, which is the entire reason to play one out rather than
//  read a score. The field shows it under the arena while a turn is fresh,
//  and the deck shows it beside the orders once the next one is being given.

import SwiftUI

struct TurnStepper: View {
    @ObservedObject var session: BattleSession
    @ObservedObject var playback: TurnPlayback
    private var turn: Int { get { session.turn } nonmutating set { session.turn = newValue } }
    private var grade: String? { get { session.grade } nonmutating set { session.grade = newValue } }
    private var replay: [Board.Step] { get { playback.replay } nonmutating set { playback.replay = newValue } }
    private var at: Int { get { playback.at } nonmutating set { playback.at = newValue } }

    /// A turn arrives as a sequence, so it is shown as one.
    ///
    /// Everything lands at once otherwise: four actions, the residuals and two
    /// faints in a single jump, with no way to see what caused what. Stepping
    /// through it is how you learn why a turn went the way it did, which is the
    /// entire reason to play one out rather than read a score.
    var body: some View {
        let step = replay.indices.contains(at) ? replay[at] : nil
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                SectionHeader(title: "Turn \(turn - 1), step \(at + 1) of \(replay.count)")
                if let step {
                    Text(step.text)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(replay.prefix(at).enumerated().reversed()), id: \.offset) {
                        _, earlier in
                        Text(earlier.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Back") { at = max(0, at - 1) }
                        .controlSize(.small).disabled(at == 0)
                    Button(at + 1 >= replay.count ? "Done" : "Next") {
                        if at + 1 >= replay.count { replay = []; at = 0 } else { at += 1 }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    Button("Skip to the end") { replay = []; at = 0 }.controlSize(.small)
                    Spacer()
                    if let grade {
                        Text(grade).font(.system(size: 10))
                            .foregroundStyle(grade.hasPrefix("That is")
                                             ? AnyShapeStyle(Palette.good)
                                             : AnyShapeStyle(Palette.warn))
                    }
                }
            }
        }
    }
}
