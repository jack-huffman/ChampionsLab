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

    /// Nothing moves while the window is in the background. A battlefield
    /// nobody is looking at does not need to keep raining, and this screen
    /// shares a machine with a search that wants every core it can get.
    @Environment(\.controlActiveState) private var active
    /// And nothing moves at all if the system has been asked to keep still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if weather == .none || strength <= 0.01 {
            Color.clear
        } else if reduceMotion {
            // The weather is still information, so it stays — as a wash of
            // colour rather than as movement.
            Rectangle().fill(still.opacity(0.10 * strength)).allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                    paused: active == .inactive)) { slice in
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

    /// The colour each sky washes the field in when it is not moving.
    private var still: Color {
        switch weather {
        case .rain: return Color(red: 0.42, green: 0.60, blue: 0.92)
        case .snow: return Color(red: 0.74, green: 0.88, blue: 0.98)
        case .sand: return Color(red: 0.80, green: 0.70, blue: 0.44)
        case .sun:  return Color(red: 1.0, green: 0.84, blue: 0.42)
        case .none: return .clear
        }
    }

    // -- rain ----------------------------------------------------------------
    //
    // Short slanted streaks. Rain reads as rain because of the streak: a round
    // drop at this size looks like snow, and the direction is what separates
    // them at a glance.
    //
    // The first version had ninety drops falling three times this fast. That
    // reads as static rather than as weather: it pulled the eye off the board,
    // and it cost a great deal more than it was worth on a machine that has a
    // search to run. Weather is the room the battle is in, not a thing to
    // watch.

    private func rain(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let drops = 26
        let colour = Color(red: 0.55, green: 0.74, blue: 1.0)
        let lean = size.height * 0.10
        for index in 0..<drops {
            let column = scatter(index)
            let speed = 0.42 + scatter(index &+ 991) * 0.26
            // fmod rather than a wrap check: a drop that reaches the bottom is
            // the same drop starting again at the top, one row over.
            let fall = (t * speed + scatter(index &+ 77)).truncatingRemainder(dividingBy: 1)
            let fell = size.height + 40
            let y = fall * fell - 20
            let x = column * (size.width + lean * 2) - lean + fall * lean
            let length = 8 + scatter(index &+ 313) * 9
            // The streak has to lie along the way the drop is actually going,
            // and trail behind it. It used to be drawn at a steep angle of its
            // own, leaning the opposite way to the travel — so the rain fell
            // more or less straight down while every drop looked like it was
            // being blown sideways.
            let run = (lean * lean + fell * fell).squareRoot()
            let alongX = lean / run, alongY = fell / run
            var streak = Path()
            streak.move(to: CGPoint(x: x - alongX * length, y: y - alongY * length))
            streak.addLine(to: CGPoint(x: x, y: y))
            context.stroke(streak, with: .color(colour.opacity(0.05 + scatter(index &+ 5) * 0.07)),
                           lineWidth: 1)
        }
    }

    // -- snow ----------------------------------------------------------------
    //
    // Slow, round, and swaying. The sway is what makes it snow rather than
    // slow rain: a flake does not fall in a straight line, and the eye knows.

    private func snow(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let flakes = 22
        let colour = Color(red: 0.88, green: 0.95, blue: 1.0)
        for index in 0..<flakes {
            let column = scatter(index)
            let speed = 0.05 + scatter(index &+ 401) * 0.05
            let fall = (t * speed + scatter(index &+ 53)).truncatingRemainder(dividingBy: 1)
            let y = fall * (size.height + 30) - 15
            let sway = sin(t * (0.5 + scatter(index &+ 131)) + scatter(index) * 9) * 13
            let x = column * size.width + sway
            let radius = 1.2 + scatter(index &+ 617) * 2.1
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(colour.opacity(0.10 + scatter(index &+ 7) * 0.16)))
        }
    }

    // -- sand ----------------------------------------------------------------
    //
    // Blowing across rather than falling: a sandstorm is wind, and the motes
    // go sideways. Long thin ellipses, because a mote at speed is a smear.

    private func sand(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let motes = 26
        let colour = Color(red: 0.86, green: 0.75, blue: 0.48)
        for index in 0..<motes {
            let row = scatter(index)
            let speed = 0.18 + scatter(index &+ 233) * 0.26
            let blow = (t * speed + scatter(index &+ 19)).truncatingRemainder(dividingBy: 1)
            let x = blow * (size.width + 60) - 30
            let drift = sin(t * 0.7 + scatter(index) * 11) * 9
            let y = row * size.height + drift
            let length = 5 + scatter(index &+ 811) * 12
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: length, height: 1.6)),
                with: .color(colour.opacity(0.06 + scatter(index &+ 3) * 0.10)))
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
            context.fill(shaft, with: .color(colour.opacity(0.016 + pulse * 0.020)))
        }
        // And a warmth over the whole thing, so the field itself looks lit.
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(colour.opacity(0.012 + 0.008 * sin(t * 0.3))))
    }
}

// MARK: - Terrain

/// The floor, when something has been done to it.
///
/// Terrain is underfoot, so this sits along the bottom of the field and fades
/// out upwards rather than covering it. Each one moves the way its terrain
/// suggests: grass grows upward, electricity flickers, psychic energy turns
/// over slowly, mist drifts.
///
/// The four are told apart by what they are made of before they are told
/// apart by colour -- blades standing up, angular sparks, flat rings opening
/// out, soft banks sliding sideways. A field you have to name by its hue is a
/// field some people cannot read at all, and the shapes carry it on their own.
/// The word for it sits at the top of the arena besides.
///
/// It used to draw at nine per cent over a near-black floor, which is to say
/// it did not draw. What is here now is meant to be seen from across a room.
struct TerrainLayer: View {
    let terrain: Terrain
    var strength: Double = 1

    @Environment(\.controlActiveState) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if terrain == .none || strength <= 0.01 {
            Color.clear
        } else if reduceMotion {
            Rectangle().fill(LinearGradient(
                colors: [tint.opacity(0), tint.opacity(0.30 * strength)],
                startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                    paused: active == .inactive)) { slice in
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let t = slice.date.timeIntervalSinceReferenceDate
                    let colour = tint
                    // The ground itself: a band of colour that stops short of
                    // halfway up, so it reads as a floor and not a filter.
                    context.fill(
                        Path(CGRect(x: 0, y: size.height * 0.40,
                                    width: size.width, height: size.height * 0.60)),
                        with: .linearGradient(
                            Gradient(colors: [colour.opacity(0), colour.opacity(0.12),
                                              colour.opacity(0.34)]),
                            startPoint: CGPoint(x: 0, y: size.height * 0.40),
                            endPoint: CGPoint(x: 0, y: size.height)))
                    // And the near edge of it, brightest where the floor is
                    // closest to the eye.
                    context.fill(
                        Path(CGRect(x: 0, y: size.height * 0.88,
                                    width: size.width, height: size.height * 0.12)),
                        with: .linearGradient(
                            Gradient(colors: [colour.opacity(0), colour.opacity(0.22)]),
                            startPoint: CGPoint(x: 0, y: size.height * 0.88),
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
        for index in 0..<30 {
            let rise = (t * (0.09 + scatter(index &+ 29) * 0.08)
                        + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = scatter(index &+ 500) * size.width
            let y = size.height - rise * size.height * 0.50
            let height = 7 + scatter(index &+ 71) * 13
            var blade = Path()
            blade.move(to: CGPoint(x: x, y: y))
            blade.addQuadCurve(to: CGPoint(x: x + 3.5, y: y - height),
                               control: CGPoint(x: x + 6.5, y: y - height * 0.5))
            context.stroke(blade, with: .color(colour.opacity((1 - rise) * 0.75)), lineWidth: 2.1)
        }
    }

    /// Sparks that sit still and blink, which is what electricity looks like
    /// when it is in the floor rather than going anywhere.
    private func electric(_ context: inout GraphicsContext, _ size: CGSize,
                          _ t: Double, _ colour: Color) {
        for index in 0..<22 {
            let phase = sin(t * (1.8 + scatter(index &+ 43) * 2.4) + scatter(index) * 12)
            guard phase > 0.40 else { continue }
            let x = scatter(index &+ 900) * size.width
            let y = size.height * (0.52 + scatter(index &+ 17) * 0.46)
            let length = 9 + scatter(index &+ 211) * 14
            var bolt = Path()
            bolt.move(to: CGPoint(x: x, y: y - length / 2))
            bolt.addLine(to: CGPoint(x: x + 4, y: y))
            bolt.addLine(to: CGPoint(x: x - 2.5, y: y + length / 2))
            context.stroke(bolt, with: .color(colour.opacity((phase - 0.40) * 1.6)), lineWidth: 2.3)
        }
    }

    /// Slow rings turning over, going nowhere.
    private func psychic(_ context: inout GraphicsContext, _ size: CGSize,
                         _ t: Double, _ colour: Color) {
        for index in 0..<14 {
            let grow = (t * 0.16 + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = scatter(index &+ 300) * size.width
            let y = size.height * (0.56 + scatter(index &+ 91) * 0.40)
            let radius = 6 + grow * 46
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.35,
                                       width: radius * 2, height: radius * 0.7)),
                with: .color(colour.opacity((1 - grow) * 0.80)), lineWidth: 2.3)
        }
    }

    /// Soft blobs sliding sideways, overlapping into fog.
    private func misty(_ context: inout GraphicsContext, _ size: CGSize,
                       _ t: Double, _ colour: Color) {
        for index in 0..<11 {
            let slide = (t * (0.03 + scatter(index &+ 7) * 0.04)
                         + scatter(index)).truncatingRemainder(dividingBy: 1)
            let x = slide * (size.width + 160) - 80
            let y = size.height * (0.56 + scatter(index &+ 133) * 0.42)
            let radius = 22 + scatter(index &+ 57) * 42
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.4,
                                       width: radius * 2, height: radius * 0.8)),
                with: .color(colour.opacity(0.065 + scatter(index &+ 3) * 0.075)))
        }
    }
}

// MARK: - A move being used

/// Where a Pokémon stands, so a move can be drawn from one to another.
struct Seat: Hashable {
    let mine: Bool
    let slot: Int

    /// The far side's slots as they stand on screen, left to right. Their
    /// first slot stands on the right -- the stage mirrors the field, so their
    /// left is your right -- and a list a player reads against the picture
    /// should run the way the picture does.
    static func farSlotsLeftToRight(_ board: Board) -> [Int] {
        Array((0..<min(board.activeCount, board.theirs.count)).reversed())
    }

}
