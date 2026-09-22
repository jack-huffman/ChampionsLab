//  ProtocolCoverageTests.swift
//  Every tag Showdown can say, either read or named as chrome.
//
//      swift test --filter ProtocolCoverageTests
//
//  Mega Evolution was dropped for a fortnight because it sat in a
//  hand-written list of tags to step over, and a list like that is one nobody
//  reads again. Scripts/mkengine.sh now writes down every tag the simulator's
//  own source can emit, and this holds the reader to it: a tag that is
//  neither handled nor justified fails here rather than going quietly missing
//  from a battle.

import XCTest
@testable import ChampionsLab

final class ProtocolCoverageTests: HarnessCase {
    /// The tags the simulator can emit, from its own source.
    private func emitted() throws -> [String] {
        guard let url = Self.beside("showdown-protocol.txt") else {
            throw XCTSkip("no data/showdown-protocol.txt; run ./Scripts/mkengine.sh")
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The tags the reader actually has a case for, read out of its source
    /// rather than listed again here -- a second list is a second thing to
    /// drift.
    private func handled() throws -> Set<String> {
        guard let url = Self.source("ShowdownBattle.swift") else {
            throw XCTSkip("cannot find ShowdownBattle.swift")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let from = text.range(of: "func read(") else { return [] }
        let body = text[from.upperBound...]
        let stop = body.range(of: "static let chrome")?.lowerBound ?? body.endIndex
        var out: Set<String> = []
        for line in body[..<stop].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case \"") else { continue }
            for piece in trimmed.dropFirst(5).split(separator: ",") {
                let name = piece.trimmingCharacters(in: CharacterSet(charactersIn: " \":"))
                if !name.isEmpty { out.insert(name) }
            }
        }
        return out
    }

    private static func beside(_ name: String) -> URL? {
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    private static func source(_ name: String) -> URL? {
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("Sources/ChampionsLab/Engine/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        return nil
    }

    func testNothingTheSimulatorSaysGoesUnaccountedFor() throws {
        let tags = try emitted()
        let read = try handled()
        let chrome = ShowdownBattle.chrome
        check("the simulator's tags were written down", tags.count > 60, "\(tags.count)")
        check("and the reader has cases", read.count > 25, "\(read.count)")
        let orphans = tags.filter { !read.contains($0) && !chrome.contains($0) }.sorted()
        check("every tag is read or named as chrome", orphans.isEmpty,
              orphans.joined(separator: ", "))
        // And never both: a tag with a case of its own listed as chrome as
        // well is a claim that it says nothing, sitting beside the code that
        // reads what it says.
        let both = read.intersection(chrome).sorted()
        check("nothing is both read and called chrome", both.isEmpty,
              both.joined(separator: ", "))
        print("  \(tags.count) tags: \(tags.filter(read.contains).count) read, "
              + "\(tags.filter(chrome.contains).count) chrome")
    }

    /// Chrome has to be a decision, not a leftover: a tag listed as saying
    /// nothing about the board, which the simulator no longer emits, is a
    /// line that should have gone when the reason for it did.
    func testTheChromeListDoesNotRot() throws {
        let tags = Set(try emitted())
        // The ones the wire carries that the simulator itself never writes --
        // stream framing and the client's own chatter -- are allowed.
        let framing: Set<String> = [
            "", "t:", "request", "sideupdate", "update", "done", "split", "uhtml",
            "uhtmlchange", "raw", "error", "seed", "c", "j", "l", "n", "expire",
            "askreg", "inactive", "inactiveoff", "-hidelinebreak", "teampreview",
            "-notarget", "-message", "-hint",
        ]
        let stale = ShowdownBattle.chrome.filter { !tags.contains($0) && !framing.contains($0) }
        check("nothing is named as chrome that the simulator never says",
              stale.isEmpty, stale.sorted().joined(separator: ", "))
    }
}
