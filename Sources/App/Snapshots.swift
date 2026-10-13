#if DEBUG
import AppKit
import BouncerCore
import SwiftUI

/// Debug-only: `BOUNCER_SNAPSHOT_DIR=/tmp/x Bouncer.app/Contents/MacOS/Bouncer`
/// renders the menu, Settings, and About views offscreen (light and dark) with
/// sample data and an in-memory tunnel, then exits. Nothing appears on screen and
/// no real settings, rules, or network configuration are touched.
@MainActor
enum SnapshotRenderer {
    static func run(into directory: URL) async {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bouncer-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let backend = SnapshotBackend()
        writeSampleStats(to: scratch.appendingPathComponent("stats.json"))
        let store = BlockingStore(rulesURL: scratch.appendingPathComponent("rules.json"), backend: backend)
        let configuration = AppConfigurationModel(store: AppConfigurationStore(fileURL: scratch.appendingPathComponent("config.toml")))
        let service = BouncerService(store: store, shell: SnapshotShell(), browser: SnapshotBrowser())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func menu() -> some View {
            MenuView(store: store, service: service, configuration: configuration, openSettings: {}, openAbout: {}, openStats: {}, quit: {})
        }
        await render(menu(), "menu-empty", into: directory)
        for pattern in ["reddit.com", "/tiktok|instagram/", "news.ycombinator.com", "*.substack.com"] {
            _ = try? await service.ruleAdd(.init(pattern: pattern))
        }
        _ = try? await service.ruleAdd(.init(action: "allow", pattern: "old.reddit.com"))
        if let x = try? await service.ruleAdd(.init(pattern: "x.com")) {
            _ = try? await service.ruleUpdate(.init(enabled: false, id: x.id))
        }
        await render(menu(), "menu-off", into: directory)
        _ = try? await service.blockingOn(.init())
        try? await Task.sleep(for: .seconds(3)) // let the self-test settle
        await render(menu(), "menu-on", into: directory)
        // README image: activity collected, switch off (offscreen windows can't
        // render an active switch, so "on" would look inconsistent).
        _ = try? await service.blockingOff(.init())
        await render(menu(), "menu-showcase", into: directory)
        backend.failNext = true
        _ = try? await service.blockingOff(.init())
        _ = try? await service.blockingOn(.init())
        await render(menu(), "menu-failed", into: directory)
        await render(SettingsView(store: store, service: service, configuration: configuration, openAbout: {}), "settings", into: directory)
        // As the window shows it on a short screen: the form scrolls.
        await render(SettingsView(store: store, service: service, configuration: configuration, openAbout: {}), "settings-short",
                     into: directory, size: CGSize(width: SettingsWindowController.width, height: 600))
        await render(AboutView(configuration: configuration, openSettings: {}), "about", into: directory)
        await render(StatsView(stats: store.stats, service: service), "stats", into: directory)
    }

    /// Two weeks of plausible history (deterministic, so renders are comparable).
    private static func writeSampleStats(to url: URL) {
        let sites = ["reddit.com", "news.ycombinator.com", "linkedin.com", "instagram.com", "x.com", "youtube.com"]
        let weights = [5, 4, 3, 2, 2, 1]
        let formatter = ISO8601DateFormatter()
        var days: [[String: Any]] = []
        for offset in 0..<14 {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let entries: [[String: Any]] = sites.enumerated().compactMap { index, site in
                let attempts = (weights[index] * (offset * 7 + index * 3 + 5)) % 9
                guard attempts > 0 else { return nil }
                return ["site": site, "attempts": attempts, "lookups": attempts * 4,
                        "lastDenied": formatter.string(from: date)]
            }
            days.append(["date": DenialStatsStore.dayKey(for: date), "sites": entries])
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "days": days]) { try? data.write(to: url) }
    }

    private static func render(_ view: some View, _ name: String, into directory: URL, size fixedSize: CGSize? = nil) async {
        for (suffix, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            let host = NSHostingView(rootView: view
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 400, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var size = fixedSize ?? host.fittingSize
            // Views built on GeometryReader (charts) can report no natural height.
            if size.width < 1 || size.height < 1 { size = CGSize(width: max(size.width, 560), height: 720) }
            FileHandle.standardError.write(Data("snapshot \(name)-\(suffix): \(size)\n".utf8))
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            window.close()
        }
    }
}

@MainActor
private final class SnapshotShell: AppShell {
    let appName = "Bouncer"
    let version = "snapshot"
    let isFrontmost = false
    func show() throws -> String { "" }
    func quit() throws -> String { "" }
    func confirmBrowserRestart(_ browser: BrowserInfo) async -> Bool { false }
}

@MainActor
private final class SnapshotBrowser: BrowserControlling {
    func defaultBrowser() -> BrowserInfo? {
        BrowserInfo(name: "Helium", bundleIdentifier: "net.imput.helium", appURL: URL(fileURLWithPath: "/Applications/Helium.app"),
                    engine: .chromium, isRunning: true)
    }
    func restart(_ browser: BrowserInfo) async throws {}
}

/// In-memory tunnel that "sees" a few blocked lookups when it starts.
@MainActor
private final class SnapshotBackend: FilterBackend {
    var installation = TunnelInstallation(installed: true)
    private(set) var isConnected = false
    var onBlocked: ((BlockedLookup) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var failNext = false

    func refresh() async {}
    func install() async throws {}
    func uninstall() async throws {}
    func activate(rules: [FilterRule], options: FilterOptions) async throws {
        if failNext {
            failNext = false
            throw FilterBackendError("tunnel_failed", "The DNS tunnel didn't start. Another VPN may be active.")
        }
        isConnected = true
        let matcher = RuleMatcher(rules: rules)
        let now = Date()
        for (domain, ago) in [("www.reddit.com", 3600.0), ("www.instagram.com", 600), ("news.ycombinator.com", 95),
                              ("www.reddit.com", 40), ("news.ycombinator.com", 12), ("news.ycombinator.com", 4)] {
            if case .blocked(let rule) = matcher.evaluate(domain) {
                onBlocked?(BlockedLookup(domain: domain, ruleID: rule.id, rulePattern: rule.pattern, date: now.addingTimeInterval(-ago)))
            }
        }
    }
    func update(rules: [FilterRule], options: FilterOptions) async throws {}
    func deactivate() async throws { isConnected = false }
    func deactivateBeforeExit(timeout: TimeInterval) { isConnected = false }
    func verifySystemResolution() async -> Bool { true }
}
#endif
