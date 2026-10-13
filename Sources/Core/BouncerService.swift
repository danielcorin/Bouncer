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
    /// Asks whether to restart the default browser now; false means "not now".
    func confirmBrowserRestart(_ browser: BrowserInfo) async -> Bool
}

/// The one implementation of every app operation. The menu bar UI calls it
/// directly; the CLI reaches it through the automation socket.
@MainActor
public final class BouncerService: ApplicationOperations {
    public let store: BlockingStore
    private let shell: AppShell
    private let browser: BrowserControlling
    private var hotkey: String
    private var restartMode: RestartBrowserMode
    private var lastRestartOffer: Date?
    private var offeringRestart = false
    /// Minimum time between restart offers, so a burst of rule edits asks once.
    var restartOfferCooldown: TimeInterval = 30
    /// The pending ask-or-restart, exposed so tests can await it.
    private(set) var restartTask: Task<Void, Never>?

    public init(store: BlockingStore, shell: AppShell, browser: BrowserControlling, configuration: AppConfiguration = .defaults) {
        self.store = store
        self.shell = shell
        self.browser = browser
        hotkey = configuration.hotkey
        restartMode = configuration.restartBrowser
    }

    /// Pushes changed runtime settings into the active filter.
    public func applyConfiguration(_ configuration: AppConfiguration) async {
        hotkey = configuration.hotkey
        restartMode = configuration.restartBrowser
        await store.applyOptions(configuration.filterOptions)
    }

    // MARK: - Browser restart

    /// Blocking just got stricter. Browsers keep using connections they already
    /// have open, so a newly blocked site can stay loaded until the browser
    /// restarts; offer (or perform) that restart without delaying the caller.
    func blockingTightened() {
        guard restartMode != .off, store.phase == .on, !offeringRestart else { return }
        if let lastRestartOffer, Date().timeIntervalSince(lastRestartOffer) < restartOfferCooldown { return }
        guard let info = browser.defaultBrowser(), info.isRunning else { return }
        lastRestartOffer = Date()
        offeringRestart = true
        let mode = restartMode
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.offeringRestart = false }
            if mode == .ask {
                guard await self.shell.confirmBrowserRestart(info) else { return }
            }
            do { try await self.browser.restart(info) } catch { self.store.note(error.localizedDescription) }
        }
    }

    public func browserRestart(_ input: APIInputs.BrowserRestart) async throws -> APIData.BrowserRestart {
        guard input.force else { throw AutomationFailure("confirmation_required", "Pass --force to quit and relaunch the default browser.") }
        guard let info = browser.defaultBrowser() else {
            throw AutomationFailure("unavailable", "macOS doesn't report a default web browser.")
        }
        guard info.isRunning else {
            return .init(browser: info.name, restarted: false, restoresTabs: info.restoresTabs, message: "\(info.name) isn't running; nothing to restart.")
        }
        try await browser.restart(info)
        let tabs = info.restoresTabs == true ? " with its windows and tabs" : ""
        return .init(browser: info.name, restarted: true, restoresTabs: info.restoresTabs, message: "Restarted \(info.name)\(tabs).")
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
        let wasOn = store.phase == .on
        try await store.setEnabled(true)
        if !wasOn { blockingTightened() }
        return state()
    }

    public func blockingOff(_ input: APIInputs.BlockingOff) async throws -> APIData.BlockingState {
        try await store.setEnabled(false)
        return state()
    }

    public func blockingToggle(_ input: APIInputs.BlockingToggle) async throws -> APIData.BlockingState {
        let turningOn = !store.isEnabled
        try await store.setEnabled(turningOn)
        if turningOn { blockingTightened() }
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
        let rule = try await store.addRule(pattern: input.pattern, kind: FilterPattern.kind(input.kind), action: FilterPattern.action(input.action))
        if rule.action == .block && rule.enabled { blockingTightened() }
        return Self.wire(rule)
    }

    public func ruleUpdate(_ input: APIInputs.RuleUpdate) async throws -> APIData.Rule {
        let before = try store.resolve(input.id)
        let rule = try await store.updateRule(input.id, pattern: input.pattern, kind: FilterPattern.kind(input.kind),
                                              action: FilterPattern.action(input.action), enabled: input.enabled)
        // Stricter when a block rule now applies that didn't (or matches differently).
        let wasBlocking = before.enabled && before.action == .block
        if rule.enabled && rule.action == .block && (!wasBlocking || rule.pattern != before.pattern || rule.kind != before.kind) {
            blockingTightened()
        }
        return Self.wire(rule)
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

    // MARK: - Stats

    public func statsShow(_ input: APIInputs.StatsShow) async throws -> APIData.Stats {
        let days: [DayDenials]
        if let date = input.date?.trimmingCharacters(in: .whitespaces), !date.isEmpty {
            guard DenialStatsStore.date(forKey: date) != nil else {
                throw AutomationFailure("invalid_input", "Use a date like \(DenialStatsStore.dayKey(for: Date())).")
            }
            days = [store.stats.day(date)]
        } else {
            let count = input.days ?? 7
            guard (1...366).contains(count) else { throw AutomationFailure("invalid_input", "--days must be between 1 and 366.") }
            days = store.stats.recentDays(count, endingOn: Date()).reversed()
        }
        return statsResult(days)
    }

    public func statsClear(_ input: APIInputs.StatsClear) async throws -> APIData.Stats {
        guard input.force else { throw AutomationFailure("confirmation_required", "Pass --force to delete all stats.") }
        store.stats.clear()
        return statsResult([store.stats.day(DenialStatsStore.dayKey(for: Date()))])
    }

    private func statsResult(_ days: [DayDenials]) -> APIData.Stats {
        let formatter = ISO8601DateFormatter()
        let today = store.stats.day(DenialStatsStore.dayKey(for: Date()))
        return .init(days: days.map { day in
            .init(date: day.date, attempts: day.attempts, lookups: day.lookups, sites: day.ranked.map {
                .init(site: $0.site, attempts: $0.attempts, lookups: $0.lookups, lastDenied: formatter.string(from: $0.lastDenied))
            })
        }, todayAttempts: today.attempts, totalAttempts: store.stats.totalAttempts)
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
