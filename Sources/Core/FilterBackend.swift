import Foundation

public struct TunnelInstallation: Equatable, Sendable {
    /// The VPN configuration is saved (the user allowed it once in macOS).
    public var installed: Bool
    public init(installed: Bool) { self.installed = installed }
}

/// What `BlockingStore` needs from the system. The app uses `TunnelFilterBackend`;
/// tests and the automation fixture inject an in-memory implementation.
@MainActor
public protocol FilterBackend: AnyObject {
    var installation: TunnelInstallation { get }
    var isConnected: Bool { get }
    /// Called for every lookup the filter blocked.
    var onBlocked: ((BlockedLookup) -> Void)? { get set }
    /// Called when filtering stops without the app asking (blocks are gone).
    var onDisconnect: ((String) -> Void)? { get set }

    /// Loads saved state; call once before reading `installation`.
    func refresh() async
    func install() async throws
    func uninstall() async throws
    func activate(rules: [FilterRule], options: FilterOptions) async throws
    func update(rules: [FilterRule], options: FilterOptions) async throws
    func deactivate() async throws
    /// Synchronous teardown while the app terminates. If the app dies without
    /// getting here, the tunnel stops itself when heartbeats cease.
    func deactivateBeforeExit(timeout: TimeInterval)
    /// Resolves a self-test name through the normal system resolver; true when the
    /// answer came from Bouncer's filter rather than some bypass.
    func verifySystemResolution() async -> Bool
}

public struct FilterBackendError: LocalizedError, Sendable {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}
