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
    check("at most a handful of dropped frames in a whole build",
          stalls.count <= 6, "\(stalls.count)")

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

    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

_ = MainActor.assumeIsolated { Task { await run() } }
RunLoop.main.run()
