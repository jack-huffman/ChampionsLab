//  PokemonTile.swift
//  The big, hoverable tile used anywhere you pick a Pokémon.

import SwiftUI

/// A Pokémon you can click, large enough to actually look at.
///
/// Small rows are fine for a list you are scanning; they are wrong for a
/// gallery you are choosing from, where the sprite is the thing carrying the
/// information. Hover lifts the tile and shows its typing, so browsing eighty
/// Megas is a matter of looking rather than reading.
struct PokemonTile: View {
    @EnvironmentObject private var store: Store
    let form: Form
    var side: CGFloat = 76
    var isSelected = false
    /// A line under the name — usage, a speed number, whatever fits.
    var caption: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                SpriteImage(form: form, side: side)
                    .scaleEffect(hovering ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                VStack(spacing: 3) {
                    Text(form.formLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 3) {
                        ForEach(form.pokeTypes) { TypeChip(type: $0, size: .small) }
                    }
                    if let caption {
                        Text(caption)
                            .font(.system(size: 10, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Palette.accent.opacity(0.18)
                          : (hovering ? Palette.surfaceRaised : Palette.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Palette.accent
                                  : (hovering ? Palette.accent.opacity(0.55) : Palette.hairline),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: hovering ? 10 : 0, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tooltip)
    }

    private var tooltip: String {
        let stats = "HP \(form.hp) · Atk \(form.attack) · Def \(form.defense) · "
            + "SpA \(form.spAttack) · SpD \(form.spDefense) · Spe \(form.speed)"
        let abilities = form.abilities.map(\.name).joined(separator: " / ")
        return "\(form.formLabel)\n\(stats)\n\(abilities)"
    }
}

/// A choice in the interview: a claim, the arithmetic behind it, and a hover.
struct ChoiceCard: View {
    let label: String
    let detail: String
    let recommended: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Palette.accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label).font(.system(size: 13, weight: .semibold))
                        if recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 8, weight: .bold)).kerning(0.5)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Palette.good.opacity(0.18))
                                .foregroundStyle(Palette.good)
                                .clipShape(Capsule())
                        }
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Palette.accent.opacity(0.12)
                          : (hovering ? Palette.surfaceRaised : Palette.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Palette.accent
                                  : (hovering ? Palette.accent.opacity(0.5) : Palette.hairline),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
