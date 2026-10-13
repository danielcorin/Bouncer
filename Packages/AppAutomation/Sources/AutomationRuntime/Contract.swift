import Foundation

public struct FieldDefinition: Codable, Sendable {
    public var name: String
    public var location: String
    public var type: String
    public var required: Bool
    public var nullable: Bool
    public var option: String?
    public var argument: Int?
    public var description: String
    public init(name: String, location: String, type: String, required: Bool, nullable: Bool = false,
                option: String? = nil, argument: Int? = nil, description: String = "") {
        self.name = name; self.location = location; self.type = type; self.required = required
        self.nullable = nullable; self.option = option; self.argument = argument; self.description = description
    }
    public func parse(_ text: String) throws -> JSONValue {
        switch type {
        case "string": return .string(text)
        case "integer": if let v = Int(text) { return .integer(v) }
        case "number": if let v = Double(text), v.isFinite { return .number(v) }
        case "boolean": if text == "true" { return .bool(true) }; if text == "false" { return .bool(false) }
        default:
            if let data = text.data(using: .utf8), let value = try? AutomationCoding.decoder.decode(JSONValue.self, from: data) {
                try validate(value); return value
            }
        }
        throw AutomationFailure("invalid_input", "\(name) requires \(type). Use JSON for arrays and objects.")
    }
    public func validate(_ value: JSONValue) throws {
        if value == .null {
            guard nullable else { throw AutomationFailure("invalid_input", "\(name) cannot be null.") }; return
        }
        let valid: Bool
        switch (type, value) {
        case ("string", .string), ("integer", .integer), ("number", .number), ("number", .integer),
             ("boolean", .bool), ("object", .object): valid = true
        case ("string[]", .array(let a)): valid = a.allSatisfy { if case .string = $0 { return true }; return false }
        case ("integer[]", .array(let a)): valid = a.allSatisfy { if case .integer = $0 { return true }; return false }
        default: valid = false
        }
        guard valid else { throw AutomationFailure("invalid_input", "\(name) requires \(type).") }
    }
}
public struct OperationDefinition: Codable, Sendable {
    public var id: String
    public var command: [String]
    public var summary: String
    public var method: String
    public var path: String
    public var fields: [FieldDefinition]
    public var destructive: Bool
    public var upload: Bool
    public var download: Bool
    public var responseSchema: String?
    public var capabilities: [String]
    public init(id: String, command: [String], summary: String, method: String, path: String,
                fields: [FieldDefinition], destructive: Bool = false, upload: Bool = false, download: Bool = false,
                responseSchema: String? = nil, capabilities: [String] = []) {
        self.id = id; self.command = command; self.summary = summary; self.method = method; self.path = path
        self.fields = fields; self.destructive = destructive; self.upload = upload; self.download = download
        self.responseSchema = responseSchema; self.capabilities = capabilities
    }
    public func validate(_ input: JSONValue) throws {
        guard let values = input.object else { throw AutomationFailure("invalid_input", "An operation input must be an object.") }
        let known = Set(fields.map(\.name)).union(upload ? ["transfer"] : [])
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            throw AutomationFailure("invalid_input", "Unknown input field '\(unknown)' for \(id).")
        }
        for field in fields {
            if let value = values[field.name] { try field.validate(value) }
            else if field.required { throw AutomationFailure("invalid_input", "\(field.name) is required for \(id).") }
        }
        if destructive, values["force"] != .bool(true) { throw AutomationFailure("force_required", "\(id) requires explicit force=true (--force).") }
        if upload, values["transfer"]?.string == nil { throw AutomationFailure("invalid_input", "Upload content is required.") }
    }
}

public struct AutomationHandshake: Codable, Sendable {
    public var protocolVersion: Int
    public var version: String
    public var session: UUID
    public var operations: [String]
    public var maximumFrameBytes: Int
    public init(version: String, session: UUID, operations: [String], maximumFrameBytes: Int) {
        protocolVersion = AutomationVersion.protocolVersion; self.version = version; self.session = session
        self.operations = operations; self.maximumFrameBytes = maximumFrameBytes
    }
}
