import Foundation
import ArgumentParser
import AutomationRuntime

/// Configure once before parsing. Extensions stay in Swift and retain typed inputs/results.
public final class CLIEnvironment {
    public static var current: CLIEnvironment!
    public let client: AutomationClient
    public let transfers: TransferStore
    private var renderers: [ObjectIdentifier: (Any) throws -> String] = [:]
    private var replacements: [ObjectIdentifier: ParsableCommand.Type] = [:]
    public init(client: AutomationClient, transfers: TransferStore) {
        self.client = client; self.transfers = transfers
    }
    public func render<O: AutomationOperation>(_ operation: O.Type, with renderer: @escaping (O.Output) throws -> String) {
        precondition(renderers[ObjectIdentifier(operation)] == nil, "Duplicate renderer registration")
        renderers[ObjectIdentifier(operation)] = { value in try renderer(value as! O.Output) }
    }
    public func replace<O: AutomationOperation>(_ operation: O.Type, with command: ParsableCommand.Type) {
        precondition(command.configuration.commandName == operation.definition.command.last, "A replacement must use the operation's command name")
        precondition(replacements[ObjectIdentifier(operation)] == nil, "Duplicate command replacement")
        replacements[ObjectIdentifier(operation)] = command
    }
    public func command<O: AutomationOperation>(_ operation: O.Type, default command: ParsableCommand.Type) -> ParsableCommand.Type {
        replacements[ObjectIdentifier(operation)] ?? command
    }
    public static func input(_ definition: OperationDefinition, values: [String: String], clear: [String], inputFile: String?) throws -> JSONValue {
        var input: [String: JSONValue] = [:]
        if let inputFile {
            guard values.isEmpty, clear.isEmpty else { throw AutomationFailure("invalid_input", "--input-file cannot be combined with input flags or arguments.") }
            let file = inputFile == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: inputFile))
            defer { if inputFile != "-" { try? file.close() } }
            let data = try file.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw AutomationFailure("payload_too_large", "Input JSON is limited to 1 MiB.") }
            guard let object = try AutomationCoding.decoder.decode(JSONValue.self, from: data).object else {
                throw AutomationFailure("invalid_input", "--input-file must contain a JSON object.")
            }
            input = object
        } else {
            for (key, text) in values {
                guard let field = definition.fields.first(where: { $0.name == key }) else { throw AutomationFailure("invalid_input", "Unknown field '\(key)'.") }
                input[key] = try field.parse(text)
            }
            for key in clear {
                guard let field = definition.fields.first(where: { $0.name == key || $0.option == "--" + key }), field.nullable else {
                    throw AutomationFailure("invalid_input", "'\(key)' is not a nullable field.")
                }
                guard input[field.name] == nil else { throw AutomationFailure("invalid_input", "'\(field.name)' cannot be set and cleared together.") }
                input[field.name] = .null
            }
        }
        return .object(input)
    }
    public func run<O: AutomationOperation>(_ operation: O.Type, values: [String: String], clear: [String], inputFile: String?, json: Bool,
                                           uploadFile: String?, outputFile: String?, overwrite: Bool) async throws {
        var input = try Self.input(operation.definition, values: values, clear: clear, inputFile: inputFile).object!
        var staged: TransferFile?
        var keepTransfer = false
        defer { if !keepTransfer, let staged { transfers.remove(staged.handle) } }
        if operation.definition.upload {
            guard let uploadFile else { throw AutomationFailure("invalid_input", "--file is required for an upload.") }
            guard input["transfer"] == nil else { throw AutomationFailure("invalid_input", "Use --file to upload content; transfer handles are private.") }
            staged = try transfers.stage(file: URL(fileURLWithPath: uploadFile), filename: input["filename"]?.string)
            input["transfer"] = .string(staged!.handle)
        }
        if operation.definition.download, outputFile == nil { throw AutomationFailure("invalid_input", "--output is required for a download.") }
        try operation.definition.validate(.object(input))
        do {
            let result = try await client.call(operation, input: JSONValue.object(input).decode())
            if operation.definition.download {
                let file = try JSONValue.encode(result.data).decode(TransferFile.self)
                defer { transfers.remove(file.handle) }
                let target = URL(fileURLWithPath: outputFile!)
                let bytes = try transfers.read(file.handle)
                try bytes.write(to: target, options: overwrite ? [.atomic] : [.withoutOverwriting])
                try Self.printJSON(OperationResult(requestId: result.requestId, data: JSONValue.object([
                    "path": .string(target.path), "byteCount": .integer(bytes.count), "filename": .string(file.filename)
                ])), pretty: !json)
            } else if !json, let renderer = renderers[ObjectIdentifier(operation)] {
                print(try renderer(result.data))
            } else { try Self.printJSON(result, pretty: !json) }
        } catch {
            keepTransfer = (error as? AutomationFailure)?.code == "outcome_unknown"
            throw error
        }
    }
    public static func printJSON<T: Encodable>(_ value: T, pretty: Bool = false) throws {
        let encoder = AutomationCoding.encoder
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data + Data([10]))
    }
    public static func report(_ error: Error, json: Bool) -> Int32 {
        let failure = AutomationFailure.normalize(error)
        let data = json ? (try? AutomationCoding.encoder.encode(OperationError(requestId: failure.details?["requestId"].flatMap(UUID.init(uuidString:)), error: failure))) : failure.message.data(using: .utf8)
        if let data { FileHandle.standardError.write(data + Data([10])) }
        return failure.exitCode
    }
}
