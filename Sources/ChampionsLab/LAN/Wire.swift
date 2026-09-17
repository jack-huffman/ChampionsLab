//  Wire.swift
//  What two copies of the app say to each other over the network.
//
//  A battle between two people is two apps and one connection. Everything
//  that crosses it is one of these messages, framed as a four-byte length
//  and JSON, so either side can read the other's whole stream a message at
//  a time. What crosses is only what the other player is allowed to know:
//  a team as Team Preview shows it is a name and six forms, not what they
//  hold or the moves they know.

import Foundation

enum Wire {
    /// Bumped when a message changes shape. Two apps that disagree do not
    /// battle; they say so.
    static let version = 1

    /// A team as the other side may see it at Team Preview.
    struct Six: Codable, Equatable, Sendable {
        let name: String
        /// The six by form id, as registered -- a Charizard, not its Mega.
        let forms: [String]
    }

    enum Message: Codable, Equatable, Sendable {
        /// First thing said on a connection, by whoever opened it.
        case hello(name: String, version: Int)
        /// A request to battle, and the answer to one.
        case invite(name: String)
        case accept(name: String)
        case decline
        /// The room: the host's format, each side's team, each side ready.
        case format(singles: Bool)
        case six(Six?)
        case ready(Bool)
        /// Out of the room, or the battle.
        case leave

        /// The battle. Both ready, the host says start and both go to Team
        /// Preview; the guest sends its team and its four; the host answers
        /// with the opening as the guest may see it, and after every turn
        /// with a snapshot and what it asks of the guest. The guest answers
        /// each request by its number.
        case start
        case preview(team: Team, bringing: [String])
        case snapshot(Snapshot)
        case choice(rqid: Int, play: Play)
        case sendIn(rqid: Int, picks: [Pick])
        case pivot(rqid: Int, bench: Int)
    }

    /// A replacement: who comes in, and where.
    struct Pick: Codable, Equatable, Sendable {
        let slot: Int
        let bench: Int
    }

    /// What the host asks of the guest, if anything.
    enum Asking: Codable, Equatable, Sendable {
        case orders
        case sendIn([Int])
        case pivot(Int)
        case wait
        case over(youWon: Bool)
    }

    /// The board as the guest may see it, the turn that got it there, and
    /// what is asked. `rqid` numbers the request so an answer cannot land
    /// on the wrong turn, as Showdown's does.
    struct Snapshot: Codable, Equatable {
        let rqid: Int
        let turn: Int
        let board: Board.Wired
        let asking: Asking
        static func == (a: Snapshot, b: Snapshot) -> Bool { a.rqid == b.rqid && a.turn == b.turn && a.asking == b.asking }
    }

    enum WireError: LocalizedError {
        case oversized(Int)
        var errorDescription: String? {
            switch self {
            case .oversized(let n): return "A message of \(n) bytes is not one of ours."
            }
        }
    }

    /// The most a frame may carry. Nothing said here is close to this; a
    /// length beyond it is a stream that is not ours.
    static let longest = 4 * 1024 * 1024

    /// A message ready to send: its length, big-endian, then its JSON.
    static func frame(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        return out
    }

    /// Every whole message at the front of the buffer, taken off it; a
    /// partial one at the end waits for the rest.
    static func unframe(_ buffer: inout Data) throws -> [Message] {
        var out: [Message] = []
        let decoder = JSONDecoder()
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard length <= longest else { throw WireError.oversized(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            out.append(try decoder.decode(Message.self, from: body))
        }
        return out
    }
}
