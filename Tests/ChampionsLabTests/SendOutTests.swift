//  SendOutTests.swift
//  The signal the field throws a ball on.
//
//      swift test --filter SendOutTests

import XCTest
@testable import ChampionsLab

@MainActor
final class SendOutTests: HarnessCase {
    private func position() -> Board {
        Board(mine: fighters([("Garchomp", "", ["Dragon Claw", "Protect"]),
                              ("Rillaboom", "", ["Wood Hammer", "Protect"]),
                              ("Kingambit", "", ["Iron Head", "Protect"])]),
              theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                ("Farigiraf", "", ["Calm Mind", "Protect"])]),
              rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }

    /// A slot whose Pokémon changed during a step is a switch. The field reads
    /// exactly this to know when to throw a ball, and the damage numbers read
    /// it to avoid putting one over somebody who just walked in.
    func testASwitchShowsAsASlotChangingHands() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        check("the turn was recorded in steps", !after.steps.isEmpty, "\(after.steps.count)")
        // The comparison the field actually makes: the first step against the
        // board the turn began on. A switch resolves before anything else, so
        // by the first step somebody else is already standing there.
        let before = start.mine[0].build.form.id
        check("the turn began with a Garchomp there",
              start.mine[0].build.form.formLabel == "Garchomp")
        check("and the first step of it has somebody else",
              after.steps.first?.myForms.first != before,
              after.steps.first?.myForms.first ?? "-")
        check("who stays there for the rest of the turn",
              Set(after.steps.compactMap { $0.myForms.first }).count == 1,
              after.steps.map { $0.myForms.first ?? "-" }.joined(separator: " → "))
        check("and it is Kingambit standing there now",
              after.mine[0].build.form.formLabel == "Kingambit",
              after.mine[0].build.form.formLabel)
    }

    func testAQuietTurnChangesNobody() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Protect"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        let first = start.mine[0].build.form.id
        check("nobody changed hands", after.steps.allSatisfy { $0.myForms.first == first })
    }

    /// A Mega Evolution changes the form and not the Pokémon. The field tells
    /// the two apart by the National Dex number, because a side cannot hold
    /// one species twice — and before it did, it threw a Poké Ball at every
    /// Salamence that Mega Evolved.
    func testAMegaEvolutionIsTheSamePokemonInAnotherForm() {
        var team = fighters([("Salamence", "Salamencite", ["Dragon Claw", "Protect"]),
                             ("Rillaboom", "", ["Wood Hammer", "Protect"])])
        team.slots[0].shiny = false
        var board = Board(mine: team,
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        let before = board.mine[0].build.form
        Switching.megaEvolve(&board.mine, slot: 0, opposing: &board.theirs, field: &board.field)
        let after = board.mine[0].build.form
        check("the form changed", before.id != after.id, "\(before.id) → \(after.id)")
        check("and it really is the Mega", after.isMega, after.formLabel)
        check("but the Pokémon did not", before.dex == after.dex,
              "\(before.dex) against \(after.dex)")
    }

    /// The other half of the same rule: somebody walking on really is somebody
    /// else, and has a different number.
    func testASwitchIsADifferentPokemonEntirely() {
        let start = position()
        let after = TurnModel.resolve(start,
            mine: Play(left: .swap(to: 2), right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        let before = start.mine[0].build.form
        let now = after.mine[0].build.form
        check("a different form", before.id != now.id)
        check("and a different Pokémon", before.dex != now.dex,
              "\(before.dex) against \(now.dex)")
    }

    /// The ball is drawn, not loaded, so it has no art to go missing — but it
    /// does have to be built at whatever size the depth gives it.
    func testTheBallDrawsAtAnySize() {
        for side in [10.0, 26.0, 96.0] as [CGFloat] {
            for open in [false, true] {
                _ = PokeBall(side: side, open: open).body
            }
        }
        check("a ball can be drawn at any size, open or shut", true)
    }
}
