import Foundation
import Network
import NetworkExtension
import os

/// A packet tunnel that claims only DNS. The system resolver is pointed at a
/// virtual server (198.18.0.1) inside the tunnel; every other packet keeps using
/// the normal network. Queries are filtered with Bouncer's real `RuleMatcher`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let dnsAddress: [UInt8] = [198, 18, 0, 1]
    private let log = Logger(subsystem: "llc.wvlen.Bouncer.TunnelPOC", category: "tunnel")
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.TunnelPOC.dns")
    private let lock = NSLock()
    private var matcher = RuleMatcher(rules: [
        FilterRule(pattern: "ycombinator.com", kind: .domain),
        FilterRule(pattern: "tiktok", kind: .regex),
    ])
    private var upstream = ["192.168.1.1", "1.1.1.1"]
    private var mode = "dns-only"
    private var stats = Stats()

    struct Stats: Codable {
        var mode = ""
        var queries = 0
        var blocked = 0
        var selfTests = 0
        var forwarded = 0
        var failed = 0
        var nonDNSPackets = 0
        var recent: [String] = []
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        mode = configuration["mode"] as? String ?? "dns-only"
        if let servers = configuration["upstream"] as? [String], !servers.isEmpty { upstream = servers }
        stats.mode = mode

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.255.255"])
        var included = [NEIPv4Route(destinationAddress: "198.18.0.1", subnetMask: "255.255.255.255")]
        if mode == "nominal-default" {
            // Claim the default route, then exclude both halves of the address
            // space so real traffic still bypasses the tunnel.
            included.append(.default())
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "128.0.0.0"),
                                   NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0")]
            let ipv6 = NEIPv6Settings(addresses: ["fd00:b0:b0::2"], networkPrefixLengths: [128])
            ipv6.includedRoutes = [.default()]
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: "::", networkPrefixLength: 1),
                                   NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1)]
            settings.ipv6Settings = ipv6
        }
        ipv4.includedRoutes = included
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: ["198.18.0.1"])
        dns.matchDomains = [""] // the default resolver for every domain
        settings.dnsSettings = dns
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error { self?.log.error("settings failed: \(error.localizedDescription, privacy: .public)") }
            else { self?.log.notice("tunnel up in \(self?.mode ?? "", privacy: .public) mode") }
            completionHandler(error)
            if error == nil { self?.readPackets() }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.notice("tunnel stopping, reason \(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let snapshot = lock.withLock { stats }
        completionHandler?(try? JSONEncoder().encode(snapshot))
    }

    // MARK: - Packets

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for packet in packets { self.handle([UInt8](packet)) }
            self.readPackets()
        }
    }

    private func handle(_ packet: [UInt8]) {
        guard let datagram = UDPDatagram(ipv4: packet), datagram.destination == Self.dnsAddress, datagram.destinationPort == 53 else {
            lock.withLock { stats.nonDNSPackets += 1 }
            return
        }
        let query = datagram.payload
        guard let question = DNSPacket.parseQuestion(query) else { forward(datagram); return }
        lock.withLock {
            stats.queries += 1
            stats.recent = Array(([question.name] + stats.recent).prefix(30))
        }
        if question.name.hasSuffix("." + HelperConstants.selfTestSuffix) {
            lock.withLock { stats.selfTests += 1 }
            reply(to: datagram, DNSPacket.addressResponse(to: query, question: question, ipv4: HelperConstants.selfTestAddress))
        } else if matcher.evaluate(question.name).isBlocked {
            lock.withLock { stats.blocked += 1 }
            log.notice("blocked \(question.name, privacy: .public)")
            reply(to: datagram, DNSPacket.blockedResponse(to: query, question: question))
        } else {
            forward(datagram, question: question)
        }
    }

    private func forward(_ datagram: UDPDatagram, question: DNSQuestion? = nil, servers: ArraySlice<String>? = nil) {
        let servers = servers ?? upstream[...]
        guard let server = servers.first else {
            lock.withLock { stats.failed += 1 }
            if let question { reply(to: datagram, DNSPacket.failureResponse(to: datagram.payload, question: question)) }
            return
        }
        // Sockets opened by the provider itself never route into its own tunnel.
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let done = OSAllocatedUnfairLock(initialState: false)
        let finish: ([UInt8]?) -> Void = { [weak self] response in
            guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
            connection.cancel()
            guard let self else { return }
            if let response {
                self.lock.withLock { self.stats.forwarded += 1 }
                self.reply(to: datagram, response)
            } else {
                self.forward(datagram, question: question, servers: servers.dropFirst())
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(datagram.payload), completion: .contentProcessed { error in if error != nil { finish(nil) } })
        connection.receiveMessage { data, _, _, error in finish(error == nil ? data.map { [UInt8]($0) } : nil) }
        queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
    }

    private func reply(to datagram: UDPDatagram, _ payload: [UInt8]) {
        let packet = datagram.reply(payload: payload)
        packetFlow.writePackets([Data(packet)], withProtocols: [NSNumber(value: AF_INET)])
    }
}

/// An IPv4 UDP datagram read from the tunnel.
struct UDPDatagram {
    var source: [UInt8]
    var destination: [UInt8]
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]

    init?(ipv4 packet: [UInt8]) {
        guard packet.count >= 28, packet[0] >> 4 == 4, packet[9] == 17 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let totalLength = min(Int(packet[2]) << 8 | Int(packet[3]), packet.count)
        guard headerLength >= 20, totalLength >= headerLength + 8 else { return nil }
        source = Array(packet[12..<16])
        destination = Array(packet[16..<20])
        sourcePort = UInt16(packet[headerLength]) << 8 | UInt16(packet[headerLength + 1])
        destinationPort = UInt16(packet[headerLength + 2]) << 8 | UInt16(packet[headerLength + 3])
        payload = Array(packet[(headerLength + 8)..<totalLength])
    }

    /// Swaps endpoints. The UDP checksum is optional over IPv4 and left zero.
    func reply(payload: [UInt8]) -> [UInt8] {
        let total = 20 + 8 + payload.count
        var header: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0, 0x40, 0, 64, 17, 0, 0]
        header += destination + source
        var sum: UInt32 = 0
        for index in stride(from: 0, to: 20, by: 2) { sum += UInt32(header[index]) << 8 | UInt32(header[index + 1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)
        let length = 8 + payload.count
        let udp: [UInt8] = [UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF), UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
                            UInt8(length >> 8), UInt8(length & 0xFF), 0, 0]
        return header + udp + payload
    }
}
