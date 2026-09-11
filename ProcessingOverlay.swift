//  ProcessingOverlay.swift
//  What the app shows while it is thinking.
//
//  The builder and the refiner take a second or two, and they used to take it
//  silently: `working` was set to true, the work ran on the main actor without
//  yielding, and SwiftUI never got a frame in which to draw anything. The
//  window simply froze and then the answer appeared. Both now hand back control
//  between steps, which is what makes this overlay able to animate at all — and
//  lets it say which step it is on rather than spinning anonymously.

import SwiftUI

/// A ring that turns while something is being worked out.
struct ProcessingOverlay: View {
    let title: String
    /// The step being worked on, which changes as it goes.
    var step: String?
    /// 0…1 where the work knows how far along it is; nil for indeterminate.
    var fraction: Double?
    var onCancel: (() -> Void)?

    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ring
                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    if let step {
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(minHeight: 30, alignment: .top)
                            .animation(.easeInOut(duration: 0.15), value: step)
                    }
                }
                .frame(width: 260)

                if let fraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.hairline)
                            Capsule().fill(Palette.accent)
                                .frame(width: geo.size.width * min(1, max(0, fraction)))
                                .animation(.easeOut(duration: 0.2), value: fraction)
                        }
                    }
                    .frame(width: 220, height: 5)
                }

                if let onCancel {
                    Button("Stop", action: onCancel)
                        .controlSize(.small)
                }
            }
            .padding(28)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
        .transition(.opacity)
        .onAppear { spin = true; pulse = true }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Palette.hairline, lineWidth: 4)
            // Two arcs at different speeds, so it reads as working rather than
            // as a progress bar that has stalled.
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(
                    AngularGradient(colors: [Palette.accent.opacity(0.1), Palette.accent],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(Palette.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: spin)
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 16))
                .foregroundStyle(Palette.accent)
                .opacity(pulse ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        }
        .frame(width: 54, height: 54)
    }
}
