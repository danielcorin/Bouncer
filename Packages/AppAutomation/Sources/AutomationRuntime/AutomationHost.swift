#if os(macOS)
import Foundation

public protocol CredentialAuthority: Sendable {
    func read() throws -> String?
    func create(replace: Bool) throws -> String
    func revoke() throws
    func authenticate(_ candidate: String) throws -> Bool
}
extension KeychainCredentialStore: CredentialAuthority {}

@MainActor
public final class AutomationHost {
    public let session = UUID()
    private let version: String
    private let operations: [String]
    /// Only an HTTP listener authenticates; a CLI-only app has no credentials.
    private let credentials: (any CredentialAuthority)?
    private let execute: @MainActor @Sendable (AutomationRequest) async throws -> JSONValue?
    private let normalize: @Sendable (Error) -> AutomationFailure
    public init(version: String, operations: [String], credentials: (any CredentialAuthority)? = nil,
                normalize: @escaping @Sendable (Error) -> AutomationFailure = { AutomationFailure.normalize($0) },
                execute: @escaping @MainActor @Sendable (AutomationRequest) async throws -> JSONValue?) {
        self.version = version; self.operations = operations; self.credentials = credentials; self.execute = execute; self.normalize = normalize
    }
    private func authority() throws -> any CredentialAuthority {
        guard let credentials else { throw AutomationFailure("capability_unavailable", "This app has no HTTP API, so it issues no credentials.") }
        return credentials
    }
    public func handle(_ request: AutomationRequest) async -> AutomationResponse {
        do {
            guard request.protocolVersion == AutomationVersion.protocolVersion else { throw AutomationFailure("incompatible_backend", "Use the CLI bundled with this app.") }
            let value: JSONValue
            switch request.operation {
            case "$handshake":
                value = try .encode(AutomationHandshake(version: version, session: session, operations: operations, maximumFrameBytes: SocketLimits.maximumFrameBytes))
            case "$credentialStatus": value = .object(["configured": .bool(try authority().read() != nil)])
            case "$credentialCreate": value = .object(["token": .string(try authority().create(replace: false))])
            case "$credentialShow":
                guard let token = try authority().read() else { throw AutomationFailure("not_found", "No API credential is configured. Run api token create.") }
                value = .object(["token": .string(token)])
            case "$credentialRotate", "$credentialRevoke":
                guard request.input.object?["force"] == .bool(true) else { throw AutomationFailure("force_required", "Credential rotation/revocation requires --force.") }
                if request.operation == "$credentialRotate" { value = .object(["token": .string(try authority().create(replace: true))]) }
                else { try authority().revoke(); value = .object(["configured": .bool(false)]) }
            case "$authenticate":
                guard let token = request.input.object?["token"]?.string, try authority().authenticate(token) else { throw AutomationFailure("unauthorized", "A valid bearer token is required.") }
                value = .object(["authenticated": .bool(true)])
            default:
                guard let result = try await execute(request) else { throw AutomationFailure("not_found", "Unknown operation '\(request.operation)'.") }
                value = result
            }
            return .init(requestId: request.requestId, data: value)
        } catch { return .init(requestId: request.requestId, error: normalize(error)) }
    }
}
#endif
