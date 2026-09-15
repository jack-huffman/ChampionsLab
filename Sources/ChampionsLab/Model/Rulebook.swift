//  Rulebook.swift
//  What the engine is allowed to know, frozen.
//
//  The dex does not change while a battle is being played, so everything the
//  turn model, the versus grid and the search need out of it is snapshotted
//  once into a value and handed around. That is what lets all of them run off
//  the main thread: the compiler can see there is no shared mutable state to
//  race on, rather than the author promising there is none.
//
//  `Store` still owns the dataset, the saved teams and the caches an interface
//  needs. It builds one of these and forwards its own lookups to it, so there
//  is one implementation of "what is this move worth" rather than two.

import Foundation

struct Rulebook: Sendable {
    /// Every legal form, and the same by id.
    let forms: [Form]
    let formsByID: [String: Form]
    /// Every move, by id.
    let moves: [String: Move]
    /// Measured usage, for the odds on what a Pokémon is holding.
    let usage: [UsageEntry]
    /// How many each format registers and brings.
    let formats: [FormatRule]

    /// Parsed move quality, kept because pricing one is a parse and the
    /// forecast prices every move of every form. Shared across threads behind
    /// a lock, which is the honest way to share a cache.
    private let qualities = Memo<String, MoveQuality>()

    init(dataset: Dataset) {
        forms = dataset.forms
        formsByID = Dictionary(dataset.forms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        moves = dataset.moves
        usage = dataset.usage
        formats = dataset.rules.formats
    }

    /// Nothing known. Every item reads as Leftovers, which is the fallback
    /// anyway, and no form resolves — for tools that only want the arithmetic.
    static let empty = Rulebook(forms: [], moves: [:], usage: [], formats: [])

    private init(forms: [Form], moves: [String: Move], usage: [UsageEntry],
                 formats: [FormatRule]) {
        self.forms = forms
        self.formsByID = Dictionary(forms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.moves = moves
        self.usage = usage
        self.formats = formats
    }

    // MARK: - Looking things up

    func move(_ id: String) -> Move? { moves[id] }

    func form(_ id: String) -> Form? { formsByID[id] }

    /// Everything this form can learn, in a settled order.
    func moves(for form: Form) -> [Move] {
        form.moves.compactMap { moves[$0] }.sorted { $0.name < $1.name }
    }

    /// How many a format brings to a battle.
    func bringCount(_ format: String) -> Int {
        formats.first { $0.id == format }?.bring ?? 4
    }

    /// The Mega this form becomes while holding that item, if any.
    ///
    /// Floette's Mega belongs to the Eternal Flower form alone: a plain
    /// Floette holds a Floettite the way anyone else would, uselessly.
    func megaForm(for base: Form, holding item: String) -> Form? {
        guard !item.isEmpty, !base.isMega else { return nil }
        if base.species == "floette", base.suffix.isEmpty { return nil }
        let candidates = forms.filter { $0.dex == base.dex && $0.isMega }
        if let exact = candidates.first(where: { $0.megaStone == item }) { return exact }
        // Only one Mega for this species and the item is some stone: take it.
        if candidates.count == 1, item == "Mega Stone" { return candidates.first }
        return nil
    }

    // MARK: - What a move is worth

    func quality(of move: Move, ability: String = "", item: String = "") -> MoveQuality {
        qualities.value("\(move.id)|\(ability)|\(item)") {
            move.quality(ability: ability, item: item)
        }
    }

    /// Six places ranked moves and only three of them applied STAB, which is
    /// how Mega Baxcalibur — a Dragon/Ice Pokémon — had its best move reported
    /// as Double-Edge. Normal at 120 beats Dragon at 106 until you remember the
    /// Dragon one is multiplied by one and a half. The damage calculator always
    /// had this right; the rankings feeding it did not, so it lives in one place
    /// now and every caller uses it.
    func moveValue(_ move: Move, for form: Form,
                   ability: String = "", item: String = "") -> Double {
        let resolved = ability.isEmpty ? (form.abilities.first?.name ?? "") : ability
        // An -ate ability changes a Normal move's type, which changes whether
        // it gets the bonus — this is why Mega Salamence clicks Double-Edge.
        let ate = AteAbility.resolve(type: move.type, ability: resolved)
        let type = ate.type, ateBoost = ate.boost
        var stab = form.types.contains(type) ? 1.5 : 1.0
        if resolved == "Adaptability", stab > 1 { stab = 2.0 }

        // Whether it can actually throw the move. Ranking on power and STAB
        // alone handed Mega Golisopod a Bug Buzz: 90 BP of Bug on a Pokémon
        // with 150 Attack and 70 Sp. Atk, where the physical 100 BP it already
        // had was worth twice as much.
        let physical = move.category == "Physical"
        let using = Double(physical ? form.attack : form.spAttack)
        let best = Double(max(form.attack, form.spAttack))
        let reach = best > 0 ? using / best : 1

        return quality(of: move, ability: resolved, item: item).expectedPower
            * stab * ateBoost * reach
    }
}

/// A cache more than one thread may reach for. The work happens outside the
/// lock, so two threads asking for the same thing at once do it twice rather
/// than one of them waiting — which for a pure function is the cheaper trade.
private final class Memo<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private var entries: [Key: Value] = [:]
    private let lock = NSLock()

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
