import Foundation

/// Locations and identity shared by the app, its installer, and the root helper.
public enum HelperConstants {
    public static let label = "llc.wvlen.Bouncer.helper"
    public static let clientIdentifier = "llc.wvlen.Bouncer"
    public static let socketPath = "/var/run/llc.wvlen.Bouncer.helper.sock"
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/llc.wvlen.Bouncer.helper"
    public static let launchDaemonPath = "/Library/LaunchDaemons/llc.wvlen.Bouncer.helper.plist"
    /// Holds the pre-activation DNS settings so they can be restored after a crash or reboot.
    public static let stateDirectory = "/Library/Application Support/Bouncer"
    public static let bundledHelperName = "BouncerHelper"
    public static let protocolVersion = 1
    public static let maxMessageBytes = 4 << 20
}

public struct FilterOptions: Codable, Equatable, Sendable {
    /// Answer NXDOMAIN for the Firefox DoH and iCloud Private Relay canary domains so
    /// those features fall back to system DNS (and therefore to Bouncer) while blocking.
    public var blockBypassCanaries: Bool
    /// Explicit upstream resolvers; empty means follow the network's DHCP/RA servers.
    public var upstreamServers: [String]

    public init(blockBypassCanaries: Bool = true, upstreamServers: [String] = []) {
        self.blockBypassCanaries = blockBypassCanaries
        self.upstreamServers = upstreamServers
    }
}

public struct HelperRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case hello, activate, update, deactivate, status
    }

    public var id: Int
    public var command: Command
    public var rules: [FilterRule]?
    public var options: FilterOptions?

    public init(id: Int, command: Command, rules: [FilterRule]? = nil, options: FilterOptions? = nil) {
        self.id = id
        self.command = command
        self.rules = rules
        self.options = options
    }
}

public struct HelperFilterStatus: Codable, Equatable, Sendable {
    public var active: Bool
    public var protocolVersion: Int
    public var upstream: [String]
    public var queries: Int
    public var blocked: Int

    public init(active: Bool, protocolVersion: Int = HelperConstants.protocolVersion, upstream: [String] = [], queries: Int = 0, blocked: Int = 0) {
        self.active = active
        self.protocolVersion = protocolVersion
        self.upstream = upstream
        self.queries = queries
        self.blocked = blocked
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

/// A response (with `id`) or an unsolicited event (`blocked`, no `id`).
public struct HelperMessage: Codable, Sendable {
    public var id: Int?
    public var error: String?
    public var status: HelperFilterStatus?
    public var blocked: BlockedLookup?

    public init(id: Int? = nil, error: String? = nil, status: HelperFilterStatus? = nil, blocked: BlockedLookup? = nil) {
        self.id = id
        self.error = error
        self.status = status
        self.blocked = blocked
    }
}

/// Newline-delimited JSON framing over the helper's Unix stream socket.
public enum HelperCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: line)
    }
}

/// Accumulates stream bytes and yields complete lines.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    /// Returns nil when a single line exceeds the frame limit.
    public mutating func append(_ data: Data) -> [Data]? {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        guard pending.count <= HelperConstants.maxMessageBytes else { return nil }
        return lines
    }
}
