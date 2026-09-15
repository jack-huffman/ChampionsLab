//  SpeedAndProtectTests.swift
//  What moves first, what Protect is worth, and how long speed control lasts.
//
//      swift test --filter SpeedAndProtectTests

import XCTest
@testable import ChampionsLab

final class SpeedAndProtectTests: HarnessCase {
    /// Speed as the field leaves it
    @MainActor func testSpeedOnTheField() throws {
print("\n== speed on the field ==")
    func runner(_ name: String, item: String, ability: String? = nil) -> Combatant {
        let f = form(name)
        var sp = Array(repeating: 0, count: 6); sp[Stat.speed.rawValue] = 32
        return Combatant(form: f, ability: ability ?? f.abilities.first?.name ?? "",
                         item: item, sp: sp, alignment: Alignment.named("Jolly"))
    }
    let plainField = Field(isDoubles: true)
    let rainField = Field(weather: .rain, isDoubles: true)
    let chomp = runner("Garchomp", item: "Choice Scarf")
    print("  Choice Scarf Garchomp: \(chomp.stat(.speed)) raw, \(chomp.speed(in: plainField)) on the field")
    check("a Choice Scarf is worth half again",
          chomp.speed(in: plainField) == Int(Double(chomp.stat(.speed)) * 1.5),
          "\(chomp.speed(in: plainField))")
    let orbChomp = runner("Garchomp", item: "Life Orb")
    check("and an item that does nothing to Speed does nothing",
          orbChomp.speed(in: plainField) == orbChomp.stat(.speed))

    let swimmer = runner("Basculegion", item: "Life Orb", ability: "Swift Swim")
    print("  Swift Swim Basculegion: \(swimmer.speed(in: plainField)) dry, \(swimmer.speed(in: rainField)) in rain")
    check("Swift Swim doubles Speed in rain",
          swimmer.speed(in: rainField) == swimmer.stat(.speed) * 2,
          "\(swimmer.speed(in: rainField))")
    check("and does nothing without it",
          swimmer.speed(in: plainField) == swimmer.stat(.speed))
    let surfer = runner("Mega Raichu Y", item: "Raichunite Y", ability: "Surge Surfer")
    check("Surge Surfer doubles Speed on Electric Terrain",
          surfer.speed(in: Field(terrain: .electric, isDoubles: true)) == surfer.stat(.speed) * 2)

    // A Choice item locks you into the first move, and an Assault Vest forbids
    // status outright, so neither can spend a turn setting up.
    check("a Choice item cannot spend a turn setting up",
          !DuelEngine.canSpendATurn(runner("Garchomp", item: "Choice Band")))
    check("nor can an Assault Vest",
          !DuelEngine.canSpendATurn(runner("Garchomp", item: "Assault Vest")))
    check("but anything else can",
          DuelEngine.canSpendATurn(runner("Garchomp", item: "Life Orb")))

    // -- Protect, and the clock speed control runs on ------------------------
    //
    // Most VGC sets carry a Protect and the battle model had never heard of it.
    // A turn of damage refused is a turn added to whatever clock the other side
    // is racing, and it is the answer to being focused down.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Protect in a duel, and the clock speed control runs on
    @MainActor func testProtectAndTheClock() throws {
print("\n== protect ==")
    func move(_ n: String) -> Move { store.data.moves.values.first { $0.name == n }! }
    check("Protect is recognised", DuelEngine.protects(in: [move("Protect")]) != nil)
    check("so are its relatives",
          DuelEngine.protects(in: [move("Spiky Shield")]) != nil
            && DuelEngine.protects(in: [move("Baneful Bunker")]) != nil)
    check("Wide Guard is not one of them, it does something else",
          DuelEngine.protects(in: [move("Wide Guard")]) == nil)
    check("nor is Endure, which leaves you on one health point",
          DuelEngine.protects(in: [move("Endure")]) == nil)

    // It has to cost the attacker a turn, both ways round.
    let plain = Duel(mine: form("Garchomp"), theirs: form("Incineroar"),
                     outgoing: 0.5, incoming: 0.5, mySpeed: 200, theirSpeed: 100,
                     myBestMove: "-", theirBestMove: "-")
    var guarded = plain
    guarded.theirProtect = "Protect"
    print("  two hits to knock out: \(plain.myTurnsToKO) turns, \(guarded.myTurnsToKO) against a Protect")
    check("a Protect on the far side adds a turn to your clock",
          guarded.myTurnsToKO == plain.myTurnsToKO + 1,
          "\(guarded.myTurnsToKO) vs \(plain.myTurnsToKO)")
    var guardedMe = plain
    guardedMe.myProtect = "Protect"
    check("and one on yours adds a turn to theirs",
          guardedMe.theirTurnsToKO == plain.theirTurnsToKO + 1)
    check("a Protect nobody is running changes nothing",
          plain.myTurnsToKO == 2 && plain.theirTurnsToKO == 2,
          "\(plain.myTurnsToKO)/\(plain.theirTurnsToKO)")

    // Durations come out of the move text, not a table in the code.

print("\n== the clock ==")
    check("Tailwind reads as four turns", Matchup.duration(of: move("Tailwind")) == 4,
          "\(Matchup.duration(of: move("Tailwind")) ?? -1)")
    check("Trick Room reads as five", Matchup.duration(of: move("Trick Room")) == 5,
          "\(Matchup.duration(of: move("Trick Room")) ?? -1)")
    check("and a move with no duration reads as none",
          Matchup.duration(of: move("Protect")) == nil)

    if let opponent = store.data.metaTeams.first(where: { $0.name == "Big Six" }) {
        let theirSix = store.opponentTeam(opponent)
        var windows = 0
        for saved in store.teams {
            let grid = Matchup(mine: saved, theirs: theirSix, rules: store.rulebook,
                               field: Field(isDoubles: true))
            guard let w = grid.window() else { continue }
            windows += 1
            let verdictText = w.closes ? "closes" : "\(w.shortfall) short"
            let padded = saved.name.padding(toLength: max(saved.name.count, 24),
                                            withPad: " ", startingAt: 0)
            print("  \(padded) \(w.tactic) \(w.turns) turns = \(w.actions) actions, "
                  + "needs \(w.needed) -> \(verdictText)")
            check("\(saved.name): doubles gives two attacking turns a turn",
                  w.actions == w.turns * 2, "\(w.actions)")
            check("\(saved.name): the cost of the four that matter is what is counted",
                  w.needed == w.cost.prefix(4).reduce(0) { $0 + $1.turns })
        }
        check("speed control was found on the saved teams", windows > 0, "\(windows)")
    }

    // -- every team is its own team ---------------------------------------
    //
    // Meta team ids were "tour-<placing>", and placing repeats across events,
    // so 112 teams shared 17 ids. Everything keyed on the id -- the built-team
    // cache, the opponent pool, the versus picker -- collapsed them onto
    // whichever arrived first, and 95 of the published lists were never scored.

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }

    /// Protect covers the turn it was used on, and then it is over
    ///
    /// The flag was cleared at the top of the next resolve rather than at the
    /// end of its own turn. Damage was right either way — nothing got through
    /// on the following turn — but the board handed back still said protected,
    /// so the card drew a shield over a Pokémon that was open again, and
    /// anything reading the board between turns read it wrong.
    @MainActor func testProtectEndsWithItsTurn() throws {
        print("\n== protect ends with its turn ==")
        let mine = fighters([("Whimsicott", "Focus Sash", ["Protect", "Moonblast"]),
                             ("Farigiraf", "Mental Herb", ["Protect", "Psychic"])])
        let theirs = fighters([("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                               ("Rillaboom", "Life Orb", ["Wood Hammer", "Protect"])])
        let start = Board(mine: mine, theirs: theirs, rules: store.rulebook,
                          field: Field(isDoubles: true), alreadyEvolved: false)

        let guarded = TurnModel.resolve(start,
            mine: Play(left: .attack(move: at(start.mine[0], "Protect"), target: 0), right: .pass),
            theirs: Play(left: .attack(move: at(start.theirs[0], "Earthquake"), target: 0),
                         right: .pass), rolling: false)
        print("  after the turn: protected \(guarded.mine[0].isProtected), "
              + "protected last turn \(guarded.mine[0].protectedLast)")
        check("the shield is down once the turn is over", !guarded.mine[0].isProtected)
        check("but the turn remembers it, which is what the next Protect is priced off",
              guarded.mine[0].protectedLast)

        // The point of the flag coming down: the following turn it takes a hit.
        let after = TurnModel.resolve(guarded,
            mine: Play(left: .pass, right: .pass),
            theirs: Play(left: .attack(move: at(guarded.theirs[0], "Earthquake"), target: 0),
                         right: .pass), rolling: false)
        let took = guarded.mine[0].hp - after.mine[0].hp
        print("  the turn after, an Earthquake took \(took)")
        check("and the Pokémon is open to damage again", took > 0, "took \(took)")

        print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED")
    }
}
