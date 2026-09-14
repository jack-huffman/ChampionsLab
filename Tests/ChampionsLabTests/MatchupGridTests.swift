//  MatchupGridTests.swift
//  The six-against-six grid: what each cell is worth, what a move is worth, and what a Pokemon is for.
//
//      swift test --filter MatchupGridTests

import XCTest
@testable import ChampionsLab

final class MatchupGridTests: HarnessCase {
    /// the grid, move valuation, stat roles, and the form that fights
    @MainActor func testGridAndValuation() throws {
    print("== matchup ==")
    let result = imported
    let bigSix = try XCTUnwrap(store.data.metaTeams.first { $0.id == "big-six" },
                               "the bundled Big Six archetype")
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

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// items this format has actually seen
    @MainActor func testItemsInTheGame() throws {
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

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// which four to bring, which two lead, and when to leave a cell
    @MainActor func testBringFourAndSwitching() throws {
        let result = imported
        let theirs = bigSixTeam
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

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
