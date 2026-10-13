import Foundation
import AutomationRuntime
import BouncerCore

/// An isolated backend for CLI/HTTP integration. This tool is never bundled or installed.
/// It runs the real `BouncerService` and `BlockingStore` over an in-memory tunnel.
@main
struct AutomationFixture {
    @MainActor static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/private/tmp/") || CommandLine.arguments[1].hasPrefix("/tmp/") else {
            fatalError("Supply an isolated /tmp directory")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let config = ConfigurationOperationService(store: AppConfigurationStore(fileURL: root.appendingPathComponent("config/bouncer/config.toml")))
        let backend = InMemoryFilterBackend(probes: fixtureProbeDomains)
        let store = BlockingStore(rulesURL: root.appendingPathComponent("rules.json"), backend: backend)
        let application = BouncerService(store: store, shell: FixtureShell())
        let transfers = TransferStore(directory: root.appendingPathComponent("Transfers"))
        let suite = CommandLine.arguments.last == "--scenarios" ? try appScenarios(application: application, configuration: config, transfers: transfers) : nil
        let host = AutomationHost(version: "fixture", operations: GeneratedCatalog.operations.map(\.id),                                   normalize: { MacAutomationErrors.normalize($0) }) { request in
            if let value = try await suite?.handle(request) { return value }
            if let value = try await config.dispatchConfiguration(request) { return value }
            return try await application.dispatchApplication(request)
        }
        let server = AutomationSocketServer(path: root.appendingPathComponent("automation.sock").path) { await host.handle($0) }
        try server.start()
        defer { server.stop() }
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        while !Task.isCancelled { try await Task.sleep(for: .seconds(30)) }
    }
}

/// Lookups the fixture "browser" makes each time blocking turns on.
let fixtureProbeDomains = ["example.com", "www.example.com", "ok.example.com", "news.ycombinator.com", "apple.com"]

@MainActor
private final class FixtureShell: AppShell {
    let appName = "Bouncer fixture"
    let version = "fixture"
    let isFrontmost = false
    func show() throws -> String {
        throw AutomationFailure("capability_unavailable", "Opening the menu requires the signed app.")
    }
    func quit() throws -> String {
        throw AutomationFailure("capability_unavailable", "App termination requires the signed app.")
    }
}
