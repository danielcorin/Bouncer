import CryptoKit
import Darwin
import Foundation

/// Talks to the root helper over its user-only Unix socket and installs it on demand.
@MainActor
public final class HelperFilterBackend: FilterBackend {
    public var onBlocked: ((BlockedLookup) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    private var connection: HelperConnection?
    private let bundledHelperURL: URL

    public init(bundledHelperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(HelperConstants.bundledHelperName)")) {
        self.bundledHelperURL = bundledHelperURL
    }

    public var isConnected: Bool { connection?.isOpen == true }

    public var installation: HelperInstallation {
        let fileManager = FileManager.default
        let installed = fileManager.fileExists(atPath: HelperConstants.installedBinaryPath)
            && fileManager.fileExists(atPath: HelperConstants.launchDaemonPath)
        guard installed else { return .init(installed: false, upToDate: false) }
        let upToDate = Self.digest(HelperConstants.installedBinaryPath) == Self.digest(bundledHelperURL.path)
        return .init(installed: true, upToDate: upToDate)
    }

    private static func digest(_ path: String) -> SHA256Digest? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data)
    }

    // MARK: - Installation

    public func install() async throws {
        guard FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) else {
            throw FilterBackendError("unavailable", "The bundled helper is missing. Reinstall Bouncer.")
        }
        connection?.close()
        connection = nil
        let plist: [String: Any] = [
            "Label": HelperConstants.label,
            "ProgramArguments": [HelperConstants.installedBinaryPath, "--owner-uid", String(getuid())],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": "/var/log/\(HelperConstants.label).log",
        ]
        // Embed the plist in the command: root can't read files in the user's
        // protected temporary directories ("Operation not permitted").
        let encodedPlist = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).base64EncodedString()

        let binary = HelperConstants.installedBinaryPath, daemon = HelperConstants.launchDaemonPath
        let script = [
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(Self.quote(bundledHelperURL.path)) \(Self.quote(binary))",
            "/bin/echo \(encodedPlist) | /usr/bin/base64 -D > \(Self.quote(daemon))",
            "/usr/sbin/chown root:wheel \(Self.quote(daemon))",
            "/bin/chmod 644 \(Self.quote(daemon))",
            "/bin/launchctl bootstrap system \(Self.quote(daemon))",
        ].joined(separator: " && ")
        try await Self.runPrivileged(script, prompt: "Bouncer needs to install its DNS helper to block sites system-wide.")
        try await waitForSocket()
    }

    public func uninstall() async throws {
        connection?.close()
        connection = nil
        let script = [
            // bootout sends SIGTERM; the helper restores DNS before exiting.
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null || true",
            "/bin/rm -f \(Self.quote(HelperConstants.installedBinaryPath)) \(Self.quote(HelperConstants.launchDaemonPath)) \(Self.quote(HelperConstants.socketPath))",
            "/bin/rm -rf \(Self.quote(HelperConstants.stateDirectory))",
        ].joined(separator: " ; ")
        try await Self.runPrivileged(script, prompt: "Bouncer needs to remove its DNS helper.")
    }

    private func waitForSocket() async throws {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: HelperConstants.socketPath) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FilterBackendError("helper_unavailable", "The helper was installed but didn't start. See /var/log/\(HelperConstants.label).log.")
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shows the standard administrator prompt via osascript, off the main thread.
    private static func runPrivileged(_ command: String, prompt: String) async throws {
        func appleScriptString(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("-128") { throw FilterBackendError("canceled", "The administrator prompt was canceled.") }
                throw FilterBackendError("helper_install_failed", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    // MARK: - Filtering

    public func activate(rules: [FilterRule], options: FilterOptions) async throws {
        try await send(.init(id: 0, command: .activate, rules: rules, options: options))
    }

    public func update(rules: [FilterRule], options: FilterOptions) async throws {
        try await send(.init(id: 0, command: .update, rules: rules, options: options))
    }

    public func deactivate() async throws {
        guard let connection, connection.isOpen else { return }
        try await send(.init(id: 0, command: .deactivate))
    }

    public func deactivateBeforeExit(timeout: TimeInterval) {
        connection?.sendAndWait(.init(id: 0, command: .deactivate), timeout: timeout)
        connection?.close()
        connection = nil
    }

    @discardableResult
    private func send(_ request: HelperRequest) async throws -> HelperFilterStatus {
        let connection = try openConnection()
        let message = try await connection.send(request)
        if let error = message.error { throw FilterBackendError("helper_failed", error) }
        return message.status ?? HelperFilterStatus(active: false)
    }

    private func openConnection() throws -> HelperConnection {
        if let connection, connection.isOpen { return connection }
        let connection = try HelperConnection(path: HelperConstants.socketPath)
        connection.onMessage = { [weak self] message in
            Task { @MainActor in
                if let lookup = message.blocked { self?.onBlocked?(lookup) }
            }
        }
        connection.onClose = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.connection = nil
                self.onDisconnect?("Lost the connection to Bouncer's DNS helper.")
            }
        }
        connection.start()
        self.connection = connection
        return connection
    }
}

/// Line-delimited JSON client. All socket I/O happens on a private queue.
final class HelperConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "llc.wvlen.Bouncer.helper-client")
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()
    private var nextID = 1
    private var pending: [Int: (Result<HelperMessage, Error>) -> Void] = [:]
    private var open = true
    private let lock = NSLock()
    var onMessage: ((HelperMessage) -> Void)?
    var onClose: (() -> Void)?

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FilterBackendError("helper_unavailable", "Couldn't create a socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw FilterBackendError("helper_unavailable", "Couldn't reach Bouncer's DNS helper (\(reason)). Reinstall it from Settings.")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        descriptor = fd
    }

    var isOpen: Bool { lock.withLock { open } }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    func send(_ request: HelperRequest, timeout: TimeInterval = 30) async throws -> HelperMessage {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(request, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    func sendAndWait(_ request: HelperRequest, timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        enqueue(request, timeout: timeout) { _ in done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func enqueue(_ request: HelperRequest, timeout: TimeInterval, completion: @escaping (Result<HelperMessage, Error>) -> Void) {
        queue.async { [self] in
            guard isOpen else { completion(.failure(FilterBackendError("helper_unavailable", "The helper connection is closed."))); return }
            var request = request
            request.id = nextID
            nextID += 1
            pending[request.id] = completion
            guard let data = try? HelperCoding.encode(request), writeAll(data) else {
                pending[request.id] = nil
                completion(.failure(FilterBackendError("helper_unavailable", "Couldn't send to the helper.")))
                closeOnQueue()
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let callback = self?.pending.removeValue(forKey: request.id) else { return }
                callback(.failure(FilterBackendError("timeout", "The helper didn't respond.")))
            }
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0, let lines = buffer.append(Data(chunk[0..<count])) else { closeOnQueue(); return }
        for line in lines {
            guard let message = try? HelperCoding.decode(HelperMessage.self, from: line) else { continue }
            if let id = message.id, let callback = pending.removeValue(forKey: id) {
                callback(.success(message))
            } else {
                onMessage?(message)
            }
        }
    }

    func close() { queue.async { self.closeOnQueue(notify: false) } }

    private func closeOnQueue(notify: Bool = true) {
        let wasOpen = lock.withLock { () -> Bool in
            defer { open = false }
            return open
        }
        guard wasOpen else { return }
        source?.cancel()
        source = nil
        let failed = pending
        pending.removeAll()
        failed.values.forEach { $0(.failure(FilterBackendError("helper_unavailable", "The helper connection closed."))) }
        if notify { onClose?() }
    }
}
