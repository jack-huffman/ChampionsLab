//  Tools/moves/main.swift
//  Does the engine pick the moves people pick?
//
//      ./Tools/moves.sh                  every replay with a usable turn one
//      ./Tools/moves.sh --games 300      a smaller sample
//      ./Tools/moves.sh --rated 1400     only the stronger players
//      ./Tools/moves.sh --from data/replays-heldout.json
//
//  Nothing in this repository has ever measured a move choice. Team strength
//  is measured, the bring-four ranking is measured, the opponent read is
//  measured, and four changes to the evaluation have been measured against
//  each other. What the engine actually does on a turn — the thing it exists
//  to do — has only ever been judged by whether the games it played came out
//  well, which is a very long way round.
//
//  Turn one is the place to ask, and the only place it can be asked honestly.
//  Both sixes are public at preview, both leads are on the field, nothing has
//  been damaged, no weather or terrain is up, nothing is boosted or statused.
//  The position is *exactly* reconstructible from a replay. Every later turn
//  needs health that the protocol gives only as a percentage of an unknown
//  bar, and statuses and stages that have to be tracked through effects the
//  parser does not model — reconstruct those and you are measuring your own
//  reconstruction.
//
//  What it cannot control for, and this matters when reading the number:
//  spreads and items are never published, so both sides are given the same
//  ordinary build. The engine is therefore choosing on a board that is close
//  to the human's but not identical to it, and some disagreement is that
//  rather than judgement. It is a floor on agreement, not a verdict.
//
//  Agreement is not the same as correctness. A ladder game is not a world
//  final, and where the engine differs from a 1200-rated player it may well be
//  right. The reason to measure it anyway is the *shape* of the disagreement:
//  a systematic bias — never switching, always attacking, ignoring Protect —
//  is a fault whatever the average says, and it is invisible until counted.

import AppKit
import Foundation

struct Replay: Decodable {
    let id: String
    let rating: Int?
    let teams: [String: [String]]
    let brought: [String: [String]]
    let turns: [Turn]

    struct Turn: Decodable {
        let n: Int
        let p1: [Act]
        let p2: [Act]
    }
    struct Act: Decodable {
        let action: String
        let move: String?
        let by: String?
        let to: String?
        let slot: String?
    }
}

struct Corpus: Decodable { let games: [Replay] }

func argument(_ flag: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: flag),
          at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

/// What one side did on turn one, reduced to a decision per slot.
enum Decision: Equatable {
    case move(String)
    case protect
    case switchOut
    case unknown

    var kind: String {
        switch self {
        case .move: return "attack or status"
        case .protect: return "Protect"
        case .switchOut: return "switch"
        case .unknown: return "unknown"
        }
    }
}

@MainActor func run() {
    let store = Store.shared
    if let error = store.loadError { print("dataset error: \(error)"); exit(1) }
    let rules = store.rulebook

    let path = FileManager.default.currentDirectoryPath + "/"
        + (argument("--from") ?? "data/replays.json")
    guard let blob = FileManager.default.contents(atPath: path),
          let corpus = try? JSONDecoder().decode(Corpus.self, from: blob) else {
        print("no \(path) — run `make replays` first")
        exit(1)
    }

    /// A replay names a species; the dex knows forms.
    func form(named raw: String) -> Form? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(raw)
        if let exact = rules.forms.first(where: { key($0.formLabel) == wanted }) { return exact }
        let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let base = key(parts[0]), tag = key(parts[1])
            let candidates = rules.forms.filter { key($0.name) == base || key($0.species) == base }
            if let match = candidates.first(where: { key($0.formLabel).contains(tag) }) { return match }
            if tag == "f", let match = candidates.first(where: { key($0.formLabel).contains("female") }) {
                return match
            }
        }
        return rules.forms.first { key($0.name) == wanted }
    }

    /// Every move each Pokémon was actually seen to use, across the whole game.
    ///
    /// This matters more than it sounds. Built from the first four moves in the
    /// dex instead, the engine is choosing from a different four than the person
    /// had — it cannot pick the move they picked, and it usually cannot pick
    /// Protect at all, which made it look as though the engine never Protected
    /// when it simply never held one. A replay reveals the real moveset as the
    /// game goes; using it is the difference between comparing two players and
    /// comparing two different games.
    func seenMoves(_ game: Replay) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for turn in game.turns {
            for act in turn.p1 + turn.p2 where act.action == "move" {
                guard let who = act.by, let move = act.move else { continue }
                if out[who]?.contains(move) != true { out[who, default: []].append(move) }
            }
        }
        return out
    }

    /// What people actually run on each Pokémon, where the usage table says.
    ///
    /// `abilities.first` is the dex's first entry, which for an Incineroar is
    /// Blaze rather than Intimidate and for a Rillaboom is Overgrow rather than
    /// Grassy Surge. Handing the engine the wrong ability makes it a different
    /// Pokémon with a different matchup, and every disagreement measured after
    /// that is partly a disagreement about which Pokémon is standing there.
    let common: [String: (ability: String, item: String)] = {
        var out: [String: (ability: String, item: String)] = [:]
        for entry in store.data.usage {
            guard let form = form(named: entry.name) else { continue }
            let ability = entry.abilityUsage?.max { $0.percent < $1.percent }?.name
            let item = entry.itemUsage?.max { $0.percent < $1.percent }?.name
            out[form.id] = (ability ?? form.abilities.first?.name ?? "",
                            item ?? form.stone ?? "Leftovers")
        }
        return out
    }()

    /// A team built plainly, the same way for both sides. Spreads are not
    /// published, so neither side gets an advantage from the guessing.
    func team(_ names: [String], seen: [String: [String]]) -> Team? {
        var out = Team()
        out.format = "doubles"
        out.slots = names.compactMap { name -> TeamSlot? in
            guard let form = form(named: name) else { return nil }
            var slot = TeamSlot(formID: form.id)
            let known = common[form.id]
            slot.ability = known?.ability ?? form.abilities.first?.name ?? ""
            // A stone always wins: a Pokémon on a published list holding one is
            // there to Mega Evolve.
            slot.item = form.stone ?? known?.item ?? "Leftovers"
            // What it was seen to use first, filled out from the dex only if
            // the game did not reveal four.
            let revealed = (seen[name] ?? []).compactMap { shown in
                form.moves.first { rules.move($0)?.name == shown }
            }
            var chosen = Array(revealed.prefix(4))
            for move in form.moves where chosen.count < 4 {
                if !chosen.contains(move) { chosen.append(move) }
            }
            slot.moves = chosen
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.hp.rawValue] = 20
            sp[(form.attack >= form.spAttack ? Stat.attack : Stat.spAttack).rawValue] = 23
            sp[Stat.speed.rawValue] = 23
            slot.sp = sp
            slot.alignmentName = form.attack >= form.spAttack ? "Adamant" : "Modest"
            return slot
        }
        return out.slots.count == names.count ? out : nil
    }

    /// What a side did on turn one, per field slot.
    func decisions(_ acts: [Replay.Act]) -> [String: Decision] {
        var out: [String: Decision] = [:]
        for act in acts {
            guard let slot = act.slot?.prefix(3).description else { continue }
            switch act.action {
            case "move":
                guard let name = act.move else { continue }
                // Protect and its family are a decision of their own: the
                // question "did it commit or cover" is more interesting than
                // which shield it used.
                out[slot] = Move.protectMoves.contains(name) ? .protect : .move(name)
            case "switch":
                if out[slot] == nil { out[slot] = .switchOut }
            default: break
            }
        }
        return out
    }

    let limit = Int(argument("--games") ?? "") ?? Int.max
    let floor = Int(argument("--rated") ?? "") ?? 0
    let nodes = Int(argument("--nodes") ?? "") ?? BattleEngine.Nodes.oneAhead
    let engine = BattleEngine(rules: rules, nodes: nodes)

    var asked = 0, unresolved = 0
    var slotsAsked = 0, slotsAgreed = 0, kindAgreed = 0
    var humanKinds: [String: Int] = [:]
    var engineKinds: [String: Int] = [:]
    /// Where they differ: what the engine chose instead of what was played.
    var swaps: [String: Int] = [:]
    /// Agreement split by how strong the players were.
    ///
    /// The question the flat figure cannot answer. Agreeing with everybody
    /// equally says the engine is average; agreeing more as the players get
    /// better says it is playing the same game they are, and agreeing *less*
    /// would say something worse than any single percentage could.
    var byBand: [String: (same: Int, of: Int)] = [:]
    let started = Date()

    for game in corpus.games {
        if asked >= limit { break }
        guard (game.rating ?? 0) >= floor, let first = game.turns.first, first.n == 1 else { continue }
        let band: String = {
            guard let rating = game.rating, rating > 0 else { return "unrated" }
            switch rating {
            case ..<1200: return "under 1200"
            case ..<1350: return "1200-1349"
            case ..<1500: return "1350-1499"
            default:      return "1500 and up"
            }
        }()
        guard let sixOne = game.teams["p1"], sixOne.count == 6,
              let sixTwo = game.teams["p2"], sixTwo.count == 6,
              let broughtOne = game.brought["p1"], broughtOne.count >= 2,
              let broughtTwo = game.brought["p2"], broughtTwo.count >= 2,
              case let shown = seenMoves(game),
              let teamOne = team(sixOne, seen: shown), let teamTwo = team(sixTwo, seen: shown)
        else { unresolved += 1; continue }

        // Both sides, each in turn as the one being asked.
        for (mine, theirs, brought, theirBrought, acts) in
            [(teamOne, teamTwo, broughtOne, broughtTwo, first.p1),
             (teamTwo, teamOne, broughtTwo, broughtOne, first.p2)] {

            let played = decisions(acts)
            guard played.count >= 1 else { unresolved += 1; continue }

            // The four they actually brought, led by the two they actually led.
            let leadNames = Array(brought.prefix(2))
            let theirLeadNames = Array(theirBrought.prefix(2))
            func arrange(_ team: Team, _ order: [String]) -> Team? {
                var out = team
                var slots: [TeamSlot] = []
                for name in order {
                    guard let wanted = form(named: name),
                          let slot = team.slots.first(where: {
                              $0.battleForm(in: rules)?.id == wanted.id
                                  || $0.form(in: rules)?.id == wanted.id
                          }) else { return nil }
                    if !slots.contains(where: { $0.formID == slot.formID }) { slots.append(slot) }
                }
                guard slots.count >= 2 else { return nil }
                slots += team.slots.filter { candidate in
                    !slots.contains { $0.formID == candidate.formID }
                }
                out.slots = slots
                return out
            }
            guard let mineOrdered = arrange(mine, brought),
                  let theirsOrdered = arrange(theirs, theirBrought),
                  leadNames.count == 2, theirLeadNames.count == 2
            else { unresolved += 1; continue }

            var board = Board(mine: mineOrdered, theirs: theirsOrdered, rules: rules,
                              field: Field(isDoubles: true), alreadyEvolved: false)
            board.activeCount = 2
            board.narrating = false
            board.sendOutLeads()

            let thought = engine.think(board)
            // The play it actually favours, not the first one it happened to
            // generate. `plays` is the candidate list and `mix` is the
            // equilibrium over it — reading `plays.first` said the engine
            // attacked on every single turn and never switched, which was this
            // harness misreading the engine rather than the engine being broken.
            guard !thought.plays.isEmpty,
                  let best = thought.mix.indices.max(by: { thought.mix[$0] < thought.mix[$1] }),
                  thought.plays.indices.contains(best)
            else { unresolved += 1; continue }
            let choice = thought.plays[best]
            asked += 1

            // Compare slot by slot. The replay names slots "p1a"/"p1b"; the
            // board knows them as 0 and 1, in the order they were sent out.
            let sideTag = acts.first?.slot?.prefix(2).description ?? "p1"
            for slot in 0..<2 {
                let tag = "\(sideTag)\(slot == 0 ? "a" : "b")"
                guard let human = played[tag], human != .unknown else { continue }
                let mineChoice = slot == 0 ? choice.left : choice.right
                var engineSide: Decision = .unknown
                switch mineChoice {
                case .attack(let index, _):
                    if board.mine.indices.contains(slot),
                       board.mine[slot].moves.indices.contains(index) {
                        let move = board.mine[slot].moves[index]
                        engineSide = Move.protectMoves.contains(move.name)
                            ? .protect : .move(move.name)
                    }
                case .protectSelf: engineSide = .protect
                case .swap: engineSide = .switchOut
                case .pass: engineSide = .unknown
                }
                guard engineSide != .unknown else { continue }

                slotsAsked += 1
                var tally = byBand[band] ?? (same: 0, of: 0)
                tally.of += 1
                if engineSide == human { tally.same += 1 }
                byBand[band] = tally
                humanKinds[human.kind, default: 0] += 1
                engineKinds[engineSide.kind, default: 0] += 1
                if engineSide == human { slotsAgreed += 1 }
                if engineSide.kind == human.kind { kindAgreed += 1 }
                if engineSide != human {
                    if case .move(let theirs) = human, case .move(let ours) = engineSide {
                        swaps["\(theirs) → \(ours)", default: 0] += 1
                    } else {
                        swaps["\(human.kind) → \(engineSide.kind)", default: 0] += 1
                    }
                }
            }
        }
    }

    let seconds = Date().timeIntervalSince(started)
    print("\n== does the engine pick the moves people pick? ==\n")
    guard slotsAsked > 0 else {
        print("  nothing to compare: \(unresolved) games could not be reconstructed")
        return
    }
    print("  \(asked) turn-one positions, \(slotsAsked) decisions, "
          + "\(unresolved) games skipped, \(String(format: "%.0f", seconds))s")
    if floor > 0 { print("  players rated \(floor) and above") }
    print()

    func share(_ part: Int, _ whole: Int) -> String {
        String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }
    print("  same move           \(share(slotsAgreed, slotsAsked)) of \(slotsAsked)")
    print("  same kind of move   \(share(kindAgreed, slotsAsked))"
          + "   (attacking, Protecting or switching)")
    print()

    print("  what each side reaches for")
    print("  " + String(repeating: "-", count: 58))
    let kinds = Set(humanKinds.keys).union(engineKinds.keys).sorted()
    for kind in kinds {
        let them = humanKinds[kind] ?? 0, us = engineKinds[kind] ?? 0
        print(String(format: "    %-20@ people %@   engine %@",
                     kind as NSString, share(them, slotsAsked) as NSString,
                     share(us, slotsAsked) as NSString))
    }
    print()
    print("  Read the gap between those two before the agreement figure. A side")
    print("  that switches on turn one a tenth as often as people do has a")
    print("  systematic bias, and that is a fault whatever the average says.")

    let order = ["under 1200", "1200-1349", "1350-1499", "1500 and up", "unrated"]
    let bands = order.compactMap { name -> (String, Int, Int)? in
        guard let tally = byBand[name], tally.of >= 30 else { return nil }
        return (name, tally.same, tally.of)
    }
    if bands.count >= 2 {
        print("\n  agreement by how strong the players were")
        print("  " + String(repeating: "-", count: 58))
        for (name, same, of) in bands {
            let rate = Double(same) / Double(of)
            let bar = String(repeating: "#", count: Int((rate * 60).rounded()))
            print(String(format: "    %-14@ %@ of %4d  %@",
                         name as NSString, share(same, of) as NSString, of, bar as NSString))
        }
        print("\n  This is the line worth watching. Agreeing with everybody equally")
        print("  says the engine is average. Agreeing more as the players get better")
        print("  says it is playing the same game they are.")
    }

    let frequent = swaps.sorted { $0.value > $1.value }.prefix(12)
    if !frequent.isEmpty {
        print("\n  most common disagreements — what was played, then what the engine wanted")
        print("  " + String(repeating: "-", count: 58))
        for (swap, count) in frequent {
            print(String(format: "    %-46@ %4d", swap as NSString, count))
        }
    }
    print("\n  Agreement is not correctness: these are ladder games, and where the")
    print("  engine differs from a 1200-rated player it may well be right. Spreads")
    print("  and items are not published either, so both sides are built plainly")
    print("  and some disagreement is that rather than judgement.")
}

MainActor.assumeIsolated { run() }
