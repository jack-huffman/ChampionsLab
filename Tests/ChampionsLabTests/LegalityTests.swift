//  LegalityTests.swift
//  What this regulation has, what it has not, and the line between them.
//
//      swift test --filter LegalityTests

import XCTest
@testable import ChampionsLab

@MainActor
final class LegalityTests: HarnessCase {

    // MARK: - The line

    func testTheRosterIsLegalAndTheRestIsNot() {
        let roster = store.data.forms
        let wider = store.data.widerForms
        print("  \(roster.count) in this regulation, \(wider.count) outside it")
        check("there is a roster", !roster.isEmpty)
        check("and a wider dex beyond it", wider.count > 500, "\(wider.count)")
        check("everything on the roster is legal", roster.allSatisfy(\.isLegal),
              roster.filter { !$0.isLegal }.prefix(4).map(\.formLabel).joined(separator: ", "))
        check("and nothing outside it is", wider.allSatisfy { !$0.isLegal },
              wider.filter(\.isLegal).prefix(4).map(\.formLabel).joined(separator: ", "))
    }

    func testTheTwoDoNotOverlap() {
        let roster = Set(store.data.forms.map(\.id))
        let wider = Set(store.data.widerForms.map(\.id))
        check("nothing is in both lists", roster.isDisjoint(with: wider),
              roster.intersection(wider).prefix(4).joined(separator: ", "))
    }

    /// The analysis, the usage table, the ladder and the sprites all walk the
    /// roster. If the wider dex ever leaked into it, every one of them would
    /// quietly start reasoning about a game that does not exist.
    func testNothingThatAnalysesTheGameSeesTheWiderDex() {
        check("the roster the app reasons about is Champions only",
              store.data.forms.allSatisfy(\.fromChampions))
        check("and everything outside says where it came from",
              store.data.widerForms.allSatisfy { $0.source == "main series" },
              store.data.widerForms.first { $0.source != "main series" }?.formLabel ?? "-")
        check("the store resolves a usage name only on the roster",
              store.form(named: "Abra") == nil || store.data.forms.contains { $0.formLabel == "Abra" })
    }

    /// A team built in the sandbox is a file somebody opens later, so whatever
    /// it names has to resolve.
    func testAWiderFormStillResolvesByID() {
        guard let outsider = store.data.widerForms.first else {
            return check("there is something outside the roster", false)
        }
        let back = store.rulebook.form(outsider.id)
        check("\(outsider.formLabel) resolves from a saved team", back?.id == outsider.id,
              back?.formLabel ?? "nothing")
        check("and is still marked as not legal", back?.isLegal == false)
    }

    func testEverythingOutsideCanAtLeastBeGivenAMove() {
        let mute = store.data.widerForms.filter { $0.moves.isEmpty }
        check("nothing outside the roster is unplayable", mute.isEmpty,
              "\(mute.count): \(mute.prefix(4).map(\.formLabel).joined(separator: ", "))")
        let unknown = store.data.widerForms.prefix(200).flatMap { form in
            form.moves.filter { store.move($0) == nil }
        }
        check("and every move it names is one this game has", unknown.isEmpty,
              unknown.prefix(4).joined(separator: ", "))
    }

    func testTheyCarryRealDexNumbers() {
        let odd = store.data.widerForms.filter { $0.dex <= 0 }
        check("nothing fan-made came along with them", odd.isEmpty,
              odd.prefix(5).map(\.formLabel).joined(separator: ", "))
    }

    // MARK: - What a team may do with it

    func testATeamIsToldWhenItCarriesSomethingThisGameHasNot() {
        guard let outsider = store.data.widerForms.first(where: { !$0.moves.isEmpty }) else {
            return check("there is something to build with", false)
        }
        var team = Team(name: "Outsiders")
        var slot = TeamSlot(formID: outsider.id)
        slot.ability = outsider.abilities.first?.name ?? ""
        slot.moves = Array(outsider.moves.prefix(4))
        team.slots = [slot]

        let complaints = team.violations(in: store)
        check("an ordinary team is told",
              complaints.contains { $0.contains("not in") },
              complaints.joined(separator: " | "))

        team.unlimited = true
        let sandbox = team.violations(in: store)
        check("a sandbox team is told once what it is",
              sandbox.contains { $0.hasPrefix("Unlimited:") },
              sandbox.joined(separator: " | "))
        check("and not told off for each of them",
              !sandbox.contains { $0.contains("not in \(store.data.regulation.name)") })
    }

    func testTheSandboxOffersEveryMoveRatherThanALearnset() {
        guard let chomp = store.data.forms.first(where: { $0.formLabel == "Garchomp" }) else {
            return check("Garchomp is in the dex", false)
        }
        let learnset = store.moveOptions(for: chomp).count
        let everything = store.moveOptions(for: chomp, unlimited: true).count
        print("  Garchomp knows \(learnset) moves; the sandbox offers \(everything)")
        check("the sandbox offers more than it can learn", everything > learnset,
              "\(everything) against \(learnset)")
        check("and offers the whole table", everything == store.data.moves.count,
              "\(everything) of \(store.data.moves.count)")
    }
}
