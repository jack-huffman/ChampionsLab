//  BoardWire.swift
//  A board from the other chair.
//
//  A game between two people is one board on one machine and a view of it on
//  the other, and your left is their right: every side, every seat and every
//  badge has to be turned round on the way. What makes those pieces encodable
//  at all is in Board.swift, beside the types, because Swift synthesises it
//  nowhere else.

import Foundation

extension Board.Step.Event {
    /// The same event from the other chair.
    var flipped: Board.Step.Event {
        switch self {
        case .ability(let firing):
            return .ability(Board.Step.Firing(mine: !firing.mine, slot: firing.slot, name: firing.name))
        case .stat(let mine, let slot, let stat, let delta, let cause):
            return .stat(mine: !mine, slot: slot, stat: stat, delta: delta, cause: cause)
        case .status(let mine, let slot, let ailment):
            return .status(mine: !mine, slot: slot, ailment: ailment)
        case .item(let firing):
            return .item(Board.Step.Firing(mine: !firing.mine, slot: firing.slot, name: firing.name))
        }
    }
}

extension Board.Action {
    /// The same action from the other chair.
    var flipped: Board.Action {
        var out = Board.Action(byMine: !byMine, slot: slot, move: move, category: category, type: type)
        out.stopped = stopped
        out.target = target
        out.aimsAtUser = aimsAtUser
        out.aimsAtAlly = aimsAtAlly
        out.hits = hits
        return out
    }
}

extension Board.Step {
    /// The same step from the other chair: each side's columns swapped, and
    /// who acted and whose ability fired turned round.
    var flipped: Board.Step {
        var out = Board.Step(text: text, action: action?.flipped,
                             myHP: theirHP, theirHP: myHP,
                             myForms: theirForms, theirForms: myForms,
                             field: field, myTailwind: theirTailwind, theirTailwind: myTailwind,
                             trickRoom: trickRoom,
                             myBoosts: theirBoosts, theirBoosts: myBoosts,
                             abilities: abilities.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) },
                             events: events.map(\.flipped),
                             myStatus: theirStatus, theirStatus: myStatus,
                             myConfused: theirConfused, theirConfused: myConfused,
                             myProtected: theirProtected, theirProtected: myProtected,
                             myVanished: theirVanished, theirVanished: myVanished)
        out.action = action?.flipped
        // The badges the field draws over a Pokemon, turned round with it.
        // They were being dropped on the way to the other chair, so a LAN
        // opponent watched a critical hit, an immunity and a miss all land
        // as plain numbers -- or as no number at all.
        out.items = items.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) }
        out.criticals = criticals.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) }
        out.untouched = untouched.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) }
        out.missed = missed.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) }
        out.blocked = blocked.map { Firing(mine: !$0.mine, slot: $0.slot, name: $0.name) }
        return out
    }
}
