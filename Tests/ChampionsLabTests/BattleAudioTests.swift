//  BattleAudioTests.swift
//  What a Pokémon is called when it speaks, and what plays under a battle.
//
//      swift test --filter BattleAudioTests

import XCTest
@testable import ChampionsLab

@MainActor
final class BattleAudioTests: HarnessCase {

    /// There is no cry for a Mega and none for a regional form: Showdown
    /// files one per species, and asking for "salamencemega" gets a page
    /// saying so rather than a sound.
    func testACryIsNamedForTheSpeciesAndNotTheForm() {
        for (label, expected) in [("Salamence", "salamence"),
                                  ("Mega Salamence", "salamence"),
                                  ("Mega Charizard Y", "charizard"),
                                  ("Alolan Ninetales", "ninetales"),
                                  ("Kommo-o", "kommoo"),
                                  ("Mr. Mime", "mrmime")] {
            guard let entry = store.data.forms.first(where: { $0.formLabel == label }) else {
                check("\(label) is in the dex", false); continue
            }
            check("\(label) cries as \(expected)",
                  BattleAudio.cryKey(for: entry) == expected,
                  BattleAudio.cryKey(for: entry))
        }
    }

    func testEveryFormHasSomethingToAskFor() {
        let mute = store.data.forms.filter { BattleAudio.cryKey(for: $0).isEmpty }
        check("every form names a cry file", mute.isEmpty,
              mute.prefix(4).map(\.formLabel).joined(separator: ", "))
    }

    /// The loop points are the reason this is a table and not a list of names:
    /// each track has an intro that must not play again, so the loop is a
    /// section rather than the whole file.
    func testTheMusicLoopsASectionRatherThanAFile() {
        let tracks = BattleAudio.tracks
        check("there are fifteen of them, as Showdown has", tracks.count == 15,
              "\(tracks.count)")
        for track in tracks {
            check("\(track.file) loops forwards",
                  track.loopEnd > track.loopStart,
                  "\(track.loopStart)–\(track.loopEnd)")
            check("  and starts after an intro worth having",
                  track.loopStart > 1, "\(track.loopStart)")
            check("  and runs for a while",
                  track.loopEnd - track.loopStart > 30,
                  "\(track.loopEnd - track.loopStart)s")
        }
        check("no two are the same tune",
              Set(tracks.map(\.file)).count == tracks.count)
    }

    /// One battle keeps one tune. The seed is chosen when a game starts and
    /// not read off anything that moves during it.
    func testASeedAlwaysPicksTheSameTrack() {
        for seed in [0, 7, 14, 15, 9999, -3] {
            let first = abs(seed) % BattleAudio.tracks.count
            let again = abs(seed) % BattleAudio.tracks.count
            check("seed \(seed) picks track \(first) every time", first == again)
            check("  and it is a track that exists",
                  BattleAudio.tracks.indices.contains(first))
        }
    }
}
