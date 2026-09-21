//  RandomOpponentTests.swift
//  Drawing an opponent rather than picking one: it comes from the ladder or
//  from your own teams, it is never the six you are bringing, and the id it
//  gives back is the ordinary kind so the rest of the lobby cannot tell.

import XCTest
@testable import ChampionsLab

@MainActor
final class RandomOpponentTests: HarnessCase {
    /// The lobby resolves an opponent id exactly one of three ways, and a
    /// drawn one has to land in the same net as a chosen one.
    private func resolves(_ id: String) -> Team? {
        if let meta = store.data.metaTeams.first(where: { $0.id == id }) {
            return store.opponentTeam(meta)
        }
        if id.hasPrefix("ladder-") { return store.ladderOpponent(id: id) }
        return store.teams.first { $0.id.uuidString == id }
    }

    func testADrawnOpponentIsAlwaysARealTeam() {
        for format in ["doubles", "singles"] {
            let pool = store.opponentPool(format: format, excluding: "")
            for _ in 0..<40 {
                guard let drawn = store.randomOpponent(format: format, excluding: "") else {
                    // Nothing to draw is a legitimate answer, but only when
                    // there was genuinely nothing there.
                    check("\(format): drew nothing only because the pool is empty", pool.isEmpty)
                    break
                }
                let team = resolves(drawn)
                check("\(format): \(drawn) is a team the lobby can open", team != nil, drawn)
                check("  with Pokemon on it", (team?.slots.count ?? 0) > 0, "\(team?.slots.count ?? 0)")
            }
        }
    }

    /// The format the app actually ships data for can always draw, and the
    /// lobby only offers the draw where the pool is not empty -- the singles
    /// lobby has no ladder behind it, so it gets no button rather than a
    /// button that does nothing.
    func testTheDrawIsOfferedExactlyWhereItWorks() {
        check("doubles has a pool", !store.opponentPool(format: "doubles", excluding: "").isEmpty)
        check("and so can always draw",
              store.randomOpponent(format: "doubles", excluding: "") != nil)
        let singles = store.opponentPool(format: "singles", excluding: "")
        check("singles draws exactly when it has a pool",
              singles.isEmpty == (store.randomOpponent(format: "singles", excluding: "") == nil),
              "\(singles.count) in the pool")
    }

    func testItNeverDrawsTheTeamYouAreBringing() {
        guard let mine = store.teams.first else {
            return check("there is a saved team to exclude", store.teams.isEmpty)
        }
        let id = mine.id.uuidString
        for _ in 0..<200 {
            let drawn = store.randomOpponent(format: mine.format, excluding: id)
            check("it drew something other than your own six", drawn != id, drawn ?? "nothing")
        }
    }

    /// Every id in the pool, not a sample of it. The pool took on a hundred
    /// and twelve teams in one go, and a draw landing on a broken one would
    /// surface as an empty team preview perhaps one game in a hundred --
    /// exactly the kind of thing a forty-draw sample walks straight past.
    func testEverySingleThingInThePoolIsAWholeTeam() {
        let pool = store.opponentPool(format: "doubles", excluding: "")
        check("the pool is the whole chooser, not just the ladder", pool.count > 100, "\(pool.count)")
        check("and has no id in it twice", Set(pool).count == pool.count,
              "\(pool.count - Set(pool).count) repeated")
        for id in pool {
            guard let team = resolves(id) else {
                check("\(id) resolves to a team", false); continue
            }
            check("\(team.name): enough to bring four", team.slots.count >= 4, "\(team.slots.count)")
            check("  every slot a real Pokemon",
                  team.slots.allSatisfy { $0.form(in: store.rulebook) != nil })
            check("  and every one of them with moves",
                  team.slots.allSatisfy { !$0.moves.isEmpty })
        }
    }

    /// The draw has to actually vary -- one that always returns the same team
    /// passes every other test here and is useless.
    func testTheDrawVariesWhenThereIsMoreThanOneToDrawFrom() {
        let pool = store.ladderTeams(format: "doubles").count
        check("the ladder offers more than one opponent", pool > 1, "\(pool)")
        var seen = Set<String>()
        for _ in 0..<200 {
            if let drawn = store.randomOpponent(format: "doubles", excluding: "") { seen.insert(drawn) }
        }
        check("two hundred draws found more than one of them", seen.count > 1, "\(seen.count)")
    }

    /// Your own teams join the pool, but only the ones built for the format
    /// being played -- being handed your singles six for a doubles game reads
    /// as a bug rather than a draw.
    func testOnlyYourTeamsForThisFormatCanBeDrawn() {
        let mine = Set(store.teams.map(\.id.uuidString))
        for format in ["doubles", "singles"] {
            let wrong = Set(store.teams.filter { $0.format != format }.map(\.id.uuidString))
            for _ in 0..<200 {
                guard let drawn = store.randomOpponent(format: format, excluding: ""),
                      mine.contains(drawn) else { continue }
                check("\(format): a drawn team of yours is built for it",
                      !wrong.contains(drawn), drawn)
            }
        }
    }
}
