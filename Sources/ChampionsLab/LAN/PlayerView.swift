//  PlayerView.swift
//  The board as one player may see it.
//
//  One machine holds the truth of a game between two people. What the other
//  player receives is this: their own side whole -- it is their team, and
//  their choices depend on all of it -- and this side as the game has shown
//  it. A Pokemon that has not come out is the pair they would expect, as the
//  engine's own view of a hidden bench already works; one that has is its
//  form, its health, its status and stages, the moves it has declared, and
//  its item and ability only once they have acted in the open. Nothing of
//  what a Pokemon holds or how it was built crosses before the game itself
//  gives it away. This is Showdown's `|request|` and its `|split|` lines,
//  in the shape of a Board.

import Foundation

extension Board {
    /// This board from the other player's chair, with this side reduced to
    /// what they have been shown. `pendingPivot` and the turn's records come
    /// along, turned round, so the other player's screen can play the turn.
    func asTheOtherPlayerSeesIt() -> Board {
        // Your unseen bench becomes the pair they would expect, as the engine
        // already imagines it for them, then the chair turns.
        var out = asTheySeeIt.flipped
        // Nothing worked out from this side's builds may cross either.
        out.theirWorth = [:]
        out.theirBeats = [:]
        for index in out.theirs.indices {
            out.theirs[index] = out.theirs[index].asShown
        }
        out.steps = steps.map(\.flipped)
        return out
    }

    /// The pieces of a board that cross the wire, and a board rebuilt from
    /// them on the other side.
    struct Wired: Codable {
        var mine: [Fighter]
        var theirs: [Fighter]
        var field: Field
        var activeCount: Int
        var myTailwind: Int
        var theirTailwind: Int
        var trickRoom: Int
        var weatherTurns: Int
        var terrainTurns: Int
        var myScreens: Screens
        var theirScreens: Screens
        var story: [String]
        var steps: [Step]
        var myRoster: [String]
        var theirRoster: [String]
        var myBenchGuesses: [BenchGuess]
        var theirBenchGuesses: [BenchGuess]
        var pendingPivot: Pivot?
    }

    var wired: Wired {
        Wired(mine: mine, theirs: theirs, field: field, activeCount: activeCount,
              myTailwind: myTailwind, theirTailwind: theirTailwind, trickRoom: trickRoom,
              weatherTurns: weatherTurns, terrainTurns: terrainTurns,
              myScreens: myScreens, theirScreens: theirScreens,
              story: story, steps: steps, myRoster: myRoster, theirRoster: theirRoster,
              myBenchGuesses: myBenchGuesses, theirBenchGuesses: theirBenchGuesses,
              pendingPivot: pendingPivot)
    }

    init(wired: Wired) {
        self.init(mine: wired.mine, theirs: wired.theirs, field: wired.field)
        activeCount = wired.activeCount
        myTailwind = wired.myTailwind
        theirTailwind = wired.theirTailwind
        trickRoom = wired.trickRoom
        weatherTurns = wired.weatherTurns
        terrainTurns = wired.terrainTurns
        myScreens = wired.myScreens
        theirScreens = wired.theirScreens
        story = wired.story
        steps = wired.steps
        myRoster = wired.myRoster
        theirRoster = wired.theirRoster
        myBenchGuesses = wired.myBenchGuesses
        theirBenchGuesses = wired.theirBenchGuesses
        pendingPivot = wired.pendingPivot
    }
}

extension Fighter {
    /// This Pokemon as the other player has been shown it. What is public
    /// stays: form, health, status, stages, whether it is out, protected,
    /// charging, behind a substitute. What is private goes unless the game
    /// has given it away: the item, the ability, the moves not yet declared,
    /// and the spread, which nothing ever gives away.
    var asShown: Fighter {
        var shown = Combatant(form: build.form,
                              ability: abilityRevealed ? build.ability : "",
                              item: itemRevealed ? build.item : "",
                              sp: Array(repeating: 0, count: 6),
                              alignment: .neutral)
        shown.boosts = build.boosts
        shown.status = build.status
        shown.itemSpent = itemRevealed ? build.itemSpent : false
        shown.fallenAllies = build.fallenAllies
        shown.lastMoveFailed = build.lastMoveFailed
        // A stone is an item: the Mega to come stays hidden until it has come.
        var out = Fighter(build: shown, moves: moves.filter { revealedMoves.contains($0.id) },
                          hp: hp, pendingMega: itemRevealed || hasMegaEvolved ? pendingMega : nil)
        out.status = status
        out.asleepFor = asleepFor
        out.frozenFor = frozenFor
        out.confusedFor = confusedFor
        out.toxicTurns = toxicTurns
        out.seen = seen
        out.justArrived = justArrived
        out.arrivedThisTurn = arrivedThisTurn
        out.isProtected = isProtected
        out.protectedLast = protectedLast
        out.protectStreak = protectStreak
        out.substitute = substitute
        out.charging = charging
        out.chargingTarget = chargingTarget
        out.hidden = hidden
        out.hasMegaEvolved = hasMegaEvolved
        out.drawingFire = drawingFire
        out.switchStreak = switchStreak
        out.flinched = flinched
        out.revealedMoves = revealedMoves
        out.itemRevealed = itemRevealed
        out.abilityRevealed = abilityRevealed
        return out
    }
}
