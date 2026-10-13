import Foundation
import Network
import SystemConfiguration

/// Chooses the real resolvers and relays queries to them. While blocking, the
/// services' manual DNS points at us, but each service's State key still carries
/// the DHCP/RA servers, so switching networks keeps working.
final class UpstreamResolver: @unchecked Sendable {
    static let fallback = ["1.1.1.1", "8.8.8.8"]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.helper.upstream", attributes: .concurrent)
    private var explicit: [String] = []
    private var captured: [String] = []
    private var cached: (servers: [String], at: Date)?

    func configure(explicit servers: [String]) {
        lock.withLock {
            explicit = servers.filter(Self.isUsable)
            cached = nil
        }
    }

    /// Snapshot the effective resolvers before we replace them.
    func captureSystemServers() {
        let servers = Self.serverAddresses(atKey: "State:/Network/Global/DNS").filter(Self.isUsable)
        lock.withLock {
            captured = servers
            cached = nil
        }
    }

    func currentServers() -> [String] {
        lock.withLock {
            if !explicit.isEmpty { return explicit }
            if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.servers }
            var servers = Self.detectServiceServers()
            for server in captured where !servers.contains(server) { servers.append(server) }
            if servers.isEmpty { servers = Self.fallback }
            cached = (servers, Date())
            return servers
        }
    }

    /// Tries each server in order with a two-second budget apiece; nil if all fail.
    func forward(_ query: [UInt8], tcp: Bool, completion: @escaping ([UInt8]?) -> Void) {
        attempt(query, tcp: tcp, servers: currentServers()[...].prefix(3), completion: completion)
    }

    private func attempt(_ query: [UInt8], tcp: Bool, servers: ArraySlice<String>, completion: @escaping ([UInt8]?) -> Void) {
        guard let server = servers.first else { completion(nil); return }
        let exchange = Exchange(server: server, query: query, tcp: tcp, queue: queue)
        exchange.run { [weak self] response in
            if let response { completion(response) }
            else if let self { self.attempt(query, tcp: tcp, servers: servers.dropFirst(), completion: completion) }
            else { completion(nil) }
        }
    }

    // MARK: - Discovery

    private static func detectServiceServers() -> [String] {
        var ordered: [String] = []
        let primary = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key in
            (SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any])?["PrimaryService"] as? String
        }
        var serviceIDs = primary
        if let keys = SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/[^/]+/DNS" as CFString) as? [String] {
            for key in keys.sorted() {
                let id = key.split(separator: "/")[3]
                if !serviceIDs.contains(String(id)) { serviceIDs.append(String(id)) }
            }
        }
        for id in serviceIDs {
            for server in serverAddresses(atKey: "State:/Network/Service/\(id)/DNS") where isUsable(server) && !ordered.contains(server) {
                ordered.append(server)
            }
        }
        // Prefer IPv4 servers: they are reachable on more networks.
        return ordered.filter { !$0.contains(":") } + ordered.filter { $0.contains(":") }
    }

    private static func serverAddresses(atKey key: String) -> [String] {
        (SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
    }

    static func isUsable(_ server: String) -> Bool {
        if server.contains("%") { return false } // scoped link-local addresses
        if let v4 = IPv4Address(server) { return !v4.isLoopback && v4 != .any }
        if let v6 = IPv6Address(server) { return !v6.isLoopback && v6 != .any && !v6.isLinkLocal }
        return false
    }
}

/// A single request/response with one upstream server over UDP or TCP.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let query: [UInt8]
    private let tcp: Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var completion: (([UInt8]?) -> Void)?

    init(server: String, query: [UInt8], tcp: Bool, queue: DispatchQueue) {
        self.query = query
        self.tcp = tcp
        self.queue = queue
        connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: tcp ? .tcp : .udp)
    }

    func run(_ completion: @escaping ([UInt8]?) -> Void) {
        self.completion = completion
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        // The deadline closure also keeps this exchange alive until it settles.
        queue.asyncAfter(deadline: .now() + 2) { self.finish(nil) }
        if tcp {
            let framed = [UInt8(query.count >> 8 & 0xFF), UInt8(query.count & 0xFF)] + query
            connection.send(content: Data(framed), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(nil) }
            })
            connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
                guard let self, let data, data.count == 2, error == nil else { self?.finish(nil); return }
                let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                    guard let body, body.count == length, error == nil else { self?.finish(nil); return }
                    self?.finish(Array(body))
                }
            }
        } else {
            connection.send(content: Data(query), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(nil) }
            })
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let data, error == nil, data.count >= DNSPacket.headerLength else { self?.finish(nil); return }
                self?.finish(Array(data))
            }
        }
    }

    private func finish(_ response: [UInt8]?) {
        let callback = lock.withLock { () -> (([UInt8]?) -> Void)? in
            defer { completion = nil }
            return completion
        }
        guard let callback else { return }
        connection.cancel()
        callback(response)
    }
}
