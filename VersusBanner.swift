//  VersusBanner.swift
//  The screen between choosing two teams and choosing four: both sixes face
//  each other across a slanted divider, with what each side would bring.

import SwiftUI

// MARK: - A team as a card

/// A team shown as what it is made of: its six, a name, and a line about it.
/// Used wherever a team is chosen, because "MiggleVGC — Thavorian Trials 8"
/// tells you nothing and six sprites tell you everything.
struct SixCard: View {
    let name: String
    let tag: String
    let forms: [Form?]
    var selected = false
    var spriteSide: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(tag)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 2) {
                ForEach(Array(forms.prefix(6).enumerated()), id: \.offset) { _, form in
                    if let form {
                        SpriteImage(form: form, side: spriteSide)
                            .help(form.formLabel)
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .frame(width: spriteSide, height: spriteSide)
                            .foregroundStyle(.quaternary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.accent.opacity(0.16) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Palette.accent.opacity(0.6) : Palette.hairline,
                          lineWidth: selected ? 1.5 : 1))
    }
}

// MARK: - The slant

/// One side of the banner, cut along the divider.
struct Slab: Shape {
    /// How far the divider's ends sit from the centre line, horizontally.
    let lean: CGFloat
    let left: Bool

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        var p = Path()
        if left {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: cx + lean, y: rect.minY))
            p.addLine(to: CGPoint(x: cx - lean, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: cx + lean, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: cx - lean, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// Thin lines parallel to the divider, for pace.
struct SlantLines: Shape {
    let lean: CGFloat
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX - lean
        while x < rect.maxX + lean {
            p.move(to: CGPoint(x: x + lean, y: rect.minY))
            p.addLine(to: CGPoint(x: x - lean, y: rect.maxY))
            x += spacing
        }
        return p
    }
}

// MARK: - The banner

/// Your six on the left, theirs on the right, a divider twenty-five degrees
/// off vertical between them. Each side's formation leans with the divider:
/// the two predicted leads out front, the rest in a second rank behind.
struct VersusBanner: View {
    struct Side {
        let title: String
        let name: String
        let tag: String
        /// The six, leads first, the pair likeliest to be left home last.
        let forms: [Form]
        let leadCount: Int
        let tint: Color
    }

    let mine: Side
    let theirs: Side
    /// The grid's verdict on the whole matchup, −100…100, and in words.
    let score: Int
    let verdict: String

    private let angle: CGFloat = 25 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lean = tan(angle) * h / 2
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09)
                Slab(lean: lean, left: true)
                    .fill(LinearGradient(colors: [mine.tint.opacity(0.62), mine.tint.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Slab(lean: lean, left: false)
                    .fill(LinearGradient(colors: [theirs.tint.opacity(0.08), theirs.tint.opacity(0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                SlantLines(lean: lean, spacing: 44)
                    .stroke(.white.opacity(0.05), lineWidth: 1)
                // The divider, lit.
                Path { p in
                    p.move(to: CGPoint(x: w / 2 + lean, y: 0))
                    p.addLine(to: CGPoint(x: w / 2 - lean, y: h))
                }
                .stroke(.white.opacity(0.92), lineWidth: 3)
                .shadow(color: .white.opacity(0.55), radius: 12)

                formation(mine, in: geo.size, lean: lean, left: true)
                formation(theirs, in: geo.size, lean: lean, left: false)

                // Names in the top corners, the verdict between them: the
                // bottom centre is where the front ranks' last sprites sit.
                HStack(alignment: .top) {
                    nameBlock(mine, leading: true)
                    Spacer()
                    verdictChip.padding(.top, 4)
                    Spacer()
                    nameBlock(theirs, leading: false)
                }
                .padding(18)
                .frame(maxHeight: .infinity, alignment: .top)

                badge
            }
        }
    }

    /// Two ranks along lines parallel to the divider, the front rank nearer
    /// and larger. Positions are read off where the divider is at that height,
    /// so the whole formation leans the way the line does.
    private func formation(_ side: Side, in size: CGSize, lean: CGFloat, left: Bool) -> some View {
        let h = size.height
        let rows: [CGFloat] = [0.30, 0.56, 0.82]
        let front = Array(side.forms.prefix(3))
        let back = Array(side.forms.dropFirst(3).prefix(3))
        func dividerX(_ y: CGFloat) -> CGFloat { size.width / 2 + lean - 2 * lean * (y / h) }
        let sign: CGFloat = left ? -1 : 1
        return ZStack {
            ForEach(Array(back.enumerated()), id: \.offset) { index, form in
                let y = h * rows[index]
                sprite(form, side: 74, lead: false, tint: side.tint)
                    .position(x: dividerX(y) + sign * 262, y: y)
            }
            ForEach(Array(front.enumerated()), id: \.offset) { index, form in
                let y = h * rows[index]
                let lead = index < side.leadCount
                sprite(form, side: lead ? 104 : 86, lead: lead, tint: side.tint)
                    .position(x: dividerX(y) + sign * 122, y: y)
            }
        }
    }

    private func sprite(_ form: Form, side: CGFloat, lead: Bool, tint: Color) -> some View {
        VStack(spacing: 1) {
            SpriteImage(form: form, side: side)
                .shadow(color: tint.opacity(0.75), radius: 14)
                .shadow(color: .black.opacity(0.65), radius: 4, y: 3)
            Text(form.formLabel)
                .font(.system(size: lead ? 11 : 10, weight: lead ? .bold : .semibold))
                .foregroundStyle(.white.opacity(lead ? 1 : 0.85))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.8), radius: 3)
            if lead {
                Text("LEAD").font(.system(size: 8, weight: .heavy)).kerning(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.9)))
            }
        }
    }

    private func nameBlock(_ side: Side, leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 1) {
            Text(side.title).font(.system(size: 9, weight: .heavy)).kerning(1.4)
                .foregroundStyle(.white.opacity(0.62))
            Text(side.name.uppercased())
                .font(.system(size: 22, weight: .black)).italic()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            Text(side.tag).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .frame(maxWidth: 300, alignment: leading ? .leading : .trailing)
    }

    private var badge: some View {
        Text("VS")
            .font(.system(size: 34, weight: .black)).italic()
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.92), lineWidth: 2))
            .rotationEffect(.degrees(-25))
            .shadow(color: .white.opacity(0.45), radius: 14)
    }

    private var verdictChip: some View {
        HStack(spacing: 8) {
            Text(String(format: "%+d", score))
                .font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit()
            Text(verdict).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.14)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .help("The versus grid's verdict on six against six, before anybody has chosen four.")
    }
}

// MARK: - Words for the matchup

/// The score in words, from your side of the table.
func edgeWords(_ score: Int) -> String {
    let size = abs(score)
    let whose = score >= 0 ? "you" : "them"
    if size < 8 { return "dead even" }
    if size < 25 { return "slight edge to \(whose)" }
    if size < 50 { return "edge to \(whose)" }
    return score >= 0 ? "heavily favours you" : "heavily favours them"
}
