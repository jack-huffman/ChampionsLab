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

    /// A Pokémon's card on the battlefield.
    ///
    /// Not `surfaceRaised`, which is a *dark* grey — that reads as raised
    /// against the app's near-black canvas, and as a hole against the
    /// battlefield, which is a lighter blue with weather over it. On the field
    /// a card has to be lighter than the ground it stands on.
    static let cardOnField = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedRed: 0.235, green: 0.255, blue: 0.325, alpha: 0.97)
                          : NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.95)
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
///
/// `height` pins the tile so a grid of them reads as a grid. LazyVGrid equalises
/// cells within a row but not across rows, so without it a card with two lines of
/// analysis is visibly shorter than one with four.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var height: CGFloat? = nil
    /// Fill the height the row offers rather than hugging the content, and
    /// tell the row how tall the content wants to be. Cards side by side
    /// otherwise end at different depths, and the page moves under you as
    /// their content changes.
    var stretches = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(stretches ? AnyView(GeometryReader { geo in
                Color.clear.preference(key: CardRowHeight.self, value: geo.size.height)
            }) : AnyView(Color.clear))
            .frame(maxWidth: .infinity, minHeight: height,
                   maxHeight: stretches ? .infinity : height,
                   alignment: .topLeading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// How tall the tallest card in a row wants to be.
struct CardRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

/// Cards side by side that end at the same depth, whatever is in them.
///
/// Each card reports the height its own content wants; the row takes the
/// tallest, never less than `floor`, and gives that height to all of them.
/// The floor is what stops the row collapsing while the reading behind it is
/// still being worked out, which is what made the page jump when a matchup
/// was picked: empty cards, then full ones a moment later.
struct EqualCards<Content: View>: View {
    var spacing: CGFloat = 14
    var floor: CGFloat = 200
    @ViewBuilder var content: Content
    @State private var tallest: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content }
            .frame(height: Swift.max(tallest, floor), alignment: .top)
            .onPreferenceChange(CardRowHeight.self) { tallest = $0 }
    }
}

/// A card that keeps its detail folded away until it is wanted.
///
/// The screens in this app answer a lot of questions at once, and the ones
/// worth the most — a team's win rate, which Pokémon is costing it games —
/// were being read at the same size as the ones worth the least. Depth is not
/// the problem; showing all of it at once is. So every section states its
/// finding in one line and holds the table behind it.
///
/// `summary` is the point of the thing. A section whose folded line reads
/// "6 rows" has saved nobody anything: it should say what the rows came to,
/// so the fold can be left alone when the answer is already there.
struct Fold<Content: View>: View {
    let title: String
    /// The finding, in one line, for when this is closed.
    var summary: String = ""
    var subtitle: String? = nil
    /// Whether it starts open. The one or two sections that answer the main
    /// question should; the rest should not.
    var open = false
    /// Snapshots and anything else that cannot click have to see it all.
    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder var content: Content

    @State private var shown: Bool?

    private var isOpen: Bool { snapshotMode || (shown ?? open) }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: isOpen ? 8 : 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { shown = !isOpen }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 10)
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .textCase(.uppercase).kerning(0.6)
                            .foregroundStyle(.secondary)
                        if !summary.isEmpty, !isOpen {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                    }
                    content.padding(.leading, 18)
                }
            }
        }
    }
}

/// A vertical scroller everywhere but in a snapshot.
///
/// ImageRenderer cannot materialise a ScrollView's content, so every screen
/// that wants a shot swaps its scroller for a plain stack when `snapshotMode`
/// is on. That swap was written three times over; this is the one place.
struct MaybeScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder let content: Content
    var body: some View {
        if snapshotMode { content } else { ScrollView { content } }
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
///
/// Fixed width by default. Letting the pill size to its text made every column
/// after it in a move table shift by the difference between "Status" and
/// "Physical", so the numbers never lined up.
struct CategoryBadge: View {
    let category: String
    var width: CGFloat? = MoveColumn.category

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
        .frame(width: width, height: 18)
        .background(color)
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
}

/// Column widths for the move table, shared by the header and every row so the
/// two cannot drift apart.
enum MoveColumn {
    static let type: CGFloat = 20
    static let name: CGFloat = 150
    static let category: CGFloat = 74
    static let power: CGFloat = 34
    static let accuracy: CGFloat = 34
    static let priority: CGFloat = 32
    static let flag: CGFloat = 16
    static let flags: CGFloat = flag * 2 + 4
    static let spacing: CGFloat = 8
}

/// Column labels for a move table.
struct MoveTableHeader: View {
    var body: some View {
        HStack(spacing: MoveColumn.spacing) {
            Color.clear.frame(width: MoveColumn.type, height: 1)
            label("Move", width: MoveColumn.name, alignment: .leading)
            label("Class", width: MoveColumn.category, alignment: .center)
            label("Pow", width: MoveColumn.power, alignment: .trailing)
            label("Acc", width: MoveColumn.accuracy, alignment: .trailing)
            label("Pri", width: MoveColumn.priority, alignment: .center)
            label("", width: MoveColumn.flags, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // SwiftUI.Alignment spelled out: `Alignment` here is the stat alignment
    // (nature) type from Stats.swift, which shadows it.
    private func label(_ text: String, width: CGFloat,
                       alignment: SwiftUI.Alignment) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Sprites

extension Palette {
    /// What marks something registered shiny. Amber rather than the accent,
    /// so it is not mistaken for selection, and paired everywhere with a
    /// label and a filled-against-outlined shape rather than carrying the
    /// meaning on its own.
    static let shiny = Color(red: 0.93, green: 0.65, blue: 0.16)
}

struct SpriteImage: View {
    let form: Form
    var side: CGFloat = 48
    /// Drawn in its shiny colours. Defaulted off, so the sixty-odd places
    /// that draw a sprite without an opinion keep the one they had.
    var shiny: Bool = false

    var body: some View {
        Group {
            if let sprite = Store.shared.sprite(form, shiny: shiny) {
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

// MARK: - Lookup field

/// A replacement for `Picker` when the list is long.
///
/// SwiftUI's macOS Picker builds every row into an NSMenu the moment the view
/// appears, whichever row is selected. The slot editor has an item list of ~300
/// and four move lists of ~60, so opening a six-Pokémon team was constructing
/// roughly 3,400 menu rows before it could draw anything. This shows the current
/// value as a button and only builds rows — lazily, and filtered — once the
/// popover is actually open.
struct LookupField: View {
    enum Kind { case item, move, form }

    let kind: Kind
    let placeholder: String
    let options: [LookupOption]
    @Binding var selection: String
    var allowsNone = true

    @State private var open = false
    @State private var query = ""

    private var current: LookupOption? { options.first { $0.id == selection } }

    private var filtered: [LookupOption] {
        guard !query.isEmpty else { return options }
        let needle = query.lowercased()
        return options.filter {
            $0.name.lowercased().contains(needle)
                || ($0.subtitle?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                icon(for: current)
                Text(current?.name ?? placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(current == nil ? Palette.fainter : Palette.normal)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField(placeholder, text: $query).textFieldStyle(.plain)
                }
                .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if allowsNone {
                            row(LookupOption(id: "", name: "None", subtitle: nil))
                        }
                        ForEach(filtered) { row($0) }
                    }
                    .padding(6)
                }
            }
            .frame(width: 280, height: 320)
        }
    }

    private func row(_ option: LookupOption) -> some View {
        HStack(spacing: 6) {
            icon(for: option.id.isEmpty ? nil : option)
            VStack(alignment: .leading, spacing: 0) {
                Text(option.name).font(.system(size: 11))
                if let subtitle = option.subtitle {
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(option.id == selection ? Palette.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = option.id
            query = ""
            open = false
        }
    }

    @ViewBuilder private func icon(for option: LookupOption?) -> some View {
        switch kind {
        case .item:
            ItemIcon(name: option?.name ?? "", side: 15)
        case .move:
            if let type = option?.type { TypeIcon(type: type, side: 14) }
            else { Color.clear.frame(width: 14, height: 14) }
        case .form:
            if let form = option?.form { SpriteImage(form: form, side: 18) }
            else { Color.clear.frame(width: 18, height: 18) }
        }
    }
}

struct LookupOption: Identifiable, Hashable {
    let id: String
    let name: String
    var subtitle: String? = nil
    var type: PokeType? = nil
    var form: Form? = nil
}

// MARK: - Info affordance

/// A small "i" that explains the field it sits beside.
///
/// Hovering gives the plain text immediately through the standard tooltip;
/// clicking opens the same thing as a popover for when the text is long enough
/// that a tooltip would be a poor way to read it.
struct InfoButton: View {
    let title: String
    let body_: String
    var accent: Color = Palette.accent

    @State private var open = false

    init(title: String, body: String, accent: Color = Palette.accent) {
        self.title = title
        self.body_ = body
        self.accent = accent
    }

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(body_.isEmpty ? Palette.fainter : accent)
        }
        .buttonStyle(.plain)
        .disabled(body_.isEmpty)
        .help(body_.isEmpty ? "" : "\(title)\n\n\(body_)")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body_)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 300)
        }
    }
}

/// A −6…+6 battle stage control.
///
/// Stages change damage more than almost anything else the calculator exposes —
/// a Swords Dance is 2.0x and a Swords Dance plus a Thermal Exchange proc is
/// 2.5x — so this is a visible stepper rather than a mini popup menu.
struct StageStepper: View {
    @Binding var stage: Int

    var body: some View {
        HStack(spacing: 2) {
            button("minus", enabled: stage > -6) { stage = max(-6, stage - 1) }
            Text(stage == 0 ? "—" : (stage > 0 ? "+\(stage)" : "\(stage)"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 24)
                .foregroundStyle(stage == 0 ? Palette.fainter
                                 : (stage > 0 ? Palette.good : Palette.bad))
            button("plus", enabled: stage < 6) { stage = min(6, stage + 1) }
        }
        .frame(width: 66)
        .help("Battle stages: \(stage == 0 ? "none" : "×\(String(format: "%.2f", multiplier))")")
    }

    private var multiplier: Double {
        stage >= 0 ? Double(2 + stage) / 2 : 2 / Double(2 - stage)
    }

    private func button(_ symbol: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Stat Point bar

/// The in-game Stat Point track: a segmented rail of 32 with the invested
/// portion filled, matching how Champions itself draws a stat.
///
/// `budget` is what is still spendable elsewhere on this Pokémon, so the rail
/// dims the part of the range the 66-point total no longer allows — the game
/// stops you at the cap rather than letting you overspend and warning after.
struct StatPointBar: View {
    let sp: Int
    var budget: Int = ChampionsStats.spPerStat
    var interactive = false
    var onChange: ((Int) -> Void)? = nil

    private var reachable: Int { min(ChampionsStats.spPerStat, sp + budget) }

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(ChampionsStats.spPerStat)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                // The part the remaining budget cannot reach. Deliberately a
                // dimming rather than a warning colour: with all 66 spent every
                // rail is capped, which is a finished build, not an error.
                if interactive && reachable < ChampionsStats.spPerStat {
                    Capsule()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: unit * CGFloat(ChampionsStats.spPerStat - reachable))
                        .offset(x: unit * CGFloat(reachable))
                }
                Capsule()
                    .fill(sp == ChampionsStats.spPerStat ? Palette.good : Palette.accent)
                    .frame(width: max(0, unit * CGFloat(sp)))
            }
            .contentShape(Rectangle())
            .gesture(interactive ? drag(unit: unit) : nil)
        }
        .frame(height: 6)
    }

    private func drag(unit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let raw = Int((value.location.x / unit).rounded())
            onChange?(max(0, min(reachable, raw)))
        }
    }
}

/// One stat line as Champions draws it: name, value, rail, points spent.
struct StatLine: View {
    let stat: Stat
    let value: Int
    let sp: Int
    var budget: Int = ChampionsStats.spPerStat
    var boosted: Bool = false
    var lowered: Bool = false
    var interactive = false
    var onChange: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Text(stat.short)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                if boosted {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.good)
                } else if lowered {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.bad)
                }
            }
            .frame(width: 40, alignment: .leading)

            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            StatPointBar(sp: sp, budget: budget, interactive: interactive, onChange: onChange)

            Text(sp > 0 ? "+\(sp)" : "")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(sp == ChampionsStats.spPerStat ? Palette.good : Palette.fainter)
                .frame(width: 26, alignment: .leading)
        }
    }
}

/// Shared metrics for the pane headers either side of a split, so their
/// dividers line up.
enum HeaderBar {
    static let height: CGFloat = 44
    static let titleSize: CGFloat = 15
}
