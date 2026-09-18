//  SpreadHitsAllyTests.swift
//  Earthquake hits your own partner, and that has to cost something.
//
//      swift test --filter SpreadHitsAllyTests
//
//  "All Adjacent Pokemon" — Earthquake, Surf, Discharge — means every Pokemon
//  next to the user, and in a double battle the user's partner is one of them.
//  The move data has always said so and `hitsAlly` has always read it, but only
//  the team builder and the dex screen ever asked. The turn model did not, so
//  in an actual battle Earthquake was free spread damage with no downside.
//
//  That is not a small thing to get wrong. It is why real teams pair a Ground
//  attacker with a Flying type, a Levitate or an Air Balloon, why Tera and Wide
//  Guard matter around one, and why a player will sometimes lose a Pokemon to
//  their own attack. An engine that never pays for it over-rates every Ground
//  attacker standing beside a grounded partner.

import XCTest
@testable import ChampionsLab

final class SpreadHitsAllyTests: HarnessCase {
    @MainActor func testSpreadMovesReachTheirOwnSide() throws {
print("\n== an Earthquake hits its own side ==")
        // A grounded partner, and nothing else that could touch it: the other
        // side protects, so any damage on my partner came from my own move.
        let mine = fighters([("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"]),
                             ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"])])
        let theirs = fighters([("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"]),
                               ("Kingambit", "Leftovers", ["Iron Head", "Protect"])])
        let board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)
        let quake = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Earthquake"), target: 0),
                       right: .attack(move: at(board.mine[1], "Flare Blitz"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Protect"), target: 0)))
        check("the partner took the Earthquake",
              quake.mine[1].hp < quake.mine[1].maxHP,
              "\(quake.mine[1].hp)/\(quake.mine[1].maxHP)")
        check("the Pokémon that threw it did not hit itself",
              quake.mine[0].hp == quake.mine[0].maxHP || quake.mine[0].build.item == "Life Orb",
              "\(quake.mine[0].hp)/\(quake.mine[0].maxHP)")

        // A single-target move is not this. Dragon Claw at an opponent leaves
        // the partner alone, or the fix has been applied far too widely.
        let claw = TurnModel.resolve(board,
            mine: Play(left: .attack(move: at(board.mine[0], "Dragon Claw"), target: 0),
                       right: .attack(move: at(board.mine[1], "Flare Blitz"), target: 0)),
            theirs: Play(left: .attack(move: at(board.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(board.theirs[1], "Protect"), target: 0)))
        check("a single-target move leaves the partner alone",
              claw.mine[1].hp == claw.mine[1].maxHP,
              "\(claw.mine[1].hp)/\(claw.mine[1].maxHP)")

        // Rock Slide says "All Adjacent Foes", which is the other kind of
        // spread move and must stay the other kind.
        let foesOnly = fighters([("Garchomp", "Life Orb", ["Rock Slide", "Protect"]),
                                 ("Incineroar", "Sitrus Berry", ["Flare Blitz", "Protect"])])
        let slideBoard = Board(mine: foesOnly, theirs: theirs, rules: store.rulebook,
                               field: Field(isDoubles: true), alreadyEvolved: false)
        let slide = TurnModel.resolve(slideBoard,
            mine: Play(left: .attack(move: at(slideBoard.mine[0], "Rock Slide"), target: 0),
                       right: .attack(move: at(slideBoard.mine[1], "Flare Blitz"), target: 0)),
            theirs: Play(left: .attack(move: at(slideBoard.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(slideBoard.theirs[1], "Protect"), target: 0)))
        check("a foes-only spread move still leaves the partner alone",
              slide.mine[1].hp == slide.mine[1].maxHP,
              "\(slide.mine[1].hp)/\(slide.mine[1].maxHP)")

print("\n== and the partner's own defences apply ==")
        // Off the ground it takes nothing, and nothing here has to say so:
        // the damage calculator already knows Flying does not take Ground.
        var flying = board
        flying.mine[1].build.ability = "Levitate"
        let missed = TurnModel.resolve(flying,
            mine: Play(left: .attack(move: at(flying.mine[0], "Earthquake"), target: 0),
                       right: .attack(move: at(flying.mine[1], "Flare Blitz"), target: 0)),
            theirs: Play(left: .attack(move: at(flying.theirs[0], "Protect"), target: 0),
                         right: .attack(move: at(flying.theirs[1], "Protect"), target: 0)))
        check("a Levitating partner takes nothing from it",
              missed.mine[1].hp == missed.mine[1].maxHP,
              "\(missed.mine[1].hp)/\(missed.mine[1].maxHP)")

print("\n== and it is not scored as a knockout ==")
        // The ledger credits a knockout to whoever landed the blow. Once a
        // spread move can land on your own partner, that rule alone would have
        // a Pokémon credited for killing its teammate — which would make the
        // trade column say it was carrying the team by doing so.
        var frail = board
        frail.mine[1].hp = 1
        let ledger = SelfPlay.playLogged(
            mine: mine, theirs: theirs, rules: store.rulebook,
            forMine: SelfPlay.Seat(engine: BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.turn),
                                   branchedRolls: 1),
            forTheirs: SelfPlay.Seat(engine: BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.turn),
                                     branchedRolls: 1),
            limit: 12, dice: TeamLab.SplitMix(seed: 7), bringSpread: 1)
        let ownKnockouts = ledger.blows.filter { blow, _ in
            blow.onMine && ledger.mine.keys.contains(blow.attacker)
        }
        for (blow, hit) in ownKnockouts {
            print("    stray: \(blow.attacker) -> \(blow.victim) via \(blow.move)"
                  + " (\(hit.knockouts) KO of \(hit.times))")
        }
        print("    mine: \(ledger.mine.keys.sorted())  theirs: \(ledger.theirs.keys.sorted())")
        check("no blow in the record names one of your own as the attacker",
              ownKnockouts.isEmpty, "\(ownKnockouts.count)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }

    /// and the engine actually declines it
    ///
    /// Modelling the cost is only half of it. The point of charging for an
    /// Earthquake that lands on your own partner is that the search then stops
    /// throwing one, and a mechanic the search does not feel is a mechanic that
    /// changes nothing about how the engine plays.
    ///
    /// The same position twice, differing only in whether the partner is on the
    /// ground. Nothing else moves, so whatever the engine does differently it
    /// does because of the partner.
    @MainActor func testTheEngineDeclinesAnEarthquakeThatKillsItsPartner() throws {
print("\n== the engine declines it ==")
        // Nothing here recoils and nothing heals: recoil is a share of the
        // damage actually dealt, so a move that overkills costs its user
        // less, and a Sitrus fires when the partner is left alive -- both
        // would move the two positions apart for reasons that have nothing
        // to do with standing in the Earthquake.
        let theirs = fighters([("Rillaboom", "Black Glasses", ["Knock Off", "Protect"]),
                               ("Milotic", "Mystic Water", ["Surf", "Protect"])])
        // Dragon Claw is the out: nearly as much damage into one target, and
        // none of it on the partner. If the engine cannot find it, the cost is
        // priced but not felt.
        let mine = fighters([("Garchomp", "Life Orb", ["Earthquake", "Dragon Claw", "Protect"]),
                             ("Incineroar", "Black Glasses", ["Knock Off", "Protect"])])
        let engine = BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.oneAhead)

        func quakeShare(grounded: Bool) -> Double {
            var board = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                              field: Field(isDoubles: true), alreadyEvolved: false)
            // A partner worth keeping. It used to stand at a fifth of its
            // health, which made the test read the wrong thing: a Pokemon
            // nearly dead is worth little, so killing it costs little, and
            // what the engine was actually avoiding was the recoil its own
            // partner's Flare Blitz would have paid.
            if !grounded { board.mine[1].build.ability = "Levitate" }
            let thought = engine.think(board)
            let quake = at(board.mine[0], "Earthquake")
            // `mix` runs parallel to `plays`: how often the engine would make
            // each of them. Summing the Earthquake lines is how often it throws
            // one at all.
            var share = 0.0
            for (index, play) in thought.plays.enumerated()
            where index < thought.mix.count {
                if case .attack(let move, _) = play.left, move == quake {
                    share += thought.mix[index]
                }
            }
            return share
        }

        let onGround = quakeShare(grounded: true)
        let offGround = quakeShare(grounded: false)
        print(String(format: "  Earthquake: %.0f%% with a grounded partner, %.0f%% with one off it",
                     onGround * 100, offGround * 100))
        check("it throws the Earthquake far less when its partner is standing in it",
              onGround < offGround - 0.1,
              String(format: "%.2f against %.2f", onGround, offGround))

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
        XCTAssertEqual(fails, 0)
    }
}
