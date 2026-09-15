//  BattleEffects.swift
//  What the battlefield looks like while something is happening on it.
//
//  Three things live here, and they are separate because they run on different
//  clocks: the weather and the terrain are always going, and a move happens
//  once and is over.
//
//  All of it is drawn in `Canvas`. A hundred falling raindrops as a hundred
//  SwiftUI views is a hundred nodes for the layout system to keep, diff and
//  animate every frame; the same hundred in a Canvas is one node and a hundred
//  lines of arithmetic. This screen is the one place in the app with something
//  moving all the time, and it shares a machine with a search that wants every
//  core it can get, so the cheap version is the only version worth having.
//
//  Nothing here holds state. Every particle's position is a pure function of
//  its index and the clock, so there is no array to mutate, nothing to step,
//  and stopping is free: when the view is not on screen SwiftUI stops asking
//  the timeline for frames and the whole thing costs nothing.

import SwiftUI

// MARK: - A repeatable scatter

/// Deterministic noise in 0..<1 from an integer, so a particle can be told
/// where it belongs rather than remembering.
///
/// Any cheap integer hash does; this is the usual bit-mixer. What matters is
/// that it is the same every frame — a particle whose "random" offset changed
/// between frames would flicker rather than fall.
private func scatter(_ seed: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: seed &* 0x9E37_79B9) &+ 0x632B_E599
    x ^= x >> 13
    x = x &* 0xFF51_AFD7_ED55_8CCD
    x ^= x >> 17
    return Double(x % 100_000) / 100_000
}

// MARK: - Weather

/// Rain, snow, sand and sun, falling across the whole battlefield.
///
/// Drawn behind everything and never in front: this is the room the battle is
/// in, and a snowflake that lands on top of a Pokémon's face is a distraction
/// rather than a setting. Opacity is kept low for the same reason — the cards
/// have to stay readable through it.
struct WeatherLayer: View {
    let weather: Weather
    /// How much of it. Rain that is about to stop thins out, which is a turn
    /// counter you can see without reading one.
    var strength: Double = 1

    var body: some View {
        if weather == .none || strength <= 0.01 {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { slice in
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let t = slice.date.timeIntervalSinceReferenceDate
                    switch weather {
                    case .rain: rain(&context, size, t)
                    case .snow: snow(&context, size, t)
                    case .sand: sand(&context, size, t)
                    case .sun:  sun(&context, size, t)
                    case .none: break
                    }
                }
                .allowsHitTesting(false)
                .opacity(strength)
                // Particles start above the top edge and blow past the right
                // one by design, so the field has to cut them off at its own
                // border rather than letting them out over the interface.
                .clipped()
            }
        }
    }

    // -- rain ----------------------------------------------------------------
    //
    // Short slanted streaks, falling fast and at a constant angle. Rain reads
    // as rain because of the streak: a round drop at this size looks like
    // snow, and it is the direction that separates them at a glance.

    private func rain(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let drops = 90
        let colour = Color(red: 0.55, green: 0.74, blue: 1.0)
        let lean = size.height * 0.10
        for index in 0..<drops {
            let column = scatter(index)
            let speed = 1.5 + scatter(index &+ 991) * 0.9
            // fmod rather than a wrap check: a drop that reaches the bottom is
            // the same drop starting again at the top, one row over.
            let fall = (t * speed + scatter(index &+ 77)).truncatingRemainder(dividingBy: 1)
            let y = fall * (size.height + 40) - 20
            let x = column * (size.width + lean * 2) - lean + fall * lean
            let length = 9 + scatter(index &+ 313) * 11
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: y))
            streak.addLine(to: CGPoint(x: x - lean * 0.06 * length, y: y + length))
            context.stroke(streak, with: .color(colour.opacity(0.10 + scatter(index &+ 5) * 0.16)),
                           lineWidth: 1)
        }
    }

    // -- snow ----------------------------------------------------------------
    //
    // Slow, round, and swaying. The sway is what makes it snow rather than
    // slow rain: a flake does not fall in a straight line, and the eye knows.

    private func snow(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let flakes = 65
        let colour = Color(red: 0.88, green: 0.95, blue: 1.0)
        for index in 0..<flakes {
            let column = scatter(index)
            let speed = 0.10 + scatter(index &+ 401) * 0.10
            let fall = (t * speed + scatter(index &+ 53)).truncatingRemainder(dividingBy: 1)
            let y = fall * (size.height + 30) - 15
            let sway = sin(t * (0.5 + scatter(index &+ 131)) + scatter(index) * 9) * 13
            let x = column * size.width + sway
            let radius = 1.2 + scatter(index &+ 617) * 2.1
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(colour.opacity(0.20 + scatter(index &+ 7) * 0.35)))
        }
    }

    // -- sand ----------------------------------------------------------------
    //
    // Blowing across rather than falling: a sandstorm is wind, and the motes
    // go sideways. Long thin ellipses, because a mote at speed is a smear.

    private func sand(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let motes = 80
        let colour = Color(red: 0.86, green: 0.75, blue: 0.48)
        for index in 0..<motes {
            let row = scatter(index)
            let speed = 0.5 + scatter(index &+ 233) * 0.8
            let blow = (t * speed + scatter(index &+ 19)).truncatingRemainder(dividingBy: 1)
            let x = blow * (size.width + 60) - 30
            let drift = sin(t * 0.7 + scatter(index) * 11) * 9
            let y = row * size.height + drift
            let length = 5 + scatter(index &+ 811) * 12
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: length, height: 1.6)),
                with: .color(colour.opacity(0.12 + scatter(index &+ 3) * 0.22)))
        }
    }

    // -- sun -----------------------------------------------------------------
    //
    // No particles. Harsh sunlight is not something falling through the air,
    // it is the air being bright, so this is a handful of wide shafts leaning
    // across the field and breathing slowly. Four shapes rather than eighty.

    private func sun(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let colour = Color(red: 1.0, green: 0.86, blue: 0.45)
        for index in 0..<5 {
            let pulse = 0.5 + 0.5 * sin(t * 0.45 + Double(index) * 1.3)
            let width = size.width * (0.05 + scatter(index &+ 61) * 0.05)
            let x = size.width * (0.08 + scatter(index) * 0.84)
            let lean = size.height * 0.22
            var shaft = Path()
            shaft.move(to: CGPoint(x: x, y: -10))
            shaft.addLine(to: CGPoint(x: x + width, y: -10))
            shaft.addLine(to: CGPoint(x: x + width - lean, y: size.height + 10))
            shaft.addLine(to: CGPoint(x: x - lean, y: size.height + 10))
            shaft.closeSubpath()
            context.fill(shaft, with: .color(colour.opacity(0.030 + pulse * 0.045)))
        }
        // And a warmth over the whole thing, so the field itself looks lit.
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(colour.opacity(0.020 + 0.015 * sin(t * 0.3))))
    }
}

// MARK: - Terrain

/// The floor, when something has been done to it.
///
/// Terrain is underfoot, so this sits along the bottom of the field and fades
/// out upwards rather than covering it. Each one moves the way its terrain
/// suggests: grass grows upward, electricity flickers, psychic energy turns
/// over slowly, mist drifts.
struct TerrainLayer: View {
    let terrain: Terrain
    var strength: Double = 1

    var body: some View {
        if terrain == .none || strength <= 0.01 {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { slice in
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let t = slice.date.timeIntervalSinceReferenceDate
                    let colour = tint
                    // The ground itself: a band of colour that stops a third of
                    // the way up, so it reads as a floor and not a filter.
                    context.fill(
                        Path(CGRect(x: 0, y: size.height * 0.62,
                                    width: size.width, height: size.height * 0.38)),
                        with: .linearGradient(
                            Gradient(colors: [colour.opacity(0), colour.opacity(0.14)]),
                            startPoint: CGPoint(x: 0, y: size.height * 0.62),
                            endPoint: CGPoint(x: 0, y: size.height)))
                    switch terrain {
                    case .grassy:   grassy(&context, size, t, colour)
                    case .electric: electric(&context, size, t, colour)
                    case .psychic:  psychic(&context, size, t, colour)
                    case .misty:    misty(&context, size, t, colour)
                    case .none:     break
                    }
                }
                .allowsHitTesting(false)
                .opacity(strength)
                .clipped()
            }
        }
    }

    private var tint: Color {
        switch terrain {
        case .grassy:   return Color(red: 0.42, green: 0.80, blue: 0.38)
        case .electric: return Color(red: 0.96, green: 0.86, blue: 0.28)
        case .psychic:  return Color(red: 0.90, green: 0.40, blue: 0.64)
        case .misty:    return Color(red: 0.84, green: 0.60, blue: 0.90)
        case .none:     return .clear
        }
    }

    /// Blades drifting up off the floor and fading as they go.
    private func grassy(_ context: inout GraphicsContext, _ size: CGSize,
                        _ t: Double, _ colour: Color) {
        for index in 0..<34 {
            let rise = (t * (0.09 + scatter(index &+ 29) * 0.08)
                        + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = scatter(index &+ 500) * size.width
            let y = size.height - rise * size.height * 0.45
            let height = 4 + scatter(index &+ 71) * 7
            var blade = Path()
            blade.move(to: CGPoint(x: x, y: y))
            blade.addQuadCurve(to: CGPoint(x: x + 2.5, y: y - height),
                               control: CGPoint(x: x + 4.5, y: y - height * 0.5))
            context.stroke(blade, with: .color(colour.opacity((1 - rise) * 0.5)), lineWidth: 1.4)
        }
    }

    /// Sparks that sit still and blink, which is what electricity looks like
    /// when it is in the floor rather than going anywhere.
    private func electric(_ context: inout GraphicsContext, _ size: CGSize,
                          _ t: Double, _ colour: Color) {
        for index in 0..<26 {
            let phase = sin(t * (1.8 + scatter(index &+ 43) * 2.4) + scatter(index) * 12)
            guard phase > 0.55 else { continue }
            let x = scatter(index &+ 900) * size.width
            let y = size.height * (0.66 + scatter(index &+ 17) * 0.32)
            let length = 5 + scatter(index &+ 211) * 8
            var bolt = Path()
            bolt.move(to: CGPoint(x: x, y: y - length / 2))
            bolt.addLine(to: CGPoint(x: x + 2.5, y: y))
            bolt.addLine(to: CGPoint(x: x - 1.5, y: y + length / 2))
            context.stroke(bolt, with: .color(colour.opacity((phase - 0.55) * 1.7)), lineWidth: 1.3)
        }
    }

    /// Slow rings turning over, going nowhere.
    private func psychic(_ context: inout GraphicsContext, _ size: CGSize,
                         _ t: Double, _ colour: Color) {
        for index in 0..<14 {
            let grow = (t * 0.16 + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = scatter(index &+ 300) * size.width
            let y = size.height * (0.70 + scatter(index &+ 91) * 0.26)
            let radius = 4 + grow * 30
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.35,
                                       width: radius * 2, height: radius * 0.7)),
                with: .color(colour.opacity((1 - grow) * 0.70)), lineWidth: 1.4)
        }
    }

    /// Soft blobs sliding sideways, overlapping into fog.
    private func misty(_ context: inout GraphicsContext, _ size: CGSize,
                       _ t: Double, _ colour: Color) {
        for index in 0..<14 {
            let slide = (t * (0.03 + scatter(index &+ 7) * 0.04)
                         + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = slide * (size.width + 160) - 80
            let y = size.height * (0.68 + scatter(index &+ 133) * 0.30)
            let radius = 16 + scatter(index &+ 57) * 30
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.4,
                                       width: radius * 2, height: radius * 0.8)),
                with: .color(colour.opacity(0.06 + scatter(index &+ 3) * 0.05)))
        }
    }
}

// MARK: - A move being used

/// Where a Pokémon stands, so a move can be drawn from one to another.
struct Seat: Hashable {
    let mine: Bool
    let slot: Int
}

/// One move, mid-flight: who used it, what it was, and who it reached.
///
/// Built by the screen after a turn resolves. The targets are worked out by
/// diffing health across the step rather than predicted, so a spread move
/// carries two of them, a redirected one carries whoever actually took it,
/// and a miss carries none — and a miss that still draws the beam, going
/// nowhere, is exactly right.
struct Flourish: Equatable, Identifiable {
    let id: Int
    let action: Board.Action
    let targets: [Seat]

    var from: Seat { Seat(mine: action.byMine, slot: action.slot) }
    var type: PokeType? { PokeType(loose: action.type) }
    var isPhysical: Bool { action.category == "Physical" }
    var isSpecial: Bool { action.category == "Special" }
    var isSwitch: Bool { action.category == "Switch" }
    /// A colour to draw it in. Typeless things — a switch, a move whose type
    /// the dataset does not give — fall back to the interface accent rather
    /// than drawing nothing, because something did happen.
    var colour: Color { type?.color ?? Palette.accent }
}

/// The beam a special move sends, and the burst where it lands.
///
/// Drawn over the field but under the cards' text, in the move's own type
/// colour: the whole point is that a Flamethrower and a Surf do not look
/// alike. `progress` runs 0 to 1 across the length of the animation, and the
/// beam is a head with a tail behind it rather than a line that grows, so it
/// reads as something travelling rather than something being drawn.
struct BeamLayer: View {
    let flourish: Flourish
    let progress: Double
    /// Where a seat sits, in this view's coordinates.
    let place: (Seat) -> CGPoint

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let start = place(flourish.from)
            let colour = flourish.colour
            for target in flourish.targets {
                let end = place(target)
                draw(&context, from: start, to: end, colour: colour)
            }
            // A move that reached nobody still leaves the user: it fires past
            // the middle of the field and fades, which is what a miss looks
            // like and what a self-targeting move looks like too.
            if flourish.targets.isEmpty {
                let away = CGPoint(x: start.x + (flourish.from.mine ? 110 : -110), y: start.y - 12)
                draw(&context, from: start, to: away, colour: colour, landing: false)
            }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }

    /// `landing` is false for a move that reached nobody: the beam still
    /// fires, because the Pokémon still used it, but nothing bursts — a bloom
    /// in empty space reads as a hit that did not happen.
    private func draw(_ context: inout GraphicsContext,
                      from start: CGPoint, to end: CGPoint, colour: Color,
                      landing: Bool = true) {
        // The head travels the whole way in the first two thirds; the last
        // third is the burst, with the beam fading behind it.
        let travel = min(1, progress / 0.62)
        let eased = travel * travel * (3 - 2 * travel)
        let head = CGPoint(x: start.x + (end.x - start.x) * eased,
                           y: start.y + (end.y - start.y) * eased)
        let tailAt = max(0, eased - 0.34)
        let tail = CGPoint(x: start.x + (end.x - start.x) * tailAt,
                           y: start.y + (end.y - start.y) * tailAt)
        let fade = progress > 0.62 ? 1 - (progress - 0.62) / 0.38 : 1

        var beam = Path()
        beam.move(to: tail)
        beam.addLine(to: head)
        context.stroke(beam, with: .linearGradient(
            Gradient(colors: [colour.opacity(0), colour.opacity(0.85 * fade)]),
            startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: 7, lineCap: .round))
        context.stroke(beam, with: .linearGradient(
            Gradient(colors: [colour.opacity(0), .white.opacity(0.75 * fade)]),
            startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

        // The burst, once the head is there.
        guard landing, progress > 0.55 else { return }
        let bloom = (progress - 0.55) / 0.45
        let radius = 8 + bloom * 30
        let alpha = (1 - bloom) * 0.65
        context.stroke(
            Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .color(colour.opacity(alpha)), lineWidth: 2.5)
        context.fill(
            Path(ellipseIn: CGRect(x: end.x - radius * 0.45, y: end.y - radius * 0.45,
                                   width: radius * 0.9, height: radius * 0.9)),
            with: .color(colour.opacity(alpha * 0.5)))
    }
}

/// The hit a physical move lands: a ring of spikes thrown outward from the
/// point of contact, in the move's type colour.
///
/// Physical moves do not get a beam, because a physical move is the Pokémon
/// arriving in person — the card itself lunges, and this is what happens when
/// it gets there.
struct ImpactLayer: View {
    let flourish: Flourish
    let progress: Double
    let place: (Seat) -> CGPoint

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            // Contact lands at the far end of the lunge, not at the start of it.
            guard progress > 0.42 else { return }
            let bloom = min(1, (progress - 0.42) / 0.58)
            let colour = flourish.colour
            for target in flourish.targets {
                let at = place(target)
                let alpha = (1 - bloom) * 0.8
                for spoke in 0..<9 {
                    let angle = Double(spoke) / 9 * .pi * 2 + scatter(spoke) * 0.7
                    let near = 6 + bloom * 16
                    let far = near + 7 + scatter(spoke &+ 31) * 12 * bloom
                    var spike = Path()
                    spike.move(to: CGPoint(x: at.x + cos(angle) * near,
                                           y: at.y + sin(angle) * near))
                    spike.addLine(to: CGPoint(x: at.x + cos(angle) * far,
                                              y: at.y + sin(angle) * far))
                    context.stroke(spike, with: .color(colour.opacity(alpha)),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
                let radius = 5 + bloom * 22
                context.stroke(
                    Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(alpha * 0.55)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}

/// A status move: nothing is thrown, so the user gets a ring instead.
///
/// Swords Dance and Thunder Wave are both things that happen *to* somebody
/// rather than across the field, and a ring expanding off whoever is affected
/// says that without needing to know which of the two it was.
struct AuraLayer: View {
    let flourish: Flourish
    let progress: Double
    let place: (Seat) -> CGPoint

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let colour = flourish.colour
            // On whoever it reached, or on the user when it reached nobody,
            // which is what a Swords Dance is.
            let seats = flourish.targets.isEmpty ? [flourish.from] : flourish.targets
            for seat in seats {
                let at = place(seat)
                for ring in 0..<3 {
                    let offset = Double(ring) * 0.22
                    let phase = progress - offset
                    guard phase > 0, phase < 1 else { continue }
                    let radius = 10 + phase * 40
                    context.stroke(
                        Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius * 0.62,
                                               width: radius * 2, height: radius * 1.24)),
                        with: .color(colour.opacity((1 - phase) * 0.55)), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}
