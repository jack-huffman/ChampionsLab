//  Memo.swift
//  A cache more than one thread may reach for.
//
//  Everything cached in this project is a pure function of its key — a parsed
//  move quality, a compiled pattern, a resolved form — so two threads racing
//  to compute the same entry is a waste of a few microseconds rather than a
//  correctness problem. That shapes the design: the work happens *outside* the
//  lock, so a slow computation never blocks a reader looking for something
//  else. A cache that held its lock across the work would serialise the very
//  paths this project moved off the main thread to parallelise.

import Foundation

final class Memo<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private var entries: [Key: Value] = [:]
    private let lock = NSLock()

    init() {}

    /// The cached value for `key`, computing it if this is the first ask.
    func value(_ key: Key, _ make: () -> Value) -> Value {
        lock.lock()
        let hit = entries[key]
        lock.unlock()
        if let hit { return hit }
        let made = make()
        lock.lock()
        entries[key] = made
        lock.unlock()
        return made
    }
}
