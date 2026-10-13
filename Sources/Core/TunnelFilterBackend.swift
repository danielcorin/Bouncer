import Darwin
import Foundation
import Network
import NetworkExtension
import SystemConfiguration

/// Runs blocking through Bouncer's packet tunnel extension.
@MainActor
public final class TunnelFilterBackend: FilterBackend {
    public var onBlocked: ((BlockedLookup) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public private(set) var installation = TunnelInstallation(installed: false)

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var heartbeat: Timer?
    private var lastSequence = 0
    private var configuration: TunnelConfiguration?
    private var lastSentConfiguration: TunnelConfiguration?
    private var lastUpstreamCheck = Date.distantPast
    /// True while the app wants the tunnel up; distinguishes our own stops.
    private var expectingConnection = false
    private var napActivity: NSObjectProtocol?

    public init() {}

    public var isConnected: Bool { manager?.connection.status == .connected }

    public func refresh() async {
        manager = try? await Self.loadManager()
        installation = TunnelInstallation(installed: manager != nil)
        observeStatus()
    }

    // MARK: - Configuration

    private static func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelConstants.providerBundleIdentifier
        }
    }

    public func install() async throws {
        let manager = try await Self.loadManager() ?? NETunnelProviderManager()
        try await save(manager, configuration: configuration)
        self.manager = manager
        installation = TunnelInstallation(installed: true)
        observeStatus()
    }

    private func save(_ manager: NETunnelProviderManager, configuration: TunnelConfiguration?) async throws {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.providerBundleIdentifier
        proto.serverAddress = "DNS filter on this Mac"
        if let configuration {
            proto.providerConfiguration = [TunnelConfiguration.providerConfigurationKey: try TunnelCoding.encode(configuration)]
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = TunnelConstants.configurationName
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                throw FilterBackendError("permission_denied", "macOS didn't allow Bouncer's DNS tunnel. Turn blocking on again and choose Allow.")
            }
            throw FilterBackendError("tunnel_failed", "Couldn't save the tunnel configuration: \(error.localizedDescription)")
        }
    }

    public func uninstall() async throws {
        try await deactivate()
        guard let manager = try await Self.loadManager() else { return }
        do { try await manager.removeFromPreferences() }
        catch { throw FilterBackendError("tunnel_failed", "Couldn't remove the tunnel configuration: \(error.localizedDescription)") }
        self.manager = nil
        installation = TunnelInstallation(installed: false)
    }

    // MARK: - Lifecycle

    public func activate(rules: [FilterRule], options: FilterOptions) async throws {
        let configuration = TunnelConfiguration(rules: rules, options: options, upstream: UpstreamDetector.servers())
        self.configuration = configuration
        guard let manager = try await Self.loadManager() else {
            throw FilterBackendError("tunnel_unavailable", "Bouncer's DNS tunnel isn't installed.")
        }
        // Saving refreshes the start-time configuration (and re-enables the profile
        // if another VPN took over).
        try await save(manager, configuration: configuration)
        self.manager = manager
        observeStatus()
        expectingConnection = true
        if manager.connection.status != .connected {
            do { try manager.connection.startVPNTunnel() }
            catch {
                expectingConnection = false
                throw FilterBackendError("tunnel_failed", "Couldn't start the DNS tunnel: \(error.localizedDescription)")
            }
            guard await waitForStatus(.connected, timeout: 10) else {
                expectingConnection = false
                manager.connection.stopVPNTunnel()
                throw FilterBackendError("tunnel_failed", "The DNS tunnel didn't start. Another VPN may be active.")
            }
        }
        lastSentConfiguration = nil
        lastSequence = 0
        startHeartbeat()
        try await sendMessage(TunnelRequest(configuration: configuration, eventsAfter: Int.max))
    }

    public func update(rules: [FilterRule], options: FilterOptions) async throws {
        configuration = TunnelConfiguration(rules: rules, options: options, upstream: configuration?.upstream ?? UpstreamDetector.servers())
        guard isConnected else { return }
        try await sendMessage(TunnelRequest(configuration: configuration, eventsAfter: lastSequence))
    }

    public func deactivate() async throws {
        expectingConnection = false
        stopHeartbeat()
        guard let manager, manager.connection.status != .disconnected, manager.connection.status != .invalid else { return }
        manager.connection.stopVPNTunnel()
        _ = await waitForStatus(.disconnected, timeout: 5)
    }

    public func deactivateBeforeExit(timeout: TimeInterval) {
        expectingConnection = false
        stopHeartbeat()
        guard let manager, manager.connection.status != .disconnected else { return }
        manager.connection.stopVPNTunnel()
        let deadline = Date().addingTimeInterval(timeout)
        while manager.connection.status != .disconnected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func waitForStatus(_ target: NEVPNStatus, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if manager?.connection.status == target { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return manager?.connection.status == target
    }

    private func observeStatus() {
        guard statusObserver == nil else { return }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusChanged() }
        }
    }

    private func statusChanged() {
        guard expectingConnection, let status = manager?.connection.status, status == .disconnected || status == .invalid else { return }
        expectingConnection = false
        stopHeartbeat()
        onDisconnect?("Blocking stopped because the DNS tunnel was disconnected (another VPN may have started, or it was turned off in System Settings).")
    }

    // MARK: - Heartbeat and events

    private func startHeartbeat() {
        stopHeartbeat()
        // Keep App Nap from stretching heartbeats past the tunnel's watchdog.
        napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                            reason: "Bouncer is filtering DNS")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let napActivity { ProcessInfo.processInfo.endActivity(napActivity) }
        napActivity = nil
    }

    private func beat() {
        var request = TunnelRequest(eventsAfter: lastSequence)
        // Follow network changes: re-detect the real resolvers every few seconds.
        if Date().timeIntervalSince(lastUpstreamCheck) > 5, var configuration {
            lastUpstreamCheck = Date()
            let upstream = UpstreamDetector.servers()
            if upstream != configuration.upstream {
                configuration.upstream = upstream
                self.configuration = configuration
                request.configuration = configuration
            }
        }
        Task { try? await sendMessage(request) }
    }

    private func sendMessage(_ request: TunnelRequest) async throws {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let data = try TunnelCoding.encode(request)
        let response: Data? = try await withCheckedThrowingContinuation { continuation in
            do { try session.sendProviderMessage(data) { continuation.resume(returning: $0) } }
            catch { continuation.resume(throwing: FilterBackendError("tunnel_failed", "Couldn't reach the DNS tunnel: \(error.localizedDescription)")) }
        }
        guard let response, let reply = try? TunnelCoding.decode(TunnelReply.self, from: response) else { return }
        if request.eventsAfter == Int.max {
            lastSequence = reply.lastSequence // start fresh: don't replay old events
            return
        }
        for event in reply.events where event.sequence > lastSequence { onBlocked?(event.lookup) }
        lastSequence = max(lastSequence, reply.lastSequence)
    }

    // MARK: - Verification

    public func verifySystemResolution() async -> Bool {
        await SystemResolutionProbe.run()
    }
}

/// Resolves a one-off self-test name with getaddrinfo, the path every app uses.
enum SystemResolutionProbe {
    static func run() async -> Bool {
        let name = UUID().uuidString.prefix(8).lowercased() + "." + TunnelConstants.selfTestSuffix
        let expected = TunnelConstants.selfTestAddress.map(String.init).joined(separator: ".")
        return await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                if let address = entry.pointee.ai_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if String(cString: inet_ntoa(ipv4)) == expected { return true }
                }
                cursor = entry.pointee.ai_next
            }
            return false
        }.value
    }
}

/// The network's real resolvers. Each physical service's State key keeps its
/// DHCP/RA servers even while the tunnel is the system resolver.
public enum UpstreamDetector {
    public static let fallback = ["1.1.1.1", "8.8.8.8"]

    public static func servers() -> [String] {
        var serviceIDs = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key in
            (SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any])?["PrimaryService"] as? String
        }
        if let keys = SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/[^/]+/DNS" as CFString) as? [String] {
            for key in keys.sorted() {
                let id = String(key.split(separator: "/")[3])
                if !serviceIDs.contains(id) { serviceIDs.append(id) }
            }
        }
        var ordered: [String] = []
        for id in serviceIDs {
            let addresses = (SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(id)/DNS" as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
            for server in addresses where isUsable(server) && !ordered.contains(server) { ordered.append(server) }
        }
        let preferred = ordered.filter { !$0.contains(":") } + ordered.filter { $0.contains(":") }
        return preferred.isEmpty ? fallback : preferred
    }

    public static func isUsable(_ server: String) -> Bool {
        if server == TunnelConstants.dnsServer || server.contains("%") { return false }
        if let v4 = IPv4Address(server) { return !v4.isLoopback && v4 != .any }
        if let v6 = IPv6Address(server) { return !v6.isLoopback && v6 != .any && !v6.isLinkLocal }
        return false
    }
}
