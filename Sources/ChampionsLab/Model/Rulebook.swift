//  Rulebook.swift
//  What the engine is allowed to know, frozen.
//
//  The turn model and the search read nothing that can change under them:
//  the ladder's usage table for guessing items, and that is all. Built once
//  from the dataset and handed to the engine as a value, so the engine can
//  run on any thread — the compiler proves it touches no shared state, rather
//  than the author promising it.

import Foundation

struct Rulebook: Sendable {
    /// Measured usage, for the odds on what a Pokémon is holding.
    let usage: [UsageEntry]

    init(dataset: Dataset) {
        usage = dataset.usage
    }

    /// Nothing known: every item a Leftovers, which is the fallback anyway.
    static let empty = Rulebook(usage: [])

    private init(usage: [UsageEntry]) { self.usage = usage }
}
