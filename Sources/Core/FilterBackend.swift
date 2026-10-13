import Foundation

public struct HelperInstallation: Equatable, Sendable {
    public var installed: Bool
    public var upToDate: Bool
    public init(installed: Bool, upToDate: Bool) {
        self.installed = installed
        self.upToDate = upToDate
    }
}

/// What `BlockingStore` needs from the system. The app uses `HelperFilterBackend`;
/// tests and the automation fixture inject an in-memory implementation.
@MainActor
public protocol FilterBackend: AnyObject {
    var installation: HelperInstallation { get }
    var isConnected: Bool { get }
    /// Called for every lookup the filter blocked.
    var onBlocked: ((BlockedLookup) -> Void)? { get set }
    /// Called when the helper connection drops unexpectedly (blocks are gone).
    var onDisconnect: ((String) -> Void)? { get set }

    func install() async throws
    func uninstall() async throws
    func activate(rules: [FilterRule], options: FilterOptions) async throws
    func update(rules: [FilterRule], options: FilterOptions) async throws
    func deactivate() async throws
    /// Best-effort teardown while the app terminates; the helper also removes
    /// blocks on its own when this process's connection closes.
    func deactivateBeforeExit(timeout: TimeInterval)
    /// Resolves a self-test name through the normal system resolver; true when the
    /// answer came from Bouncer's filter rather than a bypass such as Private Relay.
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
