//  LANView.swift
//  LAN Battles: the people running the app on your network, a request to
//  one of them, and the room you share once they say yes.
//
//  The screen is the waiting room. You are visible while it is on and stay
//  visible after you leave the screen, so a request finds you anywhere in
//  the app -- it arrives as a banner over whatever you are doing. In the
//  room each of you chooses a team from your own saved ones; the other side
//  sees it as Team Preview would, six forms and a name, and nothing else.

import SwiftUI

struct LANView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    @ObservedObject private var lan = LANService.shared
    @State private var chosenTeamID = ""
    @State private var choosing = false

    var body: some View {
        if let battle = lan.battle {
            // The game itself, on the battle screen, over the link.
            BattleView(lan: battle)
                .id(ObjectIdentifier(battle))
        } else {
            waitingRoom
        }
    }

    private var waitingRoom: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let room = lan.room {
                    roomCard(room)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        youCard
                        peopleCard
                    }
                }
                if let note = lan.note {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { lan.note = nil }.controlSize(.small)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .onAppear {
            // The first visit turns you on; after that it is your switch.
            if !snapshotMode, !lan.visible, UserDefaults.standard.object(forKey: "lanVisible") == nil {
                lan.visible = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LAN Battles")
                .font(.system(size: 22, weight: .black, design: .rounded))
            Text("Play somebody on your network. Anyone running the app with LAN Battles on shows up here; ask them, and your request reaches them wherever they are in the app.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - You, and the others

    private var youCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "You", subtitle: "How the others see you.")
                TextField("Your name", text: $lan.displayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Visible on the network", isOn: $lan.visible)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                HStack(spacing: 6) {
                    Circle().fill(statusColour).frame(width: 7, height: 7)
                    Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Version \(Updater.current). Both players need the same version; the sidebar's footer checks for a newer one.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 320, alignment: .topLeading)
    }

    private var statusColour: Color {
        switch lan.status {
        case .on: return Palette.good
        case .starting: return Palette.warn
        case .off: return Palette.dim
        case .failed: return Palette.bad
        }
    }

    private var statusLine: String {
        switch lan.status {
        case .on: return "On the network as \(lan.displayName)."
        case .starting: return "Joining the network..."
        case .off: return "Not visible. Nobody can ask you for a battle."
        case .failed(let why): return "Could not join the network: \(why)"
        }
    }

    private var peopleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "People on your network",
                              subtitle: lan.peers.isEmpty
                                ? "Nobody else yet. They need the app open with LAN Battles turned on."
                                : "Ask one of them for a battle.")
                switch lan.stage {
                case .inviting(let name):
                    waiting("Waiting for \(name) to answer...") {
                        Button("Withdraw") { lan.cancelInvite() }.controlSize(.small)
                    }
                case .invited(let name):
                    waiting("\(name) wants to battle you.") {
                        Button("Decline") { lan.decline() }.controlSize(.small)
                        Button("Accept") { lan.accept() }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(Palette.accent)
                            .keyboardShortcut(.defaultAction)
                    }
                default:
                    EmptyView()
                }
                if lan.peers.isEmpty, lan.status == .on {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking...").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                ForEach(lan.peers) { peer in
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 22)).foregroundStyle(Palette.accent)
                        Text(peer.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Request a battle") { lan.invite(peer) }
                            .controlSize(.small)
                            .disabled(lan.stage != .idle)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func waiting<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12, weight: .medium))
            Spacer()
            actions()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1))
    }

    // MARK: - The room

    private func roomCard(_ room: LANService.Room) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if let theirs = lan.theirApp, theirs != Updater.current {
                    Label("\(room.theirName) is on version \(theirs); you are on \(Updater.current). Update both before playing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    SectionHeader(title: "Battle with \(room.theirName)",
                                  subtitle: room.hosting ? "You asked, so you set the format. Each of you chooses a team; the other sees its six, as Team Preview would."
                                                         : "\(room.theirName) sets the format. Each of you chooses a team; the other sees its six, as Team Preview would.")
                    Spacer()
                    Button("Leave") { lan.leaveRoom() }.controlSize(.small)
                }
                HStack(spacing: 10) {
                    if room.hosting {
                        Picker("", selection: Binding(get: { room.singles }, set: { lan.setSingles($0) })) {
                            Text("Doubles").tag(false)
                            Text("Singles").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    } else {
                        Text(room.singles ? "Singles" : "Doubles")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Palette.accent.opacity(0.16)))
                    }
                    Spacer()
                }
                HStack(alignment: .top, spacing: 14) {
                    side(title: "You", name: lan.displayName, six: room.mySix, ready: room.iAmReady,
                         tint: Palette.accent, mine: true)
                    side(title: "Them", name: room.theirName, six: room.theirSix, ready: room.theyAreReady,
                         tint: Palette.bad, mine: false)
                }
                HStack(spacing: 10) {
                    Toggle("Ready", isOn: Binding(get: { room.iAmReady }, set: { lan.setReady($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(room.mySix == nil)
                    Spacer()
                    if room.bothReady, room.hosting {
                        Button {
                            lan.startBattle()
                        } label: {
                            Label("Start battle", systemImage: "flag.2.crossed.fill")
                                .font(.system(size: 12, weight: .heavy))
                        }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Text(room.bothReady ? "Both ready. \(room.theirName) starts the battle."
                             : "When both are ready, the host starts the battle: Team Preview, then the game.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func side(title: String, name: String, six: Wire.Six?, ready: Bool, tint: Color, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 9, weight: .heavy)).kerning(1.2)
                    .foregroundStyle(tint)
                Text(name).font(.system(size: 13, weight: .bold))
                Spacer()
                if ready {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.good)
                }
            }
            if let six {
                SixCard(name: six.name, tag: "\(six.forms.count) Pok\u{00E9}mon",
                        forms: six.forms.map { store.formsByID[$0] }, selected: mine, spriteSide: 40)
            } else {
                Text(mine ? "Choose a team." : "Choosing...")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            if mine {
                Button(six == nil ? "Choose team" : "Change team") { choosing = true }
                    .controlSize(.small)
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        TeamChooser(side: .mine, myTeamID: chosenTeamID, opponentID: "",
                                    singles: lan.room?.singles ?? false) { id in
                            choosing = false
                            chosenTeamID = id
                            if let team = store.teams.first(where: { $0.id.uuidString == id }) {
                                lan.chooseTeam(team, rules: store.rulebook)
                            }
                        }
                        .environmentObject(store)
                        .frame(width: 560, height: 520)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// A request to battle, over whatever screen you are on.
struct InviteBanner: View {
    let from: String
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(from) wants to battle").font(.system(size: 13, weight: .semibold))
                Text("Over your network, in LAN Battles.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button("Decline", action: decline).controlSize(.small)
            Button("Accept", action: accept)
                .controlSize(.small).buttonStyle(.borderedProminent).tint(Palette.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
