import Foundation

/// The question section of a standard DNS query.
public struct DNSQuestion: Equatable, Sendable {
    public var id: UInt16
    public var name: String
    public var type: UInt16
    /// Byte offset just past the first question (header + QNAME + QTYPE + QCLASS).
    public var questionEnd: Int
}

/// Minimal RFC 1035 reading and response synthesis. Allowed queries are relayed
/// byte-for-byte, so only the header and first question are ever interpreted.
public enum DNSPacket {
    public static let headerLength = 12

    public static func parseQuestion(_ bytes: [UInt8]) -> DNSQuestion? {
        guard bytes.count >= headerLength else { return nil }
        let flags = bytes[2]
        let isResponse = flags & 0x80 != 0
        let opcode = (flags >> 3) & 0x0F
        let questionCount = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard !isResponse, opcode == 0, questionCount == 1 else { return nil }

        var offset = headerLength
        var labels: [String] = []
        var length = 0
        while true {
            guard offset < bytes.count else { return nil }
            let count = Int(bytes[offset])
            offset += 1
            if count == 0 { break }
            // Queries don't use name compression; treat anything else as malformed.
            guard count & 0xC0 == 0, offset + count <= bytes.count else { return nil }
            length += count + 1
            guard length <= 255 else { return nil }
            let label = bytes[offset..<offset + count]
            labels.append(String(decoding: label, as: UTF8.self))
            offset += count
        }
        guard offset + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        return DNSQuestion(id: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                           name: labels.joined(separator: ".").lowercased(), type: type, questionEnd: offset + 4)
    }

    /// NXDOMAIN with a zero-TTL SOA so resolvers (including mDNSResponder) don't
    /// cache the negative answer; turning blocking off takes effect immediately.
    public static func blockedResponse(to query: [UInt8], question: DNSQuestion) -> [UInt8] {
        var response = header(for: query, rcode: 3, authorityCount: 1)
        response += query[headerLength..<question.questionEnd]
        response += [0xC0, 0x0C, 0x00, 0x06, 0x00, 0x01] // owner = QNAME pointer, SOA, IN
        response += [0, 0, 0, 0] // TTL 0
        response += [0x00, 0x16] // RDLENGTH 22
        response += [0x00, 0x00] // MNAME ".", RNAME "."
        for value: UInt32 in [1, 3600, 600, 86400, 0] { // serial, refresh, retry, expire, minimum
            response += withUnsafeBytes(of: value.bigEndian, Array.init)
        }
        return response
    }

    /// SERVFAIL when no upstream answered, so clients fail fast instead of timing out.
    public static func failureResponse(to query: [UInt8], question: DNSQuestion) -> [UInt8] {
        header(for: query, rcode: 2, authorityCount: 0) + query[headerLength..<question.questionEnd]
    }

    private static func header(for query: [UInt8], rcode: UInt8, authorityCount: UInt8) -> [UInt8] {
        let flags = 0x80 | (query[2] & 0x79) // QR, echo opcode and RD
        return [query[0], query[1], flags, 0x80 | rcode, 0, 1, 0, 0, 0, authorityCount, 0, 0]
    }

    public static func responseCode(_ bytes: [UInt8]) -> UInt8? {
        bytes.count >= headerLength ? bytes[3] & 0x0F : nil
    }

    public static func isTruncated(_ bytes: [UInt8]) -> Bool {
        bytes.count >= headerLength && bytes[2] & 0x02 != 0
    }
}
