//  PixelSprites.swift
//  Showdown's pixel sprites, fetched on demand and kept.
//
//  The battle screen can draw its Pokemon as Pokemon Showdown does: the
//  animated gen 5 pixel sprites, backs for your side and fronts for theirs,
//  which is the look most competitive players know. They are not bundled --
//  four hundred animated files are tens of megabytes, and the illustrations
//  the rest of the app uses stay the default -- so the first time a form is
//  wanted in that style it is fetched from play.pokemonshowdown.com and kept
//  under Application Support. Until it arrives, and for a form with no sprite
//  there at all, the card shows the illustration.
//
//  Showdown keeps several sets and they are not equally complete. The Gen 6
//  one -- `ani` -- has 340 of this dex's 345 forms; the Gen 5 one the app
//  used to ask for first has 219. That gap is a hundred and twenty-one
//  Pokemon, most of Gen 8 and Gen 9 among them, quietly falling back to a
//  still or to the illustration on a screen set to pixel sprites. It asks the
//  bigger set first now and keeps the smaller one behind it, which costs
//  nothing: measured against the whole dex, `ani` has everything `gen5ani`
//  has and a hundred and twenty-one more.
//
//  What is left is five Megas this game invented -- Absol Z, Baxcalibur,
//  Garchomp Z, Golisopod, Lucario Z -- which exist in no client because they
//  exist in no other game. Showdown has drawn a still for each, and the still
//  is what comes back for those.
//
//  Shiny is the same set under another name -- gen5ani-shiny and its three
//  siblings -- and is fetched and kept the same way, under its own key so the
//  two never overwrite each other in the cache.

import AppKit
import ImageIO

@MainActor
final class PixelSprites: ObservableObject {
    /// Which of Showdown's looks to draw a battle in.
    ///
    /// The client offers two and they are different things, not two qualities
    /// of the same thing: the Gen 6 set is animated models, the Gen 5 set is
    /// animated pixel art, and people have opinions. The app's own
    /// illustrations are the third, and the last resort -- a Showdown look
    /// falls all the way through Showdown before it gives up, because a board
    /// with one Pokemon drawn in a different style to the rest is worse than
    /// one drawn a little smaller than you wanted.
    enum Style: String, CaseIterable, Sendable {
        case models, pixel, illustrated

        var label: String {
            switch self {
            case .models: return "Models"
            case .pixel: return "Pixel"
            case .illustrated: return "Art"
            }
        }
        /// The sets to try, best first. Empty for the illustrations, which
        /// are not Showdown's and are always there.
        var chain: [Source] {
            switch self {
            case .models: return [.gen6, .gen5, .still]
            // Falling through to the models rather than to the illustration:
            // a still from Gen 5 is still pixel art, and after that an
            // animated model is closer to what was asked for than a painting.
            case .pixel: return [.gen5, .still, .gen6]
            case .illustrated: return []
            }
        }

        /// The looks a battle can be set to: Showdown's two, and only those.
        ///
        /// `illustrated` is deliberately not among them. It is not one of
        /// Showdown's sets and never appears on a Showdown battle field --
        /// the client picks between its animated Gen 6 set and, under its
        /// `bwgfx` preference, the Gen 5 one, and falls back to Gen 5 stills;
        /// dex art belongs to the teambuilder and the tooltips. Offering it
        /// as a third choice put a look nobody would pick beside two they
        /// would.
        ///
        /// It stays in the enum for the two jobs it is genuinely the right
        /// answer to: a snapshot, which must not depend on the network, and
        /// the last resort when Showdown has nothing for a Pokemon at all.
        static let offered: [Style] = [.models, .pixel]

        /// What a stored preference means now. Anyone the old picker left on
        /// the illustrations is moved to the default rather than stranded on
        /// a setting nothing can show them how to leave.
        static func chosen(_ stored: String?) -> Style {
            let style = stored.flatMap { Style(rawValue: $0) } ?? .models
            return offered.contains(style) ? style : .models
        }
    }

    /// Which of Showdown's sets a sprite came out of, and how big a typical
    /// one in it is.
    ///
    /// The sets are drawn to different scales and the client knows it: a Gen 6
    /// sprite runs from 69 pixels to 195 and a Gen 5 one from 52 to 119. That
    /// spread is the Pokemon's own size -- a Joltik is small and a Staraptor
    /// has a wingspan -- and drawing each of them to fill the same square
    /// throws all of it away, which is how a Whimsicott ended up towering over
    /// a Staraptor. The median is what a sprite is measured against.
    ///
    /// A still has no size in it to read: every one is drawn on the same 96
    /// square whatever is on it, so those are left at their nominal size.
    enum Source: String, CaseIterable, Sendable {
        case gen6 = "ani"
        case gen5 = "gen5ani"
        case still = "gen5"

        var typical: Double? {
            switch self {
            case .gen6:  return 110
            case .gen5:  return 84
            case .still: return nil
            }
        }
        var extension_: String { self == .still ? "png" : "gif" }
        /// The directory, with the shape of the ask on it.
        func path(back: Bool, shiny: Bool) -> String {
            rawValue + (back ? "-back" : "") + (shiny ? "-shiny" : "") + "/"
        }
    }
    /// A sprite's frames and how long each shows. CGImages are immutable and
    /// safe to read from anywhere, which is what the unchecked promise says.
    struct Frames: @unchecked Sendable {
        let images: [CGImage]
        let delays: [TimeInterval]
        let total: TimeInterval
        /// How big this one is against a typical sprite from the same set.
        /// One for anything with no size to read. Clamped, because the widest
        /// sprite in the set is nearly three times the narrowest and a field
        /// with one Pokemon three times the other is not a field.
        var relative: Double = 1

        /// The frame showing at this instant of a clock that loops.
        func frame(at time: TimeInterval) -> CGImage {
            guard images.count > 1, total > 0 else { return images[0] }
            var into = time.truncatingRemainder(dividingBy: total)
            for (image, delay) in zip(images, delays) {
                into -= delay
                if into < 0 { return image }
            }
            return images[images.count - 1]
        }

        /// Every frame of a GIF, or the one frame of a PNG.
        nonisolated static func decode(_ data: Data, from set: Source = .still) -> Frames? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            var images: [CGImage] = [], delays: [TimeInterval] = []
            for index in 0..<count {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                var delay = 0.1
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                   let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
                    delay = max(0.02, unclamped ?? clamped ?? 0.1)
                }
                images.append(image); delays.append(delay)
            }
            guard !images.isEmpty else { return nil }
            var scale = 1.0
            if let typical = set.typical, let first = images.first {
                let widest = Double(Swift.max(first.width, first.height))
                scale = Swift.max(0.66, Swift.min(1.55, widest / typical))
            }
            return Frames(images: images, delays: delays, total: delays.reduce(0, +),
                          relative: scale)
        }
    }

    static let shared = PixelSprites()

    private init() {
        // The old cache was filled when a smaller set of Showdown's was asked
        // for first, and nothing in a cache remembers which shelf it came off.
        // Swept once, here, because this is the only thing that knows.
        Self.sweepTheOldCache()
    }
    static let credit = "Pixel sprites on the battle screen, when that style is chosen, are Pokémon Showdown's, fetched the first time they are needed."

    /// What a form's file is called there: the species id, then the forme's
    /// id after a hyphen. Charizard-Mega-Y is charizard-megay, Ninetales-Alola
    /// is ninetales-alola, Incineroar is incineroar.
    nonisolated static func slug(showdownName name: String) -> String? {
        guard !name.isEmpty else { return nil }
        func id(_ text: Substring) -> String {
            String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        }
        guard let dash = name.firstIndex(of: "-") else { return id(name[...]) }
        return id(name[..<dash]) + "-" + id(name[name.index(after: dash)...])
    }

    /// The same, for a form we actually have.
    ///
    /// The hyphen in a Showdown name usually separates the species from the
    /// forme -- Ninetales-Alola, Charizard-Mega-Y -- but sometimes it is just
    /// part of the species' name, and Kommo-o is the one in this dex. Showdown
    /// files that as "kommoo"; splitting at the hyphen asks for "kommo-o",
    /// which is not there, so Kommo-o silently had no pixel sprite at all. A
    /// form with no suffix has no forme, so there is nothing to split off.
    nonisolated static func slug(_ form: Form) -> String? {
        guard let name = form.showdown else { return nil }
        if form.suffix.isEmpty {
            return slug(showdownName: name.replacingOccurrences(of: "-", with: ""))
        }
        return slug(showdownName: name)
    }

    private var frames: [String: Frames] = [:]
    private var fetching: Set<String> = []
    private var missing: Set<String> = []

    /// The sprite's frames, or nil while it is on its way or when there is
    /// none. Asking starts the fetch and the decode, both off the main
    /// thread; the object announces itself when they land.
    func frames(for form: Form, back: Bool, shiny: Bool = false,
                style: Style = .models) -> Frames? {
        guard style != .illustrated, let slug = Self.slug(form) else { return nil }
        // Where it goes on disk is decided by which set it came out of, so two
        // looks that land on the same set share the file. What is kept in
        // memory is keyed by the look as well, because the same Pokemon is a
        // different picture in each.
        let base = (back ? "back/" : "front/") + (shiny ? "shiny/" : "") + slug
        let key = style.rawValue + "/" + base
        if let ready = frames[key] { return ready }
        guard !missing.contains(key), !fetching.contains(key) else { return nil }
        fetching.insert(key)
        let chain = style.chain
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = await Self.art(slug: slug, back: back, shiny: shiny,
                                       base: base, chain: chain)
            let decoded = found.flatMap { Frames.decode($0.data, from: $0.source) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching.remove(key)
                if let decoded { self.frames[key] = decoded } else { self.missing.insert(key) }
                self.objectWillChange.send()
            }
        }
        return nil
    }

    /// Where a fetched sprite is kept.
    ///
    /// The name carries a number because what is kept is whatever the fetch
    /// found first, and that changed: a cache filled when the Gen 5 set was
    /// asked for first would go on serving the worse sprite for ever, since
    /// nothing in a cache remembers which shelf it came off. A new directory
    /// is the whole migration; the old one is swept up once.
    /// Fetch these now, so that walking one out mid-battle is not a download.
    ///
    /// A sprite is asked for the first time the Pokemon is on screen, and the
    /// first time is exactly when somebody is watching: a Garchomp switched in
    /// showed the still, and showed the animation after the style was toggled
    /// off and back, which is the sound of a fetch finishing while nobody was
    /// asking. The whole of both teams is a few hundred kilobytes and it is
    /// wanted within the minute.
    func warm(_ forms: [Form], shiny: [Bool] = [], style: Style) {
        guard style != .illustrated else { return }
        for (index, form) in forms.enumerated() {
            let sparkly = index < shiny.count ? shiny[index] : false
            _ = frames(for: form, back: true, shiny: sparkly, style: style)
            _ = frames(for: form, back: false, shiny: sparkly, style: style)
        }
    }

    private nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChampionsLab/sprites-ani")
    }

    /// The cache from before the Gen 6 set was preferred, removed once so it
    /// is not left sitting there being nothing.
    nonisolated static func sweepTheOldCache() {
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChampionsLab/sprites")
        try? FileManager.default.removeItem(at: old)
    }

    /// The best set this Pokemon actually has, asking the site for the ones
    /// it has not been asked for yet.
    ///
    /// The chain is a statement about what *Showdown* has -- use the Gen 5
    /// sprite, and if Showdown has not got one use the Gen 6 -- and it has to
    /// be read against Showdown, not against this cache. Reading it against
    /// the cache is what made the two looks identical: viewing a battle in
    /// Models put the Gen 6 sprite on disk, and switching to Pixel then found
    /// that file two rungs down its own chain and stopped there, perfectly
    /// happy, having never once asked whether a Gen 5 sprite existed. Every
    /// Pokemon you had already looked at was immune to the toggle.
    ///
    /// So each rung is settled completely before the next is tried: on disk,
    /// or ask, and only a Pokemon the site genuinely has not got at that size
    /// moves down.
    ///
    /// The set is in the filename because nothing else remembers it, and how
    /// big a sprite should be drawn depends on which one it came out of.
    private nonisolated static func art(slug: String, back: Bool, shiny: Bool,
                                        base: String,
                                        chain: [Source]) async -> (data: Data, source: Source)? {
        let site = "https://play.pokemonshowdown.com/sprites/"
        for source in chain {
            let file = folder.appendingPathComponent("\(base).\(source.rawValue).\(source.extension_)")
            if let data = try? Data(contentsOf: file), !data.isEmpty { return (data, source) }
            // Asked before, and the site said it has not got it.
            if FileManager.default.fileExists(atPath: absent(base, source).path) { continue }
            let address = site + source.path(back: back, shiny: shiny) + slug + "." + source.extension_
            guard let url = URL(string: address),
                  let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, !data.isEmpty {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: file)
                return (data, source)
            }
            // A 404 is the site answering; anything else is the network
            // failing, and a sprite must never be written off for that.
            if code == 404 { remember(base, source) }
        }
        return nil
    }

    /// Where it is noted that Showdown has not got this Pokemon in this set.
    ///
    /// On disk rather than in memory because it is a fact about Showdown
    /// rather than about this run, and because the alternative is a round
    /// trip per Pokemon per launch for every gap in the older set -- which is
    /// a hundred and twenty-six of them.
    private nonisolated static func absent(_ base: String, _ source: Source) -> URL {
        folder.appendingPathComponent("\(base).\(source.rawValue).absent")
    }

    private nonisolated static func remember(_ base: String, _ source: Source) {
        let mark = absent(base, source)
        try? FileManager.default.createDirectory(at: mark.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: mark)
    }
}
