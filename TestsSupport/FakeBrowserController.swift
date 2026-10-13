import Foundation
import BouncerCore

/// A stand-in default browser for tests and the automation fixture; it records
/// restarts instead of quitting a real app.
@MainActor
final class FakeBrowserController: BrowserControlling {
    var browser: BrowserInfo? = BrowserInfo(name: "Fixture Browser", bundleIdentifier: "com.example.fixture-browser",
                                            appURL: URL(fileURLWithPath: "/Applications/Fixture Browser.app"),
                                            engine: .chromium, isRunning: true)
    var restartFailure: FilterBackendError?
    private(set) var restarts: [BrowserInfo] = []

    func defaultBrowser() -> BrowserInfo? { browser }

    func restart(_ browser: BrowserInfo) async throws {
        if let restartFailure { throw restartFailure }
        restarts.append(browser)
    }
}
