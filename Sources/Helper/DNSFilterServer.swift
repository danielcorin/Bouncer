import Darwin
import Foundation

/// A loopback DNS resolver: blocked names get NXDOMAIN, everything else is relayed
/// unchanged to the real upstream servers. UDP is required; TCP (used for
/// truncated answers) is best-effort because other tools sometimes own port 53/tcp.
final class DNSFilterServer: @unchecked Sendable {
    static let canaryDomains: Set<String> = [
        "use-application-dns.net", // Firefox: disable DNS-over-HTTPS on this network
        "mask.icloud.com", "mask-h2.icloud.com", // iCloud Private Relay: unavailable on this network
    ]

    private let port: UInt16
    private let upstream: UpstreamResolver
    private let onBlocked: (BlockedLookup) -> Void
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.helper.dns", attributes: .concurrent)
    private let lock = NSLock()
    private var _matcher = RuleMatcher.empty
    private var _blockCanaries = true
    private var _queries = 0
    private var _blocked = 0
    private var stopped = false
    private var udpDescriptor: Int32 = -1
    private var sources: [DispatchSourceRead] = []
    private var tcpConnections: [Int32: TCPConnection] = [:]

    init(port: UInt16, upstream: UpstreamResolver, onBlocked: @escaping (BlockedLookup) -> Void) {
        self.port = port
        self.upstream = upstream
        self.onBlocked = onBlocked
    }

    var matcher: RuleMatcher { lock.withLock { _matcher } }
    var blockCanaries: Bool { lock.withLock { _blockCanaries } }
    var queryCount: Int { lock.withLock { _queries } }
    var blockedCount: Int { lock.withLock { _blocked } }

    func configure(matcher: RuleMatcher, blockCanaries: Bool) {
        lock.withLock {
            _matcher = matcher
            _blockCanaries = blockCanaries
        }
    }

    func start() throws {
        let udp = try Self.bindLoopback(type: SOCK_DGRAM, port: port)
        udpDescriptor = udp
        let udpSource = DispatchSource.makeReadSource(fileDescriptor: udp, queue: queue)
        udpSource.setEventHandler { [weak self] in self?.readDatagrams() }
        udpSource.setCancelHandler { Darwin.close(udp) }
        udpSource.resume()
        sources.append(udpSource)

        do {
            let tcp = try Self.bindLoopback(type: SOCK_STREAM, port: port)
            guard listen(tcp, 32) == 0 else { Darwin.close(tcp); throw POSIXError.current("listen tcp") }
            let tcpSource = DispatchSource.makeReadSource(fileDescriptor: tcp, queue: queue)
            tcpSource.setEventHandler { [weak self] in self?.acceptTCP(tcp) }
            tcpSource.setCancelHandler { Darwin.close(tcp) }
            tcpSource.resume()
            sources.append(tcpSource)
        } catch {
            log("DNS over TCP unavailable (\(error.localizedDescription)); continuing with UDP only.")
        }
        log("DNS filter listening on 127.0.0.1:\(port)")
    }

    func stop() {
        lock.withLock { stopped = true }
        sources.forEach { $0.cancel() }
        sources.removeAll()
        let connections = lock.withLock { () -> [TCPConnection] in
            defer { tcpConnections.removeAll() }
            return Array(tcpConnections.values)
        }
        connections.forEach { $0.close() }
    }

    private static func bindLoopback(type: Int32, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw POSIXError.current("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let error = POSIXError.current("bind 127.0.0.1:\(port)/\(type == SOCK_DGRAM ? "udp" : "tcp")")
            Darwin.close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    // MARK: - Decisions

    private enum Verdict { case forward, blocked(FilterRule?) }

    private func verdict(for packet: [UInt8]) -> (Verdict, DNSQuestion?) {
        guard let question = DNSPacket.parseQuestion(packet) else { return (.forward, nil) }
        let (matcher, canaries) = lock.withLock {
            _queries += 1
            return (_matcher, _blockCanaries)
        }
        if canaries && Self.canaryDomains.contains(question.name) { return (.blocked(nil), question) }
        if case .blocked(let rule) = matcher.evaluate(question.name) {
            lock.withLock { _blocked += 1 }
            onBlocked(BlockedLookup(domain: question.name, ruleID: rule.id, rulePattern: rule.pattern))
            return (.blocked(rule), question)
        }
        return (.forward, question)
    }

    /// Produces exactly one reply for every well-formed query.
    private func resolve(_ packet: [UInt8], tcp: Bool, reply: @escaping ([UInt8]) -> Void) {
        let (verdict, question) = verdict(for: packet)
        switch verdict {
        case .blocked:
            reply(DNSPacket.blockedResponse(to: packet, question: question!))
        case .forward:
            upstream.forward(packet, tcp: tcp) { response in
                if let response { reply(response) }
                else if let question { reply(DNSPacket.failureResponse(to: packet, question: question)) }
            }
        }
    }

    // MARK: - UDP

    private func readDatagrams() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpDescriptor, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0 else { return }
            let packet = Array(buffer[0..<count])
            let descriptor = udpDescriptor
            let peer = from, peerLength = fromLength
            resolve(packet, tcp: false) { [weak self] response in
                // The descriptor closes on stop; never write to a recycled fd number.
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                var peer = peer
                _ = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, response, response.count, 0, $0, peerLength) }
                }
            }
        }
    }

    // MARK: - TCP

    private func acceptTCP(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let connection = TCPConnection(descriptor: client, queue: queue) { [weak self] message, respond in
                self?.resolve(message, tcp: true, reply: respond)
            } onClose: { [weak self] in
                _ = self?.lock.withLock { self?.tcpConnections.removeValue(forKey: client) }
            }
            lock.withLock { tcpConnections[client] = connection }
            connection.resume()
        }
    }
}

/// One DNS-over-TCP client: two-byte big-endian length prefix per message.
final class TCPConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var closed = false
    private let onClose: () -> Void

    init(descriptor: Int32, queue: DispatchQueue,
         onMessage: @escaping ([UInt8], @escaping ([UInt8]) -> Void) -> Void, onClose: @escaping () -> Void) {
        self.descriptor = descriptor
        self.onClose = onClose
        // Accepted sockets inherit O_NONBLOCK; block (bounded by SO_SNDTIMEO) instead.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { self.close(); return }
            let messages: [[UInt8]] = self.lock.withLock {
                self.buffer += chunk[0..<count]
                var messages: [[UInt8]] = []
                while self.buffer.count >= 2 {
                    let length = Int(self.buffer[0]) << 8 | Int(self.buffer[1])
                    guard self.buffer.count >= 2 + length else { break }
                    messages.append(Array(self.buffer[2..<2 + length]))
                    self.buffer.removeFirst(2 + length)
                }
                return messages
            }
            for message in messages {
                onMessage(message) { [weak self] response in self?.write(response) }
            }
        }
    }

    func resume() { source.resume() }

    private func write(_ response: [UInt8]) {
        let framed = [UInt8(response.count >> 8 & 0xFF), UInt8(response.count & 0xFF)] + response
        lock.withLock {
            guard !closed else { return }
            var offset = 0
            while offset < framed.count {
                let written = framed[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard shouldClose else { return }
        source.cancel()
        onClose()
    }
}
