//  Updater.swift
//  Keeping every copy of the app on the latest release.
//
//  Two people on a network are playing one game only if both apps are the
//  same app, so the app can look at the repository's latest release, say
//  when it is behind, download the disk image, swap itself for the copy
//  inside and relaunch. The repository may be private: then a GitHub token
//  with access to it is pasted once and kept in the defaults, and GitHub is
//  asked for the asset by its API address rather than its download page.
//
//  Nothing here is signed, so the copy that comes down carries the
//  quarantine mark; it is taken off, since the player asked for exactly this
//  update from exactly this repository.

import Foundation
import AppKit

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    /// Where the app lives, as owner/name.
    static let repository = "jack-huffman/ChampionsLab"

    /// A release as GitHub lists it: its version, its notes, and where the
    /// disk image is.
    struct Release: Equatable, Sendable {
        let version: String
        let tag: String
        let notes: String
        /// The asset's download page, which works for a public repository.
        let downloadURL: URL
        /// The asset by API address, which works for a private one with a token.
        let apiURL: URL
        let published: Date?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// For a private repository. Kept in the defaults; a personal machine's.
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "githubToken") }
    }

    private init() {
        token = UserDefaults.standard.string(forKey: "githubToken") ?? ""
        lastChecked = UserDefaults.standard.object(forKey: "updateCheckedAt") as? Date
    }

    /// The version this copy is, off its Info.plist; "0" outside a bundle.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Looking

    /// Once a launch, and not more often than every six hours, so the app
    /// says when it is behind without asking every time.
    func checkIfDue() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 6 * 3600 { return }
        await check()
    }

    func check() async {
        guard !isBusy else { return }
        phase = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!,
                                     timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updateCheckedAt")
            switch status {
            case 200:
                guard let release = try Self.parse(data) else {
                    phase = .failed("The latest release has no disk image attached.")
                    return
                }
                phase = Self.isNewer(release.version, than: Self.current) ? .available(release) : .upToDate
            case 404:
                phase = .failed(token.isEmpty
                                ? "No release was found. If the repository is private, paste a GitHub token with access to it."
                                : "No release was found under that token.")
            case 401, 403:
                phase = .failed("GitHub refused the token.")
            default:
                phase = .failed("GitHub answered \(status).")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The latest release out of GitHub's JSON; nil when it carries no image.
    nonisolated static func parse(_ data: Data) throws -> Release? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }
        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let download = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let api = (dmg["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let published = (root["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, tag: tag,
                       notes: root["body"] as? String ?? "",
                       downloadURL: download, apiURL: api, published: published)
    }

    /// Whether `a` is a later version than `b`, part by part: 0.3.10 is
    /// later than 0.3.9, and a missing part is zero.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<Swift.max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Download the image, take the app out of it, put it where this one is,
    /// and start it. This copy quits once the new one is running.
    func install(_ release: Release) async {
        guard !isBusy else { return }
        phase = .downloading(0)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChampionsLab-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let image = scratch.appendingPathComponent("ChampionsLab-\(release.version).dmg")
            try await download(release, to: image)
            phase = .installing
            let fresh = try await Self.unpack(image, into: scratch)
            let here = Bundle.main.bundleURL
            guard here.pathExtension == "app",
                  FileManager.default.isWritableFile(atPath: here.deletingLastPathComponent().path) else {
                NSWorkspace.shared.activateFileViewerSelecting([image])
                phase = .failed("This copy cannot replace itself where it is. The image is in the Finder; drag the app in by hand.")
                return
            }
            // The running copy moves aside -- its code is already in memory --
            // the new one takes its place, and the new one cleans the old up.
            let aside = here.deletingLastPathComponent().appendingPathComponent("ChampionsLab.old.app")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: here, to: aside)
            try FileManager.default.copyItem(at: fresh, to: here)
            try? FileManager.default.removeItem(at: scratch)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", here.path]
            try open.run()
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The copy that replaced an older one removes what it left aside.
    static func cleanUp() {
        let aside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ChampionsLab.old.app")
        if FileManager.default.fileExists(atPath: aside.path) { try? FileManager.default.removeItem(at: aside) }
    }

    private func download(_ release: Release, to file: URL) async throws {
        // A private repository's asset comes by API address with the token;
        // GitHub then redirects to storage that must not see the token.
        var request = URLRequest(url: token.isEmpty ? release.downloadURL : release.apiURL, timeoutInterval: 120)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let relay = Relay { [weak self] fraction in Task { @MainActor in self?.phase = .downloading(fraction) } }
        let session = URLSession(configuration: .ephemeral, delegate: relay, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.download("GitHub answered \(status) for the image.") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    /// The app out of the image: mounted, copied, the quarantine mark taken
    /// off, unmounted.
    nonisolated private static func unpack(_ image: URL, into scratch: URL) async throws -> URL {
        let mount = scratch.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let inside = mount.appendingPathComponent("ChampionsLab.app")
        guard FileManager.default.fileExists(atPath: inside.path) else {
            throw UpdateError.download("The image has no ChampionsLab.app in it.")
        }
        let fresh = scratch.appendingPathComponent("ChampionsLab.app")
        try FileManager.default.copyItem(at: inside, to: fresh)
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
        return fresh
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.download("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }

    enum UpdateError: LocalizedError {
        case download(String)
        var errorDescription: String? {
            switch self { case .download(let why): return why }
        }
    }

    /// Progress off the download, and the token kept off the redirect.
    private final class Relay: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, Sendable {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(stripped)
        }
    }
}
