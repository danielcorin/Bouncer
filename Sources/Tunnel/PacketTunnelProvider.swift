import Foundation
import Network
import NetworkExtension
import os

/// Bouncer's DNS tunnel. It claims a single route — the virtual resolver
/// 198.18.0.1 — and becomes the system's DNS server for every domain, which takes
/// precedence over iCloud Private Relay's encrypted DNS. All other traffic keeps
/// using the normal network. If the app stops sending heartbeats, the tunnel
/// shuts itself down so blocks never outlive Bouncer.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "llc.wvlen.Bouncer.Tunnel", category: "tunnel")
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.Tunnel.dns")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var watchdog: DispatchSourceTimer?

    private struct State {
        var engine = DNSFilterEngine(matcher: .empty, blockCanaries: true)
        var upstream: [String] = ["1.1.1.1", "8.8.8.8"]
        var events: [TunnelReply.Event] = []
        var sequence = 0
        var stats = TunnelStats()
        var lastContact = DispatchTime.now()
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let data = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[TunnelConfiguration.providerConfigurationKey] as? Data,
           let configuration = try? TunnelCoding.decode(TunnelConfiguration.self, from: data) {
            apply(configuration)
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [TunnelConstants.tunnelAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: TunnelConstants.dnsServer, subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [TunnelConstants.dnsServer])
        dns.matchDomains = [""] // the resolver for every domain
        settings.dnsSettings = dns
        // Only DNS crosses this interface; a large MTU keeps big answers in one packet.
        settings.mtu = 9000

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("Tunnel settings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.log.notice("Tunnel up")
                self.startWatchdog()
                self.readPackets()
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.notice("Tunnel stopping (reason \(reason.rawValue))")
        watchdog?.cancel()
        completionHandler()
    }

    /// Every app message is a heartbeat; it may carry a new configuration and
    /// always drains blocked lookups the app hasn't seen yet.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = try? TunnelCoding.decode(TunnelRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        if let configuration = request.configuration { apply(configuration) }
        let reply = state.withLock { state -> TunnelReply in
            state.lastContact = .now()
            return TunnelReply(events: state.events.filter { $0.sequence > request.eventsAfter }, lastSequence: state.sequence, stats: state.stats)
        }
        completionHandler?(try? TunnelCoding.encode(reply))
    }

    private func apply(_ configuration: TunnelConfiguration) {
        state.withLock { state in
            state.engine = DNSFilterEngine(matcher: RuleMatcher(rules: configuration.rules), blockCanaries: configuration.options.blockBypassCanaries)
            let explicit = configuration.options.upstreamServers
            let servers = explicit.isEmpty ? configuration.upstream : explicit
            if !servers.isEmpty { state.upstream = servers }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // DispatchTime pauses during sleep, so a sleeping Mac doesn't trip this.
            let silence = Double(DispatchTime.now().uptimeNanoseconds - self.state.withLock { $0.lastContact.uptimeNanoseconds }) / 1e9
            if silence > TunnelConstants.heartbeatTimeout {
                self.log.notice("No contact from Bouncer for \(Int(silence))s; stopping so blocks don't outlive the app.")
                self.watchdog?.cancel()
                self.cancelTunnelWithError(nil)
            }
        }
        timer.resume()
        watchdog = timer
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
        guard let datagram = UDPDatagram(ipv4: packet), datagram.destination == TunnelConstants.dnsServerBytes,
              datagram.destinationPort == 53 else { return }
        let (outcome, upstream) = state.withLock { state -> (DNSFilterEngine.Outcome, [String]) in
            state.stats.queries += 1
            return (state.engine.process(datagram.payload), state.upstream)
        }
        switch outcome {
        case .respond(let response, let blocked):
            if let blocked {
                state.withLock { state in
                    state.stats.blocked += 1
                    state.sequence += 1
                    state.events.append(.init(sequence: state.sequence, lookup: blocked))
                    if state.events.count > TunnelConstants.maxEvents { state.events.removeFirst(state.events.count - TunnelConstants.maxEvents) }
                }
            }
            reply(to: datagram, response)
        case .forward(let question):
            forward(datagram.payload, servers: upstream.prefix(3)) { [weak self] response in
                guard let self else { return }
                if let response {
                    self.state.withLock { $0.stats.forwarded += 1 }
                    self.reply(to: datagram, response)
                } else {
                    self.state.withLock { $0.stats.failed += 1 }
                    if let question { self.reply(to: datagram, DNSPacket.failureResponse(to: datagram.payload, question: question)) }
                }
            }
        }
    }

    private func reply(to datagram: UDPDatagram, _ payload: [UInt8]) {
        packetFlow.writePackets([Data(datagram.reply(payload: payload))], withProtocols: [NSNumber(value: AF_INET)])
    }

    /// Tries each upstream in turn. A truncated UDP answer is retried over TCP and
    /// returned whole, since the tunnel has no TCP path back to the client.
    private func forward(_ query: [UInt8], servers: ArraySlice<String>, completion: @escaping ([UInt8]?) -> Void) {
        guard let server = servers.first else { completion(nil); return }
        UpstreamExchange.run(query, server: server, tcp: false, queue: queue) { [weak self] response in
            guard let self else { return }
            if let response, DNSPacket.isTruncated(response) {
                UpstreamExchange.run(query, server: server, tcp: true, queue: self.queue) { full in completion(full ?? response) }
            } else if let response {
                completion(response)
            } else {
                self.forward(query, servers: servers.dropFirst(), completion: completion)
            }
        }
    }
}

/// One request/response with an upstream resolver. Sockets the provider opens
/// itself never route into its own tunnel.
enum UpstreamExchange {
    static func run(_ query: [UInt8], server: String, tcp: Bool, queue: DispatchQueue, completion: @escaping ([UInt8]?) -> Void) {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: tcp ? .tcp : .udp)
        let done = OSAllocatedUnfairLock(initialState: false)
        let finish: ([UInt8]?) -> Void = { response in
            guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
            connection.cancel()
            completion(response)
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { finish(nil) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
        if tcp {
            let framed = [UInt8(query.count >> 8 & 0xFF), UInt8(query.count & 0xFF)] + query
            connection.send(content: Data(framed), completion: .contentProcessed { if $0 != nil { finish(nil) } })
            connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                guard let data, data.count == 2, error == nil else { finish(nil); return }
                let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    finish(error == nil && body?.count == length ? body.map { [UInt8]($0) } : nil)
                }
            }
        } else {
            connection.send(content: Data(query), completion: .contentProcessed { if $0 != nil { finish(nil) } })
            connection.receiveMessage { data, _, _, error in
                finish(error == nil && (data?.count ?? 0) >= DNSPacket.headerLength ? data.map { [UInt8]($0) } : nil)
            }
        }
    }
}
