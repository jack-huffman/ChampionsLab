//  UpdateView.swift
//  The app's version, and the way to the latest one.
//
//  A line in the sidebar's footer says which version this is and whether a
//  newer one exists; clicking it opens the details: the release notes, the
//  update button, and -- for a private repository -- a place for a token.
//  A release that is newer also announces itself once, over whatever screen
//  is up, since two people cannot battle across versions.

import SwiftUI

struct UpdateLine: View {
    @ObservedObject private var updater = Updater.shared
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(text).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Version \(Updater.current). Click for updates.")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            UpdatePanel().frame(width: 360)
        }
    }

    private var symbol: String {
        switch updater.phase {
        case .available: return "arrow.down.circle.fill"
        case .checking, .downloading, .installing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.circle"
        default: return "checkmark.circle"
        }
    }

    private var text: String {
        switch updater.phase {
        case .idle: return "Version \(Updater.current)"
        case .checking: return "Checking for updates..."
        case .upToDate: return "Version \(Updater.current), the latest"
        case .available(let release): return "Version \(release.version) is available"
        case .downloading(let fraction): return String(format: "Downloading, %.0f%%", fraction * 100)
        case .installing: return "Installing..."
        case .failed: return "Version \(Updater.current), could not check"
        }
    }

    private var tint: Color {
        switch updater.phase {
        case .available: return Palette.accent
        case .failed: return Palette.warn
        default: return .secondary
        }
    }
}

struct UpdatePanel: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ChampionsLab \(Updater.current)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("Releases come from github.com/\(Updater.repository). Two people on a network need the same version to battle.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch updater.phase {
            case .available(let release):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text(release.notes).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: 140)
                    }
                    Button {
                        Task { await updater.install(release) }
                    } label: {
                        Label("Update and relaunch", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(updater.isBusy)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading the image...").font(.system(size: 11)) }
            case .installing:
                ProgressView { Text("Putting the new copy in place...").font(.system(size: 11)) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            case .upToDate:
                Label("This is the latest version.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.good)
            case .idle, .checking:
                EmptyView()
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A private repository needs a GitHub token with access to it. It is kept on this machine only.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("GitHub token", text: $updater.token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(.top, 4)
            } label: {
                Text("Private repository").font(.system(size: 11))
            }
            HStack {
                if let checked = updater.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Check now") { Task { await updater.check() } }
                    .controlSize(.small)
                    .disabled(updater.isBusy)
            }
        }
        .padding(16)
    }
}

/// A newer version, announced over whatever is on screen.
struct UpdateBanner: View {
    let release: Updater.Release
    let update: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("ChampionsLab \(release.version) is available").font(.system(size: 13, weight: .semibold))
                Text("You are on \(Updater.current). Both players need the same version for a LAN battle.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button("Later", action: later).controlSize(.small)
            Button("Update", action: update)
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
