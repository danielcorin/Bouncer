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
    var helper: HelperInstallation { get }
    var helperConnected: Bool { get }
    var activity: [ActivityEntry] { get }
    var blockedCount: Int { get }
    var blocks: AnyPublisher<ActivityEntry, Never> { get }
    static var defaultRulesURL: URL { get }
    func evaluate(_ domain: String) -> FilterDecision
    /// Re-reads helper installation and connection state.
    func refreshHelper()
}

/// Owns rules (persisted as JSON) and the blocking lifecycle. `isEnabled` is what
/// the user asked for; `phase` is what the system is actually doing.
@MainActor
public final class BlockingStore: BlockingStoreReadAccess {
    @Published public private(set) var rules: [FilterRule] = []
    @Published public private(set) var isEnabled = false
    @Published public private(set) var phase: BlockingPhase = .off
    @Published public private(set) var message: String?
    @Published public private(set) var helper: HelperInstallation
    @Published public private(set) var helperConnected = false
    @Published public private(set) var activity: [ActivityEntry] = []
    @Published public private(set) var blockedCount = 0
    public var blocks: AnyPublisher<ActivityEntry, Never> { blockSubject.eraseToAnyPublisher() }

    static let activityLimit = 100
    private let blockSubject = PassthroughSubject<ActivityEntry, Never>()
    private let backend: FilterBackend
    private let rulesURL: URL
    private var matcher = RuleMatcher.empty
    private(set) var options: FilterOptions
    private var reconnectTask: Task<Void, Never>?
    private var transition: Task<Void, Error>?

    nonisolated public static var defaultRulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bouncer/rules.json")
    }

    public init(rulesURL: URL = BlockingStore.defaultRulesURL, backend: FilterBackend, options: FilterOptions = .init()) {
        self.rulesURL = rulesURL
        self.backend = backend
        self.options = options
        helper = backend.installation
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

    private func performSetEnabled(_ enabled: Bool) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        if enabled {
            guard phase != .on || !backend.isConnected else { isEnabled = true; return }
            isEnabled = true
            phase = .starting
            message = nil
            do {
                try await ensureHelper()
                try await backend.activate(rules: rules, options: options)
                phase = .on
            } catch {
                isEnabled = false
                phase = .failed
                message = error.localizedDescription
                refreshHelper()
                throw error
            }
        } else {
            isEnabled = false
            guard phase != .off else { return }
            phase = .stopping
            do { try await backend.deactivate() } catch { message = error.localizedDescription }
            phase = .off
        }
        refreshHelper()
    }

    private func ensureHelper() async throws {
        let state = backend.installation
        if !state.installed || !state.upToDate {
            message = state.installed ? "Updating the DNS helper…" : "Installing the DNS helper…"
            try await backend.install()
            message = nil
        }
        refreshHelper()
    }

    func installHelper() async throws {
        let wasOn = isEnabled
        do {
            try await backend.install()
        } catch {
            refreshHelper()
            throw error
        }
        refreshHelper()
        if wasOn {
            phase = .off
            try await setEnabled(true)
        }
    }

    func uninstallHelper() async throws {
        try await setEnabled(false)
        try await backend.uninstall()
        refreshHelper()
    }

    public func refreshHelper() {
        helper = backend.installation
        helperConnected = backend.isConnected
    }

    /// The helper already removed blocks when the connection dropped. If blocking
    /// is still wanted (e.g. the helper was updated or restarted), re-activate.
    private func connectionLost(_ reason: String) {
        refreshHelper()
        guard isEnabled, phase == .on else { return }
        phase = .starting
        message = "\(reason) Reconnecting…"
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            for delay in [0.5, 1, 2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.isEnabled else { return }
                do {
                    try await self.backend.activate(rules: self.rules, options: self.options)
                    self.phase = .on
                    self.message = nil
                    self.refreshHelper()
                    return
                } catch {
                    self.message = "\(reason) \(error.localizedDescription)"
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isEnabled = false
            self.phase = .failed
            self.refreshHelper()
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
        reconnectTask?.cancel()
        if phase != .off || backend.isConnected { backend.deactivateBeforeExit(timeout: 3) }
        isEnabled = false
        phase = .off
    }
}
