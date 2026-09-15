//  ParityAuditTests.swift
//  Guards on the audit itself, because an audit that lies is worse than none.
//
//      swift test --filter ParityAuditTests

import XCTest
@testable import ChampionsLab

final class ParityAuditTests: HarnessCase {
    /// The control the audit runs before it reports anything.
    ///
    /// A name the model has never heard of must come back as having no effect.
    /// When this failed, the audit was reporting 99% ability coverage against a
    /// real figure of 78%, because its baseline compared one ability against
    /// another instead of against nothing.
    @MainActor func testAMadeUpNameChangesNothing() throws {
        print("\n== the audit's own control ==")
        let failure = ParityAudit.controlFailure(rules: store.rulebook)
        if let failure { print("  the control failed: \(failure)") }
        check("a made-up ability and item both read as no effect", failure == nil)
    }

    /// The audit compares two boards by writing one out as a string. Anything
    /// the string leaves out is invisible to it: a move that only changes that
    /// field reads as doing nothing at all.
    ///
    /// This is exactly what happened. Twenty-odd moves were implemented and
    /// still reported as missing — Spikes, Safeguard, Wish, Soak, Trick, the
    /// Splits and the Swaps — because the state they change had been added to
    /// `Fighter` and `Screens` without being added to the fingerprint.
    ///
    /// Counting the fields catches the next one. If this fails, a property was
    /// added to one of these types: add it to `fingerprint` in ParityAudit, then
    /// update the count here.
    @MainActor func testTheFingerprintKeepsUpWithTheBoard() throws {
        print("\n== the audit can see the whole board ==")
        let fighter = Fighter(build: Combatant(form: store.data.forms[0]), moves: [])
        let counts = [("Fighter", Mirror(reflecting: fighter).children.count, 39),
                      ("Screens", Mirror(reflecting: Screens()).children.count, 12),
                      ("Combatant", Mirror(reflecting: fighter.build).children.count, 16)]
        for (name, found, expected) in counts {
            print("  \(name): \(found) properties, fingerprint written for \(expected)")
            check("\(name) has not grown a field the audit cannot see", found == expected)
        }
    }

    /// Two boards that differ only in something the fingerprint should notice.
    /// Spot checks on the fields that were actually being missed.
    @MainActor func testTheFingerprintNoticesTheNewState() throws {
        print("\n== the fingerprint notices what moves change ==")
        let names = ["Spikes", "Toxic Spikes", "Stealth Rock", "Safeguard", "Wish",
                     "Soak", "Trick", "Switcheroo", "Worry Seed", "Skill Swap",
                     "Psych Up", "Guard Swap", "Power Swap", "Guard Split",
                     "Power Split", "Pain Split", "Attract", "Torment", "Mean Look",
                     "Substitute", "Belly Drum", "Stockpile", "Swallow", "Howl",
                     "Endure", "Wide Guard", "Aqua Ring", "Magic Room", "Wonder Room",
                     "Electro Ball", "Gyro Ball", "Grass Knot", "Low Kick",
                     "Heavy Slam", "Baton Pass", "Roar", "After You", "Guillotine",
                     // The field sweepers and stat movers, which only became
                     // possible once hazards and side conditions existed.
                     "Haze", "Defog", "Court Change", "Topsy-Turvy", "Entrainment",
                     "Role Play", "Simple Beam", "Gastro Acid", "Corrosive Gas",
                     "Reflect Type", "Magic Powder", "Speed Swap", "Power Trick",
                     "Decorate", "Aromatic Mist", "Clangorous Soul", "Heal Bell",
                     "Sticky Web", "Quash", "Recycle", "Stuff Cheeks", "Teatime",
                     "Forest's Curse", "Trick-or-Treat", "Ingrain", "Fairy Lock",
                     "Magnetic Flux", "Chilly Reception"]
        let silent = ParityAudit.movesThatDoNothing(names, rules: store.rulebook)
        print("  \(names.count - silent.count) of \(names.count) change the game")
        if !silent.isEmpty { print("  nothing happens for: \(silent.joined(separator: ", "))") }
        check("every one of them does something", silent.isEmpty)
    }
}
