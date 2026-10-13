import Foundation

/// Serializes all filter state on one queue. The session that activated blocking
/// owns it: when that connection closes for any reason, blocking is torn down.
final class Helper: @unchecked Sendable {
    private let arguments: HelperArguments
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.helper.state")
    private let systemDNS: SystemDNSConfigurator
    private let upstream = UpstreamResolver()
    private var control: ControlServer?
    private var sessions: [ObjectIdentifier: ControlSession] = [:]
    private var owner: ObjectIdentifier?
    private var filter: DNSFilterServer?

    init(arguments: HelperArguments, ownerUID: uid_t) {
        self.arguments = arguments
        systemDNS = SystemDNSConfigurator(stateDirectory: URL(fileURLWithPath: arguments.stateDirectory, isDirectory: true))
        control = nil
        let verifier = PeerVerifier(ownerUID: ownerUID, requireSignature: arguments.requireSignedClients)
        control = ControlServer(path: arguments.socketPath, ownerUID: ownerUID, verifier: verifier, queue: queue) { [weak self] session in
            self?.attach(session)
        }
    }

    func start() throws {
        try queue.sync {
            // A leftover backup means the helper or machine stopped mid-block. The
            // app reconnects and re-activates if blocking is still wanted.
            if arguments.manageSystemDNS && systemDNS.hasBackup {
                log("Restoring DNS settings left by a previous session.")
                try? systemDNS.restore()
                systemDNS.flushCaches()
            }
            try control?.start()
        }
        log("Listening for Bouncer on \(arguments.socketPath)")
    }

    func shutdown() {
        queue.sync {
            deactivate()
            control?.stop()
        }
    }

    // MARK: - Sessions (on `queue`)

    private func attach(_ session: ControlSession) {
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onRequest = { [weak self, weak session] request in
            guard let self, let session else { return }
            session.send(self.handle(request, from: key))
        }
        session.onClose = { [weak self] in
            guard let self else { return }
            self.sessions[key] = nil
            if self.owner == key {
                log("Controlling app disconnected; removing blocks.")
                self.deactivate()
            }
        }
        session.resume()
    }

    private func handle(_ request: HelperRequest, from session: ObjectIdentifier) -> HelperMessage {
        do {
            switch request.command {
            case .hello, .status:
                break
            case .activate:
                try activate(rules: request.rules ?? [], options: request.options ?? .init())
                owner = session
            case .update:
                update(rules: request.rules, options: request.options)
            case .deactivate:
                deactivate()
            }
            return HelperMessage(id: request.id, status: status())
        } catch {
            return HelperMessage(id: request.id, error: error.localizedDescription, status: status())
        }
    }

    // MARK: - Filtering (on `queue`)

    private func activate(rules: [FilterRule], options: FilterOptions) throws {
        upstream.configure(explicit: options.upstreamServers)
        if filter == nil {
            let server = DNSFilterServer(port: arguments.dnsPort, upstream: upstream) { [weak self] lookup in
                self?.queue.async { self?.broadcast(lookup) }
            }
            server.configure(matcher: RuleMatcher(rules: rules), blockCanaries: options.blockBypassCanaries)
            try server.start()
            filter = server
        } else {
            filter?.configure(matcher: RuleMatcher(rules: rules), blockCanaries: options.blockBypassCanaries)
        }
        if arguments.manageSystemDNS && !systemDNS.isApplied {
            upstream.captureSystemServers()
            do {
                try systemDNS.apply()
            } catch {
                try? systemDNS.restore()
                filter?.stop()
                filter = nil
                throw error
            }
        }
        systemDNS.flushCaches()
        log("Blocking active with \(rules.filter(\.enabled).count) enabled rules.")
    }

    private func update(rules: [FilterRule]?, options: FilterOptions?) {
        guard let filter else { return }
        if let options { upstream.configure(explicit: options.upstreamServers) }
        filter.configure(matcher: rules.map(RuleMatcher.init) ?? filter.matcher,
                         blockCanaries: options?.blockBypassCanaries ?? filter.blockCanaries)
        // Drop cached answers for names that just became blocked.
        systemDNS.flushCaches()
    }

    private func deactivate() {
        owner = nil
        if arguments.manageSystemDNS && systemDNS.isApplied {
            do { try systemDNS.restore() } catch { log("DNS restore failed: \(error.localizedDescription)") }
        }
        // Restore before stopping the listener so lookups never hit a dead resolver.
        if filter != nil {
            filter?.stop()
            filter = nil
            systemDNS.flushCaches()
            log("Blocking removed.")
        }
    }

    private func status() -> HelperFilterStatus {
        HelperFilterStatus(active: filter != nil, upstream: upstream.currentServers(),
                           queries: filter?.queryCount ?? 0, blocked: filter?.blockedCount ?? 0)
    }

    private func broadcast(_ lookup: BlockedLookup) {
        let message = HelperMessage(blocked: lookup)
        for session in sessions.values { session.send(message) }
    }
}
