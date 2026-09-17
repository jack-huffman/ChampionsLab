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
        /// The primitive's drawn size at scale one, in points.
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

    /// How the arena is laid out: its size, and where each seat's Pokemon is.
    struct Stage: Sendable {
        let arena: CGSize
        let home: @Sendable (Seat) -> CGPoint
        /// One client scene unit in points. Their scene is 640 wide.
        var unit: CGFloat { arena.width / 640 }
        var centre: CGPoint { CGPoint(x: arena.width / 2, y: arena.height / 2) }
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
                let size = CGSize(width: drawn[0] * stage.unit, height: drawn[1] * stage.unit)
                timeline.sprites.append(Sprite(
                    id: next, name: name, size: size,
                    from: place(from), to: place(to),
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
                let placed = place(pose, scaleDefault: 1, opacityDefault: 1)
                let start = clock[who] ?? 0
                let length = seconds(pose.time ?? 500)
                let end = start + length
                timeline.leans.append(Lean(
                    id: next, seat: at,
                    offset: CGSize(width: placed.point.x - home.x, height: placed.point.y - home.y),
                    scale: (placed.xscale + placed.yscale) / 2, opacity: placed.opacity,
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

        /// A client pose on this arena.
        ///
        /// Each axis mixes the two Pokemon's positions by its weights, and
        /// what is left over sits on the arena's centre, the client's origin.
        /// The constant and the leftof terms are scene units; behind(n) and
        /// the z constant are depth, drawn here as a slide along the line
        /// from your side to theirs -- right and a little up for something
        /// going behind the far side, left and a little down for the near.
        func place(_ pose: Choreography.Pose, scaleDefault: Double = 1, opacityDefault: Double = 1) -> Pose {
            let a = stage.home(attacker), d = stage.home(defender), o = stage.centre
            let unit = stage.unit
            func facing(_ seat: Seat) -> CGFloat { seat.mine ? -1 : 1 }
            func mix(_ coord: Choreography.Coordinate?, _ axis: (CGPoint) -> CGFloat) -> (CGFloat, Choreography.Coordinate) {
                let coord = coord ?? Choreography.Coordinate()
                let wa = CGFloat(coord.onAttacker), wd = CGFloat(coord.onDefender)
                return (wa * axis(a) + wd * axis(d) + (1 - wa - wd) * axis(o), coord)
            }
            let (baseX, cx) = mix(pose.x) { $0.x }
            let (baseY, cy) = mix(pose.y) { $0.y }
            let cz = pose.z ?? Choreography.Coordinate()
            // Depth relative to the anchors: the constant, and behind(n) per side.
            let depth = CGFloat(cz.c ?? 0)
                + CGFloat(cz.ab ?? 0) * facing(attacker) + CGFloat(cz.db ?? 0) * facing(defender)
            // A pose whose x follows one Pokemon and whose depth follows the
            // other sits between them.
            let between = (CGFloat(cz.onDefender) - CGFloat(cx.onDefender)) * 0.6
            let leftof = CGFloat(cx.al ?? 0) * facing(attacker) + CGFloat(cx.dl ?? 0) * facing(defender)
            let x = baseX + unit * (CGFloat(cx.c ?? 0) + leftof) + unit * 1.1 * depth + between * (d.x - a.x)
            let y = baseY - unit * CGFloat(cy.c ?? 0) - unit * 0.55 * depth
            let scale = pose.scale ?? scaleDefault
            return Pose(point: CGPoint(x: x, y: y),
                        xscale: CGFloat(pose.xscale ?? scale), yscale: CGFloat(pose.yscale ?? scale),
                        opacity: pose.opacity ?? opacityDefault)
        }
    }

    /// When the blow lands: the first primitive to arrive at a target, or the
    /// first lean that carries the user somewhere, or -- for a recipe that
    /// never goes near anyone -- a little past half way. The health bar drops
    /// at this moment rather than when the move was thrown.
    func impact(near targets: [CGPoint], attacker: Seat) -> TimeInterval {
        var soonest: TimeInterval?
        for sprite in sprites where sprite.ghostOf == nil
            && targets.contains(where: { hypot(sprite.to.point.x - $0.x, sprite.to.point.y - $0.y) < 70 }) {
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
        var offset = CGSize.zero, scale: CGFloat = 1, opacity = 1.0
        for lean in leans where lean.seat == seat && lean.start <= time {
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
