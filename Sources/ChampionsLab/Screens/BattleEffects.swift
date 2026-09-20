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

// MARK: - Coming out, and going back in

/// A Poké Ball, drawn rather than drawn from a file.
///
/// Showdown ships one as a sprite; this app ships no item art at battle size
/// and the shape is four circles and a band, so it is drawn. It is the same
/// ball whatever anybody is actually carrying — the game does not tell you
/// what ball a Pokémon came from, and guessing would be inventing.
struct PokeBall: View {
    var side: CGFloat = 26
    /// Open: the top half hinges up and the inside glows.
    var open: Bool = false

    @ObservedObject private var art = ShowdownArt.shared

    var body: some View {
        ZStack {
            if let real = art.effect("pokeball") {
                // Showdown's own, which is what everybody already pictures.
                // Fetched once and kept; until it lands, and if it never
                // does, the drawn one below stands in.
                Image(nsImage: real)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: side, height: side)
                    .rotation3DEffect(.degrees(open ? 140 : 0), axis: (x: 1, y: 0, z: 0),
                                      anchor: .center, perspective: 0.4)
            } else {
                // The white half and the band stay put; the red lid hinges off
                // them and lifts clear, which is why the two are drawn
                // separately and only the bottom is clipped to the circle.
                bottom
                lid
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.5), radius: side * 0.12, y: side * 0.06)
    }

    private var bottom: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.98, blue: 0.98),
                                              Color(red: 0.80, green: 0.80, blue: 0.82)],
                                     startPoint: .top, endPoint: .bottom))
            // What is inside, once the lid is off it.
            if open {
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(red: 1, green: 0.95, blue: 0.7)],
                                         center: .top, startRadius: 0, endRadius: side * 0.6))
                    .mask(alignment: .top) { Rectangle().frame(height: side * 0.5) }
            }
            Rectangle()
                .fill(.black.opacity(0.85))
                .frame(height: Swift.max(1.5, side * 0.09))
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(.black.opacity(0.8), lineWidth: Swift.max(1, side * 0.045)))
                .frame(width: side * 0.3, height: side * 0.3)
                .opacity(open ? 0 : 1)
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: Swift.max(1, side * 0.05)))
    }

    /// The top half, as a half-disc rather than a wedge: a full circle masked
    /// to its top, so lifting it looks like a lid coming off and not like a
    /// slice being cut out of a pie.
    private var lid: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.31, blue: 0.25),
                                          Color(red: 0.78, green: 0.16, blue: 0.13)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: Swift.max(1, side * 0.05)))
            .frame(width: side, height: side)
            .mask(alignment: .top) { Rectangle().frame(height: side * 0.5) }
            .rotationEffect(.degrees(open ? -26 : 0), anchor: .bottom)
            .offset(y: open ? -side * 0.34 : 0)
    }
}

/// A Pokémon arriving: the ball arcs in, opens, and lets it out.
///
/// The shape is Showdown's, because Showdown's is the one every player of this
/// format already reads: the ball comes in low and behind on a thrown arc over
/// about three tenths of a second, opens, and the Pokémon grows out of it and
/// settles. The arc is the part that sells it — a ball that slides in a
/// straight line looks like a bug.
struct SendOutEffect: View {
    /// Where the Pokémon stands, in the scene's own coordinates.
    let centre: CGPoint
    /// How big the Pokémon is there, so the ball is in proportion and the
    /// thing keeps its scale with the depth.
    let side: CGFloat
    /// Thrown from the near side of the field, so the two sides throw from
    /// opposite directions the way they face.
    let fromMine: Bool
    var onDone: () -> Void = {}

    @State private var flown = false
    @State private var opened = false
    @State private var gone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ballSide: CGFloat { Swift.max(14, side * 0.34) }

    var body: some View {
        ZStack {
            if !gone {
                PokeBall(side: ballSide, open: opened)
                    .rotationEffect(.degrees(flown ? 0 : (fromMine ? -220 : 220)))
                    .scaleEffect(flown ? 1 : 0.55)
                    .position(flown ? centre : start)
                    .opacity(flown ? 1 : 0)
            }
            if opened {
                // The flash the Pokémon comes out of.
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0.75), .clear],
                                         center: .center, startRadius: 0, endRadius: side * 0.55))
                    .frame(width: side * 1.1, height: side * 1.1)
                    .position(centre)
                    .blendMode(.plusLighter)
                    .opacity(gone ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: run)
    }

    /// Where it is thrown from: below and behind, straight down the line the
    /// Pokemon will stand on.
    ///
    /// No sideways component, which is Showdown's answer and was not mine:
    /// starting it off to one side made the ball cross the field on the way
    /// in, and on your own side that reads as a ball flying towards the
    /// middle rather than one being thrown out in front of you. The depth is
    /// carried by the scale instead, which is where it belongs.
    private var start: CGPoint {
        CGPoint(x: centre.x, y: centre.y + side * 0.95)
    }

    private func run() {
        guard !reduceMotion else { opened = true; gone = true; onDone(); return }
        withAnimation(.timingCurve(0.2, 0.9, 0.35, 1, duration: 0.30)) { flown = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.12)) { opened = true }
            onDone()
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.easeOut(duration: 0.22)) { gone = true }
        }
    }
}

/// The sparkle a shiny arrives in, which is the one moment the game gives you
/// to notice. Showdown darkens the field and throws a handful of shines up
/// off the Pokémon; this does the same with what it has.
struct ShinySparkle: View {
    let centre: CGPoint
    let side: CGFloat
    /// Held partway through, for a still that has to show what it looks like.
    var frozen: Bool = false

    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                let spread = (CGFloat(index) - 3) / 3
                Image(systemName: "sparkle")
                    .font(.system(size: Swift.max(7, side * (0.10 + 0.05 * abs(spread))), weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: Color(red: 1, green: 0.92, blue: 0.5), radius: 6)
                    .position(x: centre.x + spread * side * 0.55,
                              // Scattered to begin with as well as on the way
                              // up, or seven of them leave in a rank.
                              y: centre.y + side * (0.30 - 0.18 * abs(spread))
                                 - (up ? side * (0.62 + 0.22 * abs(spread)) : 0))
                    .opacity(up ? 0 : 1)
                    .scaleEffect(up ? 1.5 : 0.4)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion, !frozen else { return }
            withAnimation(.easeOut(duration: 0.75)) { up = true }
        }
    }
}

/// A Pokémon being recalled: it is drawn up into nothing and the ball drops
/// away with it.
///
/// Showdown's animUnsummon, which is its summon read backwards and a little
/// quicker: the Pokémon rises about half its own height, shrinking to nothing
/// over four tenths of a second, and the ball appears where its head was and
/// arcs back down and behind, fading. There is no cry for this one — Showdown
/// plays one coming out and one going down, and not for a recall.
///
/// It draws the departing Pokémon itself, because by the time a step is on the
/// board the slot already belongs to whoever replaced it.
struct RecallEffect: View {
    let form: Form
    let shiny: Bool
    let centre: CGPoint
    let side: CGFloat
    let mine: Bool
    var onDone: () -> Void = {}

    @State private var pulled = false
    @State private var thrown = false
    @State private var gone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !gone {
                SpriteImage(form: form, side: side, shiny: shiny)
                    .scaleEffect(pulled ? 0.01 : 1, anchor: .top)
                    .opacity(pulled ? 0 : 1)
                    .position(x: centre.x, y: centre.y - (pulled ? side * 0.42 : 0))
                PokeBall(side: Swift.max(14, side * 0.34), open: !thrown)
                    .position(x: centre.x,
                              y: centre.y - (thrown ? -side * 0.55 : side * 0.42))
                    .scaleEffect(thrown ? 0.6 : 1)
                    .opacity(pulled ? (thrown ? 0 : 1) : 0)
                    .rotationEffect(.degrees(thrown ? (mine ? -160 : 160) : 0))
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: run)
    }

    private func run() {
        guard !reduceMotion else { pulled = true; gone = true; onDone(); return }
        withAnimation(.easeIn(duration: 0.34)) { pulled = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 340_000_000)
            withAnimation(.timingCurve(0.4, 0, 0.9, 0.5, duration: 0.34)) { thrown = true }
            try? await Task.sleep(nanoseconds: 340_000_000)
            gone = true
            onDone()
        }
    }
}

/// A Pokémon becoming something else: the light gathers in, and then it
/// bursts.
///
/// Showdown's megaevo, which it plays for every transformation that does not
/// have one of its own: the field flashes a purple Showdown has been using for
/// this since Mega Evolution existed (#835BA5), an orb rushes inward over
/// three tenths of a second, and then blooms outward and away over the next
/// four. A cry goes with it.
///
/// It is deliberately not the ball. A Mega Evolution is the same Pokémon
/// changing, and throwing a Poké Ball at one says it is a different Pokémon
/// arriving — which is what this used to do, because the only thing the field
/// could see was that the form had changed.
struct MegaEvolveEffect: View {
    let centre: CGPoint
    let side: CGFloat
    var onDone: () -> Void = {}

    @State private var gathered = false
    @State private var burst = false
    @State private var over = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The colour Showdown uses for this, which is worth keeping: a player who
    /// knows the client knows what it means before anything is written down.
    private static let mega = Color(red: 0.51, green: 0.36, blue: 0.65)

    var body: some View {
        ZStack {
            if !over {
                // The field, dimmed and tinted.
                Rectangle()
                    .fill(Self.mega)
                    .opacity(burst ? 0 : (gathered ? 0.45 : 0))
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                // The orb: in, then out.
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [.white, Self.mega, Color(red: 0.62, green: 0.83, blue: 1)],
                        startPoint: .top, endPoint: .bottom),
                                  lineWidth: burst ? side * 0.05 : side * 0.22)
                    .frame(width: orbSide, height: orbSide)
                    .position(centre)
                    .opacity(burst ? 0 : (gathered ? 1 : 0.25))
                    .shadow(color: Self.mega.opacity(0.9), radius: side * 0.2)
                // And the flash it leaves behind.
                Circle()
                    .fill(RadialGradient(colors: [.white, Self.mega.opacity(0.6), .clear],
                                         center: .center, startRadius: 0, endRadius: side * 0.7))
                    .frame(width: side * 1.5, height: side * 1.5)
                    .position(centre)
                    .blendMode(.plusLighter)
                    .opacity(gathered && !burst ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: run)
    }

    private var orbSide: CGFloat {
        burst ? side * 3.4 : (gathered ? side * 0.55 : side * 2.2)
    }

    private func run() {
        guard !reduceMotion else { over = true; onDone(); return }
        withAnimation(.easeIn(duration: 0.30)) { gathered = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.42)) { burst = true }
            onDone()
            try? await Task.sleep(nanoseconds: 420_000_000)
            over = true
        }
    }
}

/// A move being wound up rather than thrown: light gathering into the user.
///
/// Showdown carries a `prepareAnim` for eighteen moves and most of them are a
/// shimmer — Sky Attack's is the user going faintly translucent — which is not
/// worth a table of its own. This is one wind-up for all of them, and its job
/// is only to be different from the move: a charging turn used to play the
/// whole flight, on the turn nothing had left the ground.
struct ChargeGlow: View {
    let centre: CGPoint
    let side: CGFloat

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [.white, Color(red: 1, green: 0.88, blue: 0.5)],
                        startPoint: .top, endPoint: .bottom),
                                  lineWidth: drawn ? side * 0.02 : side * 0.06)
                    .frame(width: ringSide(ring), height: ringSide(ring))
                    .position(centre)
                    .opacity(drawn ? 0.9 : 0)
                    .shadow(color: Color(red: 1, green: 0.85, blue: 0.4).opacity(0.8),
                            radius: side * 0.12)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeIn(duration: 0.55)) { drawn = true }
        }
    }

    /// Three rings closing in at slightly different sizes, so it reads as
    /// gathering rather than as one circle shrinking.
    private func ringSide(_ ring: Int) -> CGFloat {
        let from = side * (1.9 + CGFloat(ring) * 0.35)
        let to = side * (0.5 + CGFloat(ring) * 0.12)
        return drawn ? to : from
    }
}
