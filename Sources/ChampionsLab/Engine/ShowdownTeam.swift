//  ShowdownTeam.swift
//  A team of this app's, written the way Showdown's champions mod reads one.
//
//  Deliberately not TeamPaste.export. That writes the *mainline* dialect,
//  where a Stat Point is spelled as the EVs it would have cost -- the first
//  worth four and the rest eight apiece, so 32 points is written 252. That is
//  the right thing for a paste going to a mainline tool, and it is how a
//  252/252/4 VGC spread gets read back in.
//
//  Reg M-C is not mainline. The mod's statModify reads the EV field as the
//  points themselves:
//
//      if (statName === 'hp') return stat + evs + 75;
//      stat = stat + evs + 20;
//
//  so a paste written the mainline way gives Incineroar 95 + 252 + 75 = 422
//  HP instead of 202. Measured, not guessed: the engine says 422 for one and
//  202 for the other.

import Foundation

enum ShowdownTeam {
    /// One team as a Showdown paste in the Reg M-C dialect.
    ///
    /// Takes the rulebook and the dataset rather than the Store, so the lab
    /// and the duel -- which run in their own processes, off any actor -- can
    /// write a team out the same way the app does.
    static func paste(for team: Team, rules: Rulebook, data: Dataset) -> String {
        team.slots.compactMap { block(for: $0, rules: rules, data: data) }
            .joined(separator: "\n\n") + "\n"
    }

    /// Only the four that were brought, in the order they were brought, which
    /// is how a battle is actually started.
    static func paste(for team: Team, bringing: [Int], rules: Rulebook, data: Dataset) -> String {
        let chosen = bringing.compactMap { team.slots.indices.contains($0) ? team.slots[$0] : nil }
        return chosen.compactMap { block(for: $0, rules: rules, data: data) }
            .joined(separator: "\n\n") + "\n"
    }

    @MainActor
    static func paste(for team: Team, store: Store) -> String {
        paste(for: team, rules: store.rulebook, data: store.data)
    }

    @MainActor
    static func paste(for team: Team, bringing: [Int], store: Store) -> String {
        paste(for: team, bringing: bringing, rules: store.rulebook, data: store.data)
    }

    private static func block(for slot: TeamSlot, rules: Rulebook, data: Dataset) -> String? {
        guard let form = slot.form(in: rules) else { return nil }
        // The name Showdown files it under, which the dataset now carries for
        // every form in the game. Never the Mega: a team registers the
        // Pokemon holding the stone and the sim evolves it, the same as here.
        let species = form.showdown ?? form.formLabel
        var lines: [String] = []
        var head = slot.nickname.isEmpty ? species : "\(slot.nickname) (\(species))"
        if !slot.item.isEmpty { head += " @ \(slot.item)" }
        lines.append(head)
        if !slot.ability.isEmpty { lines.append("Ability: \(slot.ability)") }
        if slot.shiny { lines.append("Shiny: Yes") }
        lines.append("Level: \(ChampionsStats.level)")
        // The Stat Points as themselves. See the note at the top of the file.
        let spread = Stat.allCases.compactMap { stat -> String? in
            let points = slot.sp[stat.rawValue]
            guard points > 0 else { return nil }
            return "\(points) \(showdownStat(stat))"
        }
        if !spread.isEmpty { lines.append("EVs: " + spread.joined(separator: " / ")) }
        lines.append("\(slot.alignmentName) Nature")
        for id in slot.moves {
            guard let move = data.moves[id] else { continue }
            lines.append("- \(move.name)")
        }
        return lines.joined(separator: "\n")
    }

    private static func showdownStat(_ stat: Stat) -> String {
        switch stat {
        case .hp: return "HP"
        case .attack: return "Atk"
        case .defense: return "Def"
        case .spAttack: return "SpA"
        case .spDefense: return "SpD"
        case .speed: return "Spe"
        }
    }
}
