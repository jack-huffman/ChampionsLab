//  WireTests.swift
//  Messages between two copies of the app survive the wire: framed, split,
//  and read back whole.

import XCTest
@testable import ChampionsLab

final class WireTests: HarnessCase {
    func testMessagesRoundTrip() throws {
        let said: [Wire.Message] = [
            .hello(name: "Jack", version: Wire.version, app: "0.4.0"),
            .invite(name: "Jack"),
            .accept(name: "Sam"),
            .format(singles: true),
            .six(Wire.Six(name: "Sun / Dual Mega", forms: ["charizard", "whimsicott"])),
            .six(nil),
            .ready(true),
            .decline,
            .leave,
        ]
        var stream = Data()
        for message in said { stream.append(try Wire.frame(message)) }
        var buffer = stream
        let heard = try Wire.unframe(&buffer)
        check("every message came back", heard == said, "\(heard)")
        check("nothing was left over", buffer.isEmpty)
    }

    func testAPartialFrameWaitsForTheRest() throws {
        let frame = try Wire.frame(.six(Wire.Six(name: "Rain", forms: ["pelipper", "archaludon", "basculegion"])))
        let cut = frame.count / 2
        var buffer = frame.prefix(cut)
        check("half a frame is nothing yet", try Wire.unframe(&buffer).isEmpty)
        check("and stays in the buffer", buffer.count == cut)
        buffer.append(frame.suffix(from: cut))
        let heard = try Wire.unframe(&buffer)
        check("the rest completes it", heard.count == 1)
        check("and it is whole", heard.first == .six(Wire.Six(name: "Rain", forms: ["pelipper", "archaludon", "basculegion"])))
    }

    func testTwoFramesInOneRead() throws {
        var buffer = try Wire.frame(.ready(true)) + Wire.frame(.leave) + Data([0, 0])
        let heard = try Wire.unframe(&buffer)
        check("both messages", heard == [.ready(true), .leave], "\(heard)")
        check("the start of a third waits", buffer.count == 2)
    }

    func testAnAbsurdLengthIsRefused() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3])
        check("a stream that is not ours is refused", (try? Wire.unframe(&buffer)) == nil)
    }
}
