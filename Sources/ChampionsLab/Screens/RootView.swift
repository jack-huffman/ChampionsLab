//  RootView.swift
//  The scene that holds the whole app together, and the sidebar inside it.
//
//  The executable target is a single line that shows this scene; everything
//  else — the window, the menu commands, the sections — lives here in the
//  library, where the tests and the tools can reach it.

import SwiftUI

/// The one window, with its menu commands. Public because the executable
/// target, which is the only thing outside this module, has to name it.
public struct ChampionsLabScene: Scene {
    @StateObject private var store = Store.shared

    public init() {}

    public var body: some Scene {
        Window("ChampionsLab", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Team") {
                    NotificationCenter.default.post(name: .newTeam, object: nil)
                }
                .keyboardShortcut("n")
                Button("Import Team…") {
                    NotificationCenter.default.post(name: .importTeam, object: nil)
                }
                .keyboardShortcut("i")
            }
            CommandGroup(after: .saveItem) {
                Button("Reveal Saved Teams in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TeamStore.location])
                }
            }
        }
    }
}

// MARK: - Sections

enum Section: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case teams = "Teams"
    case builder = "Builder"
    case dex = "Pokédex"
    case speed = "Speed Tiers"
    case battle = "Battle Sim"
    case lan = "LAN Battles"
    case moves = "Moves"
    case items = "Items"
    case abilities = "Abilities"
    case meta = "Usage & Meta"
    case forecast = "Forecast"
    case calculator = "Calculator"
    case parity = "Parity Check"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview:   return "sparkles.rectangle.stack"
        case .teams:      return "person.3.fill"
        case .builder:    return "square.stack.3d.up.fill"
        case .dex:        return "book.closed.fill"
        case .speed:      return "speedometer"
        case .battle:     return "gamecontroller.fill"
        case .lan:        return "antenna.radiowaves.left.and.right"
        case .moves:      return "bolt.fill"
        case .items:      return "bag.fill"
        case .abilities:  return "wand.and.stars"
        case .meta:       return "chart.bar.fill"
        case .forecast:   return "chart.line.uptrend.xyaxis"
        case .calculator: return "function"
        case .parity:     return "checkmark.seal"
        }
    }

    var group: String {
        switch self {
        case .overview, .meta, .forecast:       return "Regulation"
        case .teams, .builder, .calculator,
             .battle, .lan:                     return "Build"
        case .dex, .moves, .items, .abilities,
             .speed:                            return "Database"
        case .parity:                           return "Database"
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lab = SimulationService.shared
    @ObservedObject private var lan = LANService.shared
    @ObservedObject private var updater = Updater.shared
    @State private var section: Section = .overview
    /// The newer version's banner, put away for this launch.
    @State private var updateDismissed = false

    private var groups: [(String, [Section])] {
        var seen: [String] = []
        for section in Section.allCases where !seen.contains(section.group) {
            seen.append(section.group)
        }
        return seen.map { name in
            (name, Section.allCases.filter { $0.group == name })
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(groups, id: \.0) { group in
                    SwiftUI.Section(group.0) {
                        ForEach(group.1) { item in
                            Label(item.rawValue, systemImage: item.symbol)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch section {
                case .overview:   OverviewView()
                case .teams:      TeamsView()
                case .builder:    BuilderView()
                case .dex:        DexView()
                case .speed:      SpeedTiersView()
                case .battle:     BattleView()
                case .lan:        LANView()
                case .moves:      MoveDexView()
                case .items:      ItemDexView()
                case .abilities:  AbilityDexView()
                case .meta:       MetaView()
                case .forecast:   ForecastView()
                case .parity:     ParityView()
                case .calculator:
                    // .id forces a fresh view when a new slot is sent over, so
                    // the seeded @State is rebuilt rather than reused.
                    CalculatorView(preload: store.pendingCalculation)
                        .id(store.pendingCalculation?.token)
                }
            }
            .background(Palette.canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTeam)) { _ in
            section = .teams
        }
        .onReceive(NotificationCenter.default.publisher(for: .importTeam)) { _ in
            section = .teams
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCalculator)) { _ in
            section = .calculator
        }
        // A battle request finds you wherever you are.
        .overlay(alignment: .topTrailing) {
            if case .invited(let name) = lan.stage, section != .lan {
                InviteBanner(from: name,
                             accept: { lan.accept(); section = .lan },
                             decline: { lan.decline() })
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: lan.stage)
        // A newer version says so once, wherever you are.
        .overlay(alignment: .topTrailing) {
            if case .available(let release) = updater.phase, !updateDismissed, lan.stage != .invited("") {
                UpdateBanner(release: release,
                             update: { Task { await updater.install(release) } },
                             later: { updateDismissed = true })
                    .padding(.top, lanBannerShowing ? 70 : 0)
            }
        }
        .task {
            Updater.cleanUp()
            await updater.checkIfDue()
        }
        .overlay(alignment: .top) {
            if let error = store.loadError {
                Text("Dataset failed to load: \(error)")
                    .font(.system(size: 12))
                    .padding(10)
                    .background(Palette.bad.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
    }

    private var lanBannerShowing: Bool {
        if case .invited = lan.stage { return section != .lan }
        return false
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            // A simulation keeps going when you leave its screen, so it has to
            // say so from wherever you are — and be stoppable from there.
            // Background work with no indicator is what made this app feel
            // broken once before.
            if let running = lab.running {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Simulating \(running.teamName)")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Stop") { lab.stop() }
                            .controlSize(.mini).buttonStyle(.plain)
                            .foregroundStyle(Palette.accent)
                    }
                    if let step = running.progress {
                        ProgressView(value: Double(step.played), total: Double(max(1, step.of)))
                            .progressViewStyle(.linear)
                        Text("\(step.played) of \(step.of) · \(step.wins) won")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 6) {
                Circle().fill(Palette.good).frame(width: 6, height: 6)
                Text(store.data.regulation.name)
                    .font(.system(size: 11, weight: .medium))
            }
            Text("Data \(store.data.generated) · \(store.data.forms.count) forms")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            UpdateLine()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
