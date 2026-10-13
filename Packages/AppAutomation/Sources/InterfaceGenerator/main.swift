import Foundation
import Yams

typealias Object = [String: Any]
struct GenerationError: Error, CustomStringConvertible { var description: String }
func fail(_ message: String) throws -> Never { throw GenerationError(description: message) }
func q(_ value: String) -> String { String(reflecting: value) }
func name(_ value: String) -> String { value.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
func object(_ value: Any?) -> Object { value as? Object ?? [:] }
func string(_ value: Any?) -> String { value as? String ?? "" }

struct Field {
    var key: String; var location: String; var type: String; var required: Bool; var nullable: Bool
    var option: String?; var argument: Int?; var description: String
    var base: String {
        switch type { case "string": return "String"; case "integer": return "Int"; case "number": return "Double"
        case "boolean": return "Bool"; case "string[]": return "[String]"; case "integer[]": return "[Int]"
        default: return "JSONValue" }
    }
    var swiftType: String { nullable ? "Presence<\(base)>" : base + (required ? "" : "?") }
    var definition: String {
        ".init(name: \(q(key)), location: \(q(location)), type: \(q(type)), required: \(required), nullable: \(nullable), option: \(option.map(q) ?? "nil"), argument: \(argument.map(String.init) ?? "nil"), description: \(q(description)))"
    }
}
struct Operation {
    var id: String; var command: [String]; var summary: String; var method: String; var path: String
    var capabilities: [String]; var fields: [Field]; var output: String; var result: String; var upload: Bool; var download: Bool; var destructive: Bool
    var upper: String { name(id) }
    var definition: String {
        ".init(id: \(q(id)), command: [\(command.map(q).joined(separator: ", "))], summary: \(q(summary)), method: \(q(method.uppercased())), path: \(q(path)), fields: [\n\(fields.map { "            " + $0.definition }.joined(separator: ",\n"))\n        ], destructive: \(destructive), upload: \(upload), download: \(download), responseSchema: \(download ? "nil" : q("#/components/schemas/" + result)), capabilities: [\(capabilities.map(q).joined(separator: ", "))])"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fputs("usage: app-interface SPEC OUTPUT_ROOT [CORE_MODULE] [--http]\n", stderr); exit(2) }
do {
    let specURL = URL(fileURLWithPath: args[0]); let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let module = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : "TasksCore"
    // The HTTP bridge is opt-in; a CLI-only app never compiles a server.
    let emitHTTP = args.contains("--http")
    guard let doc = try Yams.load(yaml: String(contentsOf: specURL, encoding: .utf8)) as? Object else { try fail("OpenAPI must be an object") }
    guard string(doc["openapi"]).hasPrefix("3.1.") else { try fail("Use OpenAPI 3.1") }
    let schemas = object(object(doc["components"])["schemas"])
    let reserved = Set(["class", "struct", "enum", "protocol", "extension", "func", "var", "let", "import", "switch", "case", "default", "return", "repeat", "while", "for", "if", "else", "in", "throw", "throws", "rethrows", "defer", "do", "catch", "try", "as", "is", "self", "super", "init", "deinit", "associatedtype", "typealias", "public", "private", "internal", "fileprivate", "open", "static", "subscript", "true", "false", "nil"])
    let reservedOptions = Set(["--help", "--version", "--json", "--input-file", "--clear", "--file", "--output"])
    func resolved(_ value: Any?) throws -> Object {
        let schema = object(value)
        if let ref = schema["$ref"] as? String {
            guard ref.hasPrefix("#/components/schemas/"), let found = schemas[String(ref.dropFirst(21))] else { try fail("Unresolved schema \(ref)") }
            return try resolved(found)
        }
        return schema
    }
    func type(_ schema: Object) throws -> String {
        if let ref = schema["$ref"] as? String { return "Components.Schemas." + String(ref.split(separator: "/").last!) }
        if string(schema["type"]) == "array" { return "[\(try type(object(schema["items"])))]" }
        switch string(schema["type"]) {
        case "string": return string(schema["format"]) == "date-time" ? "Date" : "String"
        case "integer": return "Int"
        case "number": return "Double"
        case "boolean": return "Bool"
        default: try fail("Response data needs a named object schema or a supported scalar/array")
        }
    }
    var operations: [Operation] = []
    let paths = object(doc["paths"])
    for path in paths.keys.sorted() {
        let item = object(paths[path])
        for method in item.keys.sorted() where ["get", "post", "patch", "put", "delete"].contains(method) {
            let op = object(item[method]); let id = string(op["operationId"])
            guard id.range(of: "^[a-z][a-zA-Z0-9]*$", options: .regularExpression) != nil else { try fail("Invalid operation ID \(id)") }
            guard !reserved.contains(id) else { try fail("Reserved Swift operation ID \(id)") }
            let cli = object(op["x-cli"]); let command = cli["command"] as? [String] ?? []
            guard !command.isEmpty, command.allSatisfy({ $0.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil }) else { try fail("\(id): x-cli.command is required") }
            guard command.count <= 2 else { try fail("\(id): this generator supports a root command or one command group") }
            let bindings = object(cli["bindings"])
            guard Set(cli.keys).isSubset(of: ["command", "bindings"]) else { try fail("\(id): custom behavior belongs in Swift; unknown x-cli key") }
            var fields: [Field] = []
            func field(_ key: String, _ schemaValue: Any?, _ location: String, _ required: Bool) throws {
                guard key.range(of: "^[a-z][a-zA-Z0-9]*$", options: .regularExpression) != nil else { try fail("\(id): invalid field name \(key)") }
                guard !reserved.contains(key) else { try fail("Reserved Swift field name \(key)") }
                let schema = try resolved(schemaValue)
                let kinds = (schema["type"] as? [String]) ?? [string(schema["type"])]
                let kind = kinds.first(where: { $0 != "null" }) ?? ""
                let fieldType = kind == "array" ? string(try resolved(schema["items"])["type"]) + "[]" : kind
                guard ["string","integer","number","boolean","string[]","integer[]"].contains(fieldType) else { try fail("\(id).\(key): unsupported input schema \(fieldType)") }
                guard schema["enum"] == nil, schema["oneOf"] == nil, schema["anyOf"] == nil else { try fail("\(id).\(key): input enum/union generation is not implemented; keep domain validation explicit") }
                let binding = object(bindings[location + "." + key])
                guard (binding["option"] != nil) != (binding["argument"] != nil) else { try fail("\(id).\(key): exactly one CLI argument or option mapping is required") }
                if let option = binding["option"] as? String {
                    guard option.range(of: "^--[a-z][a-z0-9-]*$", options: .regularExpression) != nil, !reservedOptions.contains(option) else { try fail("\(id): invalid or reserved option \(option)") }
                }
                fields.append(Field(key: key, location: location, type: fieldType, required: required,
                    nullable: kinds.contains("null"), option: binding["option"] as? String, argument: binding["argument"] as? Int,
                    description: string(schema["description"])))
            }
            for p in (item["parameters"] as? [Object] ?? []) + (op["parameters"] as? [Object] ?? []) {
                let loc = string(p["in"])
                guard ["path","query"].contains(loc) else { try fail("\(id): unsupported parameter location \(loc)") }
                try field(string(p["name"]), p["schema"], loc, p["required"] as? Bool ?? false)
            }
            let content = object(object(op["requestBody"])["content"])
            let upload = content["application/octet-stream"] != nil
            if let json = content["application/json"] {
                let body = try resolved(object(json)["schema"])
                guard body["additionalProperties"] as? Bool == false else { try fail("\(id): body must reject unknown fields") }
                let required = body["required"] as? [String] ?? []
                for key in object(body["properties"]).keys.sorted() { try field(key, object(body["properties"])[key], "body", required.contains(key)) }
            } else if !content.isEmpty && !upload { try fail("\(id): unsupported media type") }
            let keys = fields.map(\.key); guard Set(keys).count == keys.count else { try fail("\(id): duplicate flattened input field") }
            let options = fields.compactMap(\.option)
            guard options.allSatisfy({ $0.range(of: "^--[a-z][a-z0-9-]*$", options: .regularExpression) != nil }), Set(options).count == options.count else { try fail("\(id): invalid or duplicate options") }
            let positions = fields.compactMap(\.argument).sorted()
            guard positions == Array(0..<positions.count) else { try fail("\(id): positional arguments must be contiguous") }
            let expectedBindings = Set(fields.map { $0.location + "." + $0.key })
            guard Set(bindings.keys) == expectedBindings else { try fail("\(id): unknown CLI field binding") }
            let placeholders = path.split(separator: "/").filter { $0.hasPrefix("{") }.map { String($0.dropFirst().dropLast()) }
            guard Set(placeholders) == Set(fields.filter { $0.location == "path" && $0.required }.map(\.key)) else { try fail("\(id): path parameters must be declared and required") }
            if op["x-destructive"] as? Bool == true {
                guard fields.contains(where: { $0.key == "force" && $0.type == "boolean" && $0.required && $0.option == "--force" }) else { try fail("\(id): destructive operations require a required boolean force field mapped to --force") }
            }
            let response = object(object(object(op["responses"])["200"])["content"])
            let download = response["application/octet-stream"] != nil
            let resultSchema = object(object(response["application/json"])["schema"])
            let result = download ? "" : String(string(resultSchema["$ref"]).split(separator: "/").last ?? "")
            let resultObject = download ? [:] : try resolved(resultSchema)
            let output = download ? "TransferFile" : try type(object(object(resultObject["properties"])["data"]))
            operations.append(Operation(id: id, command: command, summary: string(op["summary"]), method: method, path: path,
                capabilities: op["x-capabilities"] as? [String] ?? [], fields: fields.sorted { $0.key < $1.key }, output: output, result: result, upload: upload, download: download, destructive: op["x-destructive"] as? Bool ?? false))
        }
    }
    operations.sort { $0.id < $1.id }
    guard Set(operations.map(\.id)).count == operations.count else { try fail("Duplicate operation IDs") }
    guard Set(operations.map { $0.command.joined(separator: " ") }).count == operations.count else { try fail("Duplicate CLI commands") }
    let rootCommands = Set(operations.filter { $0.command.count == 1 }.map { $0.command[0] })
    guard rootCommands.isDisjoint(with: Set(operations.filter { $0.command.count > 1 }.map { $0.command[0] })) else { try fail("A root CLI command collides with a command group") }
    let signatures = operations.map { $0.method + " " + $0.path.replacingOccurrences(of: "\\{[^}]+\\}", with: "{}", options: .regularExpression) }
    guard Set(signatures).count == signatures.count else { try fail("Ambiguous HTTP routes") }
    func write(_ path: String, _ value: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("// Generated by AppAutomation 1.0.0 from API/openapi.yaml. Do not edit.\n" + value).write(to: url, atomically: true, encoding: .utf8)
    }
    var shared = "import Foundation\nimport AutomationRuntime\n\npublic enum APIInputs {\n"
    for op in operations {
        shared += "    public struct \(op.upper): Codable, Sendable {\n"
        for f in op.fields { shared += "        public var \(f.key): \(f.swiftType)\n" }
        if op.upload { shared += "        public var transfer: String\n" }
        let params = op.fields.map { "\($0.key): \($0.swiftType)" + ($0.nullable ? " = .absent" : $0.required ? "" : " = nil") } + (op.upload ? ["transfer: String"] : [])
        shared += "        public init(\(params.joined(separator: ", "))) {\n"
        for f in op.fields { shared += "            self.\(f.key) = \(f.key)\n" }
        if op.upload { shared += "            self.transfer = transfer\n" }
        shared += "        }\n"
        let keys = op.fields.map(\.key) + (op.upload ? ["transfer"] : [])
        if !keys.isEmpty {
            shared += "        enum CodingKeys: String, CodingKey { case \(keys.joined(separator: ", ")) }\n"
            shared += "        public init(from decoder: Decoder) throws {\n            let c = try decoder.container(keyedBy: CodingKeys.self)\n"
            for f in op.fields {
                shared += "            \(f.key) = try c.\(f.nullable ? "presence" : f.required ? "decode" : "decodeIfPresent")(\(f.base).self, forKey: .\(f.key))\n"
            }
            if op.upload { shared += "            transfer = try c.decode(String.self, forKey: .transfer)\n" }
            shared += "        }\n        public func encode(to encoder: Encoder) throws {\n            var c = encoder.container(keyedBy: CodingKeys.self)\n"
            for f in op.fields { shared += "            try c.\(f.nullable ? "encodePresence" : f.required ? "encode" : "encodeIfPresent")(\(f.key), forKey: .\(f.key))\n" }
            if op.upload { shared += "            try c.encode(transfer, forKey: .transfer)\n" }
            shared += "        }\n"
        }
        shared += "    }\n"
    }
    shared += "}\n\npublic protocol LocalAppOperation: AutomationOperation {\n    static func perform(_ input: Input, application: any ApplicationOperations, configuration: any ConfigurationOperations) async throws -> Output\n}\n\npublic enum APIOperations {\n"
    for op in operations {
        shared += "    public enum \(op.upper): LocalAppOperation {\n        public typealias Input = APIInputs.\(op.upper)\n        public typealias Output = \(op.output)\n        public static let definition: OperationDefinition = \(op.definition)\n        public static func perform(_ input: Input, application: any ApplicationOperations, configuration: any ConfigurationOperations) async throws -> Output {\n            try definition.validate(JSONValue.encode(input))\n            return try await \(op.command.first == "config" ? "configuration" : "application").\(op.id)(input)\n        }\n    }\n"
    }
    shared += "}\n\npublic enum OperationID: String, Codable, CaseIterable, Sendable {\n" + operations.map { "    case \($0.id)" }.joined(separator: "\n") + "\n}\n"
    let groups = Dictionary(grouping: operations, by: { $0.command.first == "config" ? "Configuration" : "Application" })
    for group in groups.keys.sorted() {
        let ops = groups[group]!
        shared += "\npublic protocol \(group)Operations: Sendable {\n"
        for op in ops { shared += "    func \(op.id)(_ input: APIInputs.\(op.upper)) async throws -> \(op.output)\n" }
        shared += "}\npublic extension \(group)Operations {\n    func dispatch\(group)(_ request: AutomationRequest) async throws -> JSONValue? {\n        switch request.operation {\n"
        for op in ops {
            shared += "        case \(q(op.id)):\n            try APIOperations.\(op.upper).definition.validate(request.input)\n            return try await JSONValue.encode(\(op.id)(request.input.decode(APIInputs.\(op.upper).self)))\n"
        }
        shared += "        default: return nil\n        }\n    }\n}\n"
    }
    try write("Sources/Shared/API/Generated/AutomationOperations.swift", shared)
    let specData = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes])
    let catalog = "import Foundation\nimport AutomationRuntime\npublic enum GeneratedCatalog {\n    public static let operations: [OperationDefinition] = [\n" + operations.map { "        APIOperations.\($0.upper).definition" }.joined(separator: ",\n") + "\n    ]\n    public static let openAPI: String = \(q(String(decoding: specData, as: UTF8.self)))\n}\n"
    try write("Sources/Shared/API/Generated/AutomationCatalog.swift", catalog)
    var cli = "import Foundation\nimport AutomationCLI\nimport \(module)\n\nenum GeneratedCLI {\n"
    for op in operations {
        cli += "    struct \(op.upper): AsyncParsableCommand {\n        static let configuration = CommandConfiguration(commandName: \(q(op.command.last!)), abstract: \(q(op.summary)))\n"
        for f in op.fields.sorted(by: { ($0.argument ?? 100) < ($1.argument ?? 100) }) {
            if let index = f.argument {
                cli += "        @Argument(help: \(q(f.key + " (" + f.type + ")"))) var argument\(index): String?\n"
            } else if f.key == "force" {
                cli += "        @Flag(name: .customLong(\(q(String(f.option!.dropFirst(2))))), help: \(q("Confirm this destructive operation."))) var value_force = false\n"
            } else {
                cli += "        @Option(name: .customLong(\(q(String(f.option!.dropFirst(2))))), help: \(q(f.description.isEmpty ? f.key + " (" + f.type + ")" + (f.required ? "; required" : "") : f.description))) var value_\(f.key): String?\n"
            }
        }
        cli += "        @Flag(help: \(q("Emit a structured JSON result."))) var json = false\n        @Option(name: .customLong(\(q("input-file"))), help: \(q("Complete input JSON file; '-' reads stdin. Cannot combine with field flags."))) var inputFile: String?\n        @Option(help: \(q("Set a nullable field to null. Repeat for multiple fields."))) var clear: [String] = []\n"
        if op.upload { cli += "        @Option(help: \(q("File to upload."))) var file: String?\n" }
        if op.download { cli += "        @Option(help: \(q("Destination file for binary content."))) var output: String?\n        @Flag(help: \(q("Overwrite an existing destination."))) var force = false\n" }
        cli += "        mutating func run() async throws {\n            \(op.fields.isEmpty ? "let" : "var") values: [String: String] = [:]\n"
        for f in op.fields {
            if let index = f.argument { cli += "            values[\(q(f.key))] = argument\(index)\n" }
            else if f.key == "force" { cli += "            if value_force { values[\(q(f.key))] = \(q("true")) }\n" }
            else { cli += "            values[\(q(f.key))] = value_\(f.key)\n" }
        }
        cli += "            try await CLIEnvironment.current.run(APIOperations.\(op.upper).self, values: values, clear: clear, inputFile: inputFile, json: json, uploadFile: \(op.upload ? "file" : "nil"), outputFile: \(op.download ? "output" : "nil"), overwrite: \(op.download ? "force" : "false"))\n        }\n    }\n"
    }
    let nested = Dictionary(grouping: operations.filter { $0.command.count == 2 }, by: { $0.command[0] })
    for group in nested.keys.sorted() {
        cli += "    struct \(name(group))Group: AsyncParsableCommand {\n        static var configuration: CommandConfiguration { .init(commandName: \(q(group)), subcommands: [\n" + nested[group]!.map { "            CLIEnvironment.current.command(APIOperations.\($0.upper).self, default: \($0.upper).self)" }.joined(separator: ",\n") + "\n        ]) }\n    }\n"
    }
    let roots = operations.filter { $0.command.count == 1 }.map { "CLIEnvironment.current.command(APIOperations.\($0.upper).self, default: \($0.upper).self)" } + nested.keys.sorted().map { name($0) + "Group.self" }
    cli += "    static var commands: [ParsableCommand.Type] { [\n" + roots.map { "        " + $0 }.joined(separator: ",\n") + "\n    ] }\n}\n"
    try write("Sources/CLI/Generated/Commands.swift", cli)
    guard emitHTTP else {
        print("Generated \(operations.count) operations, typed dispatch, CLI commands, and discovery.")
        exit(0)
    }
    var http = "import Foundation\nimport AutomationHTTP\nimport OpenAPIRuntime\nimport \(module)\n\nstruct GeneratedHTTPBridge: APIProtocol {\n    let client: AutomationClient\n    let transfers: TransferStore\n"
    for op in operations {
        http += "    func \(op.id)(_ input: Operations.\(op.id).Input) async throws -> Operations.\(op.id).Output {\n"
        if op.upload { http += "        var stagedUpload: TransferFile?\n        var keepTransfer = false\n        defer { if !keepTransfer, let stagedUpload { transfers.remove(stagedUpload.handle) } }\n" }
        http += "        do {\n            \(op.fields.isEmpty ? "let" : "var") values: [String: JSONValue] = [:]\n"
        for f in op.fields where f.location != "body" {
            let access = "input.\(f.location).\(f.key)"
            if f.required { http += "            values[\(q(f.key))] = try JSONValue.encode(\(access))\n" }
            else { http += "            if let value = \(access) { values[\(q(f.key))] = try JSONValue.encode(value) }\n" }
        }
        if op.fields.contains(where: { $0.location == "body" }) {
            // Preserve absent vs null: the official optional DTO loses this distinction.
            http += "            for (key, value) in HTTPRequestContext.body?.object ?? [:] {\n                guard values[key] == nil else { throw AutomationFailure(\(q("invalid_input")), \(q("A body field duplicates a path/query parameter."))) }\n                values[key] = value\n            }\n"
        }
        if op.upload {
            http += "            let binary: HTTPBody\n            switch input.body { case .binary(let body): binary = body }\n            let upload = try await transfers.stage(binary, filename: input.query.filename)\n            stagedUpload = upload\n            values[\(q("transfer"))] = .string(upload.handle)\n"
        }
        http += "            let payload = JSONValue.object(values)\n            try APIOperations.\(op.upper).definition.validate(payload)\n            let result = try await client.call(APIOperations.\(op.upper).self, input: payload.decode())\n"
        if op.download {
            http += "            return .ok(.init(body: .binary(try await transfers.download(result.data))))\n"
        } else {
            http += "            let body: Components.Schemas.\(op.result) = try JSONValue.encode(result).decode()\n            return .ok(.init(body: .json(body)))\n"
        }
        http += "        } catch {\n            let failure = AutomationFailure.normalize(error)\n"
        if op.upload { http += "            keepTransfer = failure.code == \(q("outcome_unknown"))\n" }
        http += "            let body: Components.Schemas.ErrorResult = try JSONValue.encode(OperationError(requestId: AutomationContext.requestId, error: failure)).decode()\n            return .default(statusCode: failure.httpStatus, .init(body: .json(body)))\n        }\n    }\n"
    }
    http += "}\n"
    try write("Sources/HTTP/Generated/HTTPBridge.swift", http)
    print("Generated \(operations.count) operations, typed dispatch, CLI commands, discovery, and HTTP bridge.")
} catch { fputs("app-interface: \(error)\n", stderr); exit(1) }
