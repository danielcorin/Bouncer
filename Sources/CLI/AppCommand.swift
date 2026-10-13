import Foundation
import AutomationCLI
import BouncerCore

/// Composition and custom presentation are ordinary Swift; generated siblings stay present.
@main
struct BouncerCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        .init(commandName: "bouncer", abstract: "Control Bouncer through its app-owned operation service.",
              version: "1.0.0", subcommands: GeneratedCLI.commands + [APICommand.self, ConfigPathCommand.self])
    }
    static func main() async {
        CLIEnvironment.current = CLIEnvironment(client: BouncerClients.local, transfers: BouncerAutomationPaths.transfers)
        BouncerCLIStyles.install(in: CLIEnvironment.current)
        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand { try await async.run() }
            else { try command.run() }
        } catch {
            if error is AutomationFailure || error is AppConfigurationError || error is CocoaError {
                Foundation.exit(CLIEnvironment.report(MacAutomationErrors.normalize(error), json: CommandLine.arguments.contains("--json")))
            }
            if CommandLine.arguments.contains("--json"), exitCode(for: error).rawValue != 0 {
                Foundation.exit(CLIEnvironment.report(AutomationFailure("invalid_input", message(for: error)), json: true))
            }
            exit(withError: error)
        }
    }
}

enum BouncerClients {
    static let endpoint = AppEndpoint(socketPath: BouncerAutomationPaths.socket.path, appName: "Bouncer", bundleID: "llc.wvlen.Bouncer")
    static let configuration = ConfigurationOperationService()
    static var shouldLaunchApp: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_AUTOMATION_ROOT"] != nil { return false }
        #endif
        return true
    }
    static let local = AutomationClient { request in
        do {
            if let result = try await configuration.dispatchConfiguration(request) { return .init(requestId: request.requestId, data: result) }
            return try await endpoint.send(request, launchIfNeeded: shouldLaunchApp)
        } catch { throw MacAutomationErrors.normalize(error) }
    }
    static func control(_ operation: String, input: JSONValue = .object([:]), launch: Bool = true) async throws -> JSONValue {
        let request = AutomationRequest(operation: operation, input: input)
        return try await endpoint.send(request, launchIfNeeded: launch).checked(for: request)
    }
}
