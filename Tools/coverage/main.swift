//  Tools/coverage/main.swift
//  The parity audit, from the command line.
//
//  The audit itself lives in the library, where the app's Parity screen uses
//  the same code — there is one answer to "is this implemented", not two.
//
//      ./Tools/coverage.sh            a summary and the gaps
//      ./Tools/coverage.sh --gaps     every gap, named

import AppKit
import SwiftUI

@MainActor func run() {
    let store = Store.shared
    let rules = store.rulebook
    let onlyGaps = CommandLine.arguments.contains("--gaps")
    if let at = CommandLine.arguments.firstIndex(of: "--why") {
        for name in CommandLine.arguments[(at + 1)...] {
            print("== \(name) ==")
            print(ParityAudit.explain(name, rules: rules))
        }
        exit(0)
    }

    // The control runs first and alone. If a made-up name changes the game,
    // the battery is seeing differences that are not there and there is no
    // point spending four minutes printing numbers built on it.
    let failure = ParityAudit.controlFailure(rules: rules)
    if let failure {
        print("  !! the control failed: \(failure)")
        print("     Every number below would be meaningless. Fix the battery first.\n")
    } else if CommandLine.arguments.contains("--control") {
        print("  the control passes: a made-up ability and item both read as no effect.")
        exit(0)
    }
    if failure != nil { exit(1) }

    var report = ParityAudit.run(rules: rules, usage: store.data.usage) { step in
        if step.done % 100 == 0 {
            FileHandle.standardError.write("  \(step.stage)\n".data(using: .utf8)!)
        }
    }
    let items = ParityAudit.items(store.data.items, rules: rules)
    report = ParityAudit.Report(findings: (report.findings + items).sorted { $0.usage > $1.usage },
                                seconds: report.seconds)

    func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "—" : String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }
    print("== what the battle model implements ==\n")
    // Two numbers, because they answer different questions. The one that
    // decides whether the simulator is trustworthy is the left one: what it
    // covers of the things that actually turn up in games. The right one
    // counts the whole legal dex, most of which belongs to Pokémon nobody
    // brings.
    print("             carried by something played    whole legal dex")
    for kind in ParityAudit.Finding.Kind.allCases {
        let all = report.of(kind)
        guard !all.isEmpty else { continue }
        // Items have no usage share of their own; every one in the list was
        // seen in a registered team, so every one counts as played.
        let played = kind == .item ? all : all.filter { $0.usage > 0 }
        let playedOK = played.filter { $0.verdict.isCovered || $0.verdict == .notModelled }.count
        let allOK = all.filter { $0.verdict.isCovered || $0.verdict == .notModelled }.count
        let left = "\(playedOK) of \(played.count) (\(percent(playedOK, played.count)))"
        print("  \(kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
              + " \(left.padding(toLength: 30, withPad: " ", startingAt: 0))"
              + "\(allOK) of \(all.count)")
    }
    let parsed = ParityAudit.Finding.Kind.allCases
        .flatMap { report.of($0) }.filter { $0.verdict == .byRule }.count
    if parsed > 0 {
        print("\n  \(parsed) more parse into a rule the model applies but never fired for the")
        print("  audit, because the audit does not roll dice. Those are not gaps.")
    }
    for kind in ParityAudit.Finding.Kind.allCases {
        let gaps = report.of(kind).filter { $0.verdict == .noEffect }
        guard !gaps.isEmpty else { continue }
        print("\n== \(kind.plural) the audit found no effect for (\(gaps.count)) ==")
        for f in gaps.prefix(onlyGaps ? 500 : 20) {
            let share = f.usage > 0 ? String(format: "%5.1f%%", f.usage) : "     ·"
            print("  \(share)  \(f.name.padding(toLength: 22, withPad: " ", startingAt: 0))\(f.detail.prefix(74))")
        }
        if gaps.count > (onlyGaps ? 500 : 20) { print("  … and \(gaps.count - 20) more") }
    }
    print(String(format: "\n  %.1fs. \"Not proven\" means the battery could not make it matter,",
                 report.seconds))
    print("  which is where to look — not proof that the rule is missing. Run")
    print("  --why <name> to see what the battery tried.")
}
MainActor.assumeIsolated { run() }
