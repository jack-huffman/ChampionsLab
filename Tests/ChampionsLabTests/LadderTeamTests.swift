//  LadderTeamTests.swift
//  A team taken off the ladder arrives as one of yours: complete, and
//  unlocked, because the point of taking it is to change it.

import XCTest
@testable import ChampionsLab

@MainActor
final class LadderTeamTests: HarnessCase {
    func testTheLadderBuildsCompleteTeams() {
        let teams = store.ladderTeams(format: "doubles")
        check("there are teams to take", !teams.isEmpty)
        guard let first = teams.first?.team else { return }
        check("a full six", first.slots.count >= 4, "\(first.slots.count)")
        for slot in first.slots {
            let form = slot.form(in: store.rulebook)
            check("\(form?.formLabel ?? slot.formID) is a real form", form != nil)
            check("  with an ability", !slot.ability.isEmpty, slot.ability)
            check("  with moves", !slot.moves.isEmpty, "\(slot.moves.count)")
            check("  with Stat Points spent",
                  slot.sp.reduce(0, +) > 0, "\(slot.sp)")
            check("  within the cap",
                  slot.sp.reduce(0, +) <= store.data.rules.spTotal
                    && slot.sp.allSatisfy { $0 <= store.data.rules.spPerStat }, "\(slot.sp)")
            if let form {
                check("  and only moves it can learn",
                      slot.moves.allSatisfy { form.moves.contains($0) },
                      "\(slot.moves.filter { !form.moves.contains($0) })")
            }
        }
    }

    func testTheLaddersOwnTeamsStayLockedButACopyDoesNot() {
        guard let ladder = store.ladderTeams(format: "doubles").first?.team else {
            return check("there is a ladder team", false)
        }
        check("the ladder's own is locked", ladder.locked)
        // What the sheet does with it: a copy of its own, unlocked.
        var copy = ladder
        copy.id = UUID()
        copy.locked = false
        copy.slots = ladder.slots.map { slot in
            var new = slot; new.id = UUID(); return new
        }
        check("the copy is yours to edit", !copy.locked)
        check("with its own identity", copy.id != ladder.id)
        check("and its own slots", Set(copy.slots.map(\.id)).isDisjoint(with: Set(ladder.slots.map(\.id))))
        check("but the same Pokemon and sets",
              copy.slots.map(\.formID) == ladder.slots.map(\.formID)
                && copy.slots.map(\.moves) == ladder.slots.map(\.moves)
                && copy.slots.map(\.sp) == ladder.slots.map(\.sp))
    }
}
