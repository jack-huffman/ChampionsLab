//  GamePlanView.swift
//  The three questions, rendered the same way wherever a team appears.

import SwiftUI

struct GamePlanCard: View {
    @EnvironmentObject private var store: Store
    let team: Team
    var format = "doubles"
    /// Precomputed by the builder, which already has them; nil means work it
    /// out here, which is what the advisor does for a saved team.
    var precomputed: [GamePlanner.Answer]?
    var compact = false

    private var answers: [GamePlanner.Answer] {
        precomputed ?? GamePlanner(store: store, team: team, format: format).answers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "The three questions",
                          subtitle: "What this six does when it is outsped, when the Speed order flips, and when the field is not neutral.")
            ForEach(answers) { answer in
                row(answer)
            }
        }
    }

    private func row(_ answer: GamePlanner.Answer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol(answer.standing))
                    .font(.system(size: 11))
                    .foregroundStyle(colour(answer.standing))
                Text(answer.question)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Text(answer.standing.label)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(colour(answer.standing).opacity(0.18))
                    .foregroundStyle(colour(answer.standing))
                    .clipShape(Capsule())
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(answer.steps.prefix(compact ? 3 : 8).enumerated()),
                        id: \.element) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(step)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let fix = answer.fix {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wrench.adjustable")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 14, alignment: .trailing)
                        Text(fix)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 17)
        }
        .padding(.vertical, 3)
    }

    private func symbol(_ standing: GamePlanner.Answer.Standing) -> String {
        switch standing {
        case .solid:   return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .none:    return "xmark.octagon.fill"
        }
    }

    private func colour(_ standing: GamePlanner.Answer.Standing) -> Color {
        switch standing {
        case .solid:   return Palette.good
        case .partial: return Palette.warn
        case .none:    return Palette.bad
        }
    }
}
