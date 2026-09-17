//  ChoreographyTests.swift
//  The moves' choreography loads, resolves, and lands on the arena.
//
//      swift test --filter ChoreographyTests
//
//  data/animations.json is translated from the Showdown client by
//  Scripts/mkanimations.py. This holds what the app relies on: that the table
//  is there and covers what people bring, that an alias chain and an include
//  resolve to real steps, and that MoveTimeline places a recipe between the
//  right two seats on the right clock.

import XCTest
@testable import ChampionsLab

final class ChoreographyTests: HarnessCase {
    let table = Choreography.shared

    @MainActor func testTheTableIsThereAndCovers() throws {
print("\n== the table ==")
        check("the table loaded", !table.isEmpty, "\(table.moves.count) moves")
        check("it says where it came from", table.source.contains("MIT"))
        let ours = store.data.moves.values.map(\.name)
        let covered = ours.filter { table.recipe(forMove: $0) != nil }
        print("  \(covered.count) of \(ours.count) moves in the dex have a recipe")
        check("nine in ten moves have a recipe", Double(covered.count) / Double(max(1, ours.count)) > 0.85)
        for name in ["Flamethrower", "Dragon Claw", "Double-Edge", "Heat Wave", "Follow Me", "Sucker Punch", "Earthquake"] {
            check("\(name) resolves", table.recipe(forMove: name)?.steps.isEmpty == false)
        }
        check("every sprite a recipe names has a size",
              Set(table.moves.values.flatMap { $0.steps ?? [] }.compactMap(\.sprite))
                .subtracting(["attacker", "defender"]).allSatisfy { table.sprites[$0] != nil })
        check("a move without a recipe still has the client's fallback",
              table.fallback(category: "Physical", targetsSelf: false)?.steps.isEmpty == false
                && table.fallback(category: "Special", targetsSelf: false)?.steps.isEmpty == false
                && table.fallback(category: "Other", targetsSelf: true)?.steps.isEmpty == false)
        check("a flinch has its own", table.status("flinch")?.steps.isEmpty == false)

print("\n== aliases and includes ==")
        let claw = try XCTUnwrap(table.recipe(forMove: "Dragon Claw"), "Dragon Claw has no recipe")
        check("Dragon Claw borrows the claw attack: claws fly",
              claw.steps.contains { $0.kind == .effect && ($0.sprite?.contains("claw") ?? false) })
        let follow = try XCTUnwrap(table.recipe(forMove: "Follow Me"), "Follow Me has no recipe")
        check("Follow Me's dance was inlined: the user leans", follow.steps.contains { $0.kind == .move && $0.who == .attacker })
        check("and the pointer is still there", follow.steps.contains { $0.sprite == "pointer" })
        check("no include is left standing", follow.steps.allSatisfy { $0.kind != .include })
        check("Heat Wave is written against every target", table.recipe(forMove: "Heat Wave")?.spread == true)
    }

    func testARecipeLandsBetweenTheSeats() throws {
        let stage = MoveTimeline.Stage(size: CGSize(width: 800, height: 480), singles: false)
        let mine = Seat(mine: true, slot: 0), theirs = Seat(mine: false, slot: 1)
        func home(_ seat: Seat) -> CGPoint { stage.project(stage.home(seat)) }
        let flame = try XCTUnwrap(table.recipe(forMove: "Flamethrower"), "Flamethrower has no recipe")
        let timeline = MoveTimeline.build(flame, attacker: mine, targets: [theirs], sizes: table.sprites, stage: stage)
print("\n== Flamethrower, on the arena ==")
        print("  \(timeline.sprites.count) sprites, \(timeline.leans.count) leans, \(timeline.washes.count) washes, \(String(format: "%.2fs", timeline.duration))")
        check("every effect became a sprite", timeline.sprites.count == flame.steps.filter { $0.kind == .effect }.count)
        check("each starts before it ends", timeline.sprites.allSatisfy { $0.start <= $0.end })
        check("and the whole thing takes a moment, not a minute", timeline.duration > 0.3 && timeline.duration < 5,
              String(format: "%.2fs", timeline.duration))
        let from = home(mine), to = home(theirs)
        let fireballs = timeline.sprites.filter { $0.name == "fireball" }
        check("the fireballs leave from the user",
              fireballs.allSatisfy { hypot($0.from.point.x - from.x, $0.from.point.y - from.y) < 80 },
              fireballs.map { "\(Int($0.from.point.x)),\(Int($0.from.point.y))" }.joined(separator: " "))
        check("and arrive at the target",
              fireballs.allSatisfy { hypot($0.to.point.x - to.x, $0.to.point.y - to.y) < 80 })
        let mid = try XCTUnwrap(fireballs.first.flatMap { MoveTimeline.pose(of: $0, at: ($0.start + $0.end) / 2) })
        // Flamethrower eases out, so half the time is most of the way; what
        // holds is that it is strictly between the two.
        check("half-way through, one is on its way",
              mid.point.x > min(from.x, to.x) + 20 && mid.point.x < max(from.x, to.x) - 20,
              "\(Int(mid.point.x)) between \(Int(from.x)) and \(Int(to.x))")

print("\n== a contact attack queues the user's leans ==")
        let contact = try XCTUnwrap(table.fallback(category: "Physical", targetsSelf: false))
        let lunge = MoveTimeline.build(table.recipe(forMove: "Tackle") ?? contact, attacker: mine, targets: [theirs],
                                       sizes: table.sprites, stage: stage)
        let leans = lunge.leans.filter { $0.seat == mine }
        check("the user leans more than once", leans.count >= 2, "\(leans.count)")
        check("one after the other", zip(leans, leans.dropFirst()).allSatisfy { $0.end <= $1.start + 0.001 })
        check("and comes home at the end", leans.last.map { abs($0.offset.width) < 1 && abs($0.offset.height) < 1 } ?? false,
              leans.last.map { "\($0.offset)" } ?? "none")

print("\n== depth slides up and to the right, as the client draws it ==")
        let behind = Choreography.Coordinate(d: 1, db: 30)
        let stepIn = Choreography.Step(kind: .effect, sprite: "wisp", from: Choreography.Pose(x: .init(d: 1), y: .init(d: 1), z: .init(d: 1)),
                                       to: Choreography.Pose(x: .init(d: 1), y: .init(d: 1), z: behind))
        let one = MoveTimeline.build(.init(steps: [stepIn], spread: false), attacker: mine, targets: [theirs],
                                     sizes: table.sprites, stage: stage).sprites[0]
        check("behind the far side is further right", one.to.point.x > one.from.point.x)
        check("and a little higher", one.to.point.y < one.from.point.y)
        let near = MoveTimeline.build(.init(steps: [stepIn], spread: false), attacker: theirs, targets: [mine],
                                      sizes: table.sprites, stage: stage).sprites[0]
        check("behind the near side is further left", near.to.point.x < near.from.point.x)

print("\n== a spread move plays once per target ==")
        let wave = try XCTUnwrap(table.recipe(forMove: "Heat Wave"))
        let single = MoveTimeline.build(wave, attacker: mine, targets: [theirs], sizes: table.sprites, stage: stage)
        let both = MoveTimeline.build(wave, attacker: mine, targets: [theirs, Seat(mine: false, slot: 0)], sizes: table.sprites, stage: stage)
        check("two targets, more happens", both.leans.count + both.sprites.count > single.leans.count + single.sprites.count,
              "\(single.leans.count + single.sprites.count) then \(both.leans.count + both.sprites.count)")
        check("and both seats get their turn", Set(both.leans.map(\.seat)).isSuperset(of: [theirs, Seat(mine: false, slot: 0)]))
    }
}
