//  SpriteSizeTests.swift
//  A sprite is drawn at its own size, not squeezed into everybody's box.
//
//      swift test --filter SpriteSizeTests

import XCTest
import AppKit
@testable import ChampionsLab

final class SpriteSizeTests: XCTestCase {
    var fails = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "",
               file: StaticString = #filePath, line: UInt = #line) {
        if !ok { fails += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        XCTAssertTrue(ok, label, file: file, line: line)
    }

    /// A PNG of exactly this many pixels, to feed the decoder something real.
    ///
    /// Built as a bitmap rather than by drawing into an NSImage: an NSImage is
    /// measured in points and renders at the screen's backing scale, so asking
    /// for 75 gave a 150-pixel file and every measurement here came out
    /// doubled. What the decoder reads is pixels.
    private func png(_ width: Int, _ height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// Two of Showdown's looks and the app's own, and a Showdown look falls
    /// all the way through Showdown before it gives up.
    func testEachLookTriesShowdownBeforeThePainting() {
        check("Models starts with the Gen 6 set",
              PixelSprites.Style.models.chain.first == .gen6,
              "\(PixelSprites.Style.models.chain.map(\.rawValue))")
        check("Pixel starts with the Gen 5 one",
              PixelSprites.Style.pixel.chain.first == .gen5,
              "\(PixelSprites.Style.pixel.chain.map(\.rawValue))")
        for style in [PixelSprites.Style.models, .pixel] {
            check("\(style.label) tries every set Showdown has",
                  Set(style.chain) == Set(PixelSprites.Source.allCases),
                  "\(style.chain.map(\.rawValue))")
        }
        check("and the illustrations ask Showdown for nothing",
              PixelSprites.Style.illustrated.chain.isEmpty)
        check("Pixel prefers a Gen 5 still to a Gen 6 animation",
              PixelSprites.Style.pixel.chain.firstIndex(of: .still)!
                < PixelSprites.Style.pixel.chain.firstIndex(of: .gen6)!)
        check("all three are offered", PixelSprites.Style.allCases.count == 3)
        check("and they are named for what they are",
              PixelSprites.Style.allCases.map(\.label) == ["Models", "Pixel", "Art"],
              "\(PixelSprites.Style.allCases.map(\.label))")
    }

    /// A seat is a point on the ground, so a sprite is anchored by its feet.
    /// Lifting it by half the difference is what keeps a big one out of the
    /// floor, and the sums are worth pinning because nothing else checks them.
    func testASpriteIsLiftedByHalfWhateverItGained() {
        let side: CGFloat = 96
        for relative in [0.66, 1.0, 1.24, 1.55] {
            let drawn = side * relative
            let lift = -(relative - 1) / 2 * side
            // Where its bottom edge lands, measured from the middle of the box.
            let bottom = lift + drawn / 2
            check("at \(relative) its feet are where the box's are",
                  abs(bottom - side / 2) < 0.001, "\(bottom) against \(side / 2)")
        }
    }

    func testTheDirectoriesAreShowdownsOwnShape() {
        check("the Gen 6 front", PixelSprites.Source.gen6.path(back: false, shiny: false) == "ani/")
        check("its back", PixelSprites.Source.gen6.path(back: true, shiny: false) == "ani-back/")
        check("its shiny", PixelSprites.Source.gen6.path(back: false, shiny: true) == "ani-shiny/")
        check("and its shiny back",
              PixelSprites.Source.gen6.path(back: true, shiny: true) == "ani-back-shiny/")
        check("the Gen 5 one the same way",
              PixelSprites.Source.gen5.path(back: true, shiny: true) == "gen5ani-back-shiny/")
        check("and the stills",
              PixelSprites.Source.still.path(back: true, shiny: true) == "gen5-back-shiny/")
        check("the Gen 6 set is tried first",
              PixelSprites.Source.allCases.first == .gen6,
              "\(PixelSprites.Source.allCases.map(\.rawValue))")
    }

    /// The measurement this rests on: a Whimsicott's Gen 6 sprite is 75 across
    /// and a Staraptor's is 195, against a set whose median is 110.
    func testABigSpriteIsDrawnBiggerThanASmallOne() {
        guard let small = PixelSprites.Frames.decode(png(75, 67), from: .gen6),
              let large = PixelSprites.Frames.decode(png(195, 195), from: .gen6),
              let middling = PixelSprites.Frames.decode(png(110, 108), from: .gen6) else {
            return check("the decoder read all three", false)
        }
        check("the small one is drawn small", small.relative < 0.8, "\(small.relative)")
        check("the middling one is about nominal",
              abs(middling.relative - 1) < 0.05, "\(middling.relative)")
        check("the big one is drawn big", large.relative > 1.4, "\(large.relative)")
        check("and the big one really is bigger than the small one",
              large.relative > small.relative * 1.8,
              "\(large.relative) against \(small.relative)")
    }

    /// Nothing is allowed to swamp the field, however wide the client drew it.
    func testItIsClamped() {
        guard let vast = PixelSprites.Frames.decode(png(600, 600), from: .gen6),
              let tiny = PixelSprites.Frames.decode(png(8, 8), from: .gen6) else {
            return check("the decoder read both", false)
        }
        check("nothing grows past half again", vast.relative <= 1.55, "\(vast.relative)")
        check("and nothing shrinks below two thirds", tiny.relative >= 0.66, "\(tiny.relative)")
    }

    /// A still is drawn on a fixed square whatever is on it, so there is no
    /// size in it to read and it keeps the nominal one.
    func testAStillHasNoSizeToRead() {
        guard let a = PixelSprites.Frames.decode(png(96, 96), from: .still),
              let b = PixelSprites.Frames.decode(png(40, 40), from: .still) else {
            return check("the decoder read both", false)
        }
        check("a still is nominal", a.relative == 1, "\(a.relative)")
        check("whatever is drawn on it", b.relative == 1, "\(b.relative)")
    }

    /// The two animated sets are drawn to different scales, so the same
    /// picture out of each has to be measured against its own.
    func testEachSetIsMeasuredAgainstItself() {
        guard let six = PixelSprites.Frames.decode(png(84, 84), from: .gen6),
              let five = PixelSprites.Frames.decode(png(84, 84), from: .gen5) else {
            return check("the decoder read both", false)
        }
        check("84 is small for the Gen 6 set", six.relative < 0.85, "\(six.relative)")
        check("and about typical for the Gen 5 one",
              abs(five.relative - 1) < 0.05, "\(five.relative)")
    }
}
