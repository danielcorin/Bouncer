import Foundation
import AutomationCLI
import BouncerCore

struct ConfigPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config-path", abstract: "Locate the TOML configuration without opening the app.")
    @Flag var json = false
    func run() throws { try CLIEnvironment.printJSON(OperationResult(requestId: UUID(), data: ["path": AppConfigurationStore.defaultFileURL().path]), pretty: !json) }
}

struct APICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "api", abstract: "Discover the operation contract.", subcommands: [OperationsCommand.self, SchemaCommand.self])
    struct SchemaCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "schema", abstract: "Emit the bundled OpenAPI contract; works offline.")
        @Flag var json = false
        func run() throws { try CLIEnvironment.printJSON(AutomationCoding.decoder.decode(JSONValue.self, from: Data(GeneratedCatalog.openAPI.utf8)), pretty: !json) }
    }
    struct OperationsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "operations", abstract: "Describe every operation, CLI command, and route; offline by default.")
        @Flag var json = false
        @Flag(help: "Probe the running app without launching it.") var live = false
        func run() async throws {
            var result: [String: JSONValue] = ["operations": try .encode(GeneratedCatalog.operations), "availability": .string("unknown"),
                "cliOnly": .array(["config-path", "api operations", "api schema", "--generate-completion-script"].map(JSONValue.string))]
            if live {
                do { result["backend"] = try await .encode(BouncerClients.endpoint.handshake(launchIfNeeded: false)); result["availability"] = .string("ready") }
                catch { result["availability"] = .string("unavailable"); result["error"] = try .encode(AutomationFailure.normalize(error)) }
            }
            try CLIEnvironment.printJSON(OperationResult(requestId: UUID(), data: JSONValue.object(result)), pretty: !json)
        }
    }
}
