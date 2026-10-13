import Foundation
import BouncerCore

/// A deterministic stand-in for the DNS tunnel, for tests and the automation
/// fixture. It applies the real `DNSFilterEngine` rules, so simulated lookups are
/// blocked exactly as the tunnel would block them.
@MainActor
final class InMemoryFilterBackend: FilterBackend {
    var installation = TunnelInstallation(installed: false)
    private(set) var isConnected = false
    var onBlocked: ((BlockedLookup) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private(set) var activeRules: [FilterRule]?
    private(set) var activeOptions: FilterOptions?
    private(set) var installCount = 0
    private(set) var exitTeardowns = 0
    var installFailure: FilterBackendError?
    /// False simulates a bypass such as iCloud Private Relay.
    var systemResolutionReachesFilter = true
    var activateFailure: FilterBackendError?
    /// Looked up once on each activation, like a browser tab reloading.
    var probes: [String]

    init(probes: [String] = []) { self.probes = probes }

    var isActive: Bool { activeRules != nil }

    func install() async throws {
        if let installFailure { throw installFailure }
        installCount += 1
        installation = .init(installed: true)
    }

    func uninstall() async throws {
        installation = .init(installed: false)
        isConnected = false
        activeRules = nil
    }

    func activate(rules: [FilterRule], options: FilterOptions) async throws {
        guard installation.installed else { throw FilterBackendError("tunnel_unavailable", "The tunnel isn't installed.") }
        if let activateFailure { throw activateFailure }
        isConnected = true
        activeRules = rules
        activeOptions = options
        probes.forEach(simulateLookup)
    }

    func update(rules: [FilterRule], options: FilterOptions) async throws {
        guard isActive else { throw FilterBackendError("tunnel_failed", "Not active.") }
        activeRules = rules
        activeOptions = options
    }

    func refresh() async {}

    func deactivate() async throws {
        activeRules = nil
        isConnected = false
    }

    func deactivateBeforeExit(timeout: TimeInterval) {
        exitTeardowns += 1
        activeRules = nil
        isConnected = false
    }

    func verifySystemResolution() async -> Bool { isActive && systemResolutionReachesFilter }

    func simulateLookup(_ domain: String) {
        guard let activeRules, case .blocked(let rule) = RuleMatcher(rules: activeRules).evaluate(domain) else { return }
        onBlocked?(BlockedLookup(domain: domain, ruleID: rule.id, rulePattern: rule.pattern))
    }

    /// The tunnel was stopped from outside (and with it, every block).
    func simulateDisconnect() {
        isConnected = false
        activeRules = nil
        onDisconnect?("The DNS tunnel was disconnected.")
    }
}
