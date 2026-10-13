#if os(macOS)
import Foundation

public actor AppEndpoint {
    public let socketPath: String
    public let appName: String
    public let bundleID: String
    private let explicitAppURL: URL?
    private var startup: Task<AutomationHandshake, Error>?
    public init(socketPath: String, appName: String, bundleID: String, appURL: URL? = nil) {
        self.socketPath = socketPath; self.appName = appName; self.bundleID = bundleID; self.explicitAppURL = appURL
    }
    public func handshake(launchIfNeeded: Bool) async throws -> AutomationHandshake {
        if let startup { return try await startup.value }
        let task = Task { [socketPath, appName, bundleID, explicitAppURL] () throws -> AutomationHandshake in
            let probe = AutomationRequest(operation: "$handshake")
            func inspect() async throws -> AutomationHandshake {
                let response = try await AutomationSocketClient.send(probe, path: socketPath, timeout: 5)
                return try response.checked(for: probe).decode()
            }
            do { return try await inspect() }
            catch {
                guard launchIfNeeded, (error as? AutomationFailure)?.code == "unavailable" else { throw error }
            }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let sibling = executable.deletingLastPathComponent().appendingPathComponent(appName + ".app")
            let appURL = explicitAppURL ?? (bundle.pathExtension == "app" ? bundle : FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = appURL.map { ["-g", $0.path] } ?? ["-g", "-b", bundleID]
            // Process waiting runs off the cooperative executor.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    if p.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: AutomationFailure("unavailable", "Could not launch \(appName). Install or open the app.")) }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            let until = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < until {
                try Task.checkCancellation()
                do { return try await inspect() } catch {
                    if let failure = error as? AutomationFailure, !["unavailable","outcome_unknown","timeout"].contains(failure.code) { throw error }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AutomationFailure("unavailable", "\(appName) did not become ready. Open it and inspect its startup error.")
        }
        startup = task
        defer { startup = nil }
        return try await task.value
    }
    public func send(_ request: AutomationRequest, launchIfNeeded: Bool) async throws -> AutomationResponse {
        let info = try await handshake(launchIfNeeded: launchIfNeeded)
        guard info.protocolVersion == AutomationVersion.protocolVersion else { throw AutomationFailure("incompatible_backend", "Use the CLI bundled with the running app.") }
        guard request.operation.hasPrefix("$") || info.operations.contains(request.operation) else { throw AutomationFailure("incompatible_backend", "The running app does not support \(request.operation). Relaunch the matching app build.") }
        return try await AutomationSocketClient.send(request, path: socketPath)
    }
}
#endif
