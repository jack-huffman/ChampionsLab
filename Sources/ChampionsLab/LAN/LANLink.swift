//  LANLink.swift
//  A game between two people, from one side's chair.
//
//  The host holds the truth and runs the turns; the guest sends choices and
//  shows what comes back. Both screens run the same BattleSession, and the
//  session hands the link everything that would otherwise go to the engine
//  or the model: the orders for a turn, who comes in for a faint, who comes
//  in for a pivot. The link answers each with a snapshot -- the board as
//  that player may see it, and what is asked of them next -- and the session
//  shows it. The host's own screen gets a snapshot too, reduced the same
//  way, so what the host sees of the guest is what the guest sees of the
//  host.

import Foundation

@MainActor
final class LANLink: ObservableObject {
    enum Role { case host, guest }

    let role: Role
    let theirName: String
    let singles: Bool
    /// My team, whole. Theirs as they showed it: a name and six forms.
    let myTeam: Team
    let theirSix: Wire.Six
    /// The engine's advice is the player's to switch on. Remembered.
    @Published var engineEnabled: Bool {
        didSet { UserDefaults.standard.set(engineEnabled, forKey: "lanEngine") }
    }
    /// The screen playing the game, once it is up.
    weak var session: BattleSession?
    /// The latest snapshot, held for a screen that is not up yet.
    private(set) var latest: Wire.Snapshot?
    /// Numbers each request, so an answer cannot land on the wrong turn.
    private(set) var rqid = 0

    private let send: (Wire.Message) -> Void

    // The host's side of the table.
    private var truth: Board?
    private var turn = 1
    private var hostBringing: [String]?
    private var guestTeam: Team?
    private var guestBringing: [String]?
    private var hostPlay: (rqid: Int, play: Play)?
    private var guestPlay: (rqid: Int, play: Play)?
    private var hostPicks: [Wire.Pick]?
    private var guestPicks: [Wire.Pick]?
    private var awaiting: (host: [Int], guest: [Int])?

    init(role: Role, theirName: String, singles: Bool, myTeam: Team, theirSix: Wire.Six,
         send: @escaping (Wire.Message) -> Void) {
        self.role = role
        self.theirName = theirName
        self.singles = singles
        self.myTeam = myTeam
        self.theirSix = theirSix
        self.send = send
        engineEnabled = UserDefaults.standard.object(forKey: "lanEngine") as? Bool ?? false
    }

    /// Their six as a team of forms, for Team Preview and the record.
    var theirTeamShown: Team {
        var team = Team(name: theirSix.name, format: singles ? "singles" : "doubles")
        team.slots = theirSix.forms.map { TeamSlot(formID: $0) }
        return team
    }

    // MARK: - What the session hands over

    /// My four, in order, from Team Preview.
    func chose(bringing: [String]) {
        switch role {
        case .guest: send(.preview(team: myTeam, bringing: bringing))
        case .host: hostBringing = bringing; tryOpen()
        }
    }

    func chose(play: Play) {
        switch role {
        case .guest: send(.choice(rqid: rqid, play: play))
        case .host: hostPlay = (rqid, play); tryResolve()
        }
    }

    func chose(replacements picks: [(slot: Int, bench: Int)]) {
        let wired = picks.map { Wire.Pick(slot: $0.slot, bench: $0.bench) }
        switch role {
        case .guest: send(.sendIn(rqid: rqid, picks: wired))
        case .host: hostPicks = wired; tryReplace()
        }
    }

    func chose(pivotBench bench: Int) {
        switch role {
        case .guest: send(.pivot(rqid: rqid, bench: bench))
        case .host: resumePivot(bench)
        }
    }

    // MARK: - What arrives

    func handle(_ message: Wire.Message) {
        switch message {
        case .preview(let team, let bringing):
            guard role == .host else { return }
            guestTeam = team
            guestBringing = bringing
            tryOpen()
        case .snapshot(let snapshot):
            guard role == .guest else { return }
            rqid = snapshot.rqid
            latest = snapshot
            session?.receive(snapshot)
        case .choice(let id, let play):
            guard role == .host, id == rqid else { return }
            guestPlay = (id, play)
            tryResolve()
        case .sendIn(let id, let picks):
            guard role == .host, id == rqid else { return }
            guestPicks = picks
            tryReplace()
        case .pivot(let id, let bench):
            guard role == .host, id == rqid, truth?.pendingPivot?.mine == false else { return }
            resumePivot(bench)
        default:
            break
        }
    }

    /// A screen that comes up after the first snapshot arrived.
    func attach(_ session: BattleSession) {
        self.session = session
        if let latest { session.receive(latest) }
    }

    // MARK: - The host's table

    private func tryOpen() {
        guard role == .host, truth == nil, let mineBringing = hostBringing,
              let guestTeam, let guestBringing else { return }
        var board = Board.opening(mine: myTeam, bringing: mineBringing, theirs: guestTeam,
                                  theirBringing: guestBringing, rules: Store.shared.rulebook,
                                  singles: singles, sendOut: true)
        // Either side's pivot stops the turn for whoever has the choice.
        board.asksBeforePivot = true
        board.asksTheirsBeforePivot = true
        truth = board
        turn = 1
        rqid = 1
        deal(asking: .orders, guestAsking: .orders)
    }

    private func tryResolve() {
        guard let board = truth, let mine = hostPlay, mine.rqid == rqid,
              let theirs = guestPlay, theirs.rqid == rqid else { return }
        hostPlay = nil
        guestPlay = nil
        truth = TurnModel.resolve(board, mine: mine.play, theirs: theirs.play, rolling: true)
        afterTurn()
    }

    private func resumePivot(_ bench: Int) {
        guard let board = truth, board.pendingPivot != nil else { return }
        truth = TurnModel.resume(board, sendingIn: bench, rolling: true)
        afterTurn()
    }

    private func tryReplace() {
        guard var board = truth, let awaiting else { return }
        let hostReady = awaiting.host.isEmpty || hostPicks != nil
        let guestReady = awaiting.guest.isEmpty || guestPicks != nil
        guard hostReady, guestReady else { return }
        board.replaceFallen(mine: (hostPicks ?? []).map { (slot: $0.slot, bench: $0.bench) },
                            theirs: (guestPicks ?? []).map { (slot: $0.slot, bench: $0.bench) })
        truth = board
        self.awaiting = nil
        hostPicks = nil
        guestPicks = nil
        turn += 1
        rqid += 1
        deal(asking: .orders, guestAsking: .orders)
    }

    /// The turn is resolved, or resumed: what is asked of each side next.
    private func afterTurn() {
        guard let board = truth else { return }
        rqid += 1
        if let pivot = board.pendingPivot {
            deal(asking: pivot.mine ? .pivot(pivot.slot) : .wait,
                 guestAsking: pivot.mine ? .wait : .pivot(pivot.slot))
            return
        }
        if board.isOut(mine: false) || board.isOut(mine: true) {
            let hostWon = board.isOut(mine: false)
            deal(asking: .over(youWon: hostWon), guestAsking: .over(youWon: !hostWon))
            return
        }
        let hostGaps = board.gapsOfMine
        let guestGaps = board.flipped.gapsOfMine
        if hostGaps.isEmpty, guestGaps.isEmpty {
            turn += 1
            deal(asking: .orders, guestAsking: .orders)
            return
        }
        awaiting = (hostGaps, guestGaps)
        hostPicks = nil
        guestPicks = nil
        deal(asking: hostGaps.isEmpty ? .wait : .sendIn(hostGaps),
             guestAsking: guestGaps.isEmpty ? .wait : .sendIn(guestGaps))
    }

    /// Both snapshots off the one truth: the guest's from their chair with
    /// the host's side as shown, the host's the other way round.
    private func deal(asking: Wire.Asking, guestAsking: Wire.Asking) {
        guard let board = truth else { return }
        send(.snapshot(Wire.Snapshot(rqid: rqid, turn: turn,
                                     board: board.asTheOtherPlayerSeesIt().wired, asking: guestAsking)))
        let mine = Wire.Snapshot(rqid: rqid, turn: turn,
                                 board: board.flipped.asTheOtherPlayerSeesIt().wired, asking: asking)
        latest = mine
        session?.receive(mine)
    }
}
