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
    ///
    /// `forms` is the Champions roster and only that. Everything that reasons
    /// about the game -- the usage table, the ladder, the matchup grid, the
    /// spread planner, the sprites -- walks this list and is about this game.
    let forms: [Form]
    /// The rest of the National Dex, which this game has not got, for the
    /// sandbox. Never in `forms`, so nothing that analyses Champions has to
    /// know it exists.
    let wider: [Form]
    /// Both of them, because a saved team has to resolve whatever it names.
    /// A team built in the sandbox is still a file somebody opens later.
    let formsByID: [String: Form]
    /// Everything there is, for a picker that has been told to show it all.
    var everyForm: [Form] { forms + wider }
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
        wider = dataset.widerForms
        formsByID = Dictionary((dataset.forms + dataset.widerForms).map { ($0.id, $0) },
                               uniquingKeysWith: { a, _ in a })
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
        self.wider = []
        self.formsByID = Dictionary(forms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.moves = moves
        self.usage = usage
        self.formats = formats
    }

    // MARK: - Looking things up

    func move(_ id: String) -> Move? { moves[id] }

    func form(_ id: String) -> Form? { formsByID[id] }

    /// Whether this regulation has it. The one question a team validator asks
    /// that the sandbox is allowed to ignore.
    func isLegal(_ form: Form) -> Bool { form.isLegal }

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
        if let exact = candidates.first(where: { $0.megaTrigger == item }) { return exact }
        // Only one Mega for this species and the item is some stone: take it.
        // Kept for teams saved before the placeholder named which Mega it was.
        if candidates.count == 1, item == "Mega Stone" { return candidates.first }
        return nil
    }

    /// What a Mega is registered as: the Pokemon that holds the stone.
    ///
    /// A team list has no Mega on it. You bring a Charizard holding a
    /// Charizardite Y and it Mega Evolves in the battle, so the builder
    /// registers the base and the item, and `megaForm` reads the pair back.
    /// Nil for anything that is not a Mega.
    func registeredForm(of mega: Form) -> Form? {
        guard mega.isMega else { return nil }
        // The one that actually becomes it, which is the inverse of
        // `megaForm` and handles the exception it makes: Floette's Mega
        // belongs to the Eternal Flower alone, and a plain Floette holding a
        // Floettite is a Floette holding a stone. The plain species is the
        // fallback, for a Mega whose stone names nothing.
        let stone = mega.megaTrigger
        return forms.first { $0.dex == mega.dex && !$0.isMega
                             && megaForm(for: $0, holding: stone)?.id == mega.id }
            ?? forms.first { $0.dex == mega.dex && !$0.isMega && $0.suffix == "" }
            ?? forms.first { $0.dex == mega.dex && !$0.isMega }
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
