//  Tools/tree/main.swift
//  One matchup, every decision you could make in it.
//
//      ./Tools/tree.sh --team "Sun / Dual Mega" --vs "Big Six"
//      ./Tools/tree.sh --team "..." --vs "..." --depth 3
//      ./Tools/tree.sh --team "..." --vs "..." --lead "Incineroar,Whimsicott"
//      ./Tools/tree.sh --team "..." --vs "..." --playouts 20
//      ./Tools/tree.sh --list
//
//  The lab answers "how does this team do". This answers "in this exact
//  matchup, which of my decisions win" — which is a question an average cannot
//  be asked, because an average has already thrown the decisions away.
//
//  See MatchupTree.swift for why it branches one side and not both. The short
//  version: exhausting both sides is 840 nodes for one turn, 705,600 for two
//  and 36 hours for three, and that is before the dice.

import AppKit
import Foundation

func argument(_ name: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: name),
          at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}
func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

/// Reorder a team so the named Pokémon lead, and only the four play.
///
/// The board takes the first two slots as the actives and the rest as the
/// bench, so choosing a four and choosing a lead are the same operation: put
/// them in front.
@MainActor
func bring(_ team: Team, lead: [String], rules: Rulebook) -> Team {
    var out = team
    guard !lead.isEmpty else {
        out.slots = Array(team.slots.prefix(4))
        return out
    }
    func name(_ slot: TeamSlot) -> String {
        slot.battleForm(in: rules)?.formLabel ?? slot.form(in: rules)?.formLabel ?? ""
    }
    var ordered: [TeamSlot] = []
    for wanted in lead {
        if let hit = team.slots.first(where: {
            name($0).localizedCaseInsensitiveContains(wanted)
        }), !ordered.contains(where: { $0.id == hit.id }) {
            ordered.append(hit)
        }
    }
    for slot in team.slots where !ordered.contains(where: { $0.id == slot.id }) {
        if ordered.count < 4 { ordered.append(slot) }
    }
    out.slots = Array(ordered.prefix(4))
    return out
}

@MainActor
func run() {
    let store = Store.shared
    if let error = store.loadError { print("dataset: \(error)"); exit(1) }

    if has("--list") {
        print("\nyour teams")
        for team in store.teams where team.slots.count >= 4 { print("  \(team.name)") }
        print("\npublished lists")
        for team in store.data.metaTeams.prefix(40) { print("  \(team.name)") }
        return
    }

    let rules = store.rulebook
    guard let wantMine = argument("--team") else {
        print("need --team; try --list"); exit(2)
    }
    guard let mineTeam = store.teams.first(where: {
        $0.name.localizedCaseInsensitiveContains(wantMine)
    }) else { print("no team matching \(wantMine); try --list"); exit(2) }

    guard let wantTheirs = argument("--vs") else {
        print("need --vs; try --list"); exit(2)
    }
    var theirsTeam: Team?
    if let meta = store.data.metaTeams.first(where: {
        $0.name.localizedCaseInsensitiveContains(wantTheirs)
    }) { theirsTeam = store.opponentTeam(meta) }
    if theirsTeam == nil {
        theirsTeam = store.teams.first { $0.name.localizedCaseInsensitiveContains(wantTheirs) }
    }
    guard let theirsTeam else { print("no opponent matching \(wantTheirs)"); exit(2) }

    let depth = Int(argument("--depth") ?? "") ?? 3
    let playouts = Int(argument("--playouts") ?? "") ?? 0
    let replay = Int(argument("--replay") ?? "") ?? 8
    func names(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    let mine = bring(mineTeam, lead: names(argument("--lead")), rules: rules)
    let theirs = bring(theirsTeam, lead: names(argument("--their-lead")), rules: rules)

    print("\n== \(mine.name) against \(theirs.name) ==")
    print("  depth \(depth)"
          + (playouts > 0 ? ", replaying \(replay) lines each way at \(playouts) games" : ""))
    var lastStage = ""
    let report = MatchupTree.explore(
        mine: mine, theirs: theirs, rules: rules, depth: depth,
        playouts: playouts, replay: replay,
        progress: { step in
            if step.stage != lastStage {
                lastStage = step.stage
                FileHandle.standardError.write(Data("\n  \(step.stage)".utf8))
            }
            FileHandle.standardError.write(Data(".".utf8))
        })
    FileHandle.standardError.write(Data("\n".utf8))

    print("  you lead \(report.myLead.joined(separator: " and ")),"
          + " they lead \(report.theirLead.joined(separator: " and "))")
    print(String(format: "  %d nodes, %d lines, %.1fs",
                 report.nodes, report.leaves, report.seconds))

    func line(_ path: MatchupTree.Path) -> String {
        String(format: "  %5.0f%%  ", path.estimate * 100)
            + path.steps.map(\.mine).joined(separator: "  then  ")
    }

    if !report.openings.isEmpty {
        print("\n-- the opening, played out " + String(repeating: "-", count: 35))
        if let baseline = report.baseline {
            print(String(format: "  playing it straight through: %.0f%% of %d games",
                         baseline * 100, report.baselineGames))
        }
        print("  each of these forces turn one and then plays properly\n")
        for opening in report.openings {
            let against = report.baseline.map {
                String(format: "  %+4.0f", (opening.measured - $0) * 100)
            } ?? "      "
            print(String(format: "  %5.0f%% of %-4d%@   (tree said %3.0f%%)  %@",
                         opening.measured * 100, opening.games, against,
                         opening.estimate * 100, opening.play))
        }
    }

    print("\n-- the lines the tree likes " + String(repeating: "-", count: 34))
    print("  the board three turns in, which is a horizon and not a forecast")
    for path in report.best { print(line(path)) }
    print("\n-- and the ones it does not " + String(repeating: "-", count: 34))
    for path in report.worst { print(line(path)) }

    print("\n-- the turns most worth getting right " + String(repeating: "-", count: 24))
    print("  the gap between the best play here and the worst one")
    for decision in report.pivotal.prefix(6) {
        print(String(format: "\n  turn %d, swing %.0f points", decision.turn, decision.swing * 100)
              + (decision.after.isEmpty ? " (the opening)"
                 : " after " + decision.after.joined(separator: ", ")))
        for option in decision.options.prefix(3) {
            print(String(format: "    %5.0f%%  %@", option.winChance * 100, option.play))
        }
        if let worst = decision.options.last, decision.options.count > 3 {
            print(String(format: "    %5.0f%%  %@   <- worst of %d",
                         worst.winChance * 100, worst.play, decision.options.count))
        }
    }

    // The opening turn, whole. Their answers across the top, yours down the
    // side, and every cell a chance of winning from what that pair produces.
    if has("--matrix") {
        print("\n-- turn one in full " + String(repeating: "-", count: 42))
        let columns = min(report.matrix.theirs.count, 8)
        print("  (their \(columns) most likely answers of \(report.matrix.theirs.count))")
        let order = report.matrix.theirMix.enumerated()
            .sorted { $0.element > $1.element }.prefix(columns).map(\.offset)
        for (index, name) in report.matrix.theirs.enumerated() where order.contains(index) {
            print(String(format: "    %@%@",
                         String(repeating: " ", count: 2),
                         "\(order.firstIndex(of: index)! + 1). \(name)"))
        }
        print("")
        let rows = report.matrix.myMix.enumerated()
            .sorted { $0.element > $1.element }.prefix(12).map(\.offset)
        for row in rows {
            var cells = ""
            for column in order {
                cells += String(format: "%5.0f", report.matrix.winChance[row][column] * 100)
            }
            print("  \(cells)   \(report.matrix.mine[row])")
        }
    } else {
        print("\n  (--matrix for the whole opening turn, all"
              + " \(report.matrix.mine.count) x \(report.matrix.theirs.count) of it)")
    }

    print("")
    if let baseline = report.baseline, !report.openings.isEmpty {
        let best = report.openings.first?.measured ?? 0
        if baseline < 0.05 && best < 0.15 {
            print("  This matchup is lost. The best opening measured"
                  + String(format: " %.0f%% against a baseline of %.0f%%,", best * 100,
                           baseline * 100)
                  + " which is\n  a team-building problem rather than a decision one —"
                  + " no opening here is\n  going to save it.")
        } else {
            print(String(format: "  Baseline %.0f%%, best opening %.0f%%: "
                         + "the opening is worth %.0f points.",
                         baseline * 100, best * 100, (best - baseline) * 100))
        }
        print("")
    }
    print("  The line figures are the board evaluation at the horizon, and are"
          + " reliable for\n  ranking candidates rather than for putting a number"
          + " on a game — on one real\n  matchup the tree rated openings 19-53%"
          + " that played out at 0-12%. Trust the\n  measured openings above;"
          + " treat everything else as a shortlist.")
    print("  Their side answers at equilibrium rather than being enumerated;"
          + " turn one is the exception and is complete.")
}

MainActor.assumeIsolated { run() }
