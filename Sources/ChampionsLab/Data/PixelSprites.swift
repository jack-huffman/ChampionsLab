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
//  A Champions-only Mega has no animated sprite there; Showdown has drawn a
//  still for each, and the still is what comes back for those.
//
//  Shiny is the same set under another name -- gen5ani-shiny and its three
//  siblings -- and is fetched and kept the same way, under its own key so the
//  two never overwrite each other in the cache.

import AppKit
import ImageIO

@MainActor
final class PixelSprites: ObservableObject {
    /// A sprite's frames and how long each shows. CGImages are immutable and
    /// safe to read from anywhere, which is what the unchecked promise says.
    struct Frames: @unchecked Sendable {
        let images: [CGImage]
        let delays: [TimeInterval]
        let total: TimeInterval

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
        nonisolated static func decode(_ data: Data) -> Frames? {
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
            return Frames(images: images, delays: delays, total: delays.reduce(0, +))
        }
    }

    static let shared = PixelSprites()
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
    func frames(for form: Form, back: Bool, shiny: Bool = false) -> Frames? {
        guard let slug = Self.slug(form) else { return nil }
        let key = (back ? "back/" : "front/") + (shiny ? "shiny/" : "") + slug
        if let ready = frames[key] { return ready }
        guard !missing.contains(key), !fetching.contains(key) else { return nil }
        fetching.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            var data = Self.kept(key)
            if data == nil { data = await Self.fetch(slug: slug, back: back, shiny: shiny, key: key) }
            let decoded = data.flatMap(Frames.decode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching.remove(key)
                if let decoded { self.frames[key] = decoded } else { self.missing.insert(key) }
                self.objectWillChange.send()
            }
        }
        return nil
    }

    private nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChampionsLab/sprites")
    }

    /// Already on disk from an earlier fetch. Read off the main thread, like
    /// the fetch; only the decode into an image happens on it.
    private nonisolated static func kept(_ key: String) -> Data? {
        for ext in ["gif", "png"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(key + "." + ext)), !data.isEmpty { return data }
        }
        return nil
    }

    /// The animated sprite where there is one, the still where there is not,
    /// written to the cache on the way back. Bytes rather than an image, so it
    /// can cross back to the main actor.
    private nonisolated static func fetch(slug: String, back: Bool, shiny: Bool,
                                          key: String) async -> Data? {
        let base = "https://play.pokemonshowdown.com/sprites/"
        // Showdown files the shinies as the same four directories with
        // "-shiny" on the end, and carries one for everything it carries a
        // plain one for -- so a form that has an animation has a shiny
        // animation, and one that only has a still has a shiny still.
        let tail = shiny ? "-shiny/" : "/"
        let tries = [(base + (back ? "gen5ani-back" : "gen5ani") + tail + slug + ".gif", "gif"),
                     (base + (back ? "gen5-back" : "gen5") + tail + slug + ".png", "png")]
        for (address, ext) in tries {
            guard let url = URL(string: address),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let destination = folder.appendingPathComponent(key + "." + ext)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: destination)
            return data
        }
        return nil
    }
}
