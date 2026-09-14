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
        let board = Board(mine: mine, theirs: store.opponentTeam(meta), store: store)
        let game = TurnGame(board: board, store: store)
        _ = game.solve()
        let started = Date()
        let solution = game.solve()
        let warm = Date().timeIntervalSince(started) * 1000
        print(String(format: "  %d x %d matrix, warm: %.1f ms",
                     solution.myPlays.count, solution.theirPlays.count, warm))
        check("a turn solves fast enough to feel instant", warm < 120,
              String(format: "%.1f ms", warm))

        BreathLog.begin()
        _ = await game.solveYielding()
        let (count, worst) = BreathLog.end()
        print(String(format: "  yielding: %d suspensions, longest stretch %.0f ms",
                     count, worst * 1000))
        check("and the yielding path never holds the thread for a frame",
              worst < frame, String(format: "%.0f ms", worst * 1000))
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
            if let mega = slot.megaEvolution(in: store) { return mega.abilities.first?.name }
            return slot.ability.isEmpty
                ? slot.battleForm(in: store)?.abilities.first?.name : slot.ability
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
