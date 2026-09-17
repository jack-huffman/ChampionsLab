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

import AppKit

@MainActor
final class PixelSprites: ObservableObject {
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

    nonisolated static func slug(_ form: Form) -> String? { form.showdown.flatMap(slug(showdownName:)) }

    private var images: [String: NSImage] = [:]
    private var fetching: Set<String> = []
    private var missing: Set<String> = []

    /// The sprite, or nil while it is on its way or when there is none. Asking
    /// starts the fetch; the object announces itself when it lands.
    func image(for form: Form, back: Bool) -> NSImage? {
        guard let slug = Self.slug(form) else { return nil }
        let key = (back ? "back/" : "front/") + slug
        if let image = images[key] { return image }
        guard !missing.contains(key), !fetching.contains(key) else { return nil }
        fetching.insert(key)
        Task { [weak self] in
            var data = Self.kept(key)
            if data == nil { data = await Self.fetch(slug: slug, back: back, key: key) }
            guard let self else { return }
            self.fetching.remove(key)
            if let data, let image = NSImage(data: data) { self.images[key] = image } else { self.missing.insert(key) }
            self.objectWillChange.send()
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
    private nonisolated static func fetch(slug: String, back: Bool, key: String) async -> Data? {
        let base = "https://play.pokemonshowdown.com/sprites/"
        let tries = [(base + (back ? "gen5ani-back/" : "gen5ani/") + slug + ".gif", "gif"),
                     (base + (back ? "gen5-back/" : "gen5/") + slug + ".png", "png")]
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
