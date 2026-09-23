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

    /// The two looks have to actually ask for different pictures.
    ///
    /// They stopped doing that without anything in the picker changing:
    /// the chain was being read against the cache rather than against
    /// Showdown, so a Gen 6 sprite already on disk answered a request for the
    /// Gen 5 one two rungs further down its own chain, and every Pokemon you
    /// had already looked at ignored the toggle. What makes the toggle mean
    /// anything is that the two lead with different sets and that a file from
    /// one is never mistaken for a file from the other.
    func testTheTwoLooksLeadWithDifferentSets() {
        check("Models asks Showdown's Gen 6 set first",
              PixelSprites.Style.models.chain.first == .gen6,
              "\(PixelSprites.Style.models.chain.first.map(\.rawValue) ?? "nothing")")
        check("Pixel asks its Gen 5 set first",
              PixelSprites.Style.pixel.chain.first == .gen5,
              "\(PixelSprites.Style.pixel.chain.first.map(\.rawValue) ?? "nothing")")
        check("so the two do not open with the same ask",
              PixelSprites.Style.models.chain.first != PixelSprites.Style.pixel.chain.first)
        // Both end on the still, which is the same art standing still and so
        // belongs to either look.
        for style in PixelSprites.Style.offered {
            check("\(style.label) ends on a still", style.chain.last == .still,
                  "\(style.chain.map(\.rawValue))")
        }
        // And Pixel never reaches into the model set, which is the thing that
        // actually broke the toggle. Leading with different sets is not
        // enough on its own: Pixel once fell through to the Gen 6 animation
        // when Showdown had no Gen 5 one, and *nothing in this format has a
        // Gen 5 one* -- every Mega postdates Black and White and so does most
        // of the dex -- so the second rung was not a fallback, it was the
        // whole field. The toggle led with different sets and drew the same
        // picture either way.
        check("Pixel never serves a model",
              !PixelSprites.Style.pixel.chain.contains(.gen6),
              "\(PixelSprites.Style.pixel.chain.map(\.rawValue))")
        check("it is pixel art all the way down",
              Set(PixelSprites.Style.pixel.chain).isSubset(of: [.gen5, .still]),
              "\(PixelSprites.Style.pixel.chain.map(\.rawValue))")
        // Models may fall back to the pixel animation, because it is the only
        // other animation there is and five forms have no model at all.
        check("Models falls back to the pixel animation",
              PixelSprites.Style.models.chain.contains(.gen5))
        // Which leaves the two looks drawing from different shelves, which is
        // the whole of what a toggle is.
        check("so the two looks do not draw from the same shelves",
              Set(PixelSprites.Style.pixel.chain) != Set(PixelSprites.Style.models.chain),
              "pixel \(PixelSprites.Style.pixel.chain.map(\.rawValue)) "
                + "vs models \(PixelSprites.Style.models.chain.map(\.rawValue))")
    }

    /// A cached sprite has to say which set it came out of, in the filename
    /// and in the URL both. Everything about telling the looks apart rests on
    /// it: the file they are kept under, and how big they are drawn.
    func testEverySetIsItsOwnFileAndItsOwnAddress() {
        var files = Set<String>(), paths = Set<String>()
        for source in PixelSprites.Source.allCases {
            files.insert("\(source.rawValue).\(source.extension_)")
            paths.insert(source.path(back: false, shiny: false))
        }
        check("each set has its own cache filename", files.count == PixelSprites.Source.allCases.count,
              "\(files.sorted())")
        check("and its own directory on Showdown", paths.count == PixelSprites.Source.allCases.count,
              "\(paths.sorted())")
        // The shape of the ask is on the directory, the way Showdown files it.
        check("a back sprite is a different directory",
              PixelSprites.Source.gen6.path(back: true, shiny: false) == "ani-back/")
        check("and a shiny one too",
              PixelSprites.Source.gen6.path(back: false, shiny: true) == "ani-shiny/")
        check("and a shiny back is both",
              PixelSprites.Source.gen6.path(back: true, shiny: true) == "ani-back-shiny/")
        // The two animated sets are drawn to different scales, which is the
        // other half of why a sprite must remember where it came from.
        check("the two animated sets measure against different medians",
              PixelSprites.Source.gen6.typical != PixelSprites.Source.gen5.typical,
              "\(PixelSprites.Source.gen6.typical ?? -1) and \(PixelSprites.Source.gen5.typical ?? -1)")
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
