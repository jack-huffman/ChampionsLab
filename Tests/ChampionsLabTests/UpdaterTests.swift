//  UpdaterTests.swift
//  Versions compare part by part, and a GitHub release reads into what the
//  updater needs.

import XCTest
@testable import ChampionsLab

final class UpdaterTests: HarnessCase {
    func testVersionsComparePartByPart() {
        check("0.4.0 is newer than 0.3.0", Updater.isNewer("0.4.0", than: "0.3.0"))
        check("0.3.10 is newer than 0.3.9", Updater.isNewer("0.3.10", than: "0.3.9"))
        check("1.0 is newer than 0.9.9", Updater.isNewer("1.0", than: "0.9.9"))
        check("the same is not newer", !Updater.isNewer("0.3.0", than: "0.3.0"))
        check("nor is older", !Updater.isNewer("0.2.9", than: "0.3.0"))
        check("a missing part is zero", !Updater.isNewer("0.3", than: "0.3.0") && !Updater.isNewer("0.3.0", than: "0.3"))
    }

    func testAReleaseReadsOutOfGitHubsJSON() throws {
        let json = """
        {"tag_name": "v0.4.0", "body": "- LAN battles\\n- Smogon", "published_at": "2026-09-18T01:00:00Z",
         "assets": [{"name": "ChampionsLab-0.4.0.dmg",
                     "browser_download_url": "https://github.com/jack-huffman/ChampionsLab/releases/download/v0.4.0/ChampionsLab-0.4.0.dmg",
                     "url": "https://api.github.com/repos/jack-huffman/ChampionsLab/releases/assets/1"},
                    {"name": "notes.txt", "browser_download_url": "https://example.com/n", "url": "https://api.github.com/x"}]}
        """
        let release = try Updater.parse(Data(json.utf8))
        check("the version, without its v", release?.version == "0.4.0" && release?.tag == "v0.4.0")
        check("the image, not the other asset", release?.downloadURL.lastPathComponent == "ChampionsLab-0.4.0.dmg")
        check("its API address", release?.apiURL.path.hasSuffix("/assets/1") == true)
        check("the notes", release?.notes.contains("LAN battles") == true)
        check("when", release?.published != nil)
        let bare = try Updater.parse(Data("{\"tag_name\": \"v0.4.1\", \"assets\": []}".utf8))
        check("no image, no release", bare == nil)
    }
}
