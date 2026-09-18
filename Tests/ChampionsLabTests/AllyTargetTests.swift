//  AllyTargetTests.swift
//  A support move aimed at your own partner lands on your own partner.
//
//  Skill Swap, Trick, Guard Split and the rest are things you do to your own
//  side as readily as to theirs, and the screen offers the partner as a
//  target. The model resolved every support move against the far side, so an
//  ally target -- which arrives as `Choice.allyTarget` rather than a slot --
//  fell through to the first opponent instead.

import XCTest
@testable import ChampionsLab

final class AllyTargetTests: HarnessCase {
    @MainActor private func lineup() -> Board {
        let mine = fighters([("Gardevoir", "Sitrus Berry", ["Skill Swap", "Trick", "Psychic"]),
                             ("Rillaboom", "Assault Vest", ["Wood Hammer", "Fake Out"]),
                             ("Whimsicott", "Focus Sash", ["Tailwind"]),
                             ("Garchomp", "Life Orb", ["Earthquake"])])
        let theirs = fighters([("Milotic", "Leftovers", ["Scald"]),
                               ("Farigiraf", "Sitrus Berry", ["Psychic"]),
                               ("Kingambit", "Black Glasses", ["Kowtow Cleave"])])
        var board = Board(mine: mine, theirs: theirs, rules: store.rulebook)
        board.mine[0].build.ability = "Trace"
        board.mine[1].build.ability = "Grassy Surge"
        board.theirs[0].build.ability = "Marvel Scale"
        board.theirs[1].build.ability = "Armor Tail"
        return board
    }

    @MainActor func testSkillSwapOnThePartnerSwapsWithThePartner() {
        let board = lineup()
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attackingAlly(move: at(board.mine[0], "Skill Swap")), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the caster took the partner's ability",
              out.mine[0].build.ability == "Grassy Surge", out.mine[0].build.ability)
        check("and the partner took the caster's",
              out.mine[1].build.ability == "Trace", out.mine[1].build.ability)
        check("nothing across the field was touched",
              out.theirs[0].build.ability == "Marvel Scale" && out.theirs[1].build.ability == "Armor Tail",
              "\(out.theirs[0].build.ability) and \(out.theirs[1].build.ability)")
        check("and it was told as a swap with the partner",
              out.story.contains { $0.contains("Rillaboom") && $0.contains("swapped abilities") },
              "\(out.story.filter { $0.contains("swapped") })")
    }

    @MainActor func testSkillSwapAcrossTheFieldStillWorks() {
        let board = lineup()
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attack(move: at(board.mine[0], "Skill Swap"), target: 0), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the caster took the target's ability",
              out.mine[0].build.ability == "Marvel Scale", out.mine[0].build.ability)
        check("the target took the caster's",
              out.theirs[0].build.ability == "Trace", out.theirs[0].build.ability)
        check("and the partner was left alone",
              out.mine[1].build.ability == "Grassy Surge", out.mine[1].build.ability)
    }

    @MainActor func testTrickOnThePartnerTradesWithThePartner() {
        let board = lineup()
        let mineItem = board.mine[0].build.item, partnerItem = board.mine[1].build.item
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attackingAlly(move: at(board.mine[0], "Trick")), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the two of ours traded items",
              out.mine[0].build.item == partnerItem && out.mine[1].build.item == mineItem,
              "\(out.mine[0].build.item) and \(out.mine[1].build.item)")
        check("and theirs kept what it was holding",
              out.theirs[0].build.item == board.theirs[0].build.item, out.theirs[0].build.item)
    }

    @MainActor func testAnAllyTargetIsNotRefusedByWhatStandsOpposite() {
        // Armor Tail and a Dark type refuse a status move aimed at them;
        // neither has anything to say about what you do to your own partner.
        var board = lineup()
        board.theirs[0].build.ability = "Armor Tail"
        board.theirs[1].build.ability = "Armor Tail"
        let out = TurnModel.resolve(board,
                                    mine: Play(left: .attackingAlly(move: at(board.mine[0], "Skill Swap")), right: .pass),
                                    theirs: Play(left: .pass, right: .pass))
        check("the swap happened anyway",
              out.mine[0].build.ability == "Grassy Surge" && out.mine[1].build.ability == "Trace",
              "\(out.mine[0].build.ability) and \(out.mine[1].build.ability)")
    }
}
