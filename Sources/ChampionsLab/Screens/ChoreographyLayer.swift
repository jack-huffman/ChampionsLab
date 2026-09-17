//  ChoreographyLayer.swift
//  A move's choreography, drawn at an instant.
//
//  One Canvas over the arena. Each frame it asks the timeline where every
//  primitive is and draws it there with EffectSprites, lays any wash of colour
//  over the field first, and draws a Pokemon's own sprite where the recipe
//  asked for the attacker itself to fly. The cards are not drawn here: their
//  leans are card poses the playback schedules, so the cards animate with
//  SwiftUI as they always did and this layer stays a picture over them.

import SwiftUI

struct ChoreographyLayer: View {
    let scene: TurnPlayback.Scene
    /// A fixed instant, for a still; nil plays the clock from the scene's start.
    var at: TimeInterval? = nil

    var body: some View {
        if let at {
            canvas(at: at)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { slice in
                canvas(at: slice.date.timeIntervalSince(scene.startedAt))
            }
        }
    }

    private func canvas(at t: TimeInterval) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for wash in scene.timeline.washes where t >= wash.start && t <= wash.end {
                // In and out over a few frames, so a wash never snaps on.
                let edge = min(1, min(t - wash.start, wash.end - t) / 0.15)
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Self.colour(wash.colour).opacity(wash.opacity * edge)))
            }
            for sprite in scene.timeline.sprites {
                guard let pose = MoveTimeline.pose(of: sprite, at: t) else { continue }
                let w = sprite.size.width * pose.xscale, h = sprite.size.height * pose.yscale
                let rect = CGRect(x: pose.point.x - w / 2, y: pose.point.y - h / 2, width: w, height: h)
                if let seat = sprite.ghostOf {
                    guard let image = scene.ghosts[seat], rect.width > 1 else { continue }
                    var ghost = context
                    ghost.opacity = pose.opacity
                    ghost.draw(Image(nsImage: image), in: rect)
                } else {
                    EffectSprites.draw(sprite.name, in: rect, mirrored: sprite.mirrored,
                                       opacity: pose.opacity, context: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A CSS colour as the client wrote it: a hex triple, a name, or the first
    /// hex inside a gradient. Anything else is the dark the client's washes
    /// mostly are.
    static func colour(_ css: String?) -> Color {
        guard let css else { return .black }
        if let hex = css.range(of: "#[0-9a-fA-F]{3,6}", options: .regularExpression) {
            var digits = String(css[hex].dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .black }
            return Color(red: Double((value >> 16) & 0xff) / 255,
                         green: Double((value >> 8) & 0xff) / 255,
                         blue: Double(value & 0xff) / 255)
        }
        switch css.lowercased() {
        case "white": return .white
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "yellow": return .yellow
        case "orange": return .orange
        case "pink": return .pink
        case "cyan": return .cyan
        case "brown": return .brown
        default: return .black
        }
    }
}
