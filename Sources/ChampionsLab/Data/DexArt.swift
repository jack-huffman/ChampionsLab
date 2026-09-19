//  DexArt.swift
//  Pictures for the Pokemon this game has not got.
//
//  The Champions roster's art is bundled: PKHeX's 512px renders, downscaled,
//  ordinary and shiny, 350 of each. The wider roster is nine hundred more, and
//  bundling those would put a quarter of a gigabyte of pictures into an app
//  about a game that does not have them.
//
//  So they are fetched when something actually asks to look at one, and kept,
//  exactly the way the pixel sprites already are. Showdown draws a render for
//  every form it knows, shiny included, at 120px -- smaller than the bundled
//  set and much better than the question mark that was there before.
//
//  Nothing on the Champions roster ever reaches here: `Store.sprite` finds the
//  bundled art first and this is only asked when it does not.

import AppKit

@MainActor
final class DexArt: ObservableObject {
    static let shared = DexArt()
    static let credit = "Renders for Pokémon outside the Champions roster are Pokémon Showdown's, fetched the first time one is shown."

    private var images: [String: NSImage] = [:]
    private var fetching: Set<String> = []
    private var missing: Set<String> = []

    /// The render, or nil while it is on its way or when there is none.
    /// Asking starts the fetch; the object announces itself when it lands.
    func image(for form: Form, shiny: Bool) -> NSImage? {
        guard let slug = PixelSprites.slug(form) else { return nil }
        let key = (shiny ? "dex-shiny/" : "dex/") + slug
        if let ready = images[key] { return ready }
        guard !missing.contains(key), !fetching.contains(key) else { return nil }
        fetching.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            var data = Self.kept(key)
            if data == nil { data = await Self.fetch(key) }
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching.remove(key)
                if let image { self.images[key] = image } else { self.missing.insert(key) }
                self.objectWillChange.send()
            }
        }
        return nil
    }

    private nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChampionsLab/dex")
    }

    private nonisolated static func kept(_ key: String) -> Data? {
        let url = folder.appendingPathComponent(key + ".png")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private nonisolated static func fetch(_ key: String) async -> Data? {
        guard let url = URL(string: "https://play.pokemonshowdown.com/sprites/" + key + ".png"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let destination = folder.appendingPathComponent(key + ".png")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: destination)
        return data
    }
}
