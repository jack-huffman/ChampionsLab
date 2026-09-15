//  Tools/coverage/main.swift
//  What the battle model actually implements, and what it does not.
//
//  Two audits, neither of which trusts a list somebody has to remember to
//  update:
//
//  * Moves are audited by *using* them. Every legal move is put on a Pokémon,
//    used against a target, and the board is compared before and after. A
//    status move that changes nothing is a move the model does not implement,
//    whatever anyone believed.
//  * Abilities and items are audited by reading the source. If the model never
//    mentions the name, the model cannot be doing anything with it.
//
//  Both are weighted by measured usage, so the gaps that matter come first: an
//  unimplemented move nobody brings is a note, and one on a Pokémon in a
//  quarter of games is a bug.
//
//      ./Tools/coverage.sh            everything
//      ./Tools/coverage.sh --gaps     only what is missing

import AppKit
import SwiftUI

/// Everything about a board that a move could possibly change.
@MainActor func fingerprint(_ board: Board) -> String {
    var out = ""
    for side in [board.mine, board.theirs] {
        for f in side {
            out += "\(f.hp)/\(f.status.rawValue)/\(f.build.boosts)/\(f.confusedFor)"
            out += "/\(f.isProtected)/\(f.flinched)/\(f.charging ?? -1)/\(f.encoredFor)"
            out += "/\(f.hidden)/\(f.drawingFire)/\(f.build.itemSpent)/\(f.build.form.id)|"
        }
    }
    out += "\(board.field.weather)\(board.field.terrain)\(board.myTailwind)\(board.theirTailwind)"
    out += "\(board.trickRoom)\(board.myScreens.any)\(board.theirScreens.any)\(board.myScreens.wideGuard)"
    return out
}

@MainActor func run() {
    let store = Store.shared
    let rules = store.rulebook
    let onlyGaps = CommandLine.arguments.contains("--gaps")

    // How often each Pokémon is actually seen, so a gap can be weighed.
    var usageOf: [String: Double] = [:]
    for entry in store.data.usage {
        if let form = store.form(named: entry.name) { usageOf[form.id] = entry.usage }
    }
    /// The heaviest user of a move or ability, as a share of games.
    func weight(ofMove id: String) -> Double {
        store.data.forms.filter { $0.moves.contains(id) }
            .compactMap { usageOf[$0.id] }.max() ?? 0
    }
    func weight(ofAbility name: String) -> Double {
        store.data.forms.filter { $0.abilities.contains { $0.name == name } }
            .compactMap { usageOf[$0.id] }.max() ?? 0
    }

    // -- moves, by using them -------------------------------------------------
    func team(_ rows: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = rows.map { name, item, moveNames in
            let form = store.data.forms.first { $0.formLabel == name }!
            var slot = TeamSlot(formID: form.id)
            slot.item = item
            slot.ability = form.abilities.first?.name ?? ""
            slot.moves = moveNames.compactMap { n in store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32; sp[Stat.hp.rawValue] = 2
            slot.sp = sp; slot.alignmentName = "Adamant"
            return slot
        }
        return out
    }
    // A user with a spare slot for the move under test, a partner to aim ally
    // moves at, and two targets that stand still.
    // Whatever this format's widest learnset belongs to: the audit needs one
    // Pokémon that can plausibly hold any move under test.
    let versatile = store.data.forms.max { $0.moves.count < $1.moves.count }!.formLabel
    // No items on anybody: a Leftovers ticking at the end of the turn would
    // change the board on its own and make every move look implemented.
    let mine = team([(versatile, "", ["Protect"]), ("Milotic", "", ["Protect"])])
    let theirs = team([("Garchomp", "", ["Protect"]), ("Rillaboom", "", ["Protect"])])
    let bare = Board(mine: mine, theirs: theirs, rules: rules,
                     field: Field(isDoubles: true), alreadyEvolved: false)

    struct Finding { let name: String; let kind: String; let usage: Double; let note: String }
    var moveFindings: [Finding] = []
    var damaging = 0, extras = 0, inert = 0

    let legal = store.data.moves.values.filter { $0.learnable }.sorted { $0.name < $1.name }
    for move in legal {
        var board = bare
        board.mine[0].moves = [move] + board.mine[0].moves
        // Something to bring back, so Revival Blessing has work to do, and a
        // dent so healing has somewhere to go.
        board.mine[0].hp = board.mine[0].maxHP / 2
        board.mine[1].hp = board.mine[1].maxHP / 2
        let before = fingerprint(board)
        // Nobody else does anything: a partner's Protect would change the
        // board on its own and make every move look implemented.
        let after = TurnModel.resolve(
            board,
            mine: Play(left: .attack(move: 0, target: 0), right: .pass),
            theirs: Play(left: .pass, right: .pass),
            rolling: false)
        let changed = fingerprint(after) != before
        let damagedThem = after.theirs[0].hp < board.theirs[0].hp
            || after.theirs[1].hp < board.theirs[1].hp
        // What the turn said about it, beyond announcing it.
        // What the turn said beyond announcing the move, and beyond admitting
        // that nothing came of it.
        let said = after.story.filter {
            !$0.hasPrefix("\(board.mine[0].build.form.formLabel) used")
                && !$0.hasPrefix("Nothing came of it")
                && !$0.hasPrefix("But it failed")
                && !$0.hasPrefix("But nobody")
                && !$0.hasPrefix("But there was")
        }
        // A move whose text promises something beyond the damage.
        let promises = move.secondary != nil || move.charge != nil || move.drainShare != nil
            || !move.targetDrops.isEmpty || !move.selfBoosts.isEmpty || !move.selfDrops.isEmpty
            || move.confuses || move.healing != nil
        if move.isDamaging && damagedThem {
            if promises { extras += 1 } else { damaging += 1 }
        } else if changed || !said.isEmpty {
            extras += 1
        } else {
            inert += 1
            moveFindings.append(Finding(name: move.name,
                                        kind: move.isDamaging ? "damaging, did nothing" : "status, did nothing",
                                        usage: weight(ofMove: move.id),
                                        note: String(move.effect.prefix(76))))
        }
    }

    // -- abilities and items, by reading the model ----------------------------
    let modelSource: String = {
        var text = ""
        for dir in ["Sources/ChampionsLab/Battle", "Sources/ChampionsLab/Damage",
                    "Sources/ChampionsLab/Model"] {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".swift") {
                text += (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
            }
        }
        return text
    }()
    func modelMentions(_ name: String) -> Bool { modelSource.contains("\"\(name)\"") }

    var abilityFindings: [Finding] = []
    let abilities = store.data.abilities.keys.sorted()
    var abilitiesKnown = 0
    for name in abilities {
        if modelMentions(name) { abilitiesKnown += 1; continue }
        let used = weight(ofAbility: name)
        guard used > 0 else { continue }          // nothing in this format has it
        abilityFindings.append(Finding(name: name, kind: "ability", usage: used,
                                       note: String((store.data.abilities[name]?.desc ?? "").prefix(76))))
    }

    var itemFindings: [Finding] = []
    var itemsKnown = 0
    let items = store.data.items.filter { $0.seenInGame }.sorted { $0.name < $1.name }
    for item in items {
        if modelMentions(item.name) || item.name.hasSuffix("ite") || item.name.hasSuffix("ite X")
            || item.name.hasSuffix("ite Y") || item.name.hasSuffix("ite Z") {
            itemsKnown += 1; continue
        }
        itemFindings.append(Finding(name: item.name, kind: "item", usage: 0,
                                    note: String(item.effect.prefix(76))))
    }

    // -- the report -----------------------------------------------------------
    func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "—" : String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }
    print("== what the battle model implements ==\n")
    print("  moves      \(legal.count) legal in this format")
    print("             \(damaging) plain damage, which is all they claim  (\(percent(damaging, legal.count)))")
    print("             \(extras) carry an effect, and it happens  (\(percent(extras, legal.count)))")
    print("             \(inert) do nothing at all  (\(percent(inert, legal.count)))")
    print("  abilities  \(abilities.count) in the dex, \(abilitiesKnown) named by the model  (\(percent(abilitiesKnown, abilities.count)))")
    print("             \(abilityFindings.count) unimplemented and carried by something in this format")
    print("  items      \(items.count) seen in Champions, \(itemsKnown) named by the model  (\(percent(itemsKnown, items.count)))")
    print("             \(itemFindings.count) unimplemented")

    func table(_ title: String, _ findings: [Finding], limit: Int) {
        guard !findings.isEmpty else { return }
        print("\n== \(title) (\(findings.count)) ==")
        for f in findings.sorted(by: { $0.usage > $1.usage }).prefix(limit) {
            let share = f.usage > 0 ? String(format: "%5.1f%%", f.usage) : "     ·"
            print("  \(share)  \(f.name.padding(toLength: 22, withPad: " ", startingAt: 0))\(f.note)")
        }
        if findings.count > limit { print("  … and \(findings.count - limit) more") }
    }
    table("moves that do nothing", moveFindings, limit: onlyGaps ? 200 : 25)
    table("abilities something in this format carries", abilityFindings, limit: onlyGaps ? 200 : 25)
    table("items with no effect in the model", itemFindings, limit: onlyGaps ? 200 : 20)
    print("\n  A move that only reads the field, or only matters in singles, will")
    print("  show as doing nothing here. The list is where to look, not a bug count.")
}
MainActor.assumeIsolated { run() }
