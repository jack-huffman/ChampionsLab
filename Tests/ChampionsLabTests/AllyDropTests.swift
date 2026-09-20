//  AllyDropTests.swift
//  Lowering your own partner's stats, which is a thing people do on purpose.
//
//      swift test --filter AllyDropTests

import XCTest
@testable import ChampionsLab

@MainActor
final class AllyDropTests: HarnessCase {
    private func position(partnerAbility: String) -> Board {
        var board = Board(mine: fighters([("Whimsicott", "", ["Charm", "Protect"]),
                                          ("Staraptor", "", ["Brave Bird", "Protect"])]),
                          theirs: fighters([("Milotic", "", ["Calm Mind", "Protect"]),
                                            ("Farigiraf", "", ["Calm Mind", "Protect"])]),
                          rules: store.rulebook, field: Field(isDoubles: true), alreadyEvolved: false)
        board.mine[1].build.ability = partnerAbility
        return board
    }
    private func idle(_ b: Board) -> Play {
        Play(left: .attack(move: at(b.theirs[0], "Calm Mind"), target: 0),
             right: .attack(move: at(b.theirs[1], "Calm Mind"), target: 0))
    }
    /// The partner attacks rather than protecting: a Protect turns away a
    /// partner's move too, which is correct and would hide what is being
    /// tested here.
    private func charmThePartner(_ b: Board) -> Play {
        Play(left: Choice.attackingAlly(move: at(b.mine[0], "Charm")),
             right: .attack(move: at(b.mine[1], "Brave Bird"), target: 0))
    }

    /// The tech this was written for: Charm takes two stages of Attack, and a
    /// Contrary partner takes them the other way.
    func testCharmOnAContraryPartnerIsTwoStagesUp() {
        let start = position(partnerAbility: "Contrary")
        let after = TurnModel.resolve(start, mine: charmThePartner(start), theirs: idle(start))
        let attack = after.mine[1].build.boosts[Stage.attack.rawValue]
        check("the partner's Attack went up, not down", attack == 2, "\(attack)")
        check("and the log says Contrary turned it round",
              after.story.contains { $0.contains("Contrary") },
              after.story.joined(separator: " | "))
        check("nothing happened across the field",
              after.theirs.allSatisfy { $0.build.boosts[Stage.attack.rawValue] == 0 })
    }

    /// And without Contrary it is what it says on the tin, which is why you
    /// would only ever do it on purpose.
    func testCharmOnAnOrdinaryPartnerIsTwoStagesDown() {
        let start = position(partnerAbility: "Intimidate")
        let after = TurnModel.resolve(start, mine: charmThePartner(start), theirs: idle(start))
        let attack = after.mine[1].build.boosts[Stage.attack.rawValue]
        check("the partner's Attack fell", attack == -2, "\(attack)")
    }

    /// Defiant answers the other side lowering a stat. A partner helping you
    /// is not the other side, so it must not fire.
    func testAPartnersDropDoesNotSetOffDefiant() {
        let start = position(partnerAbility: "Defiant")
        let after = TurnModel.resolve(start, mine: charmThePartner(start), theirs: idle(start))
        let attack = after.mine[1].build.boosts[Stage.attack.rawValue]
        check("the drop landed and Defiant stayed quiet", attack == -2, "\(attack)")
        check("and it is not mentioned",
              !after.story.contains { $0.contains("Defiant") },
              after.story.joined(separator: " | "))
    }

    /// The ordinary case still works: aimed across the field it lands there,
    /// and there Defiant does answer it.
    func testAimedAcrossTheFieldItStillLandsThere() {
        var start = position(partnerAbility: "Intimidate")
        start.theirs[0].build.ability = "Defiant"
        let after = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Charm"), target: 0),
                       right: .attack(move: at(start.mine[1], "Protect"), target: 0)),
            theirs: idle(start))
        check("it hit the one across the field",
              after.story.contains { $0.contains("Milotic's Atk sharply fell") },
              after.story.joined(separator: " | "))
        check("and their Defiant answered it, which nets it back to nothing",
              after.story.contains { $0.contains("Defiant") }
                && after.theirs[0].build.boosts[Stage.attack.rawValue] == 0,
              "\(after.theirs[0].build.boosts[Stage.attack.rawValue])")
        check("while my own partner was untouched",
              after.mine[1].build.boosts[Stage.attack.rawValue] == 0)
    }
}
