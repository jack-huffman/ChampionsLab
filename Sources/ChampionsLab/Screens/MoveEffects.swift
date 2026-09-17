//  MoveEffects.swift
//  The cards' leans and the ground's shake, carried by the render server.
//
//  A recipe moves the cards a dozen times in a second. Publishing each lean as
//  it began re-evaluated the whole field -- cards, side panel, log -- every
//  time, which is what a stutter is. Instead the playback publishes one clock
//  that SwiftUI animates from 0 to 1 over the move, and these effects read it
//  each frame: a GeometryEffect's transform is asked for by the render server,
//  not by the view's body, so the cards move at full frame rate while the
//  field is evaluated once at the start of the move and once at its end.

import SwiftUI

/// Where a card is at this moment of the move, from its leans and the clock.
struct LeanEffect: GeometryEffect {
    var progress: Double
    let leans: [MoveTimeline.Lean]
    let duration: TimeInterval

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !leans.isEmpty else { return ProjectionTransform(.identity) }
        let pose = MoveTimeline.lean(in: leans, at: progress * duration)
        var transform = CGAffineTransform(translationX: size.width / 2 + pose.offset.width,
                                          y: size.height / 2 + pose.offset.height)
        transform = transform.scaledBy(x: pose.scale, y: pose.scale)
        transform = transform.translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

/// The field jolted a few points while the ground shakes.
struct QuakeEffect: GeometryEffect {
    var progress: Double
    let shakes: [MoveTimeline.Shake]
    let duration: TimeInterval

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let now = progress * duration
        guard shakes.contains(where: { now >= $0.start && now <= $0.end }) else {
            return ProjectionTransform(.identity)
        }
        return ProjectionTransform(CGAffineTransform(translationX: sin(now * 90) * 4, y: cos(now * 70) * 2))
    }
}
