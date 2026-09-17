//  StatArrows.swift
//  The game's sign for a stat changing: a stream of arrows rising over the
//  Pokemon when a stage goes up, falling when it comes down.
//
//  Eight chevrons scattered across the Pokemon's width, each starting a
//  moment after the last, travelling most of a body's height and fading as
//  they go. Drawn from a clock rather than animated state, so the field's
//  body is not re-evaluated for every arrow.

import SwiftUI

struct StatArrows: View {
    let up: Bool
    let tint: Color
    let side: CGFloat

    private static let count = 8
    private static let travel: TimeInterval = 0.9
    private static let stagger: TimeInterval = 0.07
    /// Where each arrow sits across the width, spread rather than random so
    /// the same change always looks the same.
    private static let lanes: [CGFloat] = [-0.36, 0.12, -0.18, 0.34, -0.04, 0.26, -0.3, 0.06]

    @State private var began = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let elapsed = context.date.timeIntervalSince(began)
            ZStack {
                ForEach(0..<Self.count, id: \.self) { index in
                    let start = Double(index) * Self.stagger
                    let progress = min(1, max(0, (elapsed - start) / Self.travel))
                    let eased = 1 - pow(1 - progress, 2)
                    let y = (up ? 1 : -1) * (side * 0.28 - eased * side * 0.7)
                    Image(systemName: up ? "chevron.up" : "chevron.down")
                        .font(.system(size: side * 0.13, weight: .black))
                        .foregroundStyle(tint)
                        .shadow(color: tint.opacity(0.9), radius: 4)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: Self.lanes[index] * side, y: y)
                        .opacity(progress <= 0 ? 0 : (1 - progress) * 1.2)
                }
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}
