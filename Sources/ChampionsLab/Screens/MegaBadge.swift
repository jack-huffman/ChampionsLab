//  MegaBadge.swift
//  The mark the field puts on a stone-holder.
//
//  On your side it is a plain M: it starts as itself and Mega Evolves when it
//  uses a move. On theirs it is a question, because their items are not on
//  show -- the badge says the species *has* a Mega and how often one carries
//  the stone, which is all the game lets you know.

import SwiftUI

struct MegaBadge: View {
    let uncertain: Bool
    let form: Form
    @EnvironmentObject private var store: Store

    /// The mark the field puts on a stone-holder: it starts as itself. On
    /// their side it is a question, because their items are not on show.
    var body: some View {
        Text(uncertain ? "M?" : "M")
            .font(.system(size: uncertain ? 7 : 8, weight: .heavy)).foregroundStyle(.white)
            .frame(width: uncertain ? 18 : 14, height: 14)
            .background(uncertain ? Palette.warn.opacity(0.7) : Palette.warn)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(uncertain ? 0.5 : 0),
                                            style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
            .help(uncertain
                  ? "\(form.formLabel) has a Mega, and you cannot see what this one holds." + MegaGuess(store: store).stoneOdds(form)
                  : "Holding its stone. It starts as itself and Mega Evolves when it uses a move.")
    }
}
