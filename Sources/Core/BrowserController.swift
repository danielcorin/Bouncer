import AppKit
import Foundation

public struct BrowserInfo: Equatable, Sendable {
    public enum Engine: String, Sendable { case chromium, safari, firefox, other }

    public var name: String
    public var bundleIdentifier: String
    public var appURL: URL
    public var engine: Engine
    public var isRunning: Bool

    public init(name: String, bundleIdentifier: String, appURL: URL, engine: Engine, isRunning: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.appURL = appURL
        self.engine = engine
        self.isRunning = isRunning
    }

    /// True when Bouncer relaunches it in a way that reopens its windows and tabs;
    /// nil when that depends on the browser's own settings.
    public var restoresTabs: Bool? { engine == .chromium ? true : nil }
}

/// Finds, quits, and relaunches the default browser. Injected so tests and the
/// automation fixture never touch real apps.
@MainActor
public protocol BrowserControlling: AnyObject {
    func defaultBrowser() -> BrowserInfo?
    func restart(_ browser: BrowserInfo) async throws
}

@MainActor
public final class WorkspaceBrowserController: BrowserControlling {
    static let chromiumIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "net.imput.helium",
    ]

    public init() {}

    public func defaultBrowser() -> BrowserInfo? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return BrowserInfo(name: name, bundleIdentifier: identifier, appURL: appURL,
                           engine: Self.engine(identifier: identifier, appURL: appURL),
                           isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
    }

    static func engine(identifier: String, appURL: URL) -> BrowserInfo.Engine {
        if identifier.hasPrefix("com.apple.Safari") { return .safari }
        if identifier.hasPrefix("org.mozilla.") { return .firefox }
        if chromiumIdentifiers.contains(identifier) { return .chromium }
        // Chromium-based apps ship "<Name> Framework.framework".
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return contents.contains { $0.hasSuffix(" Framework.framework") } ? .chromium : .other
    }

    public func restart(_ browser: BrowserInfo) async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
        // A normal quit request, like ⌘Q: the browser saves its session and may
        // ask to confirm. Never force-terminate.
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(30)
        while running.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else {
                throw FilterBackendError("browser_busy", "\(browser.name) didn't quit. It may be asking you to confirm; quit it yourself and reopen it.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if browser.engine == .chromium { configuration.arguments = ["--restore-last-session"] }
        do { _ = try await NSWorkspace.shared.openApplication(at: browser.appURL, configuration: configuration) }
        catch { throw FilterBackendError("browser_launch_failed", "\(browser.name) quit but didn't reopen: \(error.localizedDescription)") }
    }
}
