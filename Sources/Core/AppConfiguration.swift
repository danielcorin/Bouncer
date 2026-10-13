import Foundation
import Darwin
import Network
import TOML

/// What to do with the default browser after blocking tightens (blocking turns
/// on, or a block rule is added or re-enabled). Browsers reuse open connections,
/// so a restart is what makes new blocks apply to sites that are already open.
public enum RestartBrowserMode: String, CaseIterable, Codable, Sendable {
    case ask, always, off
}

public struct AppConfiguration: Equatable, Sendable {
    public static let defaults = AppConfiguration()
    public var enableOnLaunch: Bool
    public var flashIndicator: Bool
    /// Canonical chord such as `ctrl+option+cmd+b`; empty disables the global hotkey.
    public var hotkey: String
    public var blockBypassCanaries: Bool
    public var upstreamDNS: [String]
    public var restartBrowser: RestartBrowserMode

    public init(enableOnLaunch: Bool = false, flashIndicator: Bool = true, hotkey: String = "ctrl+option+cmd+b",
                blockBypassCanaries: Bool = true, upstreamDNS: [String] = [], restartBrowser: RestartBrowserMode = .ask) {
        self.enableOnLaunch = enableOnLaunch
        self.flashIndicator = flashIndicator
        self.hotkey = hotkey
        self.blockBypassCanaries = blockBypassCanaries
        self.upstreamDNS = upstreamDNS
        self.restartBrowser = restartBrowser
    }

    public var filterOptions: FilterOptions {
        FilterOptions(blockBypassCanaries: blockBypassCanaries, upstreamServers: upstreamDNS)
    }
}
public enum AppConfigurationKey: String, CaseIterable, Codable, Sendable {
    case enableOnLaunch = "enable-on-launch"
    case flashIndicator = "flash-indicator"
    case hotkey = "hotkey"
    case blockBypassCanaries = "block-bypass-canaries"
    case upstreamDNS = "upstream-dns"
    case restartBrowser = "restart-browser"
    public var valueType: String {
        switch self {
        case .enableOnLaunch, .flashIndicator, .blockBypassCanaries: "boolean"
        case .hotkey, .upstreamDNS, .restartBrowser: "string"
        }
    }
    public var documentation: String {
        switch self {
        case .enableOnLaunch: "Turn blocking on when Bouncer launches. Blocks are always removed when it quits."
        case .flashIndicator: "Briefly flash the menu bar icon and blocked domain when Bouncer blocks a lookup."
        case .hotkey: "Global shortcut that toggles blocking, e.g. ctrl+option+cmd+b. Use modifiers ctrl, option, shift, cmd. Empty disables it."
        case .blockBypassCanaries: "While blocking, answer NXDOMAIN for Firefox's DNS-over-HTTPS canary domain so Firefox falls back to system DNS."
        case .upstreamDNS: "Comma-separated resolver IPs to forward allowed lookups to. Empty follows the network's DHCP servers."
        case .restartBrowser: "After blocking turns on or a block rule is added, restart the default browser so it drops connections to newly blocked sites: ask, always, or off."
        }
    }
}
public enum AppConfigurationValue: Equatable, Sendable, Codable {
    case boolean(Bool), string(String), integer(Int)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .boolean(let v): try c.encode(v); case .string(let v): try c.encode(v); case .integer(let v): try c.encode(v) }
    }
    public var displayValue: String {
        switch self { case .boolean(let v): v ? "true" : "false"; case .string(let v): v; case .integer(let v): String(v) }
    }
}
public enum AppConfigurationSource: String, Codable, Sendable { case defaults, user }
public struct AppConfigurationEntry: Equatable, Sendable, Codable {
    public var key: AppConfigurationKey
    public var value: AppConfigurationValue
    public var source: AppConfigurationSource
    public var documentation: String
}
public enum AppConfigurationError: LocalizedError, Sendable {
    case invalidFile(path: String, reason: String)
    public var errorDescription: String? {
        switch self { case .invalidFile(let path, let reason): "Invalid configuration at \(path): \(reason)" }
    }
}
public struct AppConfigurationStore: Sendable, AppConfigurationStoreReadAccess {
    public static let changeNotification = Notification.Name("llc.wvlen.Bouncer.configurationChanged")
    public let fileURL: URL
    public init(fileURL: URL = Self.defaultFileURL()) { self.fileURL = fileURL }
    public static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let root = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? homeDirectory.appendingPathComponent(".config")
        return root.appendingPathComponent("bouncer/config.toml")
    }
    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
    }
    private func error(_ reason: String) -> AppConfigurationError { .invalidFile(path: fileURL.path, reason: reason) }
    private func overrides() throws -> [String: AppConfigurationValue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let values = try TOMLDecoder().decode([String: AppConfigurationValue].self, from: Data(contentsOf: fileURL))
            try validate(values); return values
        } catch { throw self.error(error.localizedDescription) }
    }
    private func validate(_ values: [String: AppConfigurationValue]) throws {
        for (raw, value) in values {
            guard let key = AppConfigurationKey(rawValue: raw) else { throw error("Unknown key '\(raw)'.") }
            switch (key, value) {
            case (.enableOnLaunch, .boolean), (.flashIndicator, .boolean), (.blockBypassCanaries, .boolean): break
            case (.hotkey, .string(let text)):
                guard text.isEmpty || HotkeyChord(text) != nil else { throw error("Invalid hotkey '\(text)'. \(key.documentation)") }
            case (.restartBrowser, .string(let text)):
                guard RestartBrowserMode(rawValue: text) != nil else { throw error("Invalid restart-browser '\(text)'. Use ask, always, or off.") }
            case (.upstreamDNS, .string(let text)):
                if let bad = Self.servers(text).first(where: { IPv4Address($0) == nil && IPv6Address($0) == nil }) {
                    throw error("'\(bad)' isn't an IP address. \(key.documentation)")
                }
            default: throw error("Invalid value for \(raw); expected \(key.valueType). \(key.documentation)")
            }
        }
    }
    static func servers(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }
    private func value(_ key: AppConfigurationKey, in config: AppConfiguration = .defaults) -> AppConfigurationValue {
        switch key {
        case .enableOnLaunch: .boolean(config.enableOnLaunch)
        case .flashIndicator: .boolean(config.flashIndicator)
        case .hotkey: .string(config.hotkey)
        case .blockBypassCanaries: .boolean(config.blockBypassCanaries)
        case .upstreamDNS: .string(config.upstreamDNS.joined(separator: ","))
        case .restartBrowser: .string(config.restartBrowser.rawValue)
        }
    }
    public func load() throws -> AppConfiguration {
        let values = try overrides()
        var configuration = AppConfiguration.defaults
        func bool(_ key: AppConfigurationKey) -> Bool? { if case .boolean(let v) = values[key.rawValue] { return v }; return nil }
        func string(_ key: AppConfigurationKey) -> String? { if case .string(let v) = values[key.rawValue] { return v }; return nil }
        if let v = bool(.enableOnLaunch) { configuration.enableOnLaunch = v }
        if let v = bool(.flashIndicator) { configuration.flashIndicator = v }
        if let v = bool(.blockBypassCanaries) { configuration.blockBypassCanaries = v }
        if let v = string(.hotkey) { configuration.hotkey = v.isEmpty ? "" : HotkeyChord(v)?.description ?? v }
        if let v = string(.upstreamDNS) { configuration.upstreamDNS = Self.servers(v) }
        if let v = string(.restartBrowser), let mode = RestartBrowserMode(rawValue: v) { configuration.restartBrowser = mode }
        return configuration
    }
    public func validate() throws { _ = try overrides() }
    public func validate(content: String) throws {
        do { try validate(TOMLDecoder().decode([String: AppConfigurationValue].self, from: Data(content.utf8))) }
        catch { throw self.error(error.localizedDescription) }
    }
    public func entry(for key: AppConfigurationKey) throws -> AppConfigurationEntry {
        let overrides = try overrides()
        return .init(key: key, value: overrides[key.rawValue] ?? value(key), source: overrides[key.rawValue] == nil ? .defaults : .user, documentation: key.documentation)
    }
    public func entries(changesOnly: Bool) throws -> [AppConfigurationEntry] {
        let values = try overrides()
        return AppConfigurationKey.allCases.map { key in
            AppConfigurationEntry(key: key, value: values[key.rawValue] ?? value(key), source: values[key.rawValue] == nil ? .defaults : .user, documentation: key.documentation)
        }.filter { !changesOnly || $0.source == .user }
    }
    @discardableResult func set(_ key: AppConfigurationKey, value text: String) throws -> AppConfiguration {
        let value: AppConfigurationValue
        switch key {
        case .enableOnLaunch, .flashIndicator, .blockBypassCanaries:
            guard text == "true" || text == "false" else { throw error("Use true or false.") }; value = .boolean(text == "true")
        case .hotkey:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || HotkeyChord(trimmed) != nil else { throw error("Invalid hotkey '\(text)'. \(key.documentation)") }
            value = .string(trimmed.isEmpty ? "" : HotkeyChord(trimmed)!.description)
        case .upstreamDNS:
            value = .string(Self.servers(text).joined(separator: ","))
        case .restartBrowser:
            value = .string(text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        try validate([key.rawValue: value])
        return try update { $0[key.rawValue] = value == self.value(key) ? nil : value }
    }
    @discardableResult func unset(_ key: AppConfigurationKey) throws -> AppConfiguration { try update { $0[key.rawValue] = nil } }
    private func update(_ change: (inout [String: AppConfigurationValue]) -> Void) throws -> AppConfiguration {
        try prepareDirectory()
        let fd = open(fileURL.deletingLastPathComponent().appendingPathComponent(".config.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("Could not open configuration lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw error("Could not lock configuration.") }
        defer { flock(fd, LOCK_UN) }
        var values = try overrides(); change(&values)
        if values.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        } else {
            let encoder = TOMLEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(values).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return try load()
    }
}
