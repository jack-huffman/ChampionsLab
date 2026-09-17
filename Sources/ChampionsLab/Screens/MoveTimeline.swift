//  MoveTimeline.swift
//  A recipe placed on the arena, on one clock.
//
//  Choreography says what a move does in the client's scene: poses relative
//  to the two Pokemon, in three axes, in milliseconds. This turns one recipe
//  into things the arena can draw at a given instant -- each primitive with
//  the point, size and opacity it starts and ends at, each card lean, each
//  wash of colour, each shake -- against the seats as this arena lays them
//  out. Pure, so a test can build one and read the numbers off it.
//
//  The client's own semantics, kept: an effect starts at its from-time and
//  ends at its to-time or half a second later, a to-pose inheriting whatever
//  the from-pose said; a lean is queued behind the Pokemon's previous lean,
//  runs half a second unless told, and returns home for any axis it does not
//  name; a wait pushes everything after it back. Depth is the one thing
//  translated rather than kept: the client draws in perspective, and here
//  behind(n) becomes a slide along the line from your side to theirs.

import Foundation
import CoreGraphics

struct MoveTimeline: Sendable {
    struct Pose: Sendable, Equatable {
        var point: CGPoint
        var xscale: CGFloat = 1
        var yscale: CGFloat = 1
        var opacity: Double = 1
    }
    struct Sprite: Identifiable, Sendable {
        let id: Int
        let name: String
        /// The primitive's size in scene units; the pose's scale carries depth
        /// and the view's scale, so the drawn width is size times xscale.
        let size: CGSize
        let from: Pose
        let to: Pose
        let start: TimeInterval
        let end: TimeInterval
        let easing: Choreography.Easing
        let ending: Choreography.Ending?
        /// A left-handed slash drawn for the far side is mirrored for the near.
        let mirrored: Bool
        /// Set when the recipe flies a Pokemon's own sprite: whose.
        let ghostOf: Seat?
    }
    struct Lean: Identifiable, Sendable {
        let id: Int
        let seat: Seat
        /// Where the card goes, as an offset from its home, and how it looks there.
        let offset: CGSize
        let scale: CGFloat
        let opacity: Double
        let start: TimeInterval
        let end: TimeInterval
        let easing: Choreography.Easing
    }
    struct Wash: Identifiable, Sendable {
        let id: Int
        /// A CSS colour as the client wrote it; nil for one of its backdrop images.
        let colour: String?
        let start: TimeInterval
        let end: TimeInterval
        let opacity: Double
    }
    struct Shake: Identifiable, Sendable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    var sprites: [Sprite] = []
    var leans: [Lean] = []
    var washes: [Wash] = []
    var shakes: [Shake] = []
    /// When the last thing finishes.
    var duration: TimeInterval = 0

    /// The client's scene, fitted to this view.
    ///
    /// Showdown draws a battle in a 640 by 360 scene: your side stands at the
    /// front, at depth 0, and theirs at the back, at depth 200, and a point's
    /// depth slides it up and to the right and shrinks it -- that is the whole
    /// of the perspective, and every recipe's coordinates assume it. This is
    /// that scene, scaled to fit the arena and centred in it, so a recipe's
    /// numbers mean here exactly what they mean there.
    struct Stage: Sendable {
        static let scene = CGSize(width: 640, height: 360)
        /// The view, in points.
        let size: CGSize
        let singles: Bool
        /// Gen 5 pixel sprites are drawn bigger than everything else, as the
        /// client draws them: twice life size at the front.
        let pixel: Bool

        init(size: CGSize, singles: Bool, pixel: Bool = true) {
            self.size = size; self.singles = singles; self.pixel = pixel
        }

        /// Points per scene unit for sizes and heights: the scene fitted to
        /// the view.
        var k: CGFloat { max(0.1, min(size.width / Self.scene.width, size.height / Self.scene.height)) }
        /// Points per scene unit across. A window wider than the client's
        /// scene spreads the field rather than leaving it in a letterbox: x
        /// stretches up to 1.7 times further than y, sizes stay true, and
        /// every recipe's offset stretches with the seats it is written from.
        var kx: CGFloat { max(k, min(size.width / Self.scene.width, k * 1.7)) }
        /// Where the scene's corner sits.
        var origin: CGPoint {
            CGPoint(x: (size.width - Self.scene.width * kx) / 2, y: (size.height - Self.scene.height * k) / 2)
        }

        /// Where a seat's Pokemon stands, in scene units. The client's own
        /// numbers for a double battle -- the first slot a little toward the
        /// middle, the second out to the side, their back row a touch higher
        /// -- then your row moved left and a little up and theirs right, so
        /// the two teams stand apart rather than one in front of the other,
        /// which is what a battle read as here. Recipes are written from
        /// these, so the moves follow.
        func home(_ seat: Seat) -> SIMD3<Double> {
            let z: Double = seat.mine ? 0 : 200
            let apart: Double = seat.mine ? -30 : 80
            let lift: Double = seat.mine ? 12 : 0
            if singles { return SIMD3(apart, lift, z) }
            let x = (Double(seat.slot) * -75 + 18) * (seat.mine ? -1 : 1) + apart
            let y = (seat.mine ? Double(seat.slot) * -10 : Double(seat.slot) * 7) + lift
            return SIMD3(x, y, z)
        }

        /// How big something at this depth is drawn, relative to its size at
        /// the middle of the field.
        func depthScale(_ z: Double, pixelSprite: Bool = false) -> Double {
            max(0.1, pixelSprite ? 2.0 - z / 200 : 1.5 - 0.5 * (z / 200))
        }

        /// A scene point on this view: the client's `pos`, then scaled and offset.
        func project(_ p: SIMD3<Double>) -> CGPoint {
            let s = depthScale(p.z)
            let left = 210 + 220 * (p.z / 200) + p.x * s
            let top = 245 - 110 * (p.z / 200) - p.y * s
            return CGPoint(x: origin.x + left * kx, y: origin.y + top * k)
        }

        /// Points per unit of something drawn at this depth.
        func scale(at z: Double, pixelSprite: Bool = false) -> CGFloat {
            depthScale(z, pixelSprite: pixelSprite) * k
        }

        var centre: CGPoint { project(SIMD3(0, 0, 100)) }
    }

    // MARK: - Building

    static func build(_ recipe: Choreography.Resolved, attacker: Seat, targets: [Seat],
                      sizes: [String: [Double]], stage: Stage, speed: Double = 1) -> MoveTimeline {
        var out = MoveTimeline()
        let defenders = targets.isEmpty ? [attacker] : targets
        // A spread move: what touches the defender plays once per target, and
        // the rest -- the user's own lunge, the wash -- once.
        if recipe.spread, defenders.count > 1 {
            var builder = Builder(attacker: attacker, defender: defenders[0], sizes: sizes, stage: stage, speed: speed)
            for step in recipe.steps where !step.touchesDefender { builder.add(step) }
            for defender in defenders {
                builder.defender = defender
                builder.resetClocks()
                for step in recipe.steps where step.touchesDefender { builder.add(step) }
            }
            out = builder.timeline
        } else {
            var builder = Builder(attacker: attacker, defender: defenders[0], sizes: sizes, stage: stage, speed: speed)
            for step in recipe.steps { builder.add(step) }
            out = builder.timeline
        }
        return out
    }

    private struct Builder {
        let attacker: Seat
        var defender: Seat
        let sizes: [String: [Double]]
        let stage: Stage
        let speed: Double
        var timeline = MoveTimeline()
        /// Each Pokemon's queue: its next lean starts when its last one ended.
        var clock: [Choreography.Part: TimeInterval] = [:]
        /// A wait pushes everything after it back.
        var offset: TimeInterval = 0
        var next = 0

        init(attacker: Seat, defender: Seat, sizes: [String: [Double]], stage: Stage, speed: Double) {
            self.attacker = attacker; self.defender = defender; self.sizes = sizes; self.stage = stage; self.speed = speed
        }

        mutating func resetClocks() { clock = [:] }

        func seat(_ part: Choreography.Part) -> Seat { part == .attacker ? attacker : defender }
        func seconds(_ ms: Double) -> TimeInterval { ms / 1000 / speed }

        mutating func add(_ step: Choreography.Step) {
            switch step.kind {
            case .effect:
                guard let name = step.sprite, var from = step.from else { return }
                var to = step.to ?? Choreography.Pose()
                // The to-pose inherits the from-pose: the client spreads one over the other.
                to.x = to.x ?? from.x; to.y = to.y ?? from.y; to.z = to.z ?? from.z
                to.scale = to.scale ?? from.scale
                to.xscale = to.xscale ?? from.xscale; to.yscale = to.yscale ?? from.yscale
                to.opacity = to.opacity ?? from.opacity
                from.time = from.time ?? 0
                let start = seconds(from.time!) + offset
                let end = seconds(to.time ?? (from.time! + 500)) + offset
                let ghost = name == "attacker" || name == "defender"
                let drawn = ghost ? [96.0, 96.0] : (sizes[name] ?? [100, 100])
                let size = CGSize(width: drawn[0], height: drawn[1])
                var fromPlaced = place(from), toPlaced = place(to)
                if ghost, stage.pixel {
                    // A Pokemon's own sprite flies at the size the Pokemon is
                    // drawn, which for a pixel sprite is bigger than an effect.
                    let fromZ = point(from).z, toZ = point(to).z
                    let growFrom = stage.depthScale(fromZ, pixelSprite: true) / stage.depthScale(fromZ)
                    let growTo = stage.depthScale(toZ, pixelSprite: true) / stage.depthScale(toZ)
                    fromPlaced.xscale *= growFrom; fromPlaced.yscale *= growFrom
                    toPlaced.xscale *= growTo; toPlaced.yscale *= growTo
                }
                timeline.sprites.append(Sprite(
                    id: next, name: name, size: size,
                    from: fromPlaced, to: toPlaced,
                    start: start, end: max(end, start), easing: step.easing ?? .linear, ending: step.ending,
                    mirrored: !seat(name == "defender" ? .defender : .attacker).mine
                        && (name.hasPrefix("left") || name.hasPrefix("right")),
                    ghostOf: ghost ? seat(name == "defender" ? .defender : .attacker) : nil))
                next += 1
                timeline.duration = max(timeline.duration, end + (step.ending == nil ? 0 : 0.2))
            case .move:
                guard let who = step.who else { return }
                let at = seat(who)
                let home = stage.home(at)
                var pose = step.to ?? Choreography.Pose()
                // Any axis not named is home; the client's anim() spreads the
                // sprite's own position under the end pose.
                let own = Choreography.Coordinate(a: who == .attacker ? 1 : nil, d: who == .defender ? 1 : nil)
                pose.x = pose.x ?? own; pose.y = pose.y ?? own; pose.z = pose.z ?? own
                let there = point(pose)
                let from = stage.project(home), to = stage.project(there)
                // Bigger as it comes toward the front, smaller as it goes back.
                let depth = stage.depthScale(there.z) / stage.depthScale(home.z)
                let start = clock[who] ?? 0
                let length = seconds(pose.time ?? 500)
                let end = start + length
                timeline.leans.append(Lean(
                    id: next, seat: at,
                    offset: CGSize(width: to.x - from.x, height: to.y - from.y),
                    scale: CGFloat(pose.scale ?? 1) * CGFloat(depth), opacity: pose.opacity ?? 1,
                    start: start, end: end, easing: step.easing ?? .linear))
                next += 1
                clock[who] = end
                timeline.duration = max(timeline.duration, end)
            case .delay:
                guard let who = step.who else { return }
                clock[who] = (clock[who] ?? 0) + seconds(step.ms ?? 0)
            case .wait:
                offset += seconds(step.ms ?? 0)
                timeline.duration = max(timeline.duration, offset)
            case .background:
                let start = seconds(step.delay ?? 0) + offset
                let end = start + seconds(step.duration ?? 500)
                timeline.washes.append(Wash(id: next, colour: step.image == nil ? step.colour : nil,
                                            start: start, end: end, opacity: step.opacity ?? 0.5))
                next += 1
                timeline.duration = max(timeline.duration, end)
            case .shake:
                let start = seconds(step.delay ?? 0) + offset
                let end = start + seconds(step.ms ?? 300)
                timeline.shakes.append(Shake(id: next, start: start, end: end))
                next += 1
                timeline.duration = max(timeline.duration, end)
            case .include:
                break // inlined by Choreography before it gets here
            }
        }

        /// A client pose in the scene, then on this view.
        ///
        /// Each axis is the weighted sum the recipe wrote -- so much of the
        /// attacker's coordinate, so much of the defender's, a constant --
        /// with behind(n) and leftof(n) signed by the side each Pokemon stands
        /// on, exactly as the client evaluates them. The point is then
        /// projected, and the size scaled by depth the same way.
        func place(_ pose: Choreography.Pose, scaleDefault: Double = 1, opacityDefault: Double = 1) -> Pose {
            let p = point(pose)
            let s = stage.scale(at: p.z)
            let scale = pose.scale ?? scaleDefault
            return Pose(point: stage.project(p),
                        xscale: CGFloat(pose.xscale ?? scale) * s, yscale: CGFloat(pose.yscale ?? scale) * s,
                        opacity: pose.opacity ?? opacityDefault)
        }

        /// The scene coordinates a pose names, before projection.
        func point(_ pose: Choreography.Pose) -> SIMD3<Double> {
            let a = stage.home(attacker), d = stage.home(defender)
            func facing(_ seat: Seat) -> Double { seat.mine ? -1 : 1 }
            func axis(_ coord: Choreography.Coordinate?, _ own: (SIMD3<Double>) -> Double, behind: Bool) -> Double {
                guard let coord else { return 0 }
                var value = (coord.a ?? 0) * own(a) + (coord.d ?? 0) * own(d) + (coord.c ?? 0)
                value += (coord.ax ?? 0) * a.x + (coord.ay ?? 0) * a.y + (coord.az ?? 0) * a.z
                value += (coord.dx ?? 0) * d.x + (coord.dy ?? 0) * d.y + (coord.dz ?? 0) * d.z
                if behind {
                    value += (coord.ab ?? 0) * facing(attacker) + (coord.db ?? 0) * facing(defender)
                } else {
                    value += (coord.al ?? 0) * facing(attacker) + (coord.dl ?? 0) * facing(defender)
                }
                return value
            }
            return SIMD3(axis(pose.x, { $0.x }, behind: false),
                         axis(pose.y, { $0.y }, behind: false),
                         axis(pose.z, { $0.z }, behind: true))
        }
    }

    /// When the blow lands: the first primitive to arrive at a target, or the
    /// first lean that carries the user somewhere, or -- for a recipe that
    /// never goes near anyone -- a little past half way. The health bar drops
    /// at this moment rather than when the move was thrown.
    func impact(near targets: [CGPoint], attacker: Seat, within reach: CGFloat = 70) -> TimeInterval {
        var soonest: TimeInterval?
        for sprite in sprites where sprite.ghostOf == nil
            && targets.contains(where: { hypot(sprite.to.point.x - $0.x, sprite.to.point.y - $0.y) < reach }) {
            soonest = min(soonest ?? .infinity, sprite.end)
        }
        for lean in leans where lean.seat == attacker && hypot(lean.offset.width, lean.offset.height) > 40 {
            soonest = min(soonest ?? .infinity, lean.end)
        }
        return min(duration, soonest ?? duration * 0.55)
    }

    // MARK: - Reading it at an instant

    /// Where along the way a sprite is at `t` in 0...1, after the easing.
    /// The ballistic family is linear along the line and arcs in height; the
    /// arcs are what the client's own easing curves say.
    static func along(_ easing: Choreography.Easing, _ t: Double) -> Double {
        switch easing {
        case .linear, .ballistic, .ballisticUp, .ballisticUnder, .ballistic2, .ballistic2Under, .ballistic2Back: return t
        case .swing: return 0.5 - cos(t * .pi) / 2
        case .accel: return t * t
        case .decel: let u = 1 - t; return 1 - u * u
        }
    }

    /// The vertical progress at `t`, given whether the move goes up the
    /// screen: the client's ballistic curves overshoot the destination by a
    /// third of the drop and come back; the second family only eases.
    static func rise(_ easing: Choreography.Easing, _ t: Double, goingUp: Bool) -> Double {
        func ballisticUp(_ x: Double) -> Double { -3 * x * x + 4 * x }
        func ballisticDown(_ x: Double) -> Double { let u = 1 - x; return 1 - ballisticUp(u) }
        func quadUp(_ x: Double) -> Double { let u = 1 - x; return 1 - u * u }
        func quadDown(_ x: Double) -> Double { x * x }
        switch easing {
        case .ballistic: return goingUp ? ballisticUp(t) : ballisticDown(t)
        case .ballisticUnder: return goingUp ? ballisticDown(t) : ballisticUp(t)
        case .ballistic2, .ballistic2Back: return goingUp ? quadUp(t) : quadDown(t)
        case .ballistic2Under: return goingUp ? quadDown(t) : quadUp(t)
        default: return along(easing, t)
        }
    }

    /// A sprite's pose at `time`, or nil when it is not on screen.
    static func pose(of sprite: Sprite, at time: TimeInterval) -> Pose? {
        guard time >= sprite.start else { return nil }
        let length = max(0.001, sprite.end - sprite.start)
        if time <= sprite.end {
            let t = min(1, (time - sprite.start) / length)
            let along = along(sprite.easing, t)
            let goingUp = sprite.to.point.y < sprite.from.point.y
            let rise = rise(sprite.easing, t, goingUp: goingUp)
            return Pose(point: CGPoint(x: sprite.from.point.x + (sprite.to.point.x - sprite.from.point.x) * along,
                                       y: sprite.from.point.y + (sprite.to.point.y - sprite.from.point.y) * rise),
                        xscale: sprite.from.xscale + (sprite.to.xscale - sprite.from.xscale) * along,
                        yscale: sprite.from.yscale + (sprite.to.yscale - sprite.from.yscale) * along,
                        opacity: sprite.from.opacity + (sprite.to.opacity - sprite.from.opacity) * along)
        }
        // After it arrives: a fade thins it out, an explode blows it up and
        // out, and anything else is simply gone.
        guard let ending = sprite.ending else { return nil }
        let tail = ending == .fade ? 0.1 : 0.2
        let t = (time - sprite.end) / tail
        guard t <= 1 else { return nil }
        var pose = sprite.to
        pose.opacity = sprite.to.opacity * (1 - t)
        if ending == .explode { pose.xscale *= 1 + 0.5 * t; pose.yscale *= 1 + 0.5 * t }
        return pose
    }

    /// A card's lean at `time`: the offset, scale and opacity it should show,
    /// blended from the leans that reach this instant. A lean that has ended
    /// holds until the next begins, which is what a queue does.
    static func lean(for seat: Seat, in leans: [Lean], at time: TimeInterval) -> (offset: CGSize, scale: CGFloat, opacity: Double) {
        lean(in: leans.filter { $0.seat == seat }, at: time)
    }

    /// The same, over leans already known to be one card's.
    static func lean(in leans: [Lean], at time: TimeInterval) -> (offset: CGSize, scale: CGFloat, opacity: Double) {
        var offset = CGSize.zero, scale: CGFloat = 1, opacity = 1.0
        for lean in leans where lean.start <= time {
            let length = max(0.001, lean.end - lean.start)
            let t = min(1, (time - lean.start) / length)
            let along = along(lean.easing, t)
            let goingUp = lean.offset.height < offset.height
            let rise = rise(lean.easing, t, goingUp: goingUp)
            offset = CGSize(width: offset.width + (lean.offset.width - offset.width) * along,
                            height: offset.height + (lean.offset.height - offset.height) * rise)
            scale += (lean.scale - scale) * along
            opacity += (lean.opacity - opacity) * along
        }
        return (offset, scale, opacity)
    }
}
