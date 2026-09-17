//  MegaGuess.swift
//  What a team list, and the ladder, let you know about somebody's Megas.
//
//  Nobody's items are on show at Team Preview. What you actually know about
//  their Charizard is that Charizard has a Mega -- not whether this one is
//  carrying the stone, nor which of two stones it would be. These are the
//  five questions the battle screens ask about that, in one place: what a
//  slot is registered as, who on a team holds a stone, who *could* be, how
//  often a species carries its stone on the ladder, and which Mega it most
//  likely becomes. They were private helpers on two different views, which is
//  how the versus page and Team Preview came to disagree about a badge.

import Foundation

@MainActor
struct MegaGuess {
    let store: Store

    /// What a slot is registered as — a Charizard, not the Mega it becomes.
    /// Plans and grids speak in battle forms; anything shown before the battle
    /// speaks in these, because that is what walks out.
    func registered(_ battle: Form, in team: Team) -> Form {
        team.slots.first { $0.battleForm(in: store.rulebook)?.id == battle.id }?.form(in: store.rulebook) ?? battle
    }

    func stoneHolders(_ team: Team) -> Set<String> {
        Set(team.slots.filter { $0.megaEvolution(in: store.rulebook) != nil }
                      .compactMap { $0.form(in: store.rulebook)?.id })
    }

    /// Theirs that *could* be holding a stone. Nobody's items are on show at
    /// Team Preview, so what you actually know about their Charizard is that
    /// Charizard has a Mega — not whether this one is carrying it. Reading
    /// their list would answer a question the game does not let you ask.
    func possibleMegas(_ team: Team) -> Set<String> {
        Set(team.slots.compactMap { slot -> String? in
            guard let form = slot.form(in: store.rulebook) else { return nil }
            let couldMega = store.data.forms.contains { $0.isMega && $0.species == form.species }
            return couldMega ? form.id : nil
        })
    }

    /// How often that species actually carries its stone on the ladder.
    func stoneOdds(_ form: Form) -> String {
        let engine = BattleEngine(rules: store.rulebook)
        guard let stone = engine.itemOdds(for: form).first(where: { $0.item.hasSuffix("ite") || $0.item.hasSuffix("ite X") || $0.item.hasSuffix("ite Y") || $0.item.hasSuffix("ite Z") })
        else { return "" }
        return String(format: " About %.0f%% of them carry %@.", stone.chance * 100, stone.item)
    }

    /// The Mega a species most likely becomes, by what the ladder carries:
    /// Charizard is a Y far more often than an X.
    func likelyMega(of form: Form) -> Form? {
        let megas = store.data.forms.filter { $0.isMega && $0.species == form.species }
        guard !megas.isEmpty else { return nil }
        let odds = BattleEngine(rules: store.rulebook).itemOdds(for: form)
        if let stone = odds.first(where: { entry in megas.contains { $0.megaStone == entry.item } }),
           let match = megas.first(where: { $0.megaStone == stone.item }) {
            return match
        }
        return megas.first
    }
}
