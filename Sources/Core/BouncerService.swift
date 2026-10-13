import AutomationRuntime
import Foundation

/// App-process facts and window actions that only the running app can provide.
@MainActor
public protocol AppShell: AnyObject {
    var appName: String { get }
    var version: String { get }
    var isFrontmost: Bool { get }
    func show() throws -> String
    func quit() throws -> String
}

/// The one implementation of every app operation. The menu bar UI calls it
/// directly; the CLI reaches it through the automation socket.
@MainActor
public final class BouncerService: ApplicationOperations {
    public let store: BlockingStore
    private let shell: AppShell
    private var hotkey: String

    public init(store: BlockingStore, shell: AppShell, configuration: AppConfiguration = .defaults) {
        self.store = store
        self.shell = shell
        hotkey = configuration.hotkey
    }

    /// Pushes changed runtime settings into the active filter.
    public func applyConfiguration(_ configuration: AppConfiguration) async {
        hotkey = configuration.hotkey
        await store.applyOptions(configuration.filterOptions)
    }

    /// Loads saved tunnel state; call once at launch.
    public func start() async { await store.prepare() }

    public func shutdown() { store.shutdown() }

    // MARK: - App

    public func status(_ input: APIInputs.Status) async throws -> APIData.AppStatus {
        .init(appName: shell.appName, version: shell.version, processIdentifier: Int(ProcessInfo.processInfo.processIdentifier),
              isFrontmost: shell.isFrontmost, blocking: state())
    }

    public func show(_ input: APIInputs.Show) async throws -> APIData.Message { .init(message: try shell.show()) }
    public func quit(_ input: APIInputs.Quit) async throws -> APIData.Message { .init(message: try shell.quit()) }

    // MARK: - Blocking

    public func blockingOn(_ input: APIInputs.BlockingOn) async throws -> APIData.BlockingState {
        try await store.setEnabled(true)
        return state()
    }

    public func blockingOff(_ input: APIInputs.BlockingOff) async throws -> APIData.BlockingState {
        try await store.setEnabled(false)
        return state()
    }

    public func blockingToggle(_ input: APIInputs.BlockingToggle) async throws -> APIData.BlockingState {
        try await store.setEnabled(!store.isEnabled)
        return state()
    }

    public func tunnelInstall(_ input: APIInputs.TunnelInstall) async throws -> APIData.BlockingState {
        try await store.installTunnel()
        return state()
    }

    public func tunnelRemove(_ input: APIInputs.TunnelRemove) async throws -> APIData.BlockingState {
        guard input.force else { throw AutomationFailure("confirmation_required", "Pass --force true to remove the tunnel configuration.") }
        try await store.removeTunnel()
        return state()
    }

    // MARK: - Rules

    public func ruleList(_ input: APIInputs.RuleList) async throws -> APIData.RuleList {
        .init(rules: store.rules.map(Self.wire))
    }

    public func ruleAdd(_ input: APIInputs.RuleAdd) async throws -> APIData.Rule {
        try await Self.wire(store.addRule(pattern: input.pattern, kind: FilterPattern.kind(input.kind), action: FilterPattern.action(input.action)))
    }

    public func ruleUpdate(_ input: APIInputs.RuleUpdate) async throws -> APIData.Rule {
        try await Self.wire(store.updateRule(input.id, pattern: input.pattern, kind: FilterPattern.kind(input.kind),
                                             action: FilterPattern.action(input.action), enabled: input.enabled))
    }

    public func ruleRemove(_ input: APIInputs.RuleRemove) async throws -> APIData.Rule {
        try await Self.wire(store.removeRule(input.id))
    }

    public func ruleTest(_ input: APIInputs.RuleTest) async throws -> APIData.RuleTest {
        let domain = FilterPattern.normalizeDomain(input.domain)
        guard !domain.isEmpty else { throw AutomationFailure("invalid_input", "Enter a domain to test.") }
        switch store.evaluate(domain) {
        case .blocked(let rule): return .init(domain: domain, decision: .blocked, rule: Self.wire(rule))
        case .allowed(let rule): return .init(domain: domain, decision: .allowed, rule: Self.wire(rule))
        case .unmatched: return .init(domain: domain, decision: .unmatched)
        }
    }

    public func activityList(_ input: APIInputs.ActivityList) async throws -> APIData.Activity {
        let limit = input.limit ?? 20
        guard limit > 0 else { throw AutomationFailure("invalid_input", "--limit must be positive.") }
        let formatter = ISO8601DateFormatter()
        return .init(events: store.activity.prefix(limit).map {
            .init(domain: $0.domain, rulePattern: $0.rulePattern, at: formatter.string(from: $0.lastSeen), count: $0.count)
        }, blockedCount: store.blockedCount)
    }

    // MARK: - Wire mapping

    func state() -> APIData.BlockingState {
        store.refreshTunnel()
        return .init(enabled: store.isEnabled, phase: .init(rawValue: store.phase.rawValue) ?? .off, message: store.message,
                     ruleCount: store.rules.count, blockedCount: store.blockedCount, hotkey: hotkey, dnsVerified: store.dnsVerified,
                     tunnel: .init(installed: store.tunnel.installed, connected: store.tunnelConnected))
    }

    static func wire(_ rule: FilterRule) -> APIData.Rule {
        .init(id: rule.id.uuidString, pattern: rule.pattern, kind: rule.kind == .regex ? .regex : .domain,
              action: rule.action == .allow ? .allow : .block, enabled: rule.enabled)
    }
}
