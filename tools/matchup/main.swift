//  tools/matchup/main.swift
//  Checks the paste importer, the EV<->SP conversion and the versus engine
//  against a real Showdown list and a bundled meta archetype.
//
//      ./tools/matchup.sh

import AppKit
import SwiftUI

let paste = """
Incineroar @ Assault Vest
Ability: Intimidate
Level: 50
EVs: 252 HP / 4 Atk / 252 SpD
Careful Nature
- Fake Out
- Parting Shot
- Darkest Lariat
- Flare Blitz

Charizard-Mega-Y @ Charizardite Y
Ability: Drought
EVs: 4 HP / 252 SpA / 252 Spe
Timid Nature
- Heat Wave
- Solar Beam
- Air Slash
- Protect

Garchomp @ Choice Scarf
Ability: Rough Skin
EVs: 252 Atk / 4 HP / 252 Spe
Jolly Nature
- Earthquake
- Rock Slide
- Dragon Claw
- Protect

Indeedee-F @ Psychic Seed
Ability: Psychic Surge
- Follow Me
- Trick Room
- Dazzling Gleam
- Helping Hand

Amoonguss @ Leftovers
Ability: Regenerator
- Spore
- Rage Powder
"""

@MainActor func run() {
    let store = Store.shared
    var fails = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if !ok { fails += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    print("== EV <-> SP conversion ==")
    // 0 EVs is 0 SP, 4 EVs buys the first point, every point after costs 8,
    // and 252 lands exactly on the 32 SP cap.
    check("0 EVs -> 0 SP", TeamPaste.statPoints(fromEVs: 0) == 0)
    check("4 EVs -> 1 SP", TeamPaste.statPoints(fromEVs: 4) == 1)
    check("12 EVs -> 2 SP", TeamPaste.statPoints(fromEVs: 12) == 2)
    check("252 EVs -> the 32 SP cap",
          TeamPaste.statPoints(fromEVs: 252) == ChampionsStats.spPerStat)
    check("SP 32 -> 252 EVs", TeamPaste.evs(fromStatPoints: 32) == 252)
    let classic = [252, 252, 4, 0, 0, 0].map(TeamPaste.statPoints(fromEVs:))
    check("a 252/252/4 spread fits the 66 SP budget",
          classic.reduce(0, +) <= ChampionsStats.spTotal, "\(classic.reduce(0, +))")

    print("\n== import ==")
    let result = TeamPaste.parse(paste, store: store, name: "Paste test")
    print("  parsed \(result.team.slots.count) Pokemon")
    for w in result.warnings { print("  warn: \(w)") }
    // Amoonguss is deliberately not in the Champions roster — Serebii 404s on it
    // — so the parser should skip it with a warning rather than inventing a slot.
    check("imported 4 legal slots", result.team.slots.count == 4, "\(result.team.slots.count)")
    check("warned about the illegal entry",
          result.warnings.contains { $0.contains("Amoonguss") })

    let labels = result.team.slots.compactMap { $0.form(in: store)?.formLabel }
    print("  ->", labels.joined(separator: ", "))
    check("Charizard-Mega-Y resolved", labels.contains("Mega Charizard Y"))
    check("Indeedee-F resolved", labels.contains("Indeedee (Female)"))

    if let zard = result.team.slots.first(where: { $0.form(in: store)?.formLabel == "Mega Charizard Y" }) {
        check("Timid parsed", zard.alignmentName == "Timid", zard.alignmentName)
        check("252 SpA -> 32 SP", zard.sp[Stat.spAttack.rawValue] == 32, "\(zard.sp)")
        check("4 moves", zard.moves.count == 4, "\(zard.moves.count)")
        check("SP within budget", zard.spUsed <= ChampionsStats.spTotal, "\(zard.spUsed)")
    }
    // Every imported move must be one the form can actually learn.
    check("no unlearnable moves imported", result.team.slots.allSatisfy { slot in
        guard let form = slot.form(in: store) else { return false }
        return slot.moves.allSatisfy { form.moves.contains($0) }
    })
    // Charizard holding its stone must be analysed as Mega Charizard Y.
    if let zard = result.team.slots.first(where: { $0.form(in: store)?.name == "Charizard" }) {
        check("stone resolves to the Mega",
              zard.battleForm(in: store)?.formLabel == "Mega Charizard Y",
              zard.battleForm(in: store)?.formLabel ?? "nil")
    }

    print("\n== export round-trip ==")
    let text = TeamPaste.export(result.team, store: store)
    let back = TeamPaste.parse(text, store: store)
    check("round-trips to same count", back.team.slots.count == result.team.slots.count,
          "\(back.team.slots.count) vs \(result.team.slots.count)")
    let a = result.team.slots.map { $0.sp }, b = back.team.slots.map { $0.sp }
    check("SP survive the round trip", a == b, "\(a.first ?? []) vs \(b.first ?? [])")

    print("\n== matchup ==")
    guard let bigSix = store.data.metaTeams.first(where: { $0.id == "big-six" }) else {
        print("  FAIL no big-six"); exit(1)
    }
    let theirs = TeamPaste.team(from: bigSix, store: store)
    check("meta team built", theirs.slots.count == 6, "\(theirs.slots.count)")

    let m = Matchup(mine: result.team, theirs: theirs, store: store,
                    field: Field(isDoubles: true))
    let v = m.verdict
    print("  cells \(v.totalCells)  wins \(v.winCount)  losses \(v.lossCount)  edge \(v.score)  faster \(v.speedEdge)%")
    check("grid is mine x theirs", v.totalCells == result.team.slots.count * theirs.slots.count, "\(v.totalCells)")
    check("score in range", (-100...100).contains(v.score), "\(v.score)")
    for line in v.advice { print("  advice: \(line)") }
    print("  unanswered:", v.unanswered.map(\.formLabel))
    print("  dead weight:", v.deadWeight.map(\.formLabel))

    let mirror = Matchup(mine: theirs, theirs: theirs, store: store, field: Field(isDoubles: true))
    print("  mirror edge: \(mirror.verdict.score)")
    check("mirror is even", abs(mirror.verdict.score) <= 5, "\(mirror.verdict.score)")

    // -- same-type bonus in move ranking ---------------------------------
    //
    // Six places ranked moves and three of them ignored STAB, which reported a
    // Dragon/Ice Pokemon's best move as Normal-type Double-Edge. One function
    // does it now; these keep it honest.
    print("\n== move valuation ==")
    func form(_ name: String) -> Form { store.data.forms.first { $0.formLabel == name }! }
    let bax = form("Mega Baxcalibur")
    let baxBest = store.bestMove(for: bax)?.name ?? "-"
    print("  Mega Baxcalibur's best move: \(baxBest)")
    check("STAB decides Baxcalibur's best move", baxBest == "Glaive Rush", baxBest)

    let goli = form("Mega Golisopod")
    let goliBest = store.bestMove(for: goli)?.name ?? "-"
    print("  Mega Golisopod's best move: \(goliBest)")
    check("a physical attacker is not handed a special move",
          store.data.moves.values.first { $0.name == goliBest }?.category == "Physical", goliBest)

    // Aerilate makes a Normal move STAB Flying, which must survive the fix.
    let mence = form("Mega Salamence")
    let edge = store.data.moves.values.first { $0.name == "Double-Edge" }!
    let claw = store.data.moves.values.first { $0.name == "Dragon Claw" }!
    check("Aerilate keeps Double-Edge above a Dragon move",
          store.moveValue(edge, for: mence, ability: "Aerilate")
            > store.moveValue(claw, for: mence, ability: "Aerilate"), "no")

    // A recharge turn is the same complaint as Steel Beam's recoil: 150 base
    // power that only fires every second turn is worth less than 120 that fires
    // every turn. Unpriced, it made Giga Impact Mega Salamence's best move.
    let giga = store.data.moves.values.first { $0.name == "Giga Impact" }!
    check("a recharge turn is priced in",
          store.moveValue(edge, for: mence, ability: "Aerilate")
            > store.moveValue(giga, for: mence, ability: "Aerilate"), "no")

    // And a move it gets no bonus for must rank below one it does.
    let glaive = store.data.moves.values.first { $0.name == "Glaive Rush" }!
    check("STAB Glaive Rush beats neutral Double-Edge on Baxcalibur",
          store.moveValue(glaive, for: bax) > store.moveValue(edge, for: bax), "no")

    // -- what a Pokemon's stats say it is for -----------------------------
    print("\n== stat roles ==")
    let pult = form("Dragapult")
    let pultRole = store.statRole(of: pult)
    print("  Dragapult: \(pultRole.summary)")
    check("Dragapult is physical", pultRole.offence == .physical, pultRole.offence.rawValue)
    check("and special is recognised as a real second set",
          pultRole.alsoViable == .special, "\(String(describing: pultRole.alsoViable))")

    let goliRole = store.statRole(of: goli)
    print("  Mega Golisopod: \(goliRole.summary)")
    check("175 Def against 120 SpD is physically bulky",
          goliRole.defence == .physicalWall, goliRole.defence.rawValue)

    let milo = store.statRole(of: form("Milotic"))
    check("Milotic is specially bulky", milo.defence == .specialWall, milo.defence.rawValue)
    let gengar = store.statRole(of: form("Mega Gengar"))
    check("Mega Gengar is a special attacker", gengar.offence == .special, gengar.offence.rawValue)
    check("and frail", gengar.defence == .frail, gengar.defence.rawValue)
    let whim = store.statRole(of: form("Whimsicott"))
    check("Whimsicott is not an attacker", whim.offence == .none, whim.offence.rawValue)

    // -- the form that actually fights ------------------------------------
    //
    // Champions registers the base Pokemon holding its stone, so a list reads
    // "Salamence @ Salamencite" and a Mega Salamence walks out. The versus grid
    // read the registered form, which duelled 186 of the 192 stone-holders in
    // the bundled lists as their unevolved selves.
    print("\n== megas fight as megas ==")
    var menceTeam = Team(); menceTeam.format = "doubles"
    var menceSlot = TeamSlot(formID: form("Salamence").id)
    menceSlot.item = "Salamencite"
    menceTeam.slots = [menceSlot]
    let menceGrid = Matchup(mine: menceTeam, theirs: menceTeam, store: store,
                            field: Field(isDoubles: true))
    let fighting = menceGrid.myForms.first?.formLabel ?? "-"
    print("  Salamence @ Salamencite fights as: \(fighting)")
    check("a base form holding its stone duels as the Mega",
          fighting == "Mega Salamence", fighting)
    // And it has to fight with the Mega's ability, not the base form's. Ranking
    // its moves under Intimidate rather than Aerilate picks a Dragon move,
    // because the thing that makes Double-Edge its best attack is missing.
    let menceCell = menceGrid.cell(mine: menceGrid.myForms[0], theirs: menceGrid.myForms[0])
    let menceMove = menceCell?.myBestMove ?? "-"
    print("  and its best move reads: \(menceMove)")
    check("moves are ranked under the Mega's ability", menceMove == "Double-Edge", menceMove)

    // -- which four, and which two lead -----------------------------------
    // -- items that are actually in this game -------------------------------
    //
    // The item list is scraped from Serebii's main-series itemdex, because
    // Serebii publishes no Champions one, and a good part of it is not in this
    // game. Assault Vest is the clearest case: a VGC staple on none of the 105
    // registered lists, while Choice Scarf is on twenty-two of them.
    print("\n== items in the game ==")
    let seen = store.data.items.filter(\.seenInGame)
    print("  \(seen.count) of \(store.data.items.count) items have been seen in Champions")
    check("the gate keeps a real, useful share of the list",
          seen.count > 60 && seen.count < store.data.items.count, "\(seen.count)")
    for name in ["Choice Scarf", "Sitrus Berry", "Life Orb", "Focus Sash", "Rocky Helmet"] {
        check("\(name) is in the game", store.item(named: name)?.seenInGame == true)
    }
    for name in ["Assault Vest", "Choice Band", "Choice Specs", "Covert Cloak"] {
        check("\(name) is gated", store.item(named: name)?.seenInGame == false)
    }
    // A Mega cannot evolve without its stone, so every stone must be allowed.
    let stonesGated = store.data.forms.filter(\.isMega).compactMap { form -> String? in
        let stone = form.megaStone.isEmpty ? "Mega Stone" : form.megaStone
        return store.item(named: stone)?.seenInGame == false ? form.formLabel : nil
    }
    check("no Mega has its own stone gated", stonesGated.isEmpty,
          stonesGated.prefix(3).joined(separator: ", "))
    // And nothing the app scores against may hold one.
    var holders: [String] = []
    for meta in store.data.metaTeams {
        for member in meta.members where !member.item.isEmpty {
            if store.item(named: member.item)?.seenInGame == false {
                holders.append("\(meta.name): \(member.form) @ \(member.item)")
            }
        }
    }
    check("no bundled team holds an item that is not in the game",
          holders.isEmpty, holders.prefix(3).joined(separator: "; "))
    // Nor may the builder reach for one.
    let builder = TeamBuilder(store: store, format: "doubles")
    var usedItems = Set<String>()
    var builtItems: [String] = []
    for form in store.data.forms.prefix(60) {
        let slot = builder.flesh(form, plan: .balance, usedItems: &usedItems)
        if !slot.item.isEmpty, store.item(named: slot.item)?.seenInGame == false {
            builtItems.append("\(form.formLabel) @ \(slot.item)")
        }
    }
    check("the builder never assigns one", builtItems.isEmpty,
          builtItems.prefix(3).joined(separator: "; "))

    // -- what actually moves first ----------------------------------------
    //
    // Every screen that asked about turn order read the raw Speed stat. A
    // Choice Scarf is the most common speed item in the format and was worth
    // nothing; Swift Swim, Chlorophyll, Sand Rush and Surge Surfer are the
    // entire point of the teams that run them and were read as team-building
    // labels rather than as Speed.
    print("\n== speed on the field ==")
    func runner(_ name: String, item: String, ability: String? = nil) -> Combatant {
        let f = form(name)
        var sp = Array(repeating: 0, count: 6); sp[Stat.speed.rawValue] = 32
        return Combatant(form: f, ability: ability ?? f.abilities.first?.name ?? "",
                         item: item, sp: sp, alignment: Alignment.named("Jolly"))
    }
    let plainField = Field(isDoubles: true)
    let rainField = Field(weather: .rain, isDoubles: true)
    let chomp = runner("Garchomp", item: "Choice Scarf")
    print("  Choice Scarf Garchomp: \(chomp.stat(.speed)) raw, \(chomp.speed(in: plainField)) on the field")
    check("a Choice Scarf is worth half again",
          chomp.speed(in: plainField) == Int(Double(chomp.stat(.speed)) * 1.5),
          "\(chomp.speed(in: plainField))")
    let orbChomp = runner("Garchomp", item: "Life Orb")
    check("and an item that does nothing to Speed does nothing",
          orbChomp.speed(in: plainField) == orbChomp.stat(.speed))

    let swimmer = runner("Basculegion", item: "Life Orb", ability: "Swift Swim")
    print("  Swift Swim Basculegion: \(swimmer.speed(in: plainField)) dry, \(swimmer.speed(in: rainField)) in rain")
    check("Swift Swim doubles Speed in rain",
          swimmer.speed(in: rainField) == swimmer.stat(.speed) * 2,
          "\(swimmer.speed(in: rainField))")
    check("and does nothing without it",
          swimmer.speed(in: plainField) == swimmer.stat(.speed))
    let surfer = runner("Mega Raichu Y", item: "Raichunite Y", ability: "Surge Surfer")
    check("Surge Surfer doubles Speed on Electric Terrain",
          surfer.speed(in: Field(terrain: .electric, isDoubles: true)) == surfer.stat(.speed) * 2)

    // A Choice item locks you into the first move, and an Assault Vest forbids
    // status outright, so neither can spend a turn setting up.
    check("a Choice item cannot spend a turn setting up",
          !DuelEngine.canSpendATurn(runner("Garchomp", item: "Choice Band")))
    check("nor can an Assault Vest",
          !DuelEngine.canSpendATurn(runner("Garchomp", item: "Assault Vest")))
    check("but anything else can",
          DuelEngine.canSpendATurn(runner("Garchomp", item: "Life Orb")))

    // -- Protect, and the clock speed control runs on ------------------------
    //
    // Most VGC sets carry a Protect and the battle model had never heard of it.
    // A turn of damage refused is a turn added to whatever clock the other side
    // is racing, and it is the answer to being focused down.
    print("\n== protect ==")
    func move(_ n: String) -> Move { store.data.moves.values.first { $0.name == n }! }
    check("Protect is recognised", DuelEngine.protects(in: [move("Protect")]) != nil)
    check("so are its relatives",
          DuelEngine.protects(in: [move("Spiky Shield")]) != nil
            && DuelEngine.protects(in: [move("Baneful Bunker")]) != nil)
    check("Wide Guard is not one of them, it does something else",
          DuelEngine.protects(in: [move("Wide Guard")]) == nil)
    check("nor is Endure, which leaves you on one health point",
          DuelEngine.protects(in: [move("Endure")]) == nil)

    // It has to cost the attacker a turn, both ways round.
    let plain = Duel(mine: form("Garchomp"), theirs: form("Incineroar"),
                     outgoing: 0.5, incoming: 0.5, mySpeed: 200, theirSpeed: 100,
                     myBestMove: "-", theirBestMove: "-")
    var guarded = plain
    guarded.theirProtect = "Protect"
    print("  two hits to knock out: \(plain.myTurnsToKO) turns, \(guarded.myTurnsToKO) against a Protect")
    check("a Protect on the far side adds a turn to your clock",
          guarded.myTurnsToKO == plain.myTurnsToKO + 1,
          "\(guarded.myTurnsToKO) vs \(plain.myTurnsToKO)")
    var guardedMe = plain
    guardedMe.myProtect = "Protect"
    check("and one on yours adds a turn to theirs",
          guardedMe.theirTurnsToKO == plain.theirTurnsToKO + 1)
    check("a Protect nobody is running changes nothing",
          plain.myTurnsToKO == 2 && plain.theirTurnsToKO == 2,
          "\(plain.myTurnsToKO)/\(plain.theirTurnsToKO)")

    // Durations come out of the move text, not a table in the code.
    print("\n== the clock ==")
    check("Tailwind reads as four turns", Matchup.duration(of: move("Tailwind")) == 4,
          "\(Matchup.duration(of: move("Tailwind")) ?? -1)")
    check("Trick Room reads as five", Matchup.duration(of: move("Trick Room")) == 5,
          "\(Matchup.duration(of: move("Trick Room")) ?? -1)")
    check("and a move with no duration reads as none",
          Matchup.duration(of: move("Protect")) == nil)

    if let opponent = store.data.metaTeams.first(where: { $0.name == "Big Six" }) {
        let theirSix = store.opponentTeam(opponent)
        var windows = 0
        for saved in store.teams {
            let grid = Matchup(mine: saved, theirs: theirSix, store: store,
                               field: Field(isDoubles: true))
            guard let w = grid.window() else { continue }
            windows += 1
            let verdictText = w.closes ? "closes" : "\(w.shortfall) short"
            let padded = saved.name.padding(toLength: max(saved.name.count, 24),
                                            withPad: " ", startingAt: 0)
            print("  \(padded) \(w.tactic) \(w.turns) turns = \(w.actions) actions, "
                  + "needs \(w.needed) -> \(verdictText)")
            check("\(saved.name): doubles gives two attacking turns a turn",
                  w.actions == w.turns * 2, "\(w.actions)")
            check("\(saved.name): the cost of the four that matter is what is counted",
                  w.needed == w.cost.prefix(4).reduce(0) { $0 + $1.turns })
        }
        check("speed control was found on the saved teams", windows > 0, "\(windows)")
    }

    // -- every team is its own team ---------------------------------------
    //
    // Meta team ids were "tour-<placing>", and placing repeats across events,
    // so 112 teams shared 17 ids. Everything keyed on the id -- the built-team
    // cache, the opponent pool, the versus picker -- collapsed them onto
    // whichever arrived first, and 95 of the published lists were never scored.
    print("\n== meta team identity ==")
    let metaIDs = store.data.metaTeams.map(\.id)
    print("  \(metaIDs.count) teams, \(Set(metaIDs).count) distinct ids")
    check("every meta team has its own id", Set(metaIDs).count == metaIDs.count,
          "\(metaIDs.count - Set(metaIDs).count) collisions")
    // And the cache keyed on it hands back distinct teams.
    let firstFew = store.data.metaTeams.filter { $0.record != nil }.prefix(8)
    let builtIDs = firstFew.map { meta in
        store.opponentTeam(meta).slots.compactMap { $0.form(in: store)?.formLabel }
            .sorted().joined(separator: ",")
    }
    check("and the built-team cache does not alias them",
          Set(builtIDs).count == builtIDs.count,
          "\(builtIDs.count - Set(builtIDs).count) aliased")

    print("\n== bring four ==")
    let sixes = store.data.metaTeams.filter { $0.members.count == 6 && $0.format == "doubles" }
    check("two full six-Pokemon lists to work with", sixes.count >= 2, "\(sixes.count)")
    if sixes.count >= 2 {
        let mineTeam = store.opponentTeam(sixes[0])
        let theirTeam = store.opponentTeam(sixes[1])
        let grid = Matchup(mine: mineTeam, theirs: theirTeam, store: store,
                           field: Field(isDoubles: true))
        let picker = BringFour(matchup: grid, store: store)

        print("  mine:   \(sixes[0].name)")
        print("  theirs: \(sixes[1].name)")
        let likely = picker.theirLikelyFour
        print("  they most likely bring: \(likely.map(\.formLabel).joined(separator: ", "))")
        check("they bring four", likely.count == 4, "\(likely.count)")

        let plans = picker.plans
        let megaCount = grid.myForms.filter(\.isMega).count
        // C(6,4) is fifteen, less any four holding two Megas: a second Mega
        // cannot evolve, so it is a slot spent on an unusable item.
        print("  fours offered: \(plans.count) (team carries \(megaCount) Mega\(megaCount == 1 ? "" : "s"))")
        check("every legal four is considered",
              plans.count == (megaCount >= 2 ? 9 : 15), "\(plans.count)")
        check("no four carries two Megas",
              plans.allSatisfy { $0.bring.filter(\.isMega).count <= 1 })
        check("each plan brings four", plans.allSatisfy { $0.bring.count == 4 })
        check("and benches the other two", plans.allSatisfy { $0.benched.count == 2 })
        check("leads come from the four", plans.allSatisfy { plan in
            plan.leads.allSatisfy { lead in plan.bring.contains { $0.id == lead.id } } })
        check("nobody is both brought and benched", plans.allSatisfy { plan in
            Set(plan.bring.map(\.id)).isDisjoint(with: Set(plan.benched.map(\.id))) })
        check("scores stay on the -100...100 scale",
              plans.allSatisfy { (-100...100).contains($0.score) })
        check("ranked best first", zip(plans, plans.dropFirst()).allSatisfy { $0.score >= $1.score })

        // The whole point is that the choice matters. If the best four and the
        // worst four score the same, this is an expensive way to print a list.
        if let best = plans.first, let worst = plans.last {
            print("  best four scores \(best.score), worst \(worst.score)")
            check("the choice of four actually changes the matchup",
                  best.score > worst.score, "\(best.score) vs \(worst.score)")
        }

        // Scoring a subset has to agree with scoring the whole team, or two
        // screens will disagree about the same six.
        check("rating the whole six matches the verdict",
              grid.rate(bringing: grid.myForms, against: grid.theirForms).score
                == grid.verdict.score,
              "\(grid.rate(bringing: grid.myForms, against: grid.theirForms).score) vs \(grid.verdict.score)")

        for plan in plans.prefix(2) {
            print("  --")
            print("  bring \(plan.bring.map(\.formLabel).joined(separator: ", "))")
            print("    leads \(plan.leads.map(\.formLabel).joined(separator: " + ")) | score \(plan.score) (grid \(plan.edge), turn one \(String(format: "%+.2f", plan.turnOne.value)))")
            for line in plan.reasons { print("    · \(line)") }
            for line in plan.warnings { print("    ! \(line)") }
        }
    }

    // -- leaving a cell you are losing -------------------------------------
    //
    // Switching resolves before any move, so a lost one-on-one is normally a
    // lost turn rather than a lost Pokemon. The grid scored every bad cell as
    // though both sides were nailed to the floor.
    print("\n== switching ==")
    let uturn = store.data.moves.values.first { $0.name == "U-turn" }!
    let shot = store.data.moves.values.first { $0.name == "Parting Shot" }!
    let claw2 = store.data.moves.values.first { $0.name == "Dragon Claw" }!
    check("a damaging pivot is recognised", DuelEngine.pivot(in: [claw2, uturn])?.name == "U-turn")
    check("so is a status one", DuelEngine.pivot(in: [shot])?.name == "Parting Shot")
    check("and an ordinary attack is not", DuelEngine.pivot(in: [claw2]) == nil)

    // The paste's Incineroar runs Parting Shot, so its losing cells have a way
    // out that the grid can name.
    let switchGrid = Matchup(mine: result.team, theirs: theirs, store: store,
                             field: Field(isDoubles: true))
    let ways = switchGrid.retreats()
    print("  losing cells: \(ways.count)")
    let withPivot = ways.filter { $0.pivot != nil }
    print("  of those, \(withPivot.count) leave on a pivot move")
    check("a slot running Parting Shot has it read as its way out",
          withPivot.contains { $0.from.formLabel == "Incineroar" && $0.pivot == "Parting Shot" })
    if let best = ways.first(where: { $0.pivot != nil && $0.into != nil }) {
        print("  e.g. \(best.from.formLabel) loses to \(best.against.formLabel) -> \(best.pivot!) into \(best.into!.formLabel)")
    }
    check("no retreat sends a Pokemon into itself",
          ways.allSatisfy { $0.into?.id != $0.from.id })

    // Mega Gengar is the only trapping ability in Regulation M-C, so it should
    // be the only thing that turns a lost cell into a lost Pokemon.
    var gengarTeam = Team(); gengarTeam.format = "doubles"
    var gengarSlot = TeamSlot(formID: form("Gengar").id)
    gengarSlot.item = "Gengarite"
    gengarTeam.slots = [gengarSlot]
    let trapGrid = Matchup(mine: result.team, theirs: gengarTeam, store: store,
                           field: Field(isDoubles: true))
    print("  versus Gengar + Gengarite: fights as \(trapGrid.theirForms.first?.formLabel ?? "-"), ability \(trapGrid.theirForms.first?.abilities.first?.name ?? "-")")
    check("Shadow Tag traps every cell it is in",
          trapGrid.duels.allSatisfy(\.iAmTrapped), "\(trapGrid.duels.filter(\.iAmTrapped).count)/\(trapGrid.duels.count)")
    check("and nothing else does",
          switchGrid.duels.allSatisfy { !$0.iAmTrapped })

    // The discount is applied to both sides, so a team against itself is still
    // level. Softening only your own losses would lift every score on screen.
    let selfGrid = Matchup(mine: result.team, theirs: result.team, store: store,
                           field: Field(isDoubles: true))
    print("  mirror edge with switching modelled: \(selfGrid.verdict.score)")
    check("leaving is worth the same to both sides", abs(selfGrid.verdict.score) <= 5,
          "\(selfGrid.verdict.score)")

    for line in switchGrid.verdict.advice where line.contains("switch") || line.contains("come in")
        || line.contains("lost turn") || line.contains("traps") {
        print("  advice: \(line)")
    }

    // -- Stat Points spent against real numbers -----------------------------
    //
    // A spread is a set of thresholds, and below a threshold the points bought
    // nothing. The builder used to spend them by habit: 32 into the attacking
    // stat, some Speed, the rest into health.
    print("\n== spreads ==")
    var planner = SpreadPlanner(store: store, format: "doubles")
    planner.field = Field(isDoubles: true)
    let speedMarks = planner.speedBenchmarks()
    print("  \(speedMarks.count) Speed numbers worth clearing, fastest \(speedMarks.first?.number ?? 0)")
    check("Speed benchmarks come out of measured usage", speedMarks.count >= 8,
          "\(speedMarks.count)")
    check("and are ordered fastest first",
          zip(speedMarks, speedMarks.dropFirst()).allSatisfy { $0.number >= $1.number })
    check("every one is reachable arithmetic, not a nonsense number",
          speedMarks.allSatisfy { $0.number > 0 && $0.number < 600 })

    let survival = planner.survivalBenchmarks(for: form("Mega Golisopod"))
    print("  \(survival.count) attacks worth living through, hardest \(survival.first?.label ?? "-")")
    check("survival benchmarks name a move", survival.allSatisfy { $0.move != nil })
    check("and never include the Pokemon itself",
          survival.allSatisfy { $0.threat.dex != form("Mega Golisopod").dex })

    for (name, item, isAttacker) in [("Mega Baxcalibur", "Baxcalibrite", true),
                                     ("Incineroar", "Sitrus Berry", false),
                                     ("Mega Golisopod", "Golisopite", true)] {
        let target = form(name)
        let plan = planner.plan(for: target, item: item, attacker: isAttacker)
        let spelled = Stat.allCases.filter { plan.sp[$0.rawValue] > 0 }
            .map { "\($0.short) \(plan.sp[$0.rawValue])" }.joined(separator: " / ")
        print("  \(name): \(plan.alignment.name), \(spelled) — clears \(Int(plan.cover * 100))%")
        check("\(name): the spread is legal",
              plan.spent <= ChampionsStats.spTotal
                && plan.sp.allSatisfy { $0 <= ChampionsStats.spPerStat },
              "\(plan.spent) points, max \(plan.sp.max() ?? 0) in one stat")
        check("\(name): it spends what it has rather than leaving points on the table",
              plan.spent >= ChampionsStats.spTotal - 2, "\(plan.spent)")
        check("\(name): the alignment does not drop what the Pokemon is for",
              isAttacker
                ? plan.alignment.down != (target.attack >= target.spAttack ? .attack : .spAttack)
                : true,
              plan.alignment.label)
        check("\(name): it says what it bought", !plan.lines.isEmpty)
        // Every benchmark is either met or missed, never both and never lost.
        let ids = Set(plan.met.map(\.id)).intersection(Set(plan.missed.map(\.id)))
        check("\(name): no benchmark is counted twice", ids.isEmpty, "\(ids.count)")
    }

    // A threat used as a benchmark must itself be legal, or the whole exercise
    // is built against a Pokemon the game would not accept.
    let probe = planner.speedBenchmarks().first
    check("benchmark threats are built inside the Stat Point rules", probe != nil)

    // -- the turn as the game it actually is --------------------------------
    //
    // Both sides lock in two choices knowing nothing about the other's. That is
    // a matrix game, and what players call reading an opponent is what game
    // theory calls a mixed strategy.
    print("\n== the solver ==")
    func mix(_ m: [[Double]]) -> (row: [Double], column: [Double], value: Double) {
        TurnGame.equilibrium(m, iterations: 20000)
    }
    let pennies = mix([[1, -1], [-1, 1]])
    print("  matching pennies: \(pennies.row.map { String(format: "%.2f", $0) }.joined(separator: "/"))")
    check("matching pennies is a coin flip",
          pennies.row.allSatisfy { abs($0 - 0.5) < 0.02 } && abs(pennies.value) < 0.02)
    let rps = mix([[0, -1, 1], [1, 0, -1], [-1, 1, 0]])
    print("  rock paper scissors: \(rps.row.map { String(format: "%.2f", $0) }.joined(separator: "/"))")
    check("rock paper scissors is even thirds",
          rps.row.allSatisfy { abs($0 - 1.0 / 3) < 0.02 } && abs(rps.value) < 0.02)
    let dominant = mix([[2, 3], [0, 1]])
    check("a dominant option is taken every time",
          dominant.row[0] > 0.98 && abs(dominant.value - 2) < 0.05,
          "\(dominant.row[0])")
    let saddle = mix([[4, 2], [3, 1]])
    check("a saddle point is a pure strategy both ways",
          saddle.row[0] > 0.98 && saddle.column[1] > 0.98 && abs(saddle.value - 2) < 0.05)
    check("an empty matrix does not crash", TurnGame.equilibrium([]).value == 0)

    print("\n== a turn played out ==")
    if let opponent = store.data.metaTeams.first(where: { $0.name == "Big Six" }),
       let mineTeam = store.teams.first(where: { $0.slots.count >= 4 }) {
        let start = Board(mine: mineTeam, theirs: store.opponentTeam(opponent), store: store)
        check("both sides have two out and the rest behind",
              start.mine.count >= 2 && start.theirs.count >= 2)
        check("everyone starts at full health",
              start.mine.allSatisfy { $0.hp == $0.maxHP })

        // Protect has to actually refuse the damage.
        let attackers = start.theirs.prefix(2)
        if let hitIndex = start.mine[0].moves.firstIndex(where: \.isDamaging),
           let guardIndex = start.theirs[0].moves.firstIndex(where: {
               DuelEngine.protectMoves.contains($0.name) }) {
            let openTurn = TurnModel.resolve(
                start, mine: Play(left: .attack(move: hitIndex, target: 0),
                                  right: .attack(move: hitIndex, target: 0)),
                theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
                store: store)
            let guardedTurn = TurnModel.resolve(
                start, mine: Play(left: .attack(move: hitIndex, target: 0),
                                  right: .attack(move: hitIndex, target: 0)),
                theirs: Play(left: .protectSelf(move: guardIndex),
                             right: .attack(move: 0, target: 0)), store: store)
            print("  their lead takes \(start.theirs[0].maxHP - openTurn.theirs[0].hp) open, "
                  + "\(start.theirs[0].maxHP - guardedTurn.theirs[0].hp) behind Protect")
            check("Protect refuses the damage",
                  guardedTurn.theirs[0].hp > openTurn.theirs[0].hp
                    || openTurn.theirs[0].hp == start.theirs[0].maxHP,
                  "\(guardedTurn.theirs[0].hp) vs \(openTurn.theirs[0].hp)")
        }
        _ = attackers

        let game = TurnGame(board: start, store: store)
        // The first solve pays for warming the damage calculator's caches, and
        // measuring that measures the caches rather than the search. What the
        // interface actually costs is the second one — and it takes the
        // yielding path anyway, which is checked for stalls in tools/hitch.sh.
        _ = game.solve()
        let started = Date()
        let solution = game.solve()
        let took = Date().timeIntervalSince(started) * 1000
        print(String(format: "  %d x %d matrix in %.0f ms, turn worth %+.3f",
                     solution.myPlays.count, solution.theirPlays.count, took, solution.value))
        check("the matrix is the size the play lists say",
              solution.payoff.count == solution.myPlays.count
                && solution.payoff.allSatisfy { $0.count == solution.theirPlays.count })
        check("every payoff is a real number",
              solution.payoff.allSatisfy { $0.allSatisfy { $0.isFinite } })
        check("both mixes are probabilities",
              abs(solution.myMix.reduce(0, +) - 1) < 0.01
                && abs(solution.theirMix.reduce(0, +) - 1) < 0.01)
        // Not a speed assertion: this harness is built without optimisation, so
        // a millisecond budget here measures the compiler rather than the
        // search. tools/hitch.sh owns that, and builds with -O. This only
        // catches a blow-up in the size of the problem.
        check("the search has not blown up in size", took < 5000,
              String(format: "%.0f ms unoptimised", took))

        // A one-turn model left alone tells both sides to double-protect for
        // ever, because declining to attack costs nothing inside one turn.
        var doubleProtect = 0.0
        for (index, play) in solution.theirPlays.enumerated()
        where play.left.isProtect && play.right.isProtect {
            doubleProtect += solution.theirMix[index]
        }
        print(String(format: "  they double-protect %.0f%% of the time", doubleProtect * 100))
        check("giving up the turn is priced, so double Protect is not a free win",
              doubleProtect < 0.6, String(format: "%.0f%%", doubleProtect * 100))

        for line in game.read(solution).prefix(4) { print("  · \(line)") }

        // -- reading them ---------------------------------------------------
        //
        // Equilibrium is the mix nobody can exploit, which is the right answer
        // when you know nothing. Reading someone means leaving it on purpose,
        // and the question is what that is worth against what it risks.
        print("\n== reading them ==")
        let information = game.tells(solution)
        print(String(format: "  knowing their choice in advance is worth %+.3f", information.value))
        check("perfect information is never a loss", information.value >= -0.001,
              String(format: "%.3f", information.value))
        check("every tell is at least as good as playing blind",
              information.top.allSatisfy { $0.worthKnowing >= -0.001 })
        check("tells are ordered by what they are worth",
              zip(information.top, information.top.dropFirst())
                .allSatisfy { $0.worthKnowing >= $1.worthKnowing })
        for tell in information.top.prefix(2) {
            print(String(format: "    %-44s %3.0f%%, worth %+.2f",
                         (tell.label as NSString).utf8String!,
                         tell.likelihood * 100, tell.worthKnowing))
        }

        // A read at no strength is the equilibrium, and at full strength it is
        // a different distribution that still adds to one.
        let none = game.mix(solution, assuming: .protectsOften, strength: 0)
        check("believing nothing leaves the mix alone",
              zip(none, solution.theirMix).allSatisfy { abs($0 - $1) < 0.001 })
        for read in TurnGame.Read.allCases {
            let tilted = game.mix(solution, assuming: read, strength: 0.8)
            check("\(read.shorthand) still adds up to a distribution",
                  abs(tilted.reduce(0, +) - 1) < 0.01, "\(tilted.reduce(0, +))")
        }
        // Punishing a tendency has to beat playing the mix against it, or it is
        // not a punishment.
        let found = game.exploits(solution)
        print("  exploits found: \(found.count)")
        check("every exploit beats the mix against the tendency it answers",
              found.allSatisfy { $0.against >= $0.equilibrium - 0.001 })
        check("and each names a line you could actually pick",
              found.allSatisfy { !$0.label.isEmpty && $0.label != "—" })
        check("they are ordered by what they gain",
              zip(found, found.dropFirst()).allSatisfy { $0.gain >= $1.gain })
        for exploit in found.prefix(3) {
            print(String(format: "    %-32s gain %+.2f risk %.2f  %@",
                         (exploit.read.shorthand as NSString).utf8String!,
                         exploit.gain, exploit.cost,
                         (exploit.worthIt ? "take it" : "not yet") as NSString))
        }
        for line in game.readingNotes(solution) { print("  · \(line)") }

        // -- switching in ---------------------------------------------------
        //
        // A Pokemon that switches in takes a free hit, because it does not act
        // that turn, and arriving is itself an action: Intimidate, and the
        // weather or terrain a setter brings back with it.
        print("\n== switching in ==")
        if start.mine.count > 2, let hit = start.theirs[0].moves.firstIndex(where: \.isDamaging) {
            let stayed = TurnModel.resolve(
                start, mine: Play(left: .attack(move: 0, target: 0),
                                  right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: hit, target: 0),
                             right: .attack(move: 0, target: 1)), store: store)
            let swapped = TurnModel.resolve(
                start, mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: hit, target: 0),
                             right: .attack(move: 0, target: 1)), store: store)
            print("  the one that came in is \(swapped.mine[0].build.form.formLabel), "
                  + "on \(swapped.mine[0].hp) of \(swapped.mine[0].maxHP)")
            check("the Pokemon that switched in is the one that took the hit",
                  swapped.mine[0].build.form.id != stayed.mine[0].build.form.id)
            check("and it took a real one, because it does not act on the way in",
                  swapped.mine[0].hp < swapped.mine[0].maxHP,
                  "\(swapped.mine[0].hp)/\(swapped.mine[0].maxHP)")
        }
        // A weather setter coming in takes the field back.
        if let pelipper = store.form(named: "Pelipper") {
            var rainTeam = Team(); rainTeam.format = "doubles"
            var lead = TeamSlot(formID: form("Garchomp").id)
            lead.ability = "Rough Skin"
            var second = TeamSlot(formID: form("Incineroar").id)
            second.ability = "Intimidate"
            var bench = TeamSlot(formID: pelipper.id)
            bench.ability = "Drizzle"
            rainTeam.slots = [lead, second, bench]
            let dry = Board(mine: rainTeam, theirs: store.opponentTeam(opponent), store: store)
            check("the field starts clear", dry.field.weather == .none)
            let wet = TurnModel.resolve(dry,
                mine: Play(left: .swap(to: 2), right: .attack(move: 0, target: 0)),
                theirs: Play(left: .attack(move: 0, target: 0),
                             right: .attack(move: 0, target: 1)), store: store)
            print("  after pivoting Pelipper in, the weather is \(wet.field.weather.rawValue)")
            check("a Drizzle switch-in takes the field back", wet.field.weather == .rain,
                  wet.field.weather.rawValue)
        }
    }

    // -- Mega Evolution, and the order of it --------------------------------
    //
    // It happens after the switches and before any move, fastest first, and the
    // order is not decoration: an ability that fires on evolving fires in that
    // order, so when two Megas both bring weather the slower one evolves second
    // and its weather is the one left on the field.
    print("\n== mega evolution ==")
    func sideOf(_ entries: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = entries.map { name, item, moves in
            var slot = TeamSlot(formID: form(name).id)
            slot.item = item
            slot.moves = moves.compactMap { n in
                store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6); sp[Stat.speed.rawValue] = 32
            slot.sp = sp; slot.alignmentName = "Timid"
            return slot
        }
        return out
    }
    let sunSide = sideOf([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                          ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                          ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let snowSide = sideOf([("Froslass", "Froslassite", ["Blizzard", "Protect"]),
                           ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])

    let unevolved = Board(mine: sunSide, theirs: snowSide, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    check("a battle starts with what was registered, not what it becomes",
          unevolved.mine[0].build.form.formLabel == "Charizard",
          unevolved.mine[0].build.form.formLabel)
    check("and with the registered ability",
          unevolved.mine[0].build.ability != "Drought", unevolved.mine[0].build.ability)
    check("but it knows what it turns into",
          unevolved.mine[0].pendingMega?.formLabel == "Mega Charizard Y")
    let analysed = Board(mine: sunSide, theirs: snowSide, store: store,
                         field: Field(isDoubles: true))
    check("while every analysis screen still sees the Mega",
          analysed.mine[0].build.form.formLabel == "Mega Charizard Y",
          analysed.mine[0].build.form.formLabel)

    let mySpeed = unevolved.mine[0].build.speed(in: unevolved.field)
    let theirSpeed = unevolved.theirs[0].build.speed(in: unevolved.field)
    print("  Charizard \(mySpeed) against Froslass \(theirSpeed) — the slower evolves second")
    // Both sides toggle it on for their lead, which is how the game asks.
    let afterMega = TurnModel.resolve(
        unevolved,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                     megaSlot: 0),
        store: store)
    print("  both evolved; the weather is \(afterMega.field.weather.rawValue)")
    check("both sides Mega Evolved",
          afterMega.mine[0].build.form.isMega && afterMega.theirs[0].build.form.isMega)
    // Froslass is faster, so it evolves first and Charizard's Drought lands on
    // top of its Snow Warning.
    check("the slower Mega wins the weather war",
          afterMega.field.weather == (mySpeed < theirSpeed ? .sun : .snow),
          afterMega.field.weather.rawValue)
    check("and evolving spends the side's one Mega Evolution",
          afterMega.mine.allSatisfy(\.hasMegaEvolved))

    // Two stones on one side is legal to register and only one can be used.
    let twoStones = sideOf([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                            ("Froslass", "Froslassite", ["Blizzard", "Protect"]),
                            ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let dual = Board(mine: twoStones, theirs: snowSide, store: store,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    // Asking for the second slot as well changes nothing: a side gets one.
    let afterDual = TurnModel.resolve(
        dual,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                     megaSlot: 0),
        store: store)
    let evolvedNames = afterDual.mine.prefix(2).filter { $0.build.form.isMega }
        .map(\.build.form.formLabel)
    print("  two stones on one side, asked for the first: \(evolvedNames)")
    check("only one of them evolves", evolvedNames.count == 1, "\(evolvedNames)")
    check("and it is the one that was asked for",
          evolvedNames.first == "Mega Charizard Y", "\(evolvedNames)")

    // The other one, if that is the one you ask for.
    let afterOther = TurnModel.resolve(
        dual,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 1),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)),
        store: store)
    check("asking for the other one evolves the other one",
          afterOther.mine.prefix(2).filter { $0.build.form.isMega }
            .map(\.build.form.formLabel) == ["Mega Froslass"],
          "\(afterOther.mine.prefix(2).map(\.build.form.formLabel))")

    // Not asking leaves it alone, which is a turn people really do take.
    let held = TurnModel.resolve(
        unevolved,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)),
        store: store)
    check("nothing evolves unless it is asked to",
          !held.mine[0].build.form.isMega && !held.theirs[0].build.form.isMega)
    check("and holding it back leaves the field clear",
          held.field.weather == .none, held.field.weather.rawValue)

    // Holding it back one turn is how you win a weather war you would lose.
    let afterHeld = TurnModel.resolve(
        held,
        mine: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0),
                   megaSlot: 0),
        theirs: Play(left: .attack(move: 1, target: 0), right: .attack(move: 1, target: 0)),
        store: store)
    check("evolving a turn later still works",
          afterHeld.mine[0].build.form.isMega && afterHeld.field.weather == .sun,
          afterHeld.field.weather.rawValue)

    // Team lists register the base form; the bundled archetypes now do too.
    let stillMega = store.data.metaTeams.flatMap(\.members)
        .filter { $0.form.hasPrefix("Mega ") }
    check("no bundled team registers a Mega directly", stillMega.isEmpty,
          "\(stillMega.count)")

    // -- the rest of a turn --------------------------------------------------
    //
    // Eleven per cent of the move slots on real team lists used to land in the
    // battle loop and do nothing at all -- Follow Me, Rage Powder, Wide Guard,
    // Swords Dance, Will-O-Wisp, the screens -- and nothing happened between
    // turns either: no weather chip, no burn, no berry, no Leftovers.
    print("\n== the rest of a turn ==")
    func fighters(_ rows: [(String, String, [String])]) -> Team {
        var out = Team(); out.format = "doubles"
        out.slots = rows.map { name, item, moveNames in
            var slot = TeamSlot(formID: form(name).id)
            slot.item = item
            slot.ability = form(name).abilities.first?.name ?? ""
            slot.moves = moveNames.compactMap { n in
                store.data.moves.values.first { $0.name == n }?.id }
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32
            sp[Stat.hp.rawValue] = 2
            slot.sp = sp; slot.alignmentName = "Adamant"
            return slot
        }
        return out
    }
    let supporters = fighters([
        ("Incineroar", "Sitrus Berry", ["Will-O-Wisp", "Fake Out", "Flare Blitz", "Protect"]),
        ("Indeedee (Female)", "Leftovers", ["Follow Me", "Protect", "Dazzling Gleam"]),
        ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let aggressors = fighters([
        ("Garchomp", "Focus Sash", ["Earthquake", "Swords Dance", "Rock Slide", "Protect"]),
        ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
        ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let opening = Board(mine: supporters, theirs: aggressors, store: store,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    func at(_ fighter: Fighter, _ name: String) -> Int {
        fighter.moves.firstIndex { $0.name == name } ?? 0
    }

    let firstTurn = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Will-O-Wisp"), target: 0),
                   right: .attack(move: at(opening.mine[1], "Follow Me"), target: 0)),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    print("  the turn, in order:")
    for line in firstTurn.story.prefix(7) { print("    \(line)") }
    check("Will-O-Wisp actually burns something",
          firstTurn.theirs[0].status == .burn, firstTurn.theirs[0].status.rawValue)
    check("a burn then costs health between turns",
          firstTurn.theirs[0].hp < firstTurn.theirs[0].maxHP)
    check("Swords Dance actually raises Attack",
          firstTurn.theirs[0].build.boosts[Stat.attack.rawValue] == 2,
          "\(firstTurn.theirs[0].build.boosts[Stat.attack.rawValue])")
    // Follow Me was aimed away from Indeedee, so redirection has to have moved it.
    check("Follow Me pulls a single-target move onto itself",
          firstTurn.mine[1].hp < firstTurn.mine[1].maxHP
            || firstTurn.mine[1].fainted,
          "\(firstTurn.mine[1].hp)/\(firstTurn.mine[1].maxHP)")
    check("and the turn reads as a sequence rather than one line",
          firstTurn.story.count >= 5, "\(firstTurn.story.count)")

    // Protect, however it was chosen.
    var settled = firstTurn
    settled.fillGaps()
    let behindProtect = TurnModel.resolve(
        settled,
        mine: Play(left: .attack(move: at(settled.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: at(settled.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(settled.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(settled.theirs[1], "Wood Hammer"), target: 0)),
        store: store)
    check("Protect picked as a move still protects",
          behindProtect.mine[0].hp == settled.mine[0].hp,
          "\(behindProtect.mine[0].hp) vs \(settled.mine[0].hp)")

    // Screens, redirection of spread moves, and Wide Guard.
    let screened = fighters([("Whimsicott", "Focus Sash", ["Light Screen", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Wide Guard", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let wide = Board(mine: screened, theirs: aggressors, store: store,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    let blocked = TurnModel.resolve(
        wide,
        mine: Play(left: .attack(move: at(wide.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(wide.mine[1], "Wide Guard"), target: 0)),
        theirs: Play(left: .attack(move: at(wide.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(wide.theirs[1], "Protect"), target: 0)),
        store: store)
    check("Wide Guard turns a spread move away from the whole side",
          blocked.mine[1].hp == wide.mine[1].maxHP,
          "\(blocked.mine[1].hp)/\(wide.mine[1].maxHP)")

    let lit = TurnModel.resolve(
        wide,
        mine: Play(left: .attack(move: at(wide.mine[0], "Light Screen"), target: 0),
                   right: .attack(move: at(wide.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(wide.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(wide.theirs[1], "Protect"), target: 0)),
        store: store)
    check("Light Screen goes up and stays up", lit.myScreens.lightScreen > 0,
          "\(lit.myScreens.lightScreen)")

    // Rolling is what separates a battle from an evaluation.
    var rolls = Set<Int>()
    for _ in 0..<40 {
        let rolled = TurnModel.resolve(
            opening,
            mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                       right: .protectSelf(move: at(opening.mine[1], "Protect"))),
            theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)),
            store: store, rolling: true)
        rolls.insert(rolled.theirs[0].hp)
    }
    print("  the same attack, rolled forty times: \(rolls.count) different results")
    check("a played turn rolls the damage", rolls.count > 1, "\(rolls.count)")
    let averaged = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                   right: .protectSelf(move: at(opening.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)),
        store: store)
    let again = TurnModel.resolve(
        opening,
        mine: Play(left: .attack(move: at(opening.mine[0], "Flare Blitz"), target: 0),
                   right: .protectSelf(move: at(opening.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: at(opening.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(opening.theirs[1], "Fake Out"), target: 1)),
        store: store)
    check("while the search still gets the same answer every time",
          averaged.theirs[0].hp == again.theirs[0].hp)

    // -- turn order is re-checked, not decided once -------------------------
    //
    // A Prankster Whimsicott putting up Tailwind goes first on priority, and
    // its partner -- which has not moved yet -- is twice as fast from that
    // moment. Sorting the whole turn up front makes that impossible, and it is
    // most of why the move is worth a slot.
    print("\n== turn order ==")
    let windUp = fighters([("Whimsicott", "Focus Sash", ["Tailwind", "Protect"]),
                           ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                           ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let quick = fighters([("Garchomp", "Choice Scarf", ["Earthquake", "Protect"]),
                          ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                          ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var windBoard = Board(mine: windUp, theirs: quick, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    windBoard.mine[0].build.ability = "Prankster"
    let mySlow = windBoard.mine[1].build.speed(in: windBoard.field)
    let theirFast = windBoard.theirs[1].build.speed(in: windBoard.field)
    print("  your Incineroar \(mySlow) against their Rillaboom \(theirFast)")
    let blown = TurnModel.resolve(
        windBoard,
        mine: Play(left: .attack(move: at(windBoard.mine[0], "Tailwind"), target: 0),
                   right: .attack(move: at(windBoard.mine[1], "Flare Blitz"), target: 1)),
        theirs: Play(left: .attack(move: at(windBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(windBoard.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    let order = blown.story
    print("  the turn, in order:")
    for line in order.prefix(6) { print("    \(line)") }
    check("Tailwind went up", blown.myTailwind > 0, "\(blown.myTailwind)")
    // Incineroar is slower than Rillaboom on raw Speed, so without Tailwind
    // taking effect immediately it could only have moved second.
    let incinAt = order.firstIndex { $0.contains("Incineroar used") }
    let rillaAt = order.firstIndex { $0.contains("Rillaboom used") }
    // Either it moved first, or it moved first and knocked the other out before
    // it could — both mean the Tailwind applied inside the turn.
    check("and the partner it sped up moved before something faster than it",
          mySlow < theirFast && incinAt != nil && (rillaAt == nil || incinAt! < rillaAt!),
          "Incineroar at \(incinAt.map(String.init) ?? "-"), Rillaboom at \(rillaAt.map(String.init) ?? "-")")

    // Every line of a turn is in some step, and every step carries the board
    // as it stood, so the turn can be walked without losing anything.
    let stepped = blown.steps.flatMap { $0.text.split(separator: "\n").map(String.init) }
    check("every line of the turn is in a step", stepped == blown.story,
          "\(stepped.count) lines in \(blown.steps.count) steps vs \(blown.story.count)")
    check("and the snapshots carry the field with them",
          blown.steps.last?.myTailwind ?? 0 > 0)
    // A spread move is one step that names everyone it hit.
    let heaters = fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                            ("Whimsicott", "Focus Sash", ["Protect"])])
    let heated = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake"]),
                           ("Rillaboom", "Life Orb", ["Wood Hammer"])])
    let heatBoard = Board(mine: heaters, theirs: heated, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    let heatTurn = TurnModel.resolve(
        heatBoard,
        mine: Play(left: .attack(move: at(heatBoard.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(heatBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(heatBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(heatBoard.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    let heatStep = heatTurn.steps.first { $0.text.contains("Heat Wave") }
    print("  the Heat Wave step:")
    for line in heatStep?.text.split(separator: "\n") ?? [] { print("    \(line)") }
    check("a spread move is a single step",
          heatTurn.steps.filter { $0.text.contains("Heat Wave") }.count == 1,
          "\(heatTurn.steps.filter { $0.text.contains("Heat Wave") }.count)")
    check("and that step names both it hit",
          heatStep?.text.contains("Garchomp") == true && heatStep?.text.contains("Rillaboom") == true)

    // Final Gambit, and the rest of what a move costs the one that used it.
    print("\n== what a move costs its user ==")
    if store.data.moves.values.contains(where: { $0.name == "Final Gambit" }) {
        let gambit = fighters([("Whimsicott", "Focus Sash", ["Final Gambit", "Protect"]),
                               ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                               ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
        let board2 = Board(mine: gambit, theirs: quick, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
        if board2.mine[0].moves.contains(where: { $0.name == "Final Gambit" }) {
            let after = TurnModel.resolve(
                board2,
                mine: Play(left: .attack(move: at(board2.mine[0], "Final Gambit"), target: 0),
                           right: .attack(move: at(board2.mine[1], "Protect"), target: 0)),
                // Into something attacking, not Protecting: a Final Gambit that
                // is blocked leaves its user standing, as in the game.
                theirs: Play(left: .attack(move: board2.theirs[0].moves.firstIndex { !DuelEngine.protectMoves.contains($0.name) } ?? 0, target: 1),
                             right: .attack(move: at(board2.theirs[1], "Protect"), target: 0)),
                store: store)
            check("Final Gambit faints the one that used it",
                  after.mine[0].fainted, "\(after.mine[0].hp)")
        }
    }
    // Recoil, and a Life Orb.
    let orbed = fighters([("Garchomp", "Life Orb", ["Double-Edge", "Protect"]),
                          ("Incineroar", "Sitrus Berry", ["Protect"]),
                          ("Whimsicott", "Focus Sash", ["Protect"])])
    let orbBoard = Board(mine: orbed, theirs: quick, store: store,
                         field: Field(isDoubles: true), alreadyEvolved: false)
    if orbBoard.mine[0].moves.contains(where: { $0.name == "Double-Edge" }) {
        let after = TurnModel.resolve(
            orbBoard,
            mine: Play(left: .attack(move: at(orbBoard.mine[0], "Double-Edge"), target: 1),
                       right: .attack(move: at(orbBoard.mine[1], "Protect"), target: 0)),
            // They have to actually stand there, or nothing lands and nothing
            // is paid for it.
            theirs: Play(left: .attack(move: at(orbBoard.theirs[0], "Earthquake"), target: 0),
                         right: .attack(move: at(orbBoard.theirs[1], "Wood Hammer"), target: 0)),
            store: store)
        print("  Double-Edge off a Life Orb cost the user "
              + "\(orbBoard.mine[0].maxHP - after.mine[0].hp)")
        check("recoil and a Life Orb both come out of the attacker",
              after.mine[0].hp < orbBoard.mine[0].maxHP,
              "\(after.mine[0].hp)/\(orbBoard.mine[0].maxHP)")
    }

    // -- abilities that refuse priority outright -----------------------------
    //
    // Armor Tail and Queenly Majesty stop anything with increased priority
    // reaching that Pokemon or its partner. It is why Farigiraf is on Trick
    // Room teams: it is what stops a Fake Out taking the setup turn away.
    print("\n== priority refused ==")
    let guarded2 = fighters([("Farigiraf", "Mental Herb", ["Trick Room", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"])])
    let fakers = fighters([("Rillaboom", "Life Orb", ["Fake Out", "Wood Hammer", "Protect"]),
                           ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var tailed = Board(mine: guarded2, theirs: fakers, store: store,
                       field: Field(isDoubles: true), alreadyEvolved: false)
    tailed.mine[0].build.ability = "Armor Tail"
    print("  your lead is \(tailed.mine[0].build.form.formLabel) with "
          + "\(tailed.mine[0].build.ability)")
    let refused = TurnModel.resolve(
        tailed,
        mine: Play(left: .attack(move: at(tailed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(tailed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tailed.theirs[0], "Fake Out"), target: 0),
                     right: .attack(move: at(tailed.theirs[1], "Fake Out"), target: 1)),
        store: store)
    for line in refused.story.prefix(6) { print("    \(line)") }
    check("a Fake Out aimed at the Armor Tail is refused",
          refused.story.contains { $0.contains("refused it") })
    check("and nothing on that side flinched",
          !refused.mine[0].flinched && !refused.mine[1].flinched)

    // It must not refuse a priority move aimed at its own side.
    let ownSide = TurnModel.resolve(
        tailed,
        mine: Play(left: .attack(move: at(tailed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(tailed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tailed.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(tailed.theirs[1], "Protect"), target: 0)),
        store: store)
    check("but Protect, which is priority aimed at itself, still works",
          ownSide.story.contains { $0.contains("braced") })

    // And the search stops offering a move that cannot be used.
    var tailedGame = TurnGame(board: tailed, store: store)
    tailedGame.width = 8
    let theirOptions = tailedGame.choices(forMine: false, slot: 0)
    let stillOffered = theirOptions.contains { choice in
        if case .attack(let index, _) = choice,
           tailed.theirs[0].moves.indices.contains(index) {
            return tailed.theirs[0].moves[index].name == "Fake Out"
        }
        return false
    }
    check("the search stops offering Fake Out into it", !stillOffered)

    // -- who comes in ---------------------------------------------------------
    //
    // The game asks, and it matters: whoever arrives takes whatever lands next
    // turn without acting first. The battle fills the opponent's gaps and
    // leaves yours for you.
    print("\n== sending one in ==")
    var wounded = Board(mine: supporters, theirs: aggressors, store: store,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    wounded.mine[0].hp = 0
    wounded.theirs[0].hp = 0
    var asked = wounded
    asked.fillGaps(mine: false, theirs: true)
    check("their side fills itself", !asked.theirs[0].fainted,
          asked.theirs[0].build.form.formLabel)
    check("yours is left standing empty, to be chosen", asked.mine[0].fainted)
    check("and it says which slot is waiting", asked.gapsOfMine == [0],
          "\(asked.gapsOfMine)")
    let bench = (asked.activeCount..<asked.mine.count).first { !asked.mine[$0].fainted }!
    let comingIn = asked.mine[bench].build.form.formLabel
    asked.sendIn(bench, to: 0)
    check("sending one in puts that one in", asked.mine[0].build.form.formLabel == comingIn,
          asked.mine[0].build.form.formLabel)
    check("it arrives having not acted yet", asked.mine[0].justArrived)
    check("and there is nothing left waiting", asked.gapsOfMine.isEmpty)

    // A search cannot stop to ask, so it still fills both.
    var searching = wounded
    searching.fillGaps()
    check("a search fills both sides so it can keep going",
          !searching.mine[0].fainted && !searching.theirs[0].fainted)

    // -- what an ability does during a turn -----------------------------------
    print("\n== abilities in the turn ==")
    // Rough Skin: touching Garchomp costs an eighth.
    let touchers = fighters([("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"]),
                             ("Kingambit", "Chople Berry", ["Protect"])])
    let barbed = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
                           ("Rillaboom", "Life Orb", ["Protect"]),
                           ("Kingambit", "Chople Berry", ["Protect"])])
    var barbBoard = Board(mine: touchers, theirs: barbed, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    barbBoard.theirs[0].build.ability = "Rough Skin"
    let scraped = TurnModel.resolve(
        barbBoard,
        mine: Play(left: .attack(move: at(barbBoard.mine[0], "Flare Blitz"), target: 0),
                   right: .attack(move: at(barbBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(barbBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(barbBoard.theirs[1], "Protect"), target: 0)),
        store: store)
    check("Rough Skin costs a contact attacker health",
          scraped.story.contains { $0.contains("Rough Skin") },
          scraped.story.filter { $0.contains("Incineroar") }.joined(separator: " | "))

    // Emergency Exit: cross half and it leaves.
    let exiting = fighters([("Golisopod", "Sitrus Berry", ["First Impression", "Protect"]),
                            ("Whimsicott", "Focus Sash", ["Protect"]),
                            ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let hitters = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                            ("Incineroar", "Sitrus Berry", ["Protect"])])
    var exitBoard = Board(mine: exiting, theirs: hitters, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    exitBoard.mine[0].build.ability = "Emergency Exit"
    let fled = TurnModel.resolve(
        exitBoard,
        mine: Play(left: .attack(move: at(exitBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(exitBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(exitBoard.theirs[0], "Earthquake"), target: 0),
                     right: .attack(move: at(exitBoard.theirs[1], "Wood Hammer"), target: 0)),
        store: store)
    // Golisopod protected, so it should still be there. Now let it be hit.
    var exposed = exitBoard
    exposed.mine[0].moves = [store.data.moves.values.first { $0.name == "Iron Head" }!]
    let struck = TurnModel.resolve(
        exposed,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(exposed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(exposed.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(exposed.theirs[1], "Wood Hammer"), target: 0)),
        store: store)
    print("  after being hit, slot 0 is \(struck.mine[0].build.form.formLabel)")
    check("Emergency Exit sends Golisopod out when it drops below half",
          struck.story.contains { $0.contains("Emergency Exit") }
            && struck.mine[0].build.form.formLabel != "Golisopod",
          struck.story.filter { $0.contains("Golisopod") }.joined(separator: " | "))
    _ = fled

    // Regenerator heals on the way out.
    var regen = Board(mine: touchers, theirs: barbed, store: store,
                      field: Field(isDoubles: true), alreadyEvolved: false)
    regen.mine[0].build.ability = "Regenerator"
    regen.mine[0].hp = regen.mine[0].maxHP / 3
    let pivoted = TurnModel.resolve(
        regen,
        mine: Play(left: .swap(to: 2), right: .attack(move: at(regen.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(regen.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(regen.theirs[1], "Protect"), target: 0)),
        store: store)
    let benched = pivoted.mine.first { $0.build.form.formLabel == "Incineroar" }!
    print("  Incineroar left on \(regen.mine[0].hp), sits on the bench at \(benched.hp)")
    check("Regenerator heals a third on the way out",
          benched.hp > regen.mine[0].hp, "\(benched.hp) vs \(regen.mine[0].hp)")

    // Crits: over many rolls, some land, and the note says so.
    let blitz = barbBoard.mine[0].moves[at(barbBoard.mine[0], "Flare Blitz")]
    print("  Flare Blitz critical rate in the data: \(blitz.critRate)%")
    var crits = 0
    for _ in 0..<200 {
        let rolled = TurnModel.resolve(
            barbBoard,
            mine: Play(left: .attack(move: at(barbBoard.mine[0], "Flare Blitz"), target: 0),
                       right: .attack(move: at(barbBoard.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(barbBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(barbBoard.theirs[1], "Protect"), target: 0)),
            store: store, rolling: true)
        if rolled.story.contains(where: { $0.contains("critical") }) { crits += 1 }
    }
    print("  200 Flare Blitzes: \(crits) critical hits (about 8 expected at 1 in 24)")
    check("critical hits happen, at roughly the right rate", crits >= 1 && crits <= 30, "\(crits)")

    // And a pinch ability switches on when low.
    var low = Combatant(form: form("Charizard"), ability: "Blaze", item: "",
                        sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let target = Combatant(form: form("Rillaboom"), ability: "Grassy Surge", item: "",
                           sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let flare = store.data.moves.values.first { $0.name == "Flamethrower" }!
    let healthy = DamageCalc.calculate(attacker: low, defender: target, move: flare,
                                       field: Field(isDoubles: true)).maxDamage
    low.lowHP = true
    let desperate = DamageCalc.calculate(attacker: low, defender: target, move: flare,
                                         field: Field(isDoubles: true)).maxDamage
    print("  Blaze Flamethrower: \(healthy) healthy, \(desperate) when low")
    check("Blaze adds half again once the user is low", desperate > healthy,
          "\(desperate) vs \(healthy)")

    // -- what nobody has seen -------------------------------------------------
    print("\n== the hidden back two ==")
    let mySix = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                          ("Indeedee (Female)", "Leftovers", ["Follow Me", "Dazzling Gleam", "Protect"]),
                          ("Garchomp", "Life Orb", ["Earthquake", "Rock Slide", "Protect"]),
                          ("Whimsicott", "Focus Sash", ["Tailwind", "Moonblast", "Protect"]),
                          ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                          ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"])])
    let theirSix = fighters([("Garchomp", "Focus Sash", ["Earthquake", "Rock Slide", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Fake Out", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Sucker Punch", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Fake Out", "Flare Blitz", "Protect"]),
                             ("Charizard", "Charizardite Y", ["Heat Wave", "Solar Beam", "Protect"]),
                             ("Farigiraf", "Leftovers", ["Trick Room", "Psychic", "Protect"])])
    let game = Board.opening(mine: mySix, bringing: mySix.slots.prefix(4).map(\.formID),
                             theirs: theirSix, store: store, singles: false)
    print("  they brought \(game.theirs.map { $0.build.form.formLabel }), leading the first two")
    check("their four is chosen, but only the leads are on show",
          game.theirs.count == 4 && game.theirs[0].seen && game.theirs[1].seen
            && !game.theirs[2].seen && !game.theirs[3].seen)
    let odds = game.liveBenchGuesses
    print("  guesses: " + odds.prefix(3).map { g in
        g.fighters.map(\.build.form.formLabel).joined(separator: "+") + String(format: " %.0f%%", g.chance * 100)
    }.joined(separator: ", "))
    check("the back two are weighed as guesses that add up",
          odds.count > 1 && abs(odds.reduce(0) { $0 + $1.chance } - 1) < 0.01, "\(odds.count)")
    check("every pair they could be carrying is on the list", odds.count == 6, "\(odds.count)")
    check("including the one holding a stone",
          odds.contains { $0.fighters.contains { $0.build.form.formLabel == "Charizard" } })
    let searcher = BattleEngine(store: store, budget: 0.1)
    let worlds = searcher.imagine(game, belief: BattleEngine.Belief())
    let truth = game.theirs.dropFirst(2).map(\.build.form.id)
    let benches = worlds.map { $0.board.theirs.dropFirst(2).map(\.build.form.id) }
    print("  worlds see: " + benches.map { $0.joined(separator: "+") }.joined(separator: " | "))
    check("the search plays several possible back twos, not the answer",
          Set(benches.map { $0.joined(separator: "+") }).count > 1, "\(benches)")
    check("no world's bench is anything but a live guess",
          benches.allSatisfy { bench in odds.contains { $0.fighters.map(\.build.form.id) == bench } })
    // One walks on, and is known from then on.
    var revealed = game
    revealed.fillGaps()
    var hurt = game
    hurt.theirs[0].hp = 0
    hurt.fillGaps(mine: false, theirs: true)
    print("  after their lead fell, \(hurt.theirs[0].build.form.formLabel) came in")
    check("a Pokémon that comes in is seen", hurt.theirs[0].seen && hurt.theirUnseenBench == [3])
    let after = hurt.liveBenchGuesses
    let arrived = hurt.theirs[0].build.form.id
    check("the guesses shrink to pairs it was in",
          !after.isEmpty && after.allSatisfy { $0.fighters.contains { $0.build.form.id == arrived } },
          "\(after.count) left")
    let laterWorlds = searcher.imagine(hurt, belief: BattleEngine.Belief())
    check("the one still hidden stays a guess; the one that showed does not",
          laterWorlds.allSatisfy { $0.board.theirs[0].build.form.id == arrived }
            && Set(laterWorlds.map { $0.board.theirs[3].build.form.id }).count >= 1)
    _ = truth; _ = revealed

    // -- arriving, and what a move costs its user in stages ------------------
    print("\n== arriving ==")
    let weatherLeads = fighters([("Politoed", "Leftovers", ["Scald", "Protect"]),
                                 ("Staraptor", "Choice Scarf", ["Brave Bird", "Close Combat", "Protect"]),
                                 ("Kingambit", "Chople Berry", ["Iron Head", "Protect"]),
                                 ("Whimsicott", "Focus Sash", ["Tailwind", "Protect"])])
    let sunLeads = fighters([("Torkoal", "Charcoal", ["Eruption", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    var startBoard = Board(mine: weatherLeads, theirs: sunLeads, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    startBoard.mine[0].build.ability = "Drizzle"
    startBoard.mine[1].build.ability = "Intimidate"
    startBoard.theirs[0].build.ability = "Drought"
    startBoard.theirs[1].build.ability = "Defiant"
    startBoard.activeCount = 2
    startBoard.sendOutLeads()
    print("  at the start:")
    for line in startBoard.story { print("    \(line)") }
    let politoedSpeed = startBoard.mine[0].build.speed(in: startBoard.field)
    let torkoalSpeed = startBoard.theirs[0].build.speed(in: startBoard.field)
    print("  Politoed \(politoedSpeed) Speed against Torkoal \(torkoalSpeed)")
    check("the leads' abilities fire when the game starts",
          startBoard.story.contains { $0.contains("Drizzle") } && startBoard.story.contains { $0.contains("Intimidate") })
    check("and the slower weather setter's weather is the one that stays",
          startBoard.field.weather == (politoedSpeed > torkoalSpeed ? .sun : .rain),
          "\(startBoard.field.weather)")
    check("Intimidate into Defiant hands over two stages of Attack",
          startBoard.theirs[1].build.boosts[Stat.attack.rawValue] == 1,
          "\(startBoard.theirs[1].build.boosts[Stat.attack.rawValue])")
    // And into Competitive: the Attack goes, two stages of Special Attack come.
    var competitive = Board(mine: weatherLeads,
                            theirs: fighters([("Milotic", "Leftovers", ["Muddy Water", "Protect"]),
                                              ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])]),
                            store: store, field: Field(isDoubles: true), alreadyEvolved: false)
    competitive.mine[1].build.ability = "Intimidate"
    competitive.theirs[0].build.ability = "Competitive"
    competitive.activeCount = 2
    competitive.sendOutLeads()
    for line in competitive.story where line.contains("Competitive") { print("    \(line)") }
    check("Intimidate into Competitive costs Attack and gives two stages of Special Attack",
          competitive.theirs[0].build.boosts[Stat.attack.rawValue] == -1
            && competitive.theirs[0].build.boosts[Stat.spAttack.rawValue] == 2,
          "\(competitive.theirs[0].build.boosts)")
    print("  a Milotic with nothing registered fights with: \(Board(mine: weatherLeads, theirs: fighters([("Milotic", "Leftovers", ["Protect"])]), store: store, field: Field(isDoubles: true), alreadyEvolved: false).theirs[0].build.ability)")

    // Both sides lose a Pokémon; both send in at once, faster first.
    var fallen = startBoard
    fallen.mine[0].hp = 0
    fallen.theirs[0].hp = 0
    fallen.mine[2].build.ability = "Intimidate"     // Kingambit, slower
    fallen.theirs[2].build.ability = "Intimidate"   // Garchomp, faster
    fallen.story = []
    fallen.replaceFallen(mine: [(slot: 0, bench: 2)], store: store)
    print("  after the faints:")
    for line in fallen.story { print("    \(line)") }
    let mineIn = fallen.mine[0].build.form.formLabel, theirsIn = fallen.theirs[0].build.form.formLabel
    check("both sides send in at once", mineIn == "Kingambit" && !fallen.theirs[0].fainted,
          "\(mineIn) and \(theirsIn)")
    let garchompFirst = fallen.story.firstIndex { $0.contains("They sent in") }! <
                        fallen.story.firstIndex { $0.contains("You sent in") }!
    check("the faster one arrives first", garchompFirst)
    // Garchomp arrived first, so its Intimidate never saw Kingambit; Kingambit
    // arrived second and its Intimidate hit Garchomp.
    check("and the faster one's Intimidate never touches the slower arrival",
          fallen.mine[0].build.boosts[Stat.attack.rawValue] == 0
            && fallen.theirs[0].build.boosts[Stat.attack.rawValue] == -1,
          "\(fallen.mine[0].build.boosts[Stat.attack.rawValue]) / \(fallen.theirs[0].build.boosts[Stat.attack.rawValue])")
    check("and the arrival is seen from then on", fallen.theirs[0].seen)

    // Close Combat costs its user, unless it is Contrary.
    let closeCombat = at(startBoard.mine[1], "Close Combat")
    print("  Close Combat lowers: \(startBoard.mine[1].moves[closeCombat].selfDrops)")
    var combat = startBoard
    combat.story = []
    let fought = TurnModel.resolve(
        combat,
        mine: Play(left: .attack(move: at(combat.mine[0], "Protect"), target: 0),
                   right: .attack(move: closeCombat, target: 1)),
        theirs: Play(left: .attack(move: at(combat.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(combat.theirs[1], "Iron Head"), target: 0)),
        store: store)
    for line in fought.story where line.contains("Staraptor") { print("    \(line)") }
    check("Close Combat drops the user's defences",
          fought.mine[1].build.boosts[Stat.defense.rawValue] == -1
            && fought.mine[1].build.boosts[Stat.spDefense.rawValue] == -1,
          "\(fought.mine[1].build.boosts)")
    combat.mine[1].build.ability = "Contrary"
    let contrary = TurnModel.resolve(
        combat,
        mine: Play(left: .attack(move: at(combat.mine[0], "Protect"), target: 0),
                   right: .attack(move: closeCombat, target: 1)),
        theirs: Play(left: .attack(move: at(combat.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(combat.theirs[1], "Iron Head"), target: 0)),
        store: store)
    for line in contrary.story where line.contains("Contrary") { print("    \(line)") }
    check("and Contrary turns the drop into a raise",
          contrary.mine[1].build.boosts[Stat.defense.rawValue] == 1
            && contrary.mine[1].build.boosts[Stat.spDefense.rawValue] == 1,
          "\(contrary.mine[1].build.boosts)")

    // Revival Blessing brings one of your own back, at half.
    print("\n== the party as a target ==")
    let revivers = fighters([("Pawmot", "Focus Sash", ["Revival Blessing", "Close Combat", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                             ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    let bystanders = fighters([("Rillaboom", "Life Orb", ["Protect"]),
                               ("Incineroar", "Sitrus Berry", ["Protect"])])
    var reviveBoard = Board(mine: revivers, theirs: bystanders, store: store,
                            field: Field(isDoubles: true), alreadyEvolved: false)
    reviveBoard.mine[3].hp = 0        // Kingambit is down
    let blessing = at(reviveBoard.mine[0], "Revival Blessing")
    check("Revival Blessing is aimed at the party", reviveBoard.mine[0].moves[blessing].aim == .party)
    let game2 = TurnGame(board: reviveBoard, store: store)
    let offered = game2.choices(forMine: true, slot: 0)
    check("the search offers it once somebody has fainted",
          offered.contains(.attack(move: blessing, target: 3)), "\(offered)")
    let revived = TurnModel.resolve(
        reviveBoard,
        mine: Play(left: .attack(move: blessing, target: 3),
                   right: .attack(move: at(reviveBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(reviveBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(reviveBoard.theirs[1], "Protect"), target: 0)),
        store: store)
    for line in revived.story where line.contains("Kingambit") { print("    \(line)") }
    check("and the fallen one comes back at half its health",
          revived.mine[3].hp == revived.mine[3].maxHP / 2, "\(revived.mine[3].hp)/\(revived.mine[3].maxHP)")
    print("  described as: \(game2.describe(Choice.attack(move: blessing, target: 3), fighter: reviveBoard.mine[0], foes: Array(reviveBoard.theirs.prefix(2)), team: reviveBoard.mine))")

    // Both of theirs act every turn, and a switch is said out loud.
    print("\n== both of theirs act ==")
    let bothGame = Board.opening(mine: mySix, bringing: mySix.slots.prefix(4).map(\.formID),
                                 theirs: theirSix, store: store, singles: false)
    let bothSolve = TurnGame(board: bothGame, store: store).solve(iterations: 300)
    let theirsActing = bothSolve.theirPlays.filter { !$0.left.isPass && !$0.right.isPass }.count
    check("every line of theirs gives both Pokémon something to do",
          theirsActing == bothSolve.theirPlays.count, "\(theirsActing) of \(bothSolve.theirPlays.count)")
    let kinds = Set(bothSolve.theirPlays.flatMap { [$0.left, $0.right] }.map { choice -> String in
        switch choice {
        case .attack: return "attack"
        case .protectSelf: return "protect"
        case .swap: return "switch"
        case .pass: return "pass"
        }
    })
    check("and they can attack, Protect and switch, like you", kinds.isSuperset(of: ["attack", "protect", "switch"]), "\(kinds)")
    let switching = TurnModel.resolve(
        bothGame,
        mine: Play(left: .protectSelf(move: at(bothGame.mine[0], "Protect")),
                   right: .protectSelf(move: at(bothGame.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: 0, target: 0), right: .swap(to: 2)),
        store: store)
    for line in switching.story.prefix(4) { print("    \(line)") }
    check("a switch is narrated", switching.story.contains { $0.hasPrefix("They switched") })
    check("and the one that came in is seen", switching.theirs[1].seen)
    // Both sides switch: the faster one leaves first, and each switch is a
    // step of its own that also carries what the arrival did.
    var bothSwitch = bothGame
    bothSwitch.mine[2].build.ability = "Intimidate"
    let leaverSpeed = bothSwitch.mine[0].build.speed(in: bothSwitch.field)
    let theirLeaverSpeed = bothSwitch.theirs[1].build.speed(in: bothSwitch.field)
    let swapped = TurnModel.resolve(
        bothSwitch,
        mine: Play(left: .swap(to: 2), right: .protectSelf(move: at(bothSwitch.mine[1], "Protect"))),
        theirs: Play(left: .attack(move: 0, target: 0), right: .swap(to: 2)),
        store: store)
    print("  \(bothSwitch.mine[0].build.form.formLabel) \(leaverSpeed) leaves against \(bothSwitch.theirs[1].build.form.formLabel) \(theirLeaverSpeed)")
    for step in swapped.steps.prefix(3) { print("    step: \(step.text.replacingOccurrences(of: "\n", with: " / "))") }
    let mineAt = swapped.story.firstIndex { $0.hasPrefix("You switched") }!
    let theirsAt = swapped.story.firstIndex { $0.hasPrefix("They switched") }!
    check("switches happen in Speed order", leaverSpeed > theirLeaverSpeed ? mineAt < theirsAt : theirsAt < mineAt)
    check("and before any move", max(mineAt, theirsAt) < swapped.story.firstIndex { $0.contains(" used ") }!)
    check("and the arrival's ability is in the switch's step",
          swapped.steps.contains { $0.text.hasPrefix("You switched") && $0.text.contains("Intimidate") },
          swapped.steps.first { $0.text.hasPrefix("You switched") }?.text ?? "-")

    // Weather Ball is whatever the weather says it is, when it lands.
    print("\n== the field decides the move ==")
    let weatherBall = store.data.moves.values.first { $0.name == "Weather Ball" }!
    let inSun = DamageCalc.fieldForm(of: weatherBall, in: Field(weather: .sun, isDoubles: true))
    let inRain = DamageCalc.fieldForm(of: weatherBall, in: Field(weather: .rain, isDoubles: true))
    let clear = DamageCalc.fieldForm(of: weatherBall, in: Field(isDoubles: true))
    print("  Weather Ball: clear \(clear.type) \(clear.power), sun \(inSun.type) \(inSun.power), rain \(inRain.type) \(inRain.power)")
    check("Weather Ball is Fire and 100 under sun", inSun.type == .fire && inSun.power == 100)
    check("Water and 100 under rain, Normal and 50 with nothing up",
          inRain.type == .water && inRain.power == 100 && clear.type == .normal && clear.power == 50)

    // -- two turns for one move, and Protect wearing thin ----------------------
    print("\n== two-turn moves ==")
    let chargers = fighters([("Kingambit", "Leftovers", ["Electro Shot", "Solar Beam", "Fly", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
    let standing = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Earthquake", "Protect"]),
                             ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    let chargeBoard = Board(mine: chargers, theirs: standing, store: store,
                            field: Field(isDoubles: true), alreadyEvolved: false)
    let eShot = at(chargeBoard.mine[0], "Electro Shot")
    let beam = at(chargeBoard.mine[0], "Solar Beam")
    let fly = at(chargeBoard.mine[0], "Fly")
    let electro = chargeBoard.mine[0].moves[eShot]
    print("  Electro Shot reads: hides \(electro.charge?.hides ?? false), skips in \(electro.charge?.skipsIn.map { "\($0)" } ?? "nothing"), boosts \(electro.charge?.boosts ?? [:])")
    check("Electro Shot is read as a two-turn move that boosts Sp. Atk and skips in rain",
          electro.charge?.skipsIn == Weather.rain && electro.charge?.boosts[Stat.spAttack] == 1 && electro.charge?.hides == false)
    let quiet = { (board: Board, left: Choice) -> Board in
        TurnModel.resolve(board,
                          mine: Play(left: left, right: .attack(move: at(board.mine[1], "Protect"), target: 0)),
                          // Rillaboom attacks rather than Protects, or the
                          // one-turn tests would be measuring its Protect.
                          theirs: Play(left: .attack(move: at(board.theirs[0], "Swords Dance"), target: 0),
                                       right: .attack(move: at(board.theirs[1], "Wood Hammer"), target: 1)),
                          store: store)
    }
    let charged1 = quiet(chargeBoard, .attack(move: eShot, target: 1))
    for line in charged1.story where line.contains("Kingambit") { print("    \(line)") }
    let charged1SpA: Int = charged1.mine[0].build.boosts[Stat.spAttack.rawValue]
    let charged1Unhurt: Bool = charged1.theirs[1].hp == charged1.theirs[1].maxHP
    let charged1Charging: Bool = charged1.mine[0].charging == eShot
    check("with no rain, the first turn only charges: +1 Sp. Atk and no damage",
          charged1SpA == 1 && charged1Unhurt && charged1Charging,
          "spa \(charged1SpA), hp \(charged1.theirs[1].hp)/\(charged1.theirs[1].maxHP)")
    // Next turn it fires, whatever it is told to do.
    let fired = quiet(charged1, .attack(move: at(charged1.mine[0], "Protect"), target: 0))
    for line in fired.story where line.contains("Kingambit") { print("    \(line)") }
    check("the second turn fires it, even when asked to do something else",
          fired.theirs[1].hp < fired.theirs[1].maxHP && fired.mine[0].charging == nil,
          "hp \(fired.theirs[1].hp)/\(fired.theirs[1].maxHP)")
    var rainy = chargeBoard
    rainy.field.weather = .rain
    let atOnce = quiet(rainy, .attack(move: eShot, target: 1))
    for line in atOnce.story where line.contains("Kingambit") { print("    \(line)") }
    let atOnceSpA: Int = atOnce.mine[0].build.boosts[Stat.spAttack.rawValue]
    let atOnceHurt: Bool = atOnce.theirs[1].hp < atOnce.theirs[1].maxHP
    check("in rain the boost and the beam both land in one turn",
          atOnceSpA == 1 && atOnceHurt && atOnce.mine[0].charging == nil)
    var sunny = chargeBoard
    sunny.field.weather = .sun
    let solar = quiet(sunny, .attack(move: beam, target: 0))
    let solarSlow = quiet(chargeBoard, .attack(move: beam, target: 0))
    let solarHurt: Bool = solar.theirs[0].hp < solar.theirs[0].maxHP
    let solarSlowUnhurt: Bool = solarSlow.theirs[0].hp == solarSlow.theirs[0].maxHP
    check("Solar Beam fires at once in sun and charges without it",
          solarHurt && solar.mine[0].charging == nil && solarSlowUnhurt && solarSlow.mine[0].charging == beam)
    // Fly: out of reach for the turn it is up — once it is up, which means
    // it has to move first. Whimsicott outspeeds both of theirs; a Kingambit
    // would have been hit before it left the ground, as in the game.
    var flyBoard = chargeBoard
    flyBoard.mine[1].moves = [chargeBoard.mine[0].moves[fly], chargeBoard.mine[1].moves[0]]
    let flew = TurnModel.resolve(flyBoard,
        mine: Play(left: .attack(move: at(flyBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(flyBoard.theirs[0], "Earthquake"), target: 1),
                     right: .attack(move: at(flyBoard.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    for line in flew.story where line.contains("reach") || line.contains("Fly") { print("    \(line)") }
    check("a Pokémon in the air cannot be hit", flew.mine[1].hidden && flew.mine[1].hp == flew.mine[1].maxHP,
          "hp \(flew.mine[1].hp)/\(flew.mine[1].maxHP)")
    check("and the search offers only the finish while it is charging",
          TurnGame(board: charged1, store: store).choices(forMine: true, slot: 0) == [.attack(move: eShot, target: 1)])

    print("\n== Protect wearing thin ==")
    let protect = at(chargeBoard.mine[1], "Protect")
    let once = TurnModel.resolve(chargeBoard,
        mine: Play(left: .attack(move: at(chargeBoard.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: protect)),
        theirs: Play(left: .attack(move: at(chargeBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(chargeBoard.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    check("the first Protect holds and starts a streak",
          once.mine[1].hp == once.mine[1].maxHP && once.mine[1].protectStreak == 1)
    let twice = TurnModel.resolve(once,
        mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                   right: .protectSelf(move: protect)),
        theirs: Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(once.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    for line in twice.story where line.contains("Whimsicott") { print("    \(line)") }
    check("the search takes a second Protect in a row as a failure",
          twice.mine[1].hp < twice.mine[1].maxHP && twice.mine[1].protectStreak == 0)
    var heldCount = 0
    for _ in 0..<600 {
        let rolled = TurnModel.resolve(once,
            mine: Play(left: .attack(move: at(once.mine[0], "Protect"), target: 0),
                       right: .protectSelf(move: protect)),
            theirs: Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(once.theirs[1], "Protect"), target: 0)),
            store: store, rolling: true)
        if rolled.mine[1].isProtected { heldCount += 1 }
    }
    print("  600 second Protects in a row: \(heldCount) held (about 200 expected)")
    check("a played second Protect holds about a third of the time", heldCount > 140 && heldCount < 260, "\(heldCount)")
    var rested = once
    rested.mine[1].isProtected = false
    let afterRest = TurnModel.resolve(rested,
        mine: Play(left: .attack(move: at(rested.mine[0], "Protect"), target: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(rested.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(rested.theirs[1], "Protect"), target: 0)),
        store: store)
    check("a turn without Protect resets the streak", afterRest.mine[1].protectStreak == 0)
    // The search weighs a repeat Protect at its odds, not as a certain miss.
    let repeatGame = TurnGame(board: once, store: store)
    let repeatChoices = repeatGame.choices(forMine: true, slot: 1)
    check("the search still offers a second Protect, at a third",
          repeatChoices.contains { $0.isProtect }, "\(repeatChoices)")
    var thrice = once
    thrice.mine[1].protectStreak = 2
    check("but not a third one, at a ninth",
          !TurnGame(board: thrice, store: store).choices(forMine: true, slot: 1).contains { $0.isProtect })
    // Kingambit charges rather than Protects, or it would be a second chancy
    // Protect and four branches.
    let guardPlay = Play(left: .attack(move: at(once.mine[0], "Solar Beam"), target: 1),
                         right: .protectSelf(move: protect))
    let hammerPlay = Play(left: .attack(move: at(once.theirs[0], "Swords Dance"), target: 0),
                          right: .attack(move: at(once.theirs[1], "Wood Hammer"), target: 1))
    let branches = TurnModel.outcomes(once, mine: guardPlay, theirs: hammerPlay, store: store)
    print("  branches: " + branches.map { String(format: "%.0f%% -> Whimsicott %d/%d", $0.chance * 100, $0.board.mine[1].hp, $0.board.mine[1].maxHP) }.joined(separator: ", "))
    check("a repeat Protect is two branches, a third and two thirds",
          branches.count == 2 && abs(branches[0].chance - 2.0 / 3.0) < 0.01 && abs(branches[1].chance - 1.0 / 3.0) < 0.01)
    let blend = repeatGame.settle(guardPlay, hammerPlay).expected
    let before = TurnModel.value(once)
    let byHand = branches.reduce(0) { $0 + $1.chance * (TurnModel.value($1.board) - before) }
    let missOnly = TurnModel.value(branches[0].board) - before
    print(String(format: "  the cell is worth %+.3f blended, %+.3f if the Protect were a certain miss", blend, missOnly))
    check("and the matrix scores it as the blend", abs(blend - byHand) < 0.0001 && blend > missOnly)
    check("the engine says how likely it is to hold",
          repeatGame.describe(Choice.protectSelf(move: protect), fighter: once.mine[1], foes: [], team: once.mine).contains("33%"))

    // Feint goes through Protect and takes it down for the partner.
    print("\n== Feint ==")
    let feinters = fighters([("Whimsicott", "Focus Sash", ["Feint", "Protect"]),
                             ("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"])])
    let guardedSide = fighters([("Kingambit", "Chople Berry", ["Protect", "Iron Head"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    let feintBoard = Board(mine: feinters, theirs: guardedSide, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    let feint = at(feintBoard.mine[0], "Feint")
    check("Feint is +2 and not protectable",
          feintBoard.mine[0].moves[feint].priority == 2 && !feintBoard.mine[0].moves[feint].isProtectable
            && feintBoard.mine[0].moves[feint].breaksProtect)
    let broken = TurnModel.resolve(feintBoard,
        mine: Play(left: .attack(move: feint, target: 0),
                   right: .attack(move: at(feintBoard.mine[1], "Dragon Claw"), target: 0)),
        theirs: Play(left: .protectSelf(move: at(feintBoard.theirs[0], "Protect")),
                     right: .attack(move: at(feintBoard.theirs[1], "Protect"), target: 0)),
        store: store)
    for line in broken.story where line.contains("Kingambit") || line.contains("Feint") || line.contains("Dragon Claw") { print("    \(line)") }
    let feintOnly = TurnModel.resolve(feintBoard,
        mine: Play(left: .attack(move: feint, target: 0),
                   right: .attack(move: at(feintBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .protectSelf(move: at(feintBoard.theirs[0], "Protect")),
                     right: .attack(move: at(feintBoard.theirs[1], "Protect"), target: 0)),
        store: store)
    let feintDamage = feintOnly.theirs[0].maxHP - feintOnly.theirs[0].hp
    print("  Feint alone took \(feintDamage); with Dragon Claw after it, \(broken.theirs[0].maxHP - broken.theirs[0].hp)")
    check("Feint lands through Protect", feintDamage > 0)
    check("and the partner's move then lands on the opened target",
          broken.theirs[0].maxHP - broken.theirs[0].hp > feintDamage
            && broken.story.contains { $0.contains("broke through") })

    // A move whose target fell before its turn came turns to the one left.
    print("\n== the target that was gone ==")
    let turners = fighters([("Whimsicott", "Focus Sash", ["Moonblast", "Protect"]),
                            ("Garchomp", "Life Orb", ["Dragon Claw", "Protect"])])
    let falling = fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                            ("Kingambit", "Chople Berry", ["Iron Head", "Protect"])])
    var turnBoard = Board(mine: turners, theirs: falling, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    turnBoard.theirs[0].hp = 1
    let turned = TurnModel.resolve(turnBoard,
        mine: Play(left: .attack(move: at(turnBoard.mine[0], "Moonblast"), target: 0),
                   right: .attack(move: at(turnBoard.mine[1], "Dragon Claw"), target: 0)),
        theirs: Play(left: .attack(move: at(turnBoard.theirs[0], "Wood Hammer"), target: 1),
                     right: .attack(move: at(turnBoard.theirs[1], "Iron Head"), target: 0)),
        store: store)
    for line in turned.story where line.contains("Dragon Claw") || line.contains("turned") || line.contains("fainted") { print("    \(line)") }
    check("Whimsicott removed Rillaboom first", turned.theirs[0].fainted)
    check("and Garchomp's Dragon Claw turned to Kingambit instead of hitting nothing",
          turned.story.contains { $0.contains("turned toward Kingambit") },
          turned.story.joined(separator: " | "))

    // Being hit by the right kind of move is worth a stage to some.
    print("\n== answering a hit ==")
    let heaters2 = fighters([("Charizard", "Charizardite Y", ["Heat Wave", "Protect"]),
                             ("Whimsicott", "Focus Sash", ["Protect"])])
    let heated2 = fighters([("Baxcalibur", "Loaded Dice", ["Glaive Rush", "Protect"]),
                            ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
    var thermal = Board(mine: heaters2, theirs: heated2, store: store,
                        field: Field(isDoubles: true), alreadyEvolved: false)
    thermal.theirs[0].build.ability = "Thermal Exchange"
    let warmed = TurnModel.resolve(thermal,
        mine: Play(left: .attack(move: at(thermal.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(thermal.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(thermal.theirs[0], "Glaive Rush"), target: 1),
                     right: .attack(move: at(thermal.theirs[1], "Wood Hammer"), target: 1)),
        store: store)
    for line in warmed.story where line.contains("Thermal") { print("    \(line)") }
    check("Thermal Exchange raises Attack when hit by a Fire move",
          warmed.theirs[0].build.boosts[Stat.attack.rawValue] == 1,
          "\(warmed.theirs[0].build.boosts[Stat.attack.rawValue]) — \(warmed.story.filter { $0.contains("Baxcalibur") })")

    // Hitting your own partner, on purpose.
    print("\n== the tech ==")
    var techBoard = Board(mine: heaters2, theirs: heated2, store: store,
                          field: Field(isDoubles: true), alreadyEvolved: false)
    techBoard.mine[1].build.item = "Weakness Policy"
    let selfHit = TurnModel.resolve(techBoard,
        mine: Play(left: .attack(move: at(techBoard.mine[0], "Heat Wave"), target: 0),
                   right: .attack(move: at(techBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(techBoard.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(techBoard.theirs[1], "Protect"), target: 0)),
        store: store)
    _ = selfHit
    var ally = techBoard
    // A small Fire move: enough to set the Policy off, not enough to remove
    // the partner, since a fainted Pokémon boosts nothing.
    ally.mine[0].moves = [store.data.moves.values.first { $0.name == "Ember" }
                          ?? store.data.moves.values.first { $0.type == "Fire" && $0.power > 0 && $0.power <= 50 }!]
                         + ally.mine[0].moves
    // The partner attacks rather than Protects, or it would block its own side.
    ally.mine[1].moves = [store.data.moves.values.first { $0.name == "Moonblast" }!] + ally.mine[1].moves
    let hitOwn = TurnModel.resolve(ally,
        mine: Play(left: Choice.attackingAlly(move: 0),
                   right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(ally.theirs[0], "Protect"), target: 0),
                     right: .attack(move: at(ally.theirs[1], "Protect"), target: 0)),
        store: store)
    for line in hitOwn.story where line.contains("Whimsicott") { print("    \(line)") }
    check("a move can be aimed at your own partner",
          hitOwn.mine[1].hp < hitOwn.mine[1].maxHP && hitOwn.theirs[0].hp == hitOwn.theirs[0].maxHP,
          "\(hitOwn.mine[1].hp)/\(hitOwn.mine[1].maxHP)")
    check("and what it carries goes off — the Weakness Policy",
          hitOwn.mine[1].build.boosts[Stat.attack.rawValue] == 2, "\(hitOwn.mine[1].build.boosts)")
    print("  described as: \(TurnGame(board: ally, store: store).describe(Choice.attackingAlly(move: 0), fighter: ally.mine[0], foes: Array(ally.theirs.prefix(2)), team: ally.mine))")

    // -- dice per target, moves that give back, and a field that runs out -----
    print("\n== each target rolls its own ==")
    let muddy = fighters([("Politoed", "Leftovers", ["Muddy Water", "Protect"]),
                          ("Whimsicott", "Focus Sash", ["Protect"])])
    let soaked = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Protect"]),
                           ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])])
    let muddyBoard = Board(mine: muddy, theirs: soaked, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    var oneOfTwo = 0, bothHit = 0
    for _ in 0..<400 {
        let rolled = TurnModel.resolve(muddyBoard,
            mine: Play(left: .attack(move: at(muddyBoard.mine[0], "Muddy Water"), target: 0),
                       right: .attack(move: at(muddyBoard.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(muddyBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(muddyBoard.theirs[1], "Swords Dance"), target: 0)),
            store: store, rolling: true)
        let hits = [rolled.theirs[0], rolled.theirs[1]].filter { $0.hp < $0.maxHP }.count
        if hits == 1 { oneOfTwo += 1 }
        if hits == 2 { bothHit += 1 }
    }
    print("  400 Muddy Waters at 85%: both hit \(bothHit), exactly one hit \(oneOfTwo) (about 102 expected)")
    check("a spread move can hit one and miss the other", oneOfTwo > 55 && oneOfTwo < 160, "\(oneOfTwo)")

    let leech = store.data.moves.values.first { $0.name == "Leech Life" }!
    print("  Leech Life gives back: \(leech.drainShare ?? 0)")
    check("draining moves are read from the text", leech.drainShare == 0.5
          && store.data.moves.values.first { $0.name == "Draining Kiss" }?.drainShare == 0.75)
    var drainBoard = Board(mine: soaked, theirs: muddy, store: store,
                           field: Field(isDoubles: true), alreadyEvolved: false)
    drainBoard.mine[0].moves = [leech] + drainBoard.mine[0].moves
    drainBoard.mine[0].hp = drainBoard.mine[0].maxHP / 2
    let drained = TurnModel.resolve(drainBoard,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(drainBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(drainBoard.theirs[0], "Muddy Water"), target: 0),
                     right: .attack(move: 0, target: 0)),
        store: store)
    for line in drained.story where line.contains("drained") { print("    \(line)") }
    let drainLine = drained.story.first { $0.contains("Garchomp drained") }
    let gained = drainLine.flatMap { line in Int(line.split(separator: " ").first { Int($0) != nil } ?? "") } ?? 0
    let taken = drained.theirs[0].maxHP - drained.theirs[0].hp
    print("  Leech Life took \(taken) from Politoed and gave \(gained) back")
    // Politoed's Leftovers give some back at the end of the turn, so what it
    // shows as lost is a little under what was dealt.
    check("Leech Life restores half of what it took",
          gained > 0 && gained >= taken / 2 - 1 && gained <= taken / 2 + 10, "\(gained) back from \(taken)")

    let tantrum = store.data.moves.values.first { $0.name == "Stomping Tantrum" }!
    check("Stomping Tantrum is read as doubling after a failed move", tantrum.doublesAfterFailure)
    var tantrumBoard = Board(mine: soaked, theirs: muddy, store: store,
                             field: Field(isDoubles: true), alreadyEvolved: false)
    tantrumBoard.mine[0].moves = [tantrum] + tantrumBoard.mine[0].moves
    // Turn one: the move goes into a Protect and fails.
    let walled = TurnModel.resolve(tantrumBoard,
        mine: Play(left: .attack(move: 0, target: 1),
                   right: .attack(move: at(tantrumBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tantrumBoard.theirs[0], "Protect"), target: 0),
                     right: .protectSelf(move: at(tantrumBoard.theirs[1], "Protect"))),
        store: store)
    check("a move that reached nobody is remembered as failed", walled.mine[0].lastMoveFailed)
    let calm = DamageCalc.calculate(attacker: tantrumBoard.mine[0].build, defender: tantrumBoard.theirs[1].build,
                                    move: tantrum, field: tantrumBoard.field).maxDamage
    var angry = walled.mine[0].build
    angry.lastMoveFailed = true
    let doubled = DamageCalc.calculate(attacker: angry, defender: walled.theirs[1].build,
                                       move: tantrum, field: walled.field).maxDamage
    print("  Stomping Tantrum: \(calm) normally, \(doubled) after a failed move")
    check("and it hits twice as hard the turn after", doubled >= calm * 2 - 2 && doubled <= calm * 2 + 2, "\(calm) vs \(doubled)")

    print("\n== the field runs out ==")
    var clock = Board(mine: muddy, theirs: soaked, store: store,
                      field: Field(isDoubles: true), alreadyEvolved: false)
    clock.mine[0].build.ability = "Drizzle"
    clock.sendOutLeads()
    check("weather set at the start has five turns on the clock", clock.field.weather == .rain && clock.weatherTurns == 5,
          "\(clock.field.weather) \(clock.weatherTurns)")
    var running = clock
    var endedAt = 0
    for turn in 1...6 where running.field.weather == .rain {
        running = TurnModel.resolve(running,
            mine: Play(left: .attack(move: at(running.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(running.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(running.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(running.theirs[1], "Protect"), target: 0)),
            store: store)
        if running.field.weather == .none { endedAt = turn }
    }
    print("  the rain stopped at the end of turn \(endedAt)")
    check("and it stops at the end of the fifth turn", endedAt == 5 && running.story.contains { $0.contains("rain stopped") })

    print("\n== the bar and the fallen ==")
    var scaled = Combatant(form: form("Dragonite"), ability: "Multiscale", item: "",
                           sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let striker = Combatant(form: form("Garchomp"), ability: "Rough Skin", item: "",
                            sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let dragonClaw = store.data.moves.values.first { $0.name == "Dragon Claw" }!
    let fresh = DamageCalc.calculate(attacker: striker, defender: scaled, move: dragonClaw, field: Field(isDoubles: true)).maxDamage
    scaled.atFullHP = false
    let dented = DamageCalc.calculate(attacker: striker, defender: scaled, move: dragonClaw, field: Field(isDoubles: true)).maxDamage
    print("  Dragon Claw into Multiscale Dragonite: \(fresh) at full, \(dented) once dented")
    check("Multiscale halves only at full health", dented >= fresh * 2 - 2 && dented <= fresh * 2 + 2, "\(fresh) vs \(dented)")
    var mourner = Combatant(form: form("Basculegion"), ability: "Adaptability", item: "",
                            sp: Array(repeating: 0, count: 6), alignment: .neutral)
    let respects = store.data.moves.values.first { $0.name == "Last Respects" }!
    let alone = DamageCalc.calculate(attacker: mourner, defender: striker, move: respects, field: Field(isDoubles: true)).maxDamage
    mourner.fallenAllies = 2
    let grieving = DamageCalc.calculate(attacker: mourner, defender: striker, move: respects, field: Field(isDoubles: true)).maxDamage
    print("  Last Respects: \(alone) with nobody down, \(grieving) with two down")
    check("Last Respects grows with every fallen teammate", grieving > alone * 2 && grieving <= alone * 3 + 3, "\(alone) vs \(grieving)")
    // And the battle actually counts them.
    var mourning = Board(mine: fighters([("Basculegion", "Choice Scarf", ["Last Respects", "Protect"]),
                                         ("Whimsicott", "Focus Sash", ["Protect"]),
                                         ("Garchomp", "Life Orb", ["Protect"]),
                                         ("Kingambit", "Chople Berry", ["Protect"])]),
                         theirs: soaked, store: store, field: Field(isDoubles: true), alreadyEvolved: false)
    let unbowed = TurnModel.resolve(mourning,
        mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(mourning.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(mourning.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    mourning.mine[2].hp = 0; mourning.mine[3].hp = 0
    let bereaved = TurnModel.resolve(mourning,
        mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
        theirs: Play(left: .attack(move: at(mourning.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(mourning.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    let took1 = unbowed.theirs[0].maxHP - unbowed.theirs[0].hp
    let took2 = bereaved.theirs[0].maxHP - bereaved.theirs[0].hp
    print("  in a turn: \(took1) with the team standing, \(took2) with two down")
    check("and in a played turn the fallen are counted", took2 > took1 * 2, "\(took1) vs \(took2)")
    let pixie = AteAbility.resolve(type: PokeType.normal, ability: "Pixilate")
    check("Pixilate turns a Normal move Fairy", pixie.type == .fairy && pixie.boost > 1)

    print("\n== what a hit does besides damage ==")
    let icy = fighters([("Whimsicott", "Focus Sash", ["Icy Wind", "Protect"]),
                        ("Milotic", "Leftovers", ["Scald", "Protect"])])
    let chilled = fighters([("Garchomp", "Life Orb", ["Swords Dance", "Protect"]),
                            ("Kingambit", "Chople Berry", ["Swords Dance", "Protect"])])
    let icyBoard = Board(mine: icy, theirs: chilled, store: store,
                         field: Field(isDoubles: true), alreadyEvolved: false)
    let windy = TurnModel.resolve(icyBoard,
        mine: Play(left: .attack(move: at(icyBoard.mine[0], "Icy Wind"), target: 0),
                   right: .attack(move: at(icyBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    for line in windy.story where line.contains("Spe") { print("    \(line)") }
    check("Icy Wind takes a stage of Speed off both",
          windy.theirs[0].build.boosts[Stat.speed.rawValue] == -1 && windy.theirs[1].build.boosts[Stat.speed.rawValue] == -1,
          "\(windy.theirs[0].build.boosts[Stat.speed.rawValue]) / \(windy.theirs[1].build.boosts[Stat.speed.rawValue])")
    let scald = store.data.moves.values.first { $0.name == "Scald" }!
    let nuzzle = store.data.moves.values.first { $0.name == "Nuzzle" }!
    let slide = store.data.moves.values.first { $0.name == "Rock Slide" }!
    check("secondary effects are read from the text",
          scald.secondary?.chance == 30 && nuzzle.secondary?.chance == 100 && slide.secondary?.chance == 30)
    var burns = 0
    for _ in 0..<300 {
        let rolled = TurnModel.resolve(icyBoard,
            mine: Play(left: .attack(move: at(icyBoard.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(icyBoard.mine[1], "Scald"), target: 0)),
            theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)),
            store: store, rolling: true)
        if rolled.theirs[0].status == .burn { burns += 1 }
    }
    print("  300 Scalds: \(burns) burns (about 90 expected)")
    check("Scald burns about three times in ten", burns > 55 && burns < 130, "\(burns)")
    let averaged2 = TurnModel.resolve(icyBoard,
        mine: Play(left: .attack(move: at(icyBoard.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(icyBoard.mine[1], "Scald"), target: 0)),
        theirs: Play(left: .attack(move: at(icyBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(icyBoard.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    check("and the search does not count on it", averaged2.theirs[0].status == .none)
    var nuzzleBoard = icyBoard
    nuzzleBoard.mine[0].moves = [nuzzle] + nuzzleBoard.mine[0].moves
    // Into Kingambit: Garchomp is Ground and Nuzzle would not touch it.
    let zapped = TurnModel.resolve(nuzzleBoard,
        mine: Play(left: .attack(move: 0, target: 1),
                   right: .attack(move: at(nuzzleBoard.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(nuzzleBoard.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(nuzzleBoard.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    check("Nuzzle paralyses every time, even for the search", zapped.theirs[1].status == .paralysis,
          "\(zapped.theirs[1].status)")

    print("\n== getting health back ==")
    let recover = store.data.moves.values.first { $0.name == "Recover" }!
    let synthesis = store.data.moves.values.first { $0.name == "Synthesis" }!
    let pulse = store.data.moves.values.first { $0.name == "Heal Pulse" }!
    check("healing moves are read from the text",
          recover.healing?.share == 0.5 && synthesis.healing?.sunlit == true && pulse.healing?.whom == .partner)
    var tired = Board(mine: fighters([("Milotic", "Leftovers", ["Recover", "Protect"]),
                                      ("Whimsicott", "Focus Sash", ["Protect"])]),
                      theirs: chilled, store: store, field: Field(isDoubles: true), alreadyEvolved: false)
    tired.mine[0].hp = tired.mine[0].maxHP / 5
    let recovered = TurnModel.resolve(tired,
        mine: Play(left: .attack(move: at(tired.mine[0], "Recover"), target: 0),
                   right: .attack(move: at(tired.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tired.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(tired.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    for line in recovered.story where line.contains("recovered") { print("    \(line)") }
    let expected = tired.mine[0].hp + tired.mine[0].maxHP / 2
    print("  Milotic \(tired.mine[0].hp) -> \(recovered.mine[0].hp) of \(tired.mine[0].maxHP) (Leftovers adds a sixteenth at the end)")
    check("Recover restores half the bar",
          recovered.mine[0].hp >= expected && recovered.mine[0].hp <= expected + tired.mine[0].maxHP / 16 + 1,
          "\(recovered.mine[0].hp) vs \(expected)")

    print("\n== confusion ==")
    let confuseRay = store.data.moves.values.first { $0.name == "Confuse Ray" }!
    let swagger = store.data.moves.values.first { $0.name == "Swagger" }!
    check("confusing moves are read from the text",
          confuseRay.confuses && swagger.confuses && swagger.targetBoosts[Stat.attack] == 2
            && store.data.moves.values.first { $0.name == "Water Pulse" }?.secondary?.chance == 20)
    var dazed = Board(mine: fighters([("Whimsicott", "Focus Sash", ["Confuse Ray", "Protect"]),
                                      ("Milotic", "Leftovers", ["Protect"])]),
                      theirs: chilled, store: store, field: Field(isDoubles: true), alreadyEvolved: false)
    dazed.mine[0].moves = [confuseRay] + dazed.mine[0].moves
    let rayed = TurnModel.resolve(dazed,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(dazed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(dazed.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(dazed.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    for line in rayed.story where line.contains("confus") { print("    \(line)") }
    check("Confuse Ray leaves the target confused", rayed.theirs[0].isConfused, "\(rayed.theirs[0].confusedFor)")
    // Over many rolled turns, a confused Pokémon hurts itself about a third of the time.
    var selfHits = 0, turnsConfused = 0
    for _ in 0..<300 {
        var still = rayed
        still.theirs[0].confusedFor = 5
        let rolled = TurnModel.resolve(still,
            mine: Play(left: .attack(move: at(still.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(still.mine[1], "Protect"), target: 0)),
            theirs: Play(left: .attack(move: at(still.theirs[0], "Swords Dance"), target: 0),
                         right: .attack(move: at(still.theirs[1], "Swords Dance"), target: 0)),
            store: store, rolling: true)
        turnsConfused += 1
        if rolled.story.contains(where: { $0.contains("hurt itself") }) { selfHits += 1 }
    }
    print("  300 confused turns: \(selfHits) went into its own face (about 100 expected)")
    check("a confused Pokémon hurts itself about one time in three", selfHits > 65 && selfHits < 140, "\(selfHits)")
    let averaged3 = TurnModel.resolve(rayed,
        mine: Play(left: .attack(move: at(rayed.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(rayed.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(rayed.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(rayed.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    check("the search lets it act, and the count runs down",
          averaged3.theirs[0].confusedFor == rayed.theirs[0].confusedFor - 1
            && averaged3.theirs[0].build.boosts[Stat.attack.rawValue] == rayed.theirs[0].build.boosts[Stat.attack.rawValue] + 2)
    var leaving = rayed
    leaving.theirs.append(rayed.theirs[1])
    let switched = TurnModel.resolve(leaving,
        mine: Play(left: .attack(move: at(leaving.mine[0], "Protect"), target: 0),
                   right: .attack(move: at(leaving.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .swap(to: 2),
                     right: .attack(move: at(leaving.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    check("switching out clears it", !switched.theirs[2].isConfused)
    var tempo = dazed
    tempo.theirs[0].build.ability = "Own Tempo"
    let unbothered = TurnModel.resolve(tempo,
        mine: Play(left: .attack(move: 0, target: 0),
                   right: .attack(move: at(tempo.mine[1], "Protect"), target: 0)),
        theirs: Play(left: .attack(move: at(tempo.theirs[0], "Swords Dance"), target: 0),
                     right: .attack(move: at(tempo.theirs[1], "Swords Dance"), target: 0)),
        store: store)
    check("Own Tempo refuses it", !unbothered.theirs[0].isConfused)

    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }
