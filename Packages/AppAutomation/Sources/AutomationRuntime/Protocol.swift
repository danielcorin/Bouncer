import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public static func encode<T: Encodable>(_ value: T) throws -> Self {
        try AutomationCoding.decoder.decode(Self.self, from: AutomationCoding.encoder.encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try AutomationCoding.decoder.decode(T.self, from: AutomationCoding.encoder.encode(self))
    }
}

public enum AutomationCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

/// Update presence is preserved all the way to the domain service.
public enum Presence<Value: Codable & Sendable>: Sendable {
    case absent, null, value(Value)
    public var optional: Value? { if case .value(let v) = self { return v }; return nil }
    public var isPresent: Bool { if case .absent = self { return false }; return true }
    public func map<T>(_ transform: (Value) throws -> T) rethrows -> T?? {
        switch self { case .absent: return nil; case .null: return .some(nil); case .value(let v): return .some(try transform(v)) }
    }
}

public extension KeyedDecodingContainer {
    func presence<T: Codable & Sendable>(_ type: T.Type, forKey key: Key) throws -> Presence<T> {
        guard contains(key) else { return .absent }
        return try decodeNil(forKey: key) ? .null : .value(decode(type, forKey: key))
    }
}
public extension KeyedEncodingContainer {
    mutating func encodePresence<T>(_ value: Presence<T>, forKey key: Key) throws {
        switch value { case .absent: break; case .null: try encodeNil(forKey: key); case .value(let v): try encode(v, forKey: key) }
    }
}

public struct AutomationFailure: Error, Codable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var details: [String: String]?
    public init(_ code: String, _ message: String, details: [String: String]? = nil) {
        self.code = code; self.message = message; self.details = details
    }
    public var errorDescription: String? { message }
    public var httpStatus: Int {
        switch code {
        case "invalid_argument", "invalid_input", "force_required": return 400
        case "unauthorized": return 401
        case "permission_denied", "capability_unavailable": return 403
        case "not_found": return 404
        case "conflict": return 409
        case "payload_too_large": return 413
        case "unavailable", "incompatible_backend", "busy": return 503
        case "timeout", "outcome_unknown": return 504
        default: return 500
        }
    }
    public var exitCode: Int32 {
        switch code {
        case "invalid_argument", "invalid_input", "force_required": return 2
        case "unavailable", "incompatible_backend", "timeout", "outcome_unknown": return 3
        default: return 1
        }
    }
    public static func normalize(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is DecodingError { return Self("invalid_input", "The input does not match the operation schema.") }
        if error is CancellationError { return Self("canceled", "The operation was canceled; a dispatched mutation may have completed.") }
        return Self("internal_error", "The operation could not be completed.")
    }
}

public struct AutomationRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var requestId: UUID
    public var operation: String
    public var input: JSONValue
    public init(operation: String, input: JSONValue = .object([:]), requestId: UUID = UUID()) {
        protocolVersion = AutomationVersion.protocolVersion
        self.operation = operation; self.input = input; self.requestId = requestId
    }
}
public enum AutomationContext {
    @TaskLocal public static var requestId: UUID?
}
public struct AutomationResponse: Codable, Sendable {
    public var protocolVersion = AutomationVersion.protocolVersion
    public var requestId: UUID
    public var data: JSONValue?
    public var error: AutomationFailure?
    public init(requestId: UUID, data: JSONValue? = nil, error: AutomationFailure? = nil) {
        self.requestId = requestId; self.data = data; self.error = error
    }
    public func checked(for request: AutomationRequest) throws -> JSONValue {
        guard protocolVersion == AutomationVersion.protocolVersion else {
            throw AutomationFailure("incompatible_backend", "Use the CLI bundled with the running app.")
        }
        guard requestId == request.requestId else { throw AutomationFailure("incompatible_backend", "The app returned a mismatched request ID.") }
        if var error {
            error.details = (error.details ?? [:]).merging(["requestId": requestId.uuidString]) { _, new in new }
            throw error
        }
        guard let data else { throw AutomationFailure("internal_error", "The app returned no result.") }
        return data
    }
}
public struct OperationResult<Value: Codable & Sendable>: Codable, Sendable {
    public var requestId: UUID
    public var data: Value
    public init(requestId: UUID, data: Value) { self.requestId = requestId; self.data = data }
}
public struct OperationError: Codable, Sendable {
    public var requestId: UUID?
    public var error: AutomationFailure
    public init(requestId: UUID? = nil, error: AutomationFailure) { self.requestId = requestId; self.error = error }
}

public protocol AutomationOperation {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
    static var definition: OperationDefinition { get }
}
public struct AutomationClient: Sendable {
    public var send: @Sendable (AutomationRequest) async throws -> AutomationResponse
    public init(send: @escaping @Sendable (AutomationRequest) async throws -> AutomationResponse) { self.send = send }
    public func call<O: AutomationOperation>(_ operation: O.Type, input: O.Input) async throws -> OperationResult<O.Output> {
        let payload = try JSONValue.encode(input)
        try O.definition.validate(payload)
        let request = AutomationRequest(operation: O.definition.id, input: payload, requestId: AutomationContext.requestId ?? UUID())
        let response = try await send(request)
        let data = try response.checked(for: request)
        do { return OperationResult(requestId: request.requestId, data: try data.decode()) }
        catch { throw AutomationFailure("incompatible_backend", "The app returned a result that does not match this CLI's schema.", details: ["requestId": request.requestId.uuidString]) }
    }
}
