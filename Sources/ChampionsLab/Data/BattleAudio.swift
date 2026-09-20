//  BattleAudio.swift
//  The sound a battle makes: what each Pokemon says, and what plays under it.
//
//  Both halves are Showdown's and both are fetched the first time they are
//  wanted, kept under Application Support beside the sprites. Nothing ships in
//  the app: the fifteen music tracks are two megabytes each and the cries are
//  one per species, which is a great deal of audio to put in a disk image for
//  something a player may turn off in the first minute.
//
//  Showdown plays a cry in exactly two places -- coming out of a ball, and
//  fainting -- and not on a recall, which is worth copying rather than
//  improving on: a sound every time something leaves as well as arrives is
//  twice the noise for no more information.
//
//  The music is the part with a trick in it. Each track has an intro and then
//  a section that loops, and Showdown carries the two timestamps per track
//  because the loop is not the whole file -- starting it over from zero would
//  replay the intro every ninety seconds. AVAudioPlayer cannot loop a section,
//  so a timer watches the playhead and sends it back.

import AVFoundation
import Foundation

@MainActor
final class BattleAudio: ObservableObject {
    static let shared = BattleAudio()
    static let credit = "Cries and battle music are Pokémon Showdown's, fetched the first time they are heard."

    // MARK: - What the listener has asked for

    private static let mutedKey = "battleMuted"
    private static let volumeKey = "battleVolume"
    private static let musicKey = "battleMusic"

    /// Silence, whatever else is set. Off by default: a battle screen that
    /// says nothing is what this was, and a program that starts making noise
    /// without being asked is a program people close.
    @Published var muted: Bool = UserDefaults.standard.object(forKey: mutedKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(muted, forKey: Self.mutedKey); apply() }
    }
    /// Nought to one, over everything.
    @Published var volume: Double = UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(volume, forKey: Self.volumeKey); apply() }
    }
    /// The music, separately from the cries: plenty of people want to hear
    /// what came out of the ball and nothing else.
    @Published var music: Bool = UserDefaults.standard.object(forKey: musicKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(music, forKey: Self.musicKey)
            if music { restartMusic() } else { stopMusic() }
        }
    }

    private var level: Float { muted ? 0 : Float(max(0, min(1, volume))) }

    private func apply() {
        player?.volume = level * 0.55
        for one in cries.values { one.volume = level }
    }

    // MARK: - Cries

    private var cries: [String: AVAudioPlayer] = [:]
    private var fetching: Set<String> = []
    private var missing: Set<String> = []

    /// What Showdown calls the file: the species, squashed. Never the form --
    /// there is no cry for a Mega, and "kommo-o" is not a filename.
    nonisolated static func cryKey(for form: Form) -> String {
        String(form.species.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }

    /// Play it if we have it, fetch it if we do not. The first time a species
    /// is seen it is silent, and every time after that it is not.
    func cry(_ form: Form) {
        guard !muted else { return }
        let key = Self.cryKey(for: form)
        guard !key.isEmpty, !missing.contains(key) else { return }
        if let player = cries[key] {
            player.volume = level
            player.currentTime = 0
            player.play()
            return
        }
        guard !fetching.contains(key) else { return }
        fetching.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            var data = Self.kept("cries/\(key).mp3")
            if data == nil {
                data = await Self.fetch("audio/cries/\(key).mp3", to: "cries/\(key).mp3")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching.remove(key)
                guard let data, let player = try? AVAudioPlayer(data: data) else {
                    self.missing.insert(key); return
                }
                player.volume = self.level
                player.prepareToPlay()
                self.cries[key] = player
                // Deliberately not played. By the time a first fetch lands the
                // moment it belonged to has gone, and a cry arriving a second
                // late over the wrong Pokemon is worse than silence.
            }
        }
    }

    // MARK: - The music

    /// A track, and where its loop begins and ends in seconds. Showdown's
    /// numbers, in its order, so a battle here sounds like a battle there.
    struct Track {
        let file: String
        let loopStart: TimeInterval
        let loopEnd: TimeInterval
    }
    static let tracks: [Track] = [
        Track(file: "dpp-trainer", loopStart: 13.440, loopEnd: 96.959),
        Track(file: "dpp-rival", loopStart: 13.888, loopEnd: 66.352),
        Track(file: "hgss-johto-trainer", loopStart: 23.731, loopEnd: 125.086),
        Track(file: "hgss-kanto-trainer", loopStart: 13.003, loopEnd: 94.656),
        Track(file: "bw-trainer", loopStart: 14.629, loopEnd: 110.109),
        Track(file: "bw-rival", loopStart: 19.180, loopEnd: 57.373),
        Track(file: "bw-subway-trainer", loopStart: 15.503, loopEnd: 110.984),
        Track(file: "bw2-kanto-gym-leader", loopStart: 14.626, loopEnd: 58.986),
        Track(file: "bw2-rival", loopStart: 7.152, loopEnd: 68.708),
        Track(file: "xy-trainer", loopStart: 7.802, loopEnd: 82.469),
        Track(file: "xy-rival", loopStart: 7.802, loopEnd: 58.634),
        Track(file: "oras-trainer", loopStart: 13.579, loopEnd: 91.548),
        Track(file: "oras-rival", loopStart: 14.303, loopEnd: 69.149),
        Track(file: "sm-trainer", loopStart: 8.323, loopEnd: 89.230),
        Track(file: "sm-rival", loopStart: 11.389, loopEnd: 62.158),
    ]

    private var player: AVAudioPlayer?
    private var looping: Task<Void, Never>?
    private var playing: Track?
    private var wanted: Int?

    /// Start the music for a game. The seed picks the track, so one battle
    /// keeps one tune from beginning to end rather than shuffling every time
    /// the view is rebuilt -- Showdown picks its by the battle's id for the
    /// same reason.
    func startMusic(seed: Int) {
        let index = abs(seed) % Self.tracks.count
        guard music, !muted else { wanted = index; return }
        guard wanted != index || player == nil else { return }
        wanted = index
        let track = Self.tracks[index]
        Task.detached(priority: .utility) { [weak self] in
            var data = Self.kept("music/\(track.file).mp3")
            if data == nil {
                data = await Self.fetch("audio/\(track.file).mp3", to: "music/\(track.file).mp3")
            }
            await MainActor.run { [weak self] in
                guard let self, self.music, !self.muted, self.wanted == index,
                      let data, let player = try? AVAudioPlayer(data: data) else { return }
                self.stopMusic(keepingChoice: true)
                player.volume = self.level * 0.55
                player.prepareToPlay()
                player.play()
                self.player = player
                self.playing = track
                self.watchTheLoop()
            }
        }
    }

    func stopMusic(keepingChoice: Bool = false) {
        looping?.cancel(); looping = nil
        player?.stop(); player = nil
        playing = nil
        if !keepingChoice { wanted = nil }
    }

    private func restartMusic() {
        guard let wanted else { return }
        self.wanted = nil
        startMusic(seed: wanted)
    }

    /// AVAudioPlayer loops whole files and these loop a section, so the
    /// playhead is watched and sent back to the top of the loop when it runs
    /// past the end of it.
    private func watchTheLoop() {
        looping?.cancel()
        looping = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let player = self.player, let track = self.playing else { return }
                if player.currentTime >= track.loopEnd || !player.isPlaying {
                    player.currentTime = track.loopStart
                    if !player.isPlaying { player.play() }
                }
            }
        }
    }

    // MARK: - Fetching and keeping

    private nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChampionsLab/audio")
    }

    private nonisolated static func kept(_ path: String) -> Data? {
        let url = folder.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private nonisolated static func fetch(_ remote: String, to path: String) async -> Data? {
        guard let url = URL(string: "https://play.pokemonshowdown.com/" + remote),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let destination = folder.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: destination)
        return data
    }
}
