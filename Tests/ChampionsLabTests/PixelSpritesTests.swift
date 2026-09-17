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

    @MainActor func testTheDexKnowsItsShowdownNames() {
        let forms = store.data.forms
        let named = forms.filter { $0.showdown != nil }
        print("  \(named.count) of \(forms.count) forms carry a Showdown name")
        check("nearly every form carries one", Double(named.count) / Double(max(1, forms.count)) > 0.9)
        check("Mega Absol Z is Absol-Mega-Z", form("Mega Absol Z").showdown == "Absol-Mega-Z",
              form("Mega Absol Z").showdown ?? "nil")
        check("and its sprite is absol-megaz", PixelSprites.slug(form("Mega Absol Z")) == "absol-megaz")
    }
}
