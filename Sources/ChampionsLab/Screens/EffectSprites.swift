//  EffectSprites.swift
//  Our drawing of the client's primitives.
//
//  The choreography names fifty-odd sprites -- fireball, icicle, lightning,
//  leftclaw, impact -- and the client draws each from a PNG. These are the
//  same names drawn as shapes: an orb is a glow with a core, a shard a
//  triangle, a claw three tapered arcs, a bolt a zigzag. Each is drawn into a
//  rectangle the size the choreography asks for, so a lightning bolt is tall
//  and a fireball round, and a left-handed one is mirrored for the near side.

import SwiftUI

enum EffectSprites {
    /// The families a name falls into, and the colours it takes.
    private enum Shape {
        case orb(Color, Color)          // core, glow
        case shard(Color)               // icicles, pointing down
        case bolt                        // lightning
        case rock(Color)
        case leaf(Color, Double)        // colour, tilt
        case spiky(Color, Int)          // caltrops, gears, metal: a spiked disc
        case burst(Color, Int)          // impact, shine, hitmark
        case claw(Color)                // three tapered arcs
        case slash(Color)               // one long tapered stroke
        case chop(Color)                // a vertical slab
        case bite(Color, Bool)          // teeth, top or bottom
        case fist(Color)
        case foot(Color)
        case glyph(String, Color)       // a letter or symbol
        case eyes
        case heart
        case ring(Color)                // web, rainbow
        case shell
        case bone
        case sword
        case pokeball
    }

    private static let shapes: [String: Shape] = [
        "wisp": .orb(.white, Color(white: 0.75)), "purplewisp": .orb(Color(red: 0.85, green: 0.6, blue: 1), .purple),
        "waterwisp": .orb(Color(red: 0.7, green: 0.9, blue: 1), .blue), "mudwisp": .orb(Color(red: 0.7, green: 0.55, blue: 0.35), Color(red: 0.45, green: 0.3, blue: 0.15)),
        "blackwisp": .orb(Color(white: 0.25), .black), "fireball": .orb(Color(red: 1, green: 0.85, blue: 0.3), Color(red: 1, green: 0.35, blue: 0.05)),
        "bluefireball": .orb(.white, Color(red: 0.3, green: 0.6, blue: 1)), "shadowball": .orb(Color(red: 0.45, green: 0.2, blue: 0.6), Color(red: 0.1, green: 0, blue: 0.2)),
        "energyball": .orb(Color(red: 0.85, green: 1, blue: 0.5), Color(red: 0.2, green: 0.8, blue: 0.2)), "electroball": .orb(.white, Color(red: 1, green: 0.85, blue: 0.1)),
        "mistball": .orb(.white, Color(red: 1, green: 0.7, blue: 0.85)), "iceball": .orb(.white, Color(red: 0.55, green: 0.85, blue: 1)),
        "flareball": .orb(Color(red: 1, green: 0.95, blue: 0.6), Color(red: 1, green: 0.55, blue: 0.1)), "moon": .orb(Color(red: 1, green: 0.98, blue: 0.8), Color(red: 0.85, green: 0.8, blue: 0.5)),
        "ultra": .orb(.white, Color(red: 0.6, green: 0.3, blue: 0.9)), "alpha": .glyph("α", Color(red: 0.4, green: 0.6, blue: 1)), "omega": .glyph("Ω", Color(red: 1, green: 0.45, blue: 0.3)),
        "zsymbol": .glyph("Z", Color(red: 0.4, green: 0.9, blue: 1)), "pointer": .glyph("▼", Color(red: 1, green: 0.9, blue: 0.3)), "angry": .glyph("#", Color(red: 1, green: 0.3, blue: 0.3)),
        "icicle": .shard(Color(red: 0.75, green: 0.95, blue: 1)), "pinkicicle": .shard(Color(red: 1, green: 0.75, blue: 0.9)),
        "lightning": .bolt,
        "rocks": .rock(Color(red: 0.55, green: 0.45, blue: 0.35)), "rock1": .rock(Color(red: 0.6, green: 0.5, blue: 0.4)), "rock2": .rock(Color(red: 0.5, green: 0.42, blue: 0.35)), "rock3": .rock(Color(red: 0.65, green: 0.55, blue: 0.45)),
        "leaf1": .leaf(Color(red: 0.4, green: 0.8, blue: 0.3), -0.6), "leaf2": .leaf(Color(red: 0.3, green: 0.7, blue: 0.25), 0.7),
        "petal": .leaf(Color(red: 1, green: 0.65, blue: 0.8), 0.3), "feather": .leaf(.white, -0.4),
        "caltrop": .spiky(Color(white: 0.5), 4), "poisoncaltrop": .spiky(Color(red: 0.6, green: 0.3, blue: 0.7), 4),
        "greenmetal1": .spiky(Color(red: 0.4, green: 0.8, blue: 0.5), 4), "greenmetal2": .spiky(Color(red: 0.3, green: 0.7, blue: 0.45), 6),
        "gear": .spiky(Color(white: 0.6), 8),
        "impact": .burst(Color(red: 1, green: 0.75, blue: 0.3), 12), "shine": .burst(Color(red: 1, green: 1, blue: 0.7), 8), "hitmark": .burst(.white, 4),
        "leftclaw": .claw(.white), "rightclaw": .claw(.white), "leftslash": .slash(.white), "rightslash": .slash(.white),
        "leftchop": .chop(.white), "rightchop": .chop(.white),
        "topbite": .bite(.white, true), "bottombite": .bite(.white, false),
        "fist": .fist(Color(red: 0.95, green: 0.8, blue: 0.65)), "fist1": .fist(Color(red: 0.95, green: 0.8, blue: 0.65)), "foot": .foot(Color(red: 0.95, green: 0.8, blue: 0.65)),
        "stare": .eyes, "heart": .heart, "web": .ring(.white), "rainbow": .ring(Color(red: 1, green: 0.5, blue: 0.5)),
        "shell": .shell, "bone": .bone, "sword": .sword, "pokeball": .pokeball,
    ]

    /// Draw one primitive into `rect`, mirrored for the near side where the
    /// shape has a hand. Unknown names draw as a plain wisp, because something
    /// did happen.
    static func draw(_ name: String, in rect: CGRect, mirrored: Bool, opacity: Double,
                     context: inout GraphicsContext) {
        guard rect.width > 0.5, rect.height > 0.5, opacity > 0.005 else { return }
        var ctx = context
        ctx.opacity = opacity
        if mirrored {
            ctx.translateBy(x: rect.midX * 2, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        switch shapes[name] ?? .orb(.white, Color(white: 0.8)) {
        case .orb(let core, let glow): orb(rect, core: core, glow: glow, in: &ctx)
        case .shard(let colour): shard(rect, colour: colour, in: &ctx)
        case .bolt: bolt(rect, in: &ctx)
        case .rock(let colour): rock(rect, colour: colour, in: &ctx)
        case .leaf(let colour, let tilt): leaf(rect, colour: colour, tilt: tilt, in: &ctx)
        case .spiky(let colour, let points): spiky(rect, colour: colour, points: points, in: &ctx)
        case .burst(let colour, let spokes): burst(rect, colour: colour, spokes: spokes, in: &ctx)
        case .claw(let colour): claw(rect, colour: colour, in: &ctx)
        case .slash(let colour): slash(rect, colour: colour, in: &ctx)
        case .chop(let colour): chop(rect, colour: colour, in: &ctx)
        case .bite(let colour, let top): bite(rect, colour: colour, top: top, in: &ctx)
        case .fist(let colour): fist(rect, colour: colour, in: &ctx)
        case .foot(let colour): foot(rect, colour: colour, in: &ctx)
        case .glyph(let text, let colour): glyph(rect, text: text, colour: colour, in: &ctx)
        case .eyes: eyes(rect, in: &ctx)
        case .heart: heart(rect, in: &ctx)
        case .ring(let colour): ring(rect, colour: colour, in: &ctx)
        case .shell: shell(rect, in: &ctx)
        case .bone: bone(rect, in: &ctx)
        case .sword: sword(rect, in: &ctx)
        case .pokeball: pokeball(rect, in: &ctx)
        }
    }

    // MARK: - The families

    private static func orb(_ r: CGRect, core: Color, glow: Color, in ctx: inout GraphicsContext) {
        let radius = min(r.width, r.height) / 2
        let centre = CGPoint(x: r.midX, y: r.midY)
        ctx.fill(Path(ellipseIn: r), with: .radialGradient(
            Gradient(colors: [core, glow, glow.opacity(0)]),
            center: centre, startRadius: 0, endRadius: radius))
    }

    private static func shard(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        for (index, share) in [0.5, 0.2, 0.8].enumerated() {
            var p = Path()
            let x = r.minX + r.width * share
            let top = r.minY + (index == 0 ? 0 : r.height * 0.3)
            let half = r.width * (index == 0 ? 0.14 : 0.09)
            p.move(to: CGPoint(x: x - half, y: top))
            p.addLine(to: CGPoint(x: x + half, y: top))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [.white, colour]),
                                              startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: r.maxY)))
        }
    }

    private static func bolt(_ r: CGRect, in ctx: inout GraphicsContext) {
        var p = Path()
        let steps = 5
        for step in 0...steps {
            let y = r.minY + r.height * Double(step) / Double(steps)
            let x = r.midX + (step % 2 == 0 ? -1 : 1) * r.width * 0.35 * (step == 0 || step == steps ? 0.2 : 1)
            step == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(p, with: .color(Color(red: 1, green: 0.85, blue: 0.2)), style: StrokeStyle(lineWidth: max(3, r.width * 0.3), lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: max(1.5, r.width * 0.12), lineCap: .round, lineJoin: .round))
    }

    private static func rock(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        var p = Path()
        let points: [(Double, Double)] = [(0.5, 0.02), (0.9, 0.3), (0.98, 0.7), (0.6, 0.98), (0.15, 0.85), (0.04, 0.4)]
        for (i, (x, y)) in points.enumerated() {
            let point = CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(Gradient(colors: [colour.opacity(0.9), colour.opacity(0.6)]),
                                          startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        ctx.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 1)
    }

    private static func leaf(_ r: CGRect, colour: Color, tilt: Double, in ctx: inout GraphicsContext) {
        var c = ctx
        c.translateBy(x: r.midX, y: r.midY)
        c.rotate(by: .radians(tilt))
        let body = CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
        c.fill(Path(ellipseIn: body), with: .color(colour))
        var vein = Path(); vein.move(to: CGPoint(x: -r.width / 2, y: 0)); vein.addLine(to: CGPoint(x: r.width / 2, y: 0))
        c.stroke(vein, with: .color(.white.opacity(0.35)), lineWidth: 1)
    }

    private static func star(_ r: CGRect, points: Int, inner: Double) -> Path {
        var p = Path()
        let centre = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        for i in 0..<(points * 2) {
            let angle = Double(i) / Double(points * 2) * .pi * 2 - .pi / 2
            let radius = i % 2 == 0 ? outer : outer * inner
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
        return p
    }

    private static func spiky(_ r: CGRect, colour: Color, points: Int, in ctx: inout GraphicsContext) {
        ctx.fill(star(r, points: points, inner: points >= 8 ? 0.7 : 0.35), with: .color(colour))
        ctx.stroke(star(r, points: points, inner: points >= 8 ? 0.7 : 0.35), with: .color(.black.opacity(0.3)), lineWidth: 1)
    }

    private static func burst(_ r: CGRect, colour: Color, spokes: Int, in ctx: inout GraphicsContext) {
        let centre = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        ctx.fill(star(r, points: spokes, inner: 0.45), with: .radialGradient(
            Gradient(colors: [.white, colour, colour.opacity(0)]), center: centre, startRadius: 0, endRadius: radius))
    }

    private static func claw(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        for i in 0..<3 {
            let x = r.minX + r.width * (0.25 + 0.25 * Double(i))
            var p = Path()
            p.move(to: CGPoint(x: x + r.width * 0.12, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: x - r.width * 0.05, y: r.maxY),
                           control: CGPoint(x: x - r.width * 0.15, y: r.midY))
            ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: max(2, r.width * 0.09), lineCap: .round))
        }
    }

    private static func slash(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX + r.width * 0.15, y: r.midY - r.height * 0.15))
        ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: max(2, r.width * 0.12), lineCap: .round))
        ctx.stroke(p, with: .color(colour.opacity(0.4)), style: StrokeStyle(lineWidth: max(4, r.width * 0.25), lineCap: .round))
    }

    private static func chop(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: r.midX - r.width * 0.06, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.06, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.16, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.16, y: r.maxY))
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(Gradient(colors: [colour, colour.opacity(0.2)]),
                                          startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
    }

    private static func bite(_ r: CGRect, colour: Color, top: Bool, in ctx: inout GraphicsContext) {
        var p = Path()
        let teeth = 5
        let base = top ? r.minY : r.maxY, tip = top ? r.maxY : r.minY
        p.move(to: CGPoint(x: r.minX, y: base))
        for i in 0..<teeth {
            let x0 = r.minX + r.width * Double(i) / Double(teeth)
            let x1 = r.minX + r.width * Double(i + 1) / Double(teeth)
            p.addLine(to: CGPoint(x: (x0 + x1) / 2, y: tip))
            p.addLine(to: CGPoint(x: x1, y: base))
        }
        p.closeSubpath()
        ctx.fill(p, with: .color(colour))
        ctx.stroke(p, with: .color(.black.opacity(0.4)), lineWidth: 1)
    }

    private static func fist(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        let body = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.18)
        ctx.fill(Path(roundedRect: body, cornerRadius: min(body.width, body.height) * 0.3), with: .color(colour))
        for i in 0..<4 {
            let k = CGRect(x: body.minX + body.width * (0.08 + 0.22 * Double(i)), y: body.minY - r.height * 0.06,
                           width: body.width * 0.2, height: body.width * 0.2)
            ctx.fill(Path(ellipseIn: k), with: .color(colour))
            ctx.stroke(Path(ellipseIn: k), with: .color(.black.opacity(0.25)), lineWidth: 1)
        }
        ctx.stroke(Path(roundedRect: body, cornerRadius: min(body.width, body.height) * 0.3), with: .color(.black.opacity(0.3)), lineWidth: 1)
    }

    private static func foot(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        let sole = CGRect(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.3, width: r.width * 0.6, height: r.height * 0.7)
        ctx.fill(Path(roundedRect: sole, cornerRadius: sole.width * 0.4), with: .color(colour))
        for i in 0..<4 {
            let toe = CGRect(x: r.minX + r.width * (0.16 + 0.19 * Double(i)), y: r.minY + r.height * (i == 0 ? 0.08 : 0.14),
                             width: r.width * 0.15, height: r.width * 0.15)
            ctx.fill(Path(ellipseIn: toe), with: .color(colour))
        }
    }

    private static func glyph(_ r: CGRect, text: String, colour: Color, in ctx: inout GraphicsContext) {
        let resolved = ctx.resolve(Text(text).font(.system(size: min(r.width, r.height) * 0.9, weight: .black)).foregroundColor(colour))
        ctx.draw(resolved, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
    }

    private static func eyes(_ r: CGRect, in ctx: inout GraphicsContext) {
        for share in [0.28, 0.72] {
            let eye = CGRect(x: r.minX + r.width * share - r.width * 0.16, y: r.minY, width: r.width * 0.32, height: r.height)
            ctx.fill(Path(ellipseIn: eye), with: .color(.white))
            let pupil = eye.insetBy(dx: eye.width * 0.32, dy: eye.height * 0.28)
            ctx.fill(Path(ellipseIn: pupil), with: .color(Color(red: 0.8, green: 0.1, blue: 0.15)))
        }
    }

    private static func heart(_ r: CGRect, in ctx: inout GraphicsContext) {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.3), control1: CGPoint(x: r.midX - w * 0.6, y: r.minY + h * 0.75), control2: CGPoint(x: r.minX, y: r.minY + h * 0.55))
        p.addArc(center: CGPoint(x: r.minX + w * 0.25, y: r.minY + h * 0.3), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: r.minX + w * 0.75, y: r.minY + h * 0.3), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.minY + h * 0.55), control2: CGPoint(x: r.midX + w * 0.6, y: r.minY + h * 0.75))
        ctx.fill(p, with: .color(Color(red: 1, green: 0.35, blue: 0.5)))
    }

    private static func ring(_ r: CGRect, colour: Color, in ctx: inout GraphicsContext) {
        let centre = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        for share in [1.0, 0.66, 0.33] {
            let rr = radius * share
            ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(colour.opacity(0.8)), lineWidth: 1.5)
        }
        for spoke in 0..<8 {
            let angle = Double(spoke) / 8 * .pi * 2
            var p = Path(); p.move(to: centre)
            p.addLine(to: CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius))
            ctx.stroke(p, with: .color(colour.opacity(0.6)), lineWidth: 1)
        }
    }

    private static func shell(_ r: CGRect, in ctx: inout GraphicsContext) {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY), radius: min(r.width / 2, r.height), startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.closeSubpath()
        ctx.fill(p, with: .color(Color(red: 0.85, green: 0.7, blue: 0.45)))
        ctx.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 1)
    }

    private static func bone(_ r: CGRect, in ctx: inout GraphicsContext) {
        let shaft = CGRect(x: r.minX + r.width * 0.2, y: r.midY - r.height * 0.12, width: r.width * 0.6, height: r.height * 0.24)
        ctx.fill(Path(roundedRect: shaft, cornerRadius: shaft.height / 2), with: .color(.white))
        for x in [r.minX + r.width * 0.2, r.maxX - r.width * 0.2] {
            for dy in [-1.0, 1.0] {
                let knob = CGRect(x: x - r.width * 0.14, y: r.midY + dy * r.height * 0.12 - r.width * 0.14, width: r.width * 0.28, height: r.width * 0.28)
                ctx.fill(Path(ellipseIn: knob), with: .color(.white))
            }
        }
    }

    private static func sword(_ r: CGRect, in ctx: inout GraphicsContext) {
        let blade = CGRect(x: r.midX - r.width * 0.12, y: r.minY, width: r.width * 0.24, height: r.height * 0.7)
        ctx.fill(Path(blade), with: .linearGradient(Gradient(colors: [.white, Color(white: 0.7)]), startPoint: CGPoint(x: blade.minX, y: 0), endPoint: CGPoint(x: blade.maxX, y: 0)))
        let guardRect = CGRect(x: r.minX, y: r.minY + r.height * 0.7, width: r.width, height: r.height * 0.08)
        ctx.fill(Path(guardRect), with: .color(Color(red: 0.8, green: 0.65, blue: 0.2)))
        let hilt = CGRect(x: r.midX - r.width * 0.1, y: r.minY + r.height * 0.78, width: r.width * 0.2, height: r.height * 0.22)
        ctx.fill(Path(hilt), with: .color(Color(red: 0.45, green: 0.25, blue: 0.1)))
    }

    private static func pokeball(_ r: CGRect, in ctx: inout GraphicsContext) {
        let ball = Path(ellipseIn: r)
        ctx.fill(ball, with: .color(.white))
        var top = Path()
        top.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        top.closeSubpath()
        ctx.fill(top, with: .color(Color(red: 0.9, green: 0.15, blue: 0.15)))
        var band = Path(); band.move(to: CGPoint(x: r.minX, y: r.midY)); band.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        ctx.stroke(band, with: .color(.black), lineWidth: max(1, r.height * 0.08))
        ctx.stroke(ball, with: .color(.black), lineWidth: 1)
    }
}
