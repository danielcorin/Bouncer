import Combine
import Foundation

public enum BlockingPhase: String, Codable, Sendable {
    case off, starting, on, stopping, failed
}

public struct ActivityEntry: Equatable, Identifiable, Sendable {
    public var domain: String
    public var rulePattern: String
    public var lastSeen: Date
    public var count: Int
    public var id: String { domain }
}

/// The public read surface UI code may use; mutations go through `BouncerService`.
@MainActor
public protocol BlockingStoreReadAccess: ObservableObject {
    var rules: [FilterRule] { get }
    var isEnabled: Bool { get }
    var phase: BlockingPhase { get }
    var message: String? { get }
    var tunnel: TunnelInstallation { get }
    var tunnelConnected: Bool { get }
    /// nil until checked; false means lookups bypass the filter.
    var dnsVerified: Bool? { get }
    var activity: [ActivityEntry] { get }
    var blockedCount: Int { get }
    var blocks: AnyPublisher<ActivityEntry, Never> { get }
    static var defaultRulesURL: URL { get }
    static var bypassWarning: String { get }
    func evaluate(_ domain: String) -> FilterDecision
    /// Re-reads tunnel installation and connection state.
    func refreshTunnel()
}

/// Owns rules (persisted as JSON) and the blocking lifecycle. `isEnabled` is what
/// the user asked for; `phase` is what the system is actually doing.
@MainActor
public final class BlockingStore: BlockingStoreReadAccess {
    @Published public private(set) var rules: [FilterRule] = []
    @Published public private(set) var isEnabled = false
    @Published public private(set) var phase: BlockingPhase = .off
    @Published public private(set) var message: String?
    @Published public private(set) var tunnel: TunnelInstallation
    @Published public private(set) var tunnelConnected = false
    @Published public private(set) var dnsVerified: Bool?
    @Published public private(set) var activity: [ActivityEntry] = []
    @Published public private(set) var blockedCount = 0
    public var blocks: AnyPublisher<ActivityEntry, Never> { blockSubject.eraseToAnyPublisher() }

    static let activityLimit = 100
    private let blockSubject = PassthroughSubject<ActivityEntry, Never>()
    private let backend: FilterBackend
    private let rulesURL: URL
    private var matcher = RuleMatcher.empty
    private(set) var options: FilterOptions
    private var transition: Task<Void, Error>?
    private var verification: Task<Void, Never>?
    /// Delays before each self-test attempt; DNS configuration changes apply asynchronously.
    var verificationDelays: [Duration] = [.milliseconds(800), .seconds(1), .seconds(2)]
    nonisolated public static let bypassWarning = "Blocks may be bypassed: a test lookup didn't reach Bouncer's DNS tunnel. Another VPN or a DNS profile may be taking priority; turn blocking off and on to retry."

    nonisolated public static var defaultRulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bouncer/rules.json")
    }

    public init(rulesURL: URL = BlockingStore.defaultRulesURL, backend: FilterBackend, options: FilterOptions = .init()) {
        self.rulesURL = rulesURL
        self.backend = backend
        self.options = options
        tunnel = backend.installation
        if let data = try? Data(contentsOf: rulesURL), let saved = try? JSONDecoder().decode([FilterRule].self, from: data) {
            rules = saved
        }
        matcher = RuleMatcher(rules: rules)
        backend.onBlocked = { [weak self] lookup in self?.record(lookup) }
        backend.onDisconnect = { [weak self] reason in self?.connectionLost(reason) }
    }

    public func evaluate(_ domain: String) -> FilterDecision { matcher.evaluate(domain) }

    // MARK: - Lifecycle (internal: reached through BouncerService)

    /// Serializes on/off requests so rapid hotkey presses can't interleave.
    func setEnabled(_ enabled: Bool) async throws {
        let previous = transition
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await self.performSetEnabled(enabled)
        }
        transition = task
        try await task.value
    }

    /// Loads the saved tunnel configuration state.
    func prepare() async {
        await backend.refresh()
        refreshTunnel()
    }

    private func performSetEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard phase != .on || !backend.isConnected else { isEnabled = true; return }
            isEnabled = true
            phase = .starting
            message = nil
            do {
                try await ensureTunnel()
                try await backend.activate(rules: rules, options: options)
                phase = .on
                verifyResolution()
            } catch {
                isEnabled = false
                phase = .failed
                message = error.localizedDescription
                refreshTunnel()
                throw error
            }
        } else {
            isEnabled = false
            verification?.cancel()
            dnsVerified = nil
            if message == Self.bypassWarning { message = nil }
            guard phase != .off else { return }
            phase = .stopping
            do { try await backend.deactivate() } catch { message = error.localizedDescription }
            phase = .off
        }
        refreshTunnel()
    }

    /// First use: macOS asks the user to allow Bouncer's VPN configuration.
    private func ensureTunnel() async throws {
        if !backend.installation.installed {
            message = "Allow Bouncer's DNS tunnel when macOS asks…"
            try await backend.install()
            message = nil
        }
        refreshTunnel()
    }

    func installTunnel() async throws {
        do { try await backend.install() } catch {
            refreshTunnel()
            throw error
        }
        refreshTunnel()
    }

    func removeTunnel() async throws {
        try await setEnabled(false)
        try await backend.uninstall()
        refreshTunnel()
    }

    public func refreshTunnel() {
        tunnel = backend.installation
        tunnelConnected = backend.isConnected
    }

    /// Filtering stopped underneath us (e.g. another VPN replaced the tunnel).
    /// Don't fight it: report that blocking is off.
    private func connectionLost(_ reason: String) {
        verification?.cancel()
        dnsVerified = nil
        refreshTunnel()
        guard isEnabled || phase != .off else { return }
        isEnabled = false
        phase = .failed
        message = reason
    }

    /// Proves end to end that the system resolver reaches the filter.
    func verifyResolution() {
        verification?.cancel()
        dnsVerified = nil
        verification = Task { @MainActor [weak self] in
            guard let delays = self?.verificationDelays else { return }
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.phase == .on else { return }
                if await self.backend.verifySystemResolution() {
                    guard !Task.isCancelled else { return }
                    self.dnsVerified = true
                    if self.message == Self.bypassWarning { self.message = nil }
                    return
                }
            }
            guard let self, !Task.isCancelled, self.phase == .on else { return }
            self.dnsVerified = false
            self.message = Self.bypassWarning
        }
    }

    func applyOptions(_ options: FilterOptions) async {
        guard options != self.options else { return }
        self.options = options
        await pushRules()
    }

    // MARK: - Rules

    func addRule(pattern: String, kind: FilterRule.Kind?, action: FilterRule.Action?) async throws -> FilterRule {
        let parsed = try FilterPattern.parse(pattern, kind: kind)
        let action = action ?? .block
        if let existing = rules.first(where: { $0.pattern == parsed.pattern && $0.kind == parsed.kind && $0.action == action }) {
            return existing
        }
        let rule = FilterRule(pattern: parsed.pattern, kind: parsed.kind, action: action)
        try await commit(rules + [rule])
        return rule
    }

    func updateRule(_ reference: String, pattern: String?, kind: FilterRule.Kind?, action: FilterRule.Action?, enabled: Bool?) async throws -> FilterRule {
        var rule = try resolve(reference)
        if pattern != nil || kind != nil {
            let parsed = try FilterPattern.parse(pattern ?? rule.pattern, kind: kind ?? (pattern == nil ? rule.kind : nil))
            rule.pattern = parsed.pattern
            rule.kind = parsed.kind
        }
        if let action { rule.action = action }
        if let enabled { rule.enabled = enabled }
        try await commit(rules.map { $0.id == rule.id ? rule : $0 })
        return rule
    }

    func removeRule(_ reference: String) async throws -> FilterRule {
        let rule = try resolve(reference)
        try await commit(rules.filter { $0.id != rule.id })
        return rule
    }

    /// Accepts a full ID, a unique ID prefix (4+ characters), or an exact pattern.
    func resolve(_ reference: String) throws -> FilterRule {
        let text = reference.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        if let exact = rules.first(where: { $0.id.uuidString.lowercased() == lowered }) { return exact }
        let normalized = (try? FilterPattern.parse(text, kind: nil).pattern) ?? text
        let byPattern = rules.filter { $0.pattern == text || $0.pattern == normalized }
        if byPattern.count == 1 { return byPattern[0] }
        if lowered.count >= 4 {
            let byPrefix = rules.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
            if byPrefix.count == 1 { return byPrefix[0] }
            if byPrefix.count > 1 { throw FilterBackendError("ambiguous", "'\(text)' matches \(byPrefix.count) rules; use more of the ID.") }
        }
        if byPattern.count > 1 { throw FilterBackendError("ambiguous", "'\(text)' matches \(byPattern.count) rules; use the rule ID.") }
        throw FilterBackendError("not_found", "No rule matches '\(text)'. Run `bouncer rules list`.")
    }

    private func commit(_ updated: [FilterRule]) async throws {
        try FileManager.default.createDirectory(at: rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: rulesURL, options: .atomic)
        rules = updated
        matcher = RuleMatcher(rules: updated)
        await pushRules()
    }

    private func pushRules() async {
        guard phase == .on else { return }
        do { try await backend.update(rules: rules, options: options) }
        catch { message = "Couldn't update the active filter: \(error.localizedDescription)" }
    }

    // MARK: - Activity

    func record(_ lookup: BlockedLookup) {
        blockedCount += 1
        var entry = ActivityEntry(domain: lookup.domain, rulePattern: lookup.rulePattern, lastSeen: lookup.date, count: 1)
        if let index = activity.firstIndex(where: { $0.domain == lookup.domain }) {
            entry.count += activity[index].count
            activity.remove(at: index)
        }
        activity.insert(entry, at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
        blockSubject.send(entry)
    }

    /// Called as the app terminates; blocks must never outlive Bouncer.
    func shutdown() {
        verification?.cancel()
        if phase != .off || backend.isConnected { backend.deactivateBeforeExit(timeout: 3) }
        isEnabled = false
        phase = .off
    }
}
