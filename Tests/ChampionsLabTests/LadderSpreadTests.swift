//  LadderSpreadTests.swift
//  A team off the ladder gets a spread worth having, not the same one six times.
//
//      swift test --filter LadderSpreadTests

import XCTest
@testable import ChampionsLab

@MainActor
final class LadderSpreadTests: HarnessCase {

    /// The report this came from: every Pokémon on "Garchomp Core" had
    /// 2 HP / 32 Attack / 32 Speed, which is not a spread anybody runs and
    /// obviously not a measured one either.
    func testTheSixDoNotAllShareOneSpread() {
        let teams = store.ladderTeams(format: "doubles")
        check("there are teams to look at", !teams.isEmpty)
        var identical: [String] = []
        for ladder in teams {
            let spreads = Set(ladder.team.slots.map { "\($0.sp)" })
            print("  \(ladder.team.name): \(spreads.count) distinct spreads across \(ladder.team.slots.count)")
            if spreads.count == 1, ladder.team.slots.count > 1 { identical.append(ladder.team.name) }
        }
        check("no team hands the same spread to all six", identical.isEmpty,
              identical.joined(separator: ", "))
    }

    func testNobodyIsHandedTheOldDefault() {
        var flat = Array(repeating: 0, count: 6)
        flat[Stat.attack.rawValue] = 32
        flat[Stat.speed.rawValue] = 32
        flat[Stat.hp.rawValue] = 2
        var wearing: [String] = []
        for ladder in store.ladderTeams(format: "doubles") {
            for slot in ladder.team.slots where slot.sp == flat {
                wearing.append(slot.form(in: store.rulebook)?.formLabel ?? slot.formID)
            }
        }
        // It is a legal spread and something could legitimately land on it,
        // but every Pokemon landing on it was the bug.
        check("it is not what everybody gets", wearing.count < 3,
              "\(wearing.count): \(wearing.prefix(6).joined(separator: ", "))")
    }

    func testEverySpreadIsLegalAndSpent() {
        for ladder in store.ladderTeams(format: "doubles") {
            for slot in ladder.team.slots {
                let who = slot.form(in: store.rulebook)?.formLabel ?? slot.formID
                check("\(who) is inside the cap",
                      slot.sp.reduce(0, +) <= store.data.rules.spTotal, "\(slot.sp.reduce(0, +))")
                check("  and inside the per-stat cap",
                      slot.sp.allSatisfy { $0 >= 0 && $0 <= store.data.rules.spPerStat }, "\(slot.sp)")
                check("  and spends most of what it has",
                      slot.sp.reduce(0, +) >= store.data.rules.spTotal - 6, "\(slot.sp.reduce(0, +))")
                check("  with an alignment that exists",
                      Alignment.all.contains { $0.name == slot.alignmentName }, slot.alignmentName)
            }
        }
    }

    /// A bulky Pokémon should not be handed a sweeper's spread.
    func testAWallIsNotGivenAnAttackersPoints() {
        guard let wallForm = store.data.forms.first(where: { $0.formLabel == "Incineroar" }),
              let chomp = store.data.forms.first(where: { $0.formLabel == "Garchomp" }) else {
            return check("both are in the dex", false)
        }
        let planner = MetaModel.planner(store: store, format: "doubles")
        let wall = planner.plan(for: wallForm)
        let sweeper = planner.plan(for: chomp)
        print("  Incineroar \(wall.sp) \(wall.alignment.name)")
        print("  Garchomp  \(sweeper.sp) \(sweeper.alignment.name)")
        check("they are not given the same points", wall.sp != sweeper.sp)
        check("the Garchomp is faster than the Incineroar",
              sweeper.sp[Stat.speed.rawValue] > wall.sp[Stat.speed.rawValue],
              "\(sweeper.sp[Stat.speed.rawValue]) against \(wall.sp[Stat.speed.rawValue])")
    }
}
