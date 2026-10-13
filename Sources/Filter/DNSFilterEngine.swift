import Foundation

/// Decides what happens to one DNS query: answer it locally (blocked, canary,
/// or self-test) or forward it unchanged to an upstream resolver.
public struct DNSFilterEngine: Sendable {
    public enum Outcome: Equatable {
        case respond([UInt8], blocked: BlockedLookup?)
        case forward(DNSQuestion?)
    }

    static let canaryDomains: Set<String> = ["use-application-dns.net"] // Firefox: disable DNS-over-HTTPS

    public var matcher: RuleMatcher
    public var blockCanaries: Bool

    public init(matcher: RuleMatcher, blockCanaries: Bool) {
        self.matcher = matcher
        self.blockCanaries = blockCanaries
    }

    public func process(_ query: [UInt8], now: Date = Date()) -> Outcome {
        guard let question = DNSPacket.parseQuestion(query) else { return .forward(nil) }
        if question.name.hasSuffix("." + TunnelConstants.selfTestSuffix) {
            return .respond(DNSPacket.addressResponse(to: query, question: question, ipv4: TunnelConstants.selfTestAddress), blocked: nil)
        }
        if blockCanaries && Self.canaryDomains.contains(question.name) {
            return .respond(DNSPacket.blockedResponse(to: query, question: question), blocked: nil)
        }
        if case .blocked(let rule) = matcher.evaluate(question.name) {
            let lookup = BlockedLookup(domain: question.name, ruleID: rule.id, rulePattern: rule.pattern, date: now)
            return .respond(DNSPacket.blockedResponse(to: query, question: question), blocked: lookup)
        }
        return .forward(question)
    }
}

/// An IPv4 UDP datagram read from the tunnel's packet flow.
public struct UDPDatagram: Equatable, Sendable {
    public var source: [UInt8]
    public var destination: [UInt8]
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: [UInt8]

    public init(source: [UInt8], destination: [UInt8], sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.source = source
        self.destination = destination
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    public init?(ipv4 packet: [UInt8]) {
        guard packet.count >= 28, packet[0] >> 4 == 4, packet[9] == 17 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let totalLength = min(Int(packet[2]) << 8 | Int(packet[3]), packet.count)
        // Fragments (MF set or nonzero offset) never carry a whole query.
        let fragmented = packet[6] & 0x20 != 0 || (Int(packet[6] & 0x1F) << 8 | Int(packet[7])) != 0
        guard headerLength >= 20, totalLength >= headerLength + 8, !fragmented else { return nil }
        source = Array(packet[12..<16])
        destination = Array(packet[16..<20])
        sourcePort = UInt16(packet[headerLength]) << 8 | UInt16(packet[headerLength + 1])
        destinationPort = UInt16(packet[headerLength + 2]) << 8 | UInt16(packet[headerLength + 3])
        payload = Array(packet[(headerLength + 8)..<totalLength])
    }

    /// The IPv4 packet that answers this datagram with `payload`, endpoints swapped.
    /// The UDP checksum is optional over IPv4 and left zero.
    public func reply(payload: [UInt8]) -> [UInt8] {
        let total = 28 + payload.count
        var header: [UInt8] = [0x45, 0, UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF), 0, 0, 0x40, 0, 64, 17, 0, 0]
        header += destination + source
        let checksum = Self.checksum(header)
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)
        let length = 8 + payload.count
        let udp: [UInt8] = [UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF), UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
                            UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), 0, 0]
        return header + udp + payload
    }

    static func checksum(_ header: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: header.count, by: 2) { sum += UInt32(header[index]) << 8 | UInt32(header[index + 1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
