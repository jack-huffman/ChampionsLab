//  LANLinkTests.swift
//  Two links on one table: the host's and the guest's, wired to each other
//  in memory, play a game through the same messages they would send over
//  the network.

import XCTest
@testable import ChampionsLab

final class LANLinkTests: HarnessCase {
    /// The two ends, each one's send delivered to the other's handle.
    @MainActor private func table() -> (host: LANLink, guest: LANLink, hostTeam: Team, guestTeam: Team) {
        let hostTeam = fighters([("Incineroar", "Sitrus Berry", ["Fake Out", "Knock Off", "Protect"]),
                                 ("Garchomp", "Life Orb", ["Earthquake", "Protect"]),
                                 ("Rillaboom", "Assault Vest", ["Wood Hammer"]),
                                 ("Whimsicott", "Focus Sash", ["Tailwind"])])
        let guestTeam = fighters([("Kingambit", "Black Glasses", ["Kowtow Cleave", "Protect"]),
                                  ("Sneasler", "Grassy Seed", ["Close Combat"]),
                                  ("Milotic", "Leftovers", ["Scald"]),
                                  ("Farigiraf", "Sitrus Berry", ["Psychic"])])
        let rules = store.rulebook
        let hostSix = Wire.Six(name: hostTeam.name, forms: hostTeam.slots.compactMap { $0.form(in: rules)?.id })
        let guestSix = Wire.Six(name: guestTeam.name, forms: guestTeam.slots.compactMap { $0.form(in: rules)?.id })
        var toGuest: [Wire.Message] = [], toHost: [Wire.Message] = []
        let host = LANLink(role: .host, theirName: "Sam", singles: false, myTeam: hostTeam, theirSix: guestSix) { toGuest.append($0) }
        let guest = LANLink(role: .guest, theirName: "Jack", singles: false, myTeam: guestTeam, theirSix: hostSix) { toHost.append($0) }
        // Delivery is by hand, after each move of the game, so the test can
        // look at what crossed.
        pump = {
            while !toGuest.isEmpty || !toHost.isEmpty {
                let g = toGuest; toGuest = []
                for m in g { guest.handle(m) }
                let h = toHost; toHost = []
                for m in h { host.handle(m) }
            }
        }
        return (host, guest, hostTeam, guestTeam)
    }
    private var pump: () -> Void = {}

    @MainActor func testAGameOpensAndATurnPlaysOverTheLink() {
        let (host, guest, hostTeam, guestTeam) = table()
        let hostScreen = BattleSession(rules: store.rulebook, playback: TurnPlayback())
        let guestScreen = BattleSession(rules: store.rulebook, playback: TurnPlayback())
        hostScreen.link = host; host.attach(hostScreen)
        guestScreen.link = guest; guest.attach(guestScreen)

        guest.chose(bringing: guestTeam.slots.map(\.formID))
        host.chose(bringing: hostTeam.slots.map(\.formID))
        pump()
        check("both screens have a board", hostScreen.board != nil && guestScreen.board != nil)
        check("the host sees its own team whole", hostScreen.board?.mine[0].build.item == "Sitrus Berry")
        check("and the guest's as shown", hostScreen.board?.theirs[0].build.item.isEmpty == true)
        check("the guest sees its own team whole", guestScreen.board?.mine[0].build.item == "Black Glasses")
        check("and the host's as shown", guestScreen.board?.theirs[0].build.item.isEmpty == true
              && guestScreen.board?.theirs[0].moves.isEmpty == true)
        check("both are asked for orders", !hostScreen.playing && !guestScreen.playing)

        // Turn one: Incineroar Fake Outs Kingambit; Kingambit Kowtow Cleaves Incineroar.
        let fakeOut = at(hostScreen.board!.mine[0], "Fake Out")
        hostScreen.leftPick = .attack(move: fakeOut, target: 0)
        hostScreen.rightPick = .pass
        hostScreen.playTurn()
        check("the host waits on the guest", hostScreen.playing && hostScreen.waitingOn != nil)
        pump()
        let cleave = at(guestScreen.board!.mine[0], "Kowtow Cleave")
        guestScreen.leftPick = .attack(move: cleave, target: 0)
        guestScreen.rightPick = .pass
        guestScreen.playTurn()
        pump()
        check("the turn resolved on both screens", hostScreen.turn == 2 && guestScreen.turn == 2, "\(hostScreen.turn) \(guestScreen.turn)")
        check("the guest saw the move the host used",
              guestScreen.board?.theirs[0].moves.map(\.name) == ["Fake Out"], "\(guestScreen.board?.theirs[0].moves.map(\.name) ?? [])")
        check("the host saw Kowtow Cleave, if it got off",
              hostScreen.board?.theirs[0].moves.map(\.name).allSatisfy { $0 == "Kowtow Cleave" } == true)
        check("the steps came to the guest from its chair",
              guestScreen.board?.steps.contains { $0.action?.byMine == false && $0.action?.move == "Fake Out" } == true)
        check("both are asked again", !hostScreen.playing && !guestScreen.playing)
        check("the request numbers agree", host.rqid == guest.rqid)
    }
}
