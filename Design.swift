//  Design.swift
//  The shared visual language: palette, surfaces, and the small components
//  every screen is assembled from.

import AppKit
import SwiftUI

// MARK: - Palette

enum Palette {
    /// Page background. Warm near-black in dark mode rather than pure black,
    /// which keeps the type colours from vibrating against it.
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.085, alpha: 1)
                          : NSColor(calibratedRed: 0.96, green: 0.965, blue: 0.975, alpha: 1)
    })

    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedRed: 0.115, green: 0.118, blue: 0.135, alpha: 1)
                          : NSColor.white
    })

    static let surfaceRaised = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedRed: 0.155, green: 0.16, blue: 0.18, alpha: 1)
                          : NSColor(calibratedRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    })

    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.09)
                          : NSColor(white: 0, alpha: 0.08)
    })

    static let accent = Color(red: 0.35, green: 0.51, blue: 0.96)
    /// Concrete stand-ins for the hierarchical styles, so a ternary that picks
    /// between a palette colour and "secondary" still typechecks as a Color.
    static let dim = Color.secondary
    static let fainter = Color.secondary.opacity(0.65)
    static let normal = Color.primary
    static let good = Color(red: 0.25, green: 0.68, blue: 0.45)
    static let warn = Color(red: 0.92, green: 0.66, blue: 0.20)
    static let bad = Color(red: 0.85, green: 0.32, blue: 0.30)

    /// Tier colours for the usage table.
    static func tier(_ tier: String) -> Color {
        switch tier {
        case "S": return Color(red: 0.87, green: 0.31, blue: 0.38)
        case "A": return Color(red: 0.94, green: 0.60, blue: 0.24)
        case "B": return Color(red: 0.33, green: 0.63, blue: 0.90)
        default:  return Color.secondary
        }
    }

    /// Green through red for a 0...100 grade.
    static func grade(_ score: Int) -> Color {
        switch score {
        case 80...:   return good
        case 60..<80: return Color(red: 0.55, green: 0.70, blue: 0.35)
        case 40..<60: return warn
        default:      return bad
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Surfaces

/// The standard bordered panel used throughout.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var accessory: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let accessory { accessory }
        }
    }
}

// MARK: - Type UI

/// A type badge. Uses the bundled icon when present and falls back to a
/// coloured pill, so the app still looks right without the PKHeX import.
struct TypeChip: View {
    let type: PokeType
    var size: Size = .regular

    enum Size { case small, regular, large }

    private var height: CGFloat {
        switch size {
        case .small: return 18
        case .regular: return 22
        case .large: return 28
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 10
        case .regular: return 11
        case .large: return 13
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = Store.shared.typeIcon(type) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: height - 6, height: height - 6)
            }
            Text(type.rawValue)
                .font(.system(size: fontSize, weight: .semibold))
        }
        .padding(.horizontal, size == .small ? 6 : 8)
        .frame(height: height)
        .background(type.color)
        .foregroundStyle(type.onColor)
        .clipShape(Capsule())
    }
}

/// Just the square icon, for dense grids.
struct TypeIcon: View {
    let type: PokeType
    var side: CGFloat = 20

    var body: some View {
        Group {
            if let icon = Store.shared.typeIcon(type) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(type.color)
            }
        }
        .frame(width: side, height: side)
        .help(type.rawValue)
    }
}

/// Physical / Special / Status, drawn rather than shipped as art.
struct CategoryBadge: View {
    let category: String

    private var color: Color {
        switch category {
        case "Physical": return Color(red: 0.76, green: 0.36, blue: 0.20)
        case "Special":  return Color(red: 0.30, green: 0.45, blue: 0.75)
        default:         return Color(red: 0.50, green: 0.50, blue: 0.55)
        }
    }

    private var symbol: String {
        switch category {
        case "Physical": return "burst.fill"
        case "Special":  return "sparkles"
        default:         return "circle.dotted"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(category == "Other" ? "Status" : category)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color)
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
}

// MARK: - Sprites

struct SpriteImage: View {
    let form: Form
    var side: CGFloat = 48

    var body: some View {
        Group {
            if let sprite = Store.shared.sprite(form) {
                Image(nsImage: sprite)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
    }
}

struct ItemIcon: View {
    let name: String
    var side: CGFloat = 22

    var body: some View {
        Group {
            if !name.isEmpty, let icon = Store.shared.itemIcon(named: name) {
                Image(nsImage: icon).resizable().interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.dashed")
                    .font(.system(size: side * 0.6))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Data display

/// A base-stat bar. Coloured by how the value compares across the dex, so a
/// 175 Defense reads instantly as exceptional.
struct StatBar: View {
    let stat: Stat
    let base: Int
    var computed: Int? = nil
    var maxBase: Int = 200

    private var fill: Color {
        switch base {
        case 150...: return Color(red: 0.24, green: 0.70, blue: 0.44)
        case 120..<150: return Color(red: 0.48, green: 0.72, blue: 0.36)
        case 90..<120: return Color(red: 0.86, green: 0.70, blue: 0.25)
        case 60..<90: return Color(red: 0.88, green: 0.52, blue: 0.28)
        default: return Color(red: 0.82, green: 0.36, blue: 0.34)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(stat.short)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            Text("\(base)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, geo.size.width * min(1, Double(base) / Double(maxBase))))
                }
            }
            .frame(height: 6)

            if let computed {
                Text("\(computed)")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

struct TierBadge: View {
    let tier: String
    var body: some View {
        Text(tier)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 20, height: 20)
            .background(Palette.tier(tier))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The "NEW IN M-C" marker.
struct NewBadge: View {
    var text = "NEW"
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .kerning(0.5)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(
                LinearGradient(colors: [Color(red: 0.95, green: 0.42, blue: 0.35),
                                        Color(red: 0.92, green: 0.28, blue: 0.48)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

/// Small key/value line used across detail panes.
struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Snapshot support

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True only while tools/snapshot.sh is rendering. ImageRenderer lays out a
    /// plain stack but produces an empty image for a ScrollView, so screens drop
    /// their scroll wrapper in this mode and render at full height instead.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}
