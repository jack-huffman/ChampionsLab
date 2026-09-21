//  PixelSpritesTests.swift
//  A form knows what Showdown calls it, and what its sprite file is called.
//
//      swift test --filter PixelSpritesTests

import XCTest
@testable import ChampionsLab

final class PixelSpritesTests: HarnessCase {
    func testSlugsAreShowdownsFilenames() {
        for (name, slug) in [("Incineroar", "incineroar"), ("Charizard-Mega-Y", "charizard-megay"),
                             ("Ninetales-Alola", "ninetales-alola"), ("Indeedee-F", "indeedee-f"),
                             ("Tauros-Paldea-Combat", "tauros-paldeacombat"), ("Mr. Mime", "mrmime"),
                             ("Farfetch\u{2019}d-Galar", "farfetchd-galar")] {
            check("\(name) is \(slug)", PixelSprites.slug(showdownName: name) == slug,
                  PixelSprites.slug(showdownName: name) ?? "nil")
        }
        check("an empty name is no slug", PixelSprites.slug(showdownName: "") == nil)
    }

    /// Showdown puts two sets on a battle field and no more: its animated
    /// Gen 6 set, and the Gen 5 one behind its `bwgfx` preference. Dex art
    /// belongs to the teambuilder and the tooltips over there, and to the
    /// snapshots and the last-resort fallback here -- never to the picker.
    func testTheBattleOffersOnlyShowdownsTwoSets() {
        let offered = PixelSprites.Style.offered
        check("two looks are offered", offered.count == 2, "\(offered.map(\.label))")
        check("and neither of them is the illustration", !offered.contains(.illustrated))
        check("both are Showdown sets", offered.allSatisfy { !$0.chain.isEmpty })
        // Whatever is stored, what comes back is something the picker shows.
        for stored in ["models", "pixel", "illustrated", "nonsense", nil] {
            let got = PixelSprites.Style.chosen(stored)
            check("\(stored ?? "nothing") stored resolves to an offered look",
                  offered.contains(got), got.label)
        }
        check("a look that is offered is kept", PixelSprites.Style.chosen("pixel") == .pixel)
        check("the illustration is not, and falls to the default",
              PixelSprites.Style.chosen("illustrated") == .models)
    }

    @MainActor func testTheDexKnowsItsShowdownNames() {
        let forms = store.data.forms
        let named = forms.filter { $0.showdown != nil }
        print("  \(named.count) of \(forms.count) forms carry a Showdown name")
        // Every one of them, not nearly every one. The battle is drawn in
        // Showdown's sets and falls back to the app's own illustration only
        // when Showdown has nothing -- so a form with no Showdown name is a
        // Pokemon that will always be drawn in the look nobody chose. The
        // five that used to be here were ours to fix, not Showdown's gaps:
        // it files Squawkabilly's plumages under one word of the colour and
        // Maushold's larger family as "Maushold-Four", and it splits Mega
        // Meowstic by gender.
        let unnamed = forms.filter { $0.showdown == nil }.map(\.formLabel).sorted()
        check("every form carries one", unnamed.isEmpty, unnamed.joined(separator: ", "))
        let unslugged = forms.filter { PixelSprites.slug($0) == nil }.map(\.formLabel).sorted()
        check("and every one of them makes a sprite filename",
              unslugged.isEmpty, unslugged.joined(separator: ", "))
        check("Mega Absol Z is Absol-Mega-Z", form("Mega Absol Z").showdown == "Absol-Mega-Z",
              form("Mega Absol Z").showdown ?? "nil")
        check("and its sprite is absol-megaz", PixelSprites.slug(form("Mega Absol Z")) == "absol-megaz")
        // The hyphen that is part of a name rather than a join. Showdown files
        // this one as kommoo, and asking for kommo-o got nothing at all.
        check("Kommo-o is kommoo, not kommo-o",
              PixelSprites.slug(form("Kommo-o")) == "kommoo",
              PixelSprites.slug(form("Kommo-o")) ?? "nil")
        // And every form's slug is one Showdown could actually have: a
        // hyphen in it means a forme, and a forme means a suffix here.
        for entry in store.data.forms where entry.showdown != nil {
            guard let piece = PixelSprites.slug(entry) else { continue }
            if piece.contains("-") {
                check("\(entry.formLabel)'s slug \(piece) is a species and a forme",
                      !entry.suffix.isEmpty, entry.suffix)
            }
        }
    }
}
