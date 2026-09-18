//  LANService.swift
//  Finding the other people running the app on your network, asking one
//  of them for a battle, and the room the two of you share once they say
//  yes.
//
//  Bonjour does the finding: every copy that is visible advertises itself
//  and browses for the others. A request opens one TCP connection, and
//  everything after -- the answer, the room, the battle to come -- travels
//  on it as Wire messages. One battle at a time: a second request while
//  one is under way is turned away at the door.
//
//  The service lives on the main actor with the rest of the interface. The
//  network's own callbacks arrive on their queue and hop across with plain
//  values, so nothing here is touched from two places.

import Foundation
import Network
import AppKit

@MainActor
final class LANService: ObservableObject {
    static let shared = LANService()
    static let serviceType = "_championslab._tcp"

    /// Someone else on the network, as Bonjour found them.
    struct Peer: Identifiable, Hashable, @unchecked Sendable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        static func == (a: Peer, b: Peer) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum Status: Equatable {
        case off, starting, on, failed(String)
    }

    /// Where a battle with somebody stands.
    enum Stage: Equatable {
        case idle
        /// Asked someone, waiting on the answer.
        case inviting(String)
        /// Someone asked; the answer is ours.
        case invited(String)
        /// Both said yes: the shared room.
        case room
    }

    /// The room two players share before a battle: the host's format, each
    /// side's team as the other may see it, and whether each is ready.
    struct Room: Equatable {
        let hosting: Bool
        let theirName: String
        var singles = false
        /// My team whole, kept here for the battle; only `mySix` crosses.
        var myTeam: Team?
        var mySix: Wire.Six?
        var theirSix: Wire.Six?
        var iAmReady = false
        var theyAreReady = false
        var bothReady: Bool { iAmReady && theyAreReady && mySix != nil && theirSix != nil }
    }

    /// How you appear to the others. Remembered.
    @Published var displayName: String {
        didSet {
            UserDefaults.standard.set(displayName, forKey: "lanDisplayName")
            if status != .off { restartAdvertising() }
        }
    }
    /// Whether the others can see you. On unless you turn it off, and
    /// remembered, so a request finds you from the moment the app opens,
    /// whatever screen you are on.
    @Published var visible: Bool {
        didSet {
            UserDefaults.standard.set(visible, forKey: "lanVisible")
            if visible { start() } else { stop() }
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var room: Room?
    /// The battle under way, once the room has started one.
    @Published private(set) var battle: LANLink?
    /// The last thing worth saying: a decline, a connection lost.
    @Published var note: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var inbox = Data()
    private var theirName = ""
    /// The version of the app the other side runs, off its hello.
    @Published private(set) var theirApp: String?
    private let queue = DispatchQueue(label: "ChampionsLab.LAN")
    /// Tells our own advertisement apart from everyone else's.
    private let peerID = UUID().uuidString

    private init() {
        displayName = UserDefaults.standard.string(forKey: "lanDisplayName")
            ?? Host.current().localizedName ?? "Trainer"
        visible = UserDefaults.standard.object(forKey: "lanVisible") as? Bool ?? true
    }

    /// Onto the network at launch, if you are visible. The setting alone did
    /// nothing until the switch was flipped, so the screen said you were on
    /// the network while nobody could see you.
    func startIfVisible() {
        if visible, listener == nil { start() }
    }

    // MARK: - On and off the network

    func start() {
        guard listener == nil else { return }
        status = .starting
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: "\(displayName) \(peerID.prefix(4))", type: Self.serviceType,
                txtRecord: NWTXTRecord(["id": peerID, "name": displayName]))
            listener.stateUpdateHandler = { [weak self] state in
                let failure: String?
                if case .failed(let error) = state { failure = error.localizedDescription } else { failure = nil }
                let ready = state == .ready
                Task { @MainActor in self?.listenerChanged(ready: ready, failure: failure) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                let boxed = Unchecked(connection)
                Task { @MainActor in self?.arrived(boxed.value) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        let mine = peerID
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.peers(in: results, excluding: mine)
            Task { @MainActor in self?.peers = found }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        leaveRoom()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        peers = []
        status = .off
    }

    private func restartAdvertising() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        start()
    }

    private func listenerChanged(ready: Bool, failure: String?) {
        if let failure { status = .failed(failure) } else if ready { status = .on }
    }

    /// The others, by their TXT records: everyone advertising but us.
    nonisolated private static func peers(in results: Set<NWBrowser.Result>, excluding mine: String) -> [Peer] {
        results.compactMap { result -> Peer? in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            let id = txt.dictionary["id"] ?? result.endpoint.debugDescription
            guard id != mine else { return nil }
            let name = txt.dictionary["name"] ?? result.endpoint.debugDescription
            return Peer(id: id, name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Asking, and being asked

    func invite(_ peer: Peer) {
        guard stage == .idle, connection == nil else { return }
        theirName = peer.name
        stage = .inviting(peer.name)
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        attach(connection)
        connection.stateUpdateHandler = { [weak self] state in
            let failure: String?
            if case .failed(let error) = state { failure = error.localizedDescription }
            else if case .waiting(let error) = state { failure = error.localizedDescription }
            else { failure = nil }
            let ready = state == .ready
            Task { @MainActor in
                guard let self else { return }
                if ready {
                    self.send(.hello(name: self.displayName, version: Wire.version, app: Updater.current))
                    self.send(.invite(name: self.displayName))
                } else if let failure {
                    self.lost("Could not reach \(peer.name): \(failure)")
                }
            }
        }
        connection.start(queue: queue)
    }

    /// Somebody connected. One battle at a time: busy, the door is shut.
    private func arrived(_ connection: NWConnection) {
        guard self.connection == nil, stage == .idle else { connection.cancel(); return }
        attach(connection)
        connection.stateUpdateHandler = { [weak self] state in
            let failure: String?
            if case .failed(let error) = state { failure = error.localizedDescription } else { failure = nil }
            if let failure { Task { @MainActor in self?.lost("Connection lost: \(failure)") } }
        }
        connection.start(queue: queue)
    }

    func accept() {
        guard case .invited(let name) = stage else { return }
        send(.accept(name: displayName))
        room = Room(hosting: false, theirName: name)
        stage = .room
    }

    func decline() {
        guard case .invited = stage else { return }
        send(.decline)
        close()
    }

    func cancelInvite() {
        guard case .inviting = stage else { return }
        send(.leave)
        close()
    }

    // MARK: - The room

    func chooseTeam(_ team: Team?, rules: Rulebook) {
        guard var room else { return }
        let six = team.map { Wire.Six(name: $0.name, forms: $0.slots.compactMap { $0.form(in: rules)?.id }) }
        room.myTeam = team
        room.mySix = six
        room.iAmReady = false
        self.room = room
        send(.six(six))
        send(.ready(false))
    }

    /// Both ready: the host says so, and both go to Team Preview.
    func startBattle() {
        guard let room, room.hosting, room.bothReady, let myTeam = room.myTeam, let theirSix = room.theirSix else { return }
        send(.start)
        battle = LANLink(role: .host, theirName: room.theirName, singles: room.singles,
                         myTeam: myTeam, theirSix: theirSix) { [weak self] in self?.send($0) }
    }

    func setReady(_ ready: Bool) {
        guard var room, room.mySix != nil || !ready else { return }
        room.iAmReady = ready
        self.room = room
        send(.ready(ready))
    }

    func setSingles(_ singles: Bool) {
        guard var room, room.hosting else { return }
        room.singles = singles
        room.iAmReady = false
        room.theyAreReady = false
        self.room = room
        send(.format(singles: singles))
    }

    func leaveRoom() {
        guard connection != nil else { return }
        send(.leave)
        close()
    }

    // MARK: - The connection

    private func attach(_ connection: NWConnection) {
        self.connection = connection
        inbox = Data()
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            let failure = error?.localizedDescription
            Task { @MainActor in self?.received(data, complete: complete, failure: failure, on: connection) }
        }
    }

    private func received(_ data: Data?, complete: Bool, failure: String?, on connection: NWConnection) {
        guard self.connection === connection else { return }
        if let data { inbox.append(data) }
        do {
            for message in try Wire.unframe(&inbox) { handle(message) }
        } catch {
            lost("The other side spoke something this app does not understand.")
            return
        }
        if let failure { lost("Connection lost: \(failure)"); return }
        if complete { lost(stage == .idle ? nil : "\(theirName) left."); return }
        receiveLoop(on: connection)
    }

    private func handle(_ message: Wire.Message) {
        switch message {
        case .hello(let name, let version, let app):
            theirName = name
            theirApp = app
            if version != Wire.version {
                send(.decline)
                lost("\(name) is running version \(app) of the app, and you are on \(Updater.current). Both need the latest.")
            } else {
                // Answered in kind, so both sides know the other's version.
                if stage == .idle { send(.hello(name: displayName, version: Wire.version, app: Updater.current)) }
            }
        case .invite(let name):
            guard stage == .idle else { send(.decline); return }
            theirName = name
            stage = .invited(name)
            // Wherever they are in the app, they should know.
            NSApp.requestUserAttention(.criticalRequest)
            NSSound(named: "Glass")?.play()
        case .accept(let name):
            guard case .inviting = stage else { return }
            theirName = name
            room = Room(hosting: true, theirName: name)
            stage = .room
            send(.format(singles: false))
        case .decline:
            lost("\(theirName) declined.")
        case .format(let singles):
            room?.singles = singles
            room?.iAmReady = false
            room?.theyAreReady = false
        case .six(let six):
            room?.theirSix = six
            room?.theyAreReady = false
        case .ready(let ready):
            room?.theyAreReady = ready
        case .leave:
            lost(battle != nil ? "\(theirName) left the battle."
                 : stage == .room ? "\(theirName) left the room." : "\(theirName) withdrew.")
        case .start:
            guard let room, !room.hosting, let myTeam = room.myTeam, let theirSix = room.theirSix else { return }
            battle = LANLink(role: .guest, theirName: room.theirName, singles: room.singles,
                             myTeam: myTeam, theirSix: theirSix) { [weak self] in self?.send($0) }
        case .preview, .snapshot, .choice, .sendIn, .pivot:
            battle?.handle(message)
        }
    }

    func send(_ message: Wire.Message) {
        guard let connection, let frame = try? Wire.frame(message) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// The connection is over, one way or another.
    private func lost(_ why: String?) {
        if let why { note = why }
        close()
    }

    private func close() {
        connection?.cancel()
        connection = nil
        inbox = Data()
        room = nil
        battle = nil
        theirApp = nil
        stage = .idle
    }
}

/// A reference the network hands us on its queue, carried to the main
/// actor. Network's objects are safe to move; the compiler cannot see it.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
