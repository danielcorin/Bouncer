import Foundation

/// Identity and addresses shared by the app and its packet tunnel extension.
public enum TunnelConstants {
    /// The embedded extension's bundle ID is always the app's plus ".Tunnel"
    /// (see project.yml), so forks only need to change PRODUCT_BUNDLE_IDENTIFIER.
    public static var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "llc.wvlen.Bouncer") + ".Tunnel"
    }
    public static let configurationName = "Bouncer"
    /// The virtual resolver inside the tunnel; the only route the tunnel claims.
    public static let dnsServer = "198.18.0.1"
    public static let dnsServerBytes: [UInt8] = [198, 18, 0, 1]
    public static let tunnelAddress = "198.18.0.2"
    /// The tunnel stops itself if the app goes this long without contact, so
    /// blocks never outlive Bouncer (e.g. after a crash or force quit).
    public static let heartbeatTimeout: TimeInterval = 10
    /// The tunnel answers `<nonce>.` + this suffix with `selfTestAddress`, so the
    /// app can prove the system resolver really goes through the filter.
    public static let selfTestSuffix = "selftest.bouncer.internal"
    public static let selfTestAddress: [UInt8] = [127, 0, 0, 53]
    public static let maxEvents = 200
}

public struct FilterOptions: Codable, Equatable, Sendable {
    /// Answer NXDOMAIN for Firefox's DNS-over-HTTPS canary so it falls back to
    /// system DNS (and therefore to Bouncer) while blocking.
    public var blockBypassCanaries: Bool
    /// Explicit upstream resolvers; empty means follow the network's DHCP/RA servers.
    public var upstreamServers: [String]

    public init(blockBypassCanaries: Bool = true, upstreamServers: [String] = []) {
        self.blockBypassCanaries = blockBypassCanaries
        self.upstreamServers = upstreamServers
    }
}

public struct BlockedLookup: Codable, Equatable, Sendable {
    public var domain: String
    public var ruleID: UUID
    public var rulePattern: String
    public var date: Date

    public init(domain: String, ruleID: UUID, rulePattern: String, date: Date = Date()) {
        self.domain = domain
        self.ruleID = ruleID
        self.rulePattern = rulePattern
        self.date = date
    }
}

/// Everything the tunnel needs to filter. Sent at start (provider configuration)
/// and again whenever rules, settings, or the network's resolvers change.
public struct TunnelConfiguration: Codable, Equatable, Sendable {
    public var rules: [FilterRule]
    public var options: FilterOptions
    /// Resolvers to forward allowed lookups to, in preference order.
    public var upstream: [String]

    public init(rules: [FilterRule], options: FilterOptions, upstream: [String]) {
        self.rules = rules
        self.options = options
        self.upstream = upstream
    }

    public static let providerConfigurationKey = "configuration"
}

/// App → tunnel message. Every message also counts as a heartbeat.
public struct TunnelRequest: Codable, Sendable {
    public var configuration: TunnelConfiguration?
    /// Return blocked lookups with a sequence number greater than this.
    public var eventsAfter: Int

    public init(configuration: TunnelConfiguration? = nil, eventsAfter: Int) {
        self.configuration = configuration
        self.eventsAfter = eventsAfter
    }
}

public struct TunnelStats: Codable, Equatable, Sendable {
    public var queries = 0
    public var blocked = 0
    public var forwarded = 0
    public var failed = 0
    public init() {}
}

public struct TunnelReply: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public var sequence: Int
        public var lookup: BlockedLookup
        public init(sequence: Int, lookup: BlockedLookup) {
            self.sequence = sequence
            self.lookup = lookup
        }
    }

    public var events: [Event]
    public var lastSequence: Int
    public var stats: TunnelStats

    public init(events: [Event], lastSequence: Int, stats: TunnelStats) {
        self.events = events
        self.lastSequence = lastSequence
        self.stats = stats
    }
}

public enum TunnelCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
