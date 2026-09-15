//  Worth.swift
//  What a Pokémon is worth against the team in front of it.
//
//  The battle engine priced every Pokémon the same: alive was 0.35 and health
//  was the other 0.65, summed and subtracted. A perfectly even trade of your
//  win condition for their least useful body came out as nothing gained and
//  nothing lost, so the engine would take it — and then have nothing left that
//  could actually win the game.
//
//  This gives the engine the one thing it was missing: some of your Pokémon
//  matter more than others, and which ones depends entirely on who you are
//  playing against. A Rillaboom is a different asset into rain than into sun.
//
//  It is built out of the duel grid the app already computes for the versus
//  screen, rather than a second opinion invented for the purpose: each cell
//  already knows how many turns each side needs to knock the other out, and
//  who moves first. Beating a cell is winning the race in it.

import Foundation

enum Worth {
    /// Around one on average, so the numbers the rest of the engine is tuned
    /// against — the 0.12 a Tailwind is worth, the 0.25 that separates a draw
    /// from a win on time — keep meaning what they meant.
    static let neutral = 1.0

    /// How much each of a side's Pokémon is worth against the other side,
    /// keyed by form id.
    ///
    /// Both the registered form and the Mega it becomes are given the same
    /// number, because they are the same Pokémon and the board will show
    /// whichever it is currently fighting as.
    static func of(_ team: Team, against foe: Team,
                   rules: Rulebook, field: Field) -> [String: Double] {
        let grid = Matchup(mine: team, theirs: foe, rules: rules, field: field)
        let theirForms = grid.theirForms
        guard !theirForms.isEmpty, !grid.myForms.isEmpty else { return [:] }

        // -- what each one can handle -----------------------------------------
        //
        // A cell is won when you take fewer turns to knock them out than they
        // take on you, with speed breaking the tie — which is the same test
        // the versus screen shows, so the two cannot drift apart.
        var raw: [(form: Form, score: Double)] = []
        for mine in grid.myForms {
            var beats = 0.0
            for theirs in theirForms {
                guard let cell = grid.cell(mine: mine, theirs: theirs) else { continue }
                if cell.myTurnsToKO < cell.theirTurnsToKO { beats += 1 }
                else if cell.myTurnsToKO == cell.theirTurnsToKO {
                    // A tie goes to whoever moves first, because they get the
                    // last hit in. Worth half either way: a race this close is
                    // decided by a roll as often as by the plan.
                    beats += cell.iAmFaster ? 0.75 : 0.25
                }
            }
            raw.append((mine, beats / Double(theirForms.count)))
        }
        guard !raw.isEmpty else { return [:] }

        // -- the jobs only one Pokémon can do ---------------------------------
        //
        // Beating cells is not the only way to be worth keeping. The Pokémon
        // holding up the Trick Room, or the only one that can take a hit meant
        // for something else, is worth more than its own duels say — and worth
        // more still when it is the only one who can do it.
        var doing: [String: Int] = [:]
        var jobs: [String: Double] = [:]
        for (slot, form) in grid.myPairs {
            var premium = 0.0
            for name in slot.moves.compactMap({ rules.move($0)?.name }) {
                switch name {
                case "Trick Room", "Tailwind":               premium = max(premium, 0.30)
                case "Follow Me", "Rage Powder":             premium = max(premium, 0.25)
                case "Reflect", "Light Screen", "Aurora Veil": premium = max(premium, 0.15)
                case "Fake Out":                             premium = max(premium, 0.10)
                default: break
                }
            }
            if slot.ability == "Intimidate" { premium = max(premium, 0.15) }
            if premium > 0 { doing[form.id] = (doing[form.id] ?? 0) + 1 }
            jobs[form.id] = premium
        }
        // Being the only one who can do a job is what makes it precious. Two
        // Tailwind setters means losing one costs far less.
        let sharing = Dictionary(grouping: jobs.filter { $0.value > 0 }.keys) { key in
            jobs[key] ?? 0
        }.mapValues(\.count)

        // -- put it on a scale the engine already understands ------------------
        //
        // Spread around one rather than starting from zero: a Pokémon that
        // beats none of their six is still a body that can take a hit, and
        // pricing it at nothing would have the engine throw it away for free.
        var out: [String: Double] = [:]
        for (form, score) in raw {
            let job = jobs[form.id] ?? 0
            let alone = (sharing[job] ?? 1) <= 1 ? 1.0 : 0.5
            out[form.id] = 0.72 + 0.56 * score + job * alone
        }
        // Normalise, so the side's total worth is the same whoever is on it and
        // only the *distribution* has changed. Without this a team of six good
        // matchups would look like a bigger team than a team of six bad ones,
        // and the engine would read a losing position as a winning one.
        let mean = out.values.reduce(0, +) / Double(out.count)
        if mean > 0 { for key in out.keys { out[key]! /= mean } }

        // The Mega is the same Pokémon as the thing that becomes it.
        for (slot, form) in grid.myPairs {
            guard let worth = out[form.id] else { continue }
            if let registered = slot.form(in: rules) { out[registered.id] = worth }
            if let mega = slot.megaEvolution(in: rules) { out[mega.id] = worth }
        }
        return out
    }
}
