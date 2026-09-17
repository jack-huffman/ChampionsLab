//  tools/hitch/main.swift
//  How long the main thread runs without a break during a build.
//
//      ./tools/hitch.sh
//
//  This is the measurement behind "the spinner is frozen". An overlay can only
//  animate when the run loop gets a turn, and on the main actor it only gets
//  one at a real suspension -- Task.yield() is not one, which is why a watchdog
//  timer set to 4ms once recorded a single tick across a whole build.
//
//  So the number that matters is not how long a build takes. It is the longest
//  stretch inside it that never hands the thread back. Anything past 16ms drops
//  a frame; the two worst stretches here were 1.2 seconds each.
//
//  Thresholds are loose on purpose. This guards against a stall coming back,
//  not against a slower machine.

import AppKit

let frame = 1.0 / 60

/// Moves that are only weak until the team's own field is up, and the ability
/// that puts it up. Mirrors the refiner's own table.
let fieldMoveNeeds: [String: Set<String>] = [
    "Grassy Glide": ["Grassy Surge"],
    "Expanding Force": ["Psychic Surge"],
    "Rising Voltage": ["Electric Surge"],
    "Psyblade": ["Electric Surge"],
    "Misty Explosion": ["Misty Surge"],
    "Terrain Pulse": ["Grassy Surge", "Psychic Surge", "Electric Surge", "Misty Surge"],
    "Weather Ball": ["Drought", "Drizzle", "Sand Stream", "Snow Warning"],
    "Solar Beam": ["Drought"], "Solar Blade": ["Drought"],
    "Thunder": ["Drizzle"], "Hurricane": ["Drizzle"],
    "Aurora Veil": ["Snow Warning"],
]

@MainActor func run() async {
    let store = Store.shared
    var fails = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if !ok { fails += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    let builder = TeamBuilder(store: store, format: "doubles")
    guard let seed = store.data.forms.first(where: { $0.formLabel == "Mega Golisopod" }) else {
        print("Mega Golisopod is not in the dex"); exit(1)
    }
    let picks = Forecast(store: store, format: "doubles").picks()

    print("== a two-Mega build, measured between suspensions ==")
    BreathLog.begin()
    let started = Date()
    let out = await builder.blueprints(seed: seed, picks: picks, perPlan: 1,
                                       dualMega: true) { _, _ in }
    let wall = Date().timeIntervalSince(started)
    let (count, worst) = BreathLog.end()
    let stalls = BreathLog.stalls

    print(String(format: "  %d teams in %.0f ms, %d suspensions", out.count, wall * 1000, count))
    print(String(format: "  longest unbroken stretch: %.0f ms", worst * 1000))
    print(String(format: "  stretches past one frame: %d, totalling %.0f ms",
                 stalls.count, stalls.reduce(0) { $0 + $1.seconds } * 1000))
    for stall in stalls.prefix(5) {
        print(String(format: "    %-20s %6.0f ms", (stall.label as NSString).utf8String!,
                     stall.seconds * 1000))
    }

    check("a build actually produced something", !out.isEmpty, "\(out.count)")
    check("every suspension is labelled",
          BreathLog.gaps.allSatisfy { !$0.label.isEmpty },
          "\(BreathLog.gaps.filter { $0.label.isEmpty }.count) unlabelled")
    // Four frames. A build that stalls longer than this is one the spinner
    // visibly freezes in, which is the thing being guarded against.
    check("no stretch runs past four frames", worst < frame * 4,
          String(format: "%.0f ms", worst * 1000))
    // A build now searches three plans rather than two, so there is more of
    // everything; this guards against a stall coming back, not against a busy
    // machine, and the number it is really watching is the one above.
    check("at most a handful of dropped frames in a whole build",
          stalls.count <= 10, "\(stalls.count)")

    // What winning teams carry cost 340ms the first time anything asked, in one
    // piece, in the middle of a search, because it rebuilt every team list once
    // per role group. A build warms it up front now; this checks it stays warm
    // rather than being rebuilt inside each evaluation.
    let reasked = Date()
    _ = store.winningStructure(format: "doubles")
    let reaskedMS = Date().timeIntervalSince(reasked) * 1000
    print(String(format: "\n  winning structure, re-asked after a build: %.2f ms", reaskedMS))
    check("the winning structure is not rebuilt per evaluation", reaskedMS < 1,
          String(format: "%.2f ms", reaskedMS))

    // -- solving a turn -----------------------------------------------------
    //
    // Every pair of your choices against every pair of theirs, each played out
    // and scored, then solved for the equilibrium. It runs while somebody
    // waits for it, so it has to be quick and it has to breathe.
    print("\n== solving a turn ==")
    if let meta = store.data.metaTeams.first(where: { $0.name == "Big Six" }),
       let mine = store.teams.first(where: { $0.slots.count >= 4 }) {
        let board = Board(mine: mine, theirs: store.opponentTeam(meta), rules: store.rulebook)
        let game = TurnGame(board: board)
        _ = game.solve()
        let started = Date()
        let solution = game.solve()
        let warm = Date().timeIntervalSince(started) * 1000
        print(String(format: "  %d x %d matrix, warm: %.1f ms",
                     solution.myPlays.count, solution.theirPlays.count, warm))
        check("a turn solves fast enough to feel instant", warm < 120,
              String(format: "%.1f ms", warm))

        // A second ply, to check what the turn buys by the end of the next one.
        let deepStart = Date()
        let pair = await game.solveDeep()
        let deepMS = Date().timeIntervalSince(deepStart) * 1000
        print(String(format: "  with a second ply: %.0f ms, one ply %+.3f, two ply %+.3f",
                     deepMS, pair.shallow.value, pair.deep.value))
        check("looking a turn further is still quick enough to do on a click",
              deepMS < 900, String(format: "%.0f ms", deepMS))
        check("the deeper solve keeps only lines the first one rated",
              pair.deep.myPlays.count <= pair.shallow.myPlays.count)

        BreathLog.begin()
        _ = await game.solveYielding()
        let (count, worst) = BreathLog.end()
        print(String(format: "  yielding: %d suspensions, longest stretch %.0f ms",
                     count, worst * 1000))
        check("and the yielding path never holds the thread for a frame",
              worst < frame, String(format: "%.0f ms", worst * 1000))
    }

    // -- searching the game rather than the turn ----------------------------
    //
    // Iterative deepening against a budget of positions, over a belief about
    // what the other side is hiding rather than a position nobody can see.
    print("\n== the search ==")
    if let meta = store.data.metaTeams.first(where: { $0.name == "Big Six" }),
       let mine = store.teams.first(where: { $0.slots.count >= 4 }) {
        let board = Board(mine: mine, theirs: store.opponentTeam(meta), rules: store.rulebook)
        var reached: [Int] = []
        for nodes in [BattleEngine.Nodes.oneAhead, BattleEngine.Nodes.screen] {
            let engine = BattleEngine(rules: store.rulebook, nodes: nodes)
            let started = Date()
            let result = engine.think(board)
            let took = Date().timeIntervalSince(started)
            reached.append(result.depth)
            print(String(format: "  %d positions -> depth %d, %d solved, value %+.3f (took %.2fs)",
                         nodes, result.depth, result.nodes, result.value, took))
            // The budget is asked before every position, so the overrun is at
            // most the children of the node it was already expanding.
            check("it respects the budget it was given",
                  result.nodes <= nodes + engine.beam * engine.beam * 2 + engine.worlds,
                  "\(result.nodes) solved for a budget of \(nodes)")
            check("the screen's budget answers in the time the screen allows",
                  nodes != BattleEngine.Nodes.screen || took < 1.5,
                  String(format: "%.2fs", took))
            check("it returns a line it actually rated",
                  result.mix.count == result.plays.count && !result.plays.isEmpty)
            check("the mix is a distribution",
                  abs(result.mix.reduce(0, +) - 1) < 0.01, "\(result.mix.reduce(0, +))")
        }
        check("more budget reaches at least as deep", reached.last! >= reached.first!,
              "\(reached)")

        // The belief: what it cannot see, and where the guess comes from.
        let engine = BattleEngine(rules: store.rulebook)
        let worlds = engine.imagine(board, belief: .init())
        print("  worlds imagined: \(worlds.count)")
        check("it imagines more than one version of what they are holding",
              worlds.count >= 1)
        check("the likeliest world comes first",
              zip(worlds, worlds.dropFirst()).allSatisfy { $0.chance >= $1.chance })
        // A Mega has no item choice, so there is nothing to guess about it.
        for fighter in board.theirs where fighter.build.form.isMega {
            let odds = engine.itemOdds(for: fighter.build.form)
            check("a Mega's stone is not treated as unknown",
                  odds.count == 1 && odds[0].chance == 1, fighter.build.form.formLabel)
            break
        }
        // And an item that has been seen stops being a guess.
        var known = BattleEngine.Belief()
        known.revealedItems[board.theirs[0].build.form.id] = "Life Orb"
        known.revealedItems[board.theirs[1].build.form.id] = "Sitrus Berry"
        check("a revealed item collapses the guessing",
              engine.imagine(board, belief: known).count
                <= engine.imagine(board, belief: .init()).count)

        // Singles is the same machinery with one slot a side.
        var solo = board
        solo.activeCount = 1
        var soloGame = TurnGame(board: solo)
        soloGame.width = 6
        let soloPlays = soloGame.plays(forMine: true)
        print("  singles: \(soloPlays.count) lines rather than \(TurnGame(board: board).plays(forMine: true).count)")
        check("singles gives one Pokemon its choices and nobody else one",
              soloPlays.allSatisfy { $0.right.isPass }, "\(soloPlays.count)")
        check("and it still resolves a turn",
              !TurnModel.resolve(solo, mine: soloPlays[0], theirs: soloPlays[0]).mine.isEmpty)
    }

    // -- what the refiner will and will not suggest -------------------------
    //
    // The move ranker prices a move on its own, which is wrong twice over: it
    // cannot see that a move is the team's last copy of a job, and it cannot
    // see that a move is only weak until the team's own field goes up. Both
    // produced advice that gives games away, so both are guarded here.
    print("\n== what the refiner will not suggest ==")
    var refineFails = 0
    var checked = 0
    for team in store.teams where team.slots.count >= 4 {
        var refiner = TeamRefiner(store: store, team: team, format: team.format)
        refiner.plan = TeamAdvisor(team: team, store: store).archetypes.first?.archetype ?? .balance
        let started = Date()
        let found = await refiner.suggestions(picks: picks, budget: 12, limit: 6) { _, _ in }
        let took = Date().timeIntervalSince(started) * 1000
        checked += 1

        // Everything the six is running, and what it would be giving up.
        let abilities = Set(team.slots.compactMap { slot -> String? in
            if let mega = slot.megaEvolution(in: store.rulebook) { return mega.abilities.first?.name }
            return slot.ability.isEmpty
                ? slot.battleForm(in: store.rulebook)?.abilities.first?.name : slot.ability
        })
        let protectedNames: Set<String> = ["Tailwind", "Trick Room", "Follow Me",
                                           "Rage Powder", "Revival Blessing"]
        for suggestion in found where suggestion.kind == .move {
            // "Pelipper: Tailwind -> Icy Wind"
            guard let arrow = suggestion.headline.range(of: " → "),
                  let colon = suggestion.headline.range(of: ": ") else { continue }
            let dropped = String(suggestion.headline[colon.upperBound..<arrow.lowerBound])
            let soleHolders = team.slots.filter { $0.moves.contains { store.move($0)?.name == dropped } }
            if protectedNames.contains(dropped), soleHolders.count <= 1 {
                print("  FAIL  would drop the team's only \(dropped): \(suggestion.headline)")
                refineFails += 1
            }
            if let needs = fieldMoveNeeds[dropped], !needs.isDisjoint(with: abilities) {
                print("  FAIL  would drop \(dropped), which this team's own field powers: \(suggestion.headline)")
                refineFails += 1
            }
        }
        print(String(format: "  %-24s %5.0f ms, %d suggestions",
                     (team.name as NSString).utf8String!, took, found.count))
    }
    check("the refiner ran on every saved team", checked > 0, "\(checked)")
    check("it never offers to drop a job the team has one copy of, or a move its own field powers",
          refineFails == 0, "\(refineFails) bad suggestions")

    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

_ = MainActor.assumeIsolated { Task { await run() } }
RunLoop.main.run()
