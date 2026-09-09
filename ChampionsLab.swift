//  ChampionsLab.swift
//  App entry point and the sidebar that holds the whole thing together.

import SwiftUI

@main
struct ChampionsLabApp: App {
    @StateObject private var store = Store.shared

    var body: some Scene {
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
            }
            CommandGroup(after: .saveItem) {
                Button("Reveal Saved Teams in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TeamStore.location])
                }
            }
        }
    }
}

extension Notification.Name {
    static let newTeam = Notification.Name("ChampionsLab.newTeam")
}

// MARK: - Sections

enum Section: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case teams = "Teams"
    case dex = "Pokédex"
    case moves = "Moves"
    case items = "Items"
    case abilities = "Abilities"
    case meta = "Usage & Meta"
    case calculator = "Calculator"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview:   return "sparkles.rectangle.stack"
        case .teams:      return "person.3.fill"
        case .dex:        return "book.closed.fill"
        case .moves:      return "bolt.fill"
        case .items:      return "bag.fill"
        case .abilities:  return "wand.and.stars"
        case .meta:       return "chart.bar.fill"
        case .calculator: return "function"
        }
    }

    var group: String {
        switch self {
        case .overview, .meta:                  return "Regulation"
        case .teams, .calculator:               return "Build"
        case .dex, .moves, .items, .abilities:  return "Database"
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var store: Store
    @State private var section: Section = .overview

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
                case .dex:        DexView()
                case .moves:      MoveDexView()
                case .items:      ItemDexView()
                case .abilities:  AbilityDexView()
                case .meta:       MetaView()
                case .calculator: CalculatorView()
                }
            }
            .background(Palette.canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTeam)) { _ in
            section = .teams
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

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(Palette.good).frame(width: 6, height: 6)
                Text(store.data.regulation.name)
                    .font(.system(size: 11, weight: .medium))
            }
            Text("Data \(store.data.generated) · \(store.data.forms.count) forms")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
