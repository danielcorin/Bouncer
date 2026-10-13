#if os(macOS)
import Foundation
import Darwin

public enum SocketLimits {
    public static let maximumFrameBytes = 1_048_576
    public static let maximumConnections = 16
    public static let requestTimeout: TimeInterval = 90
}

private enum SocketIO {
    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX); a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8CString.count <= MemoryLayout.size(ofValue: a.sun_path) else { throw AutomationFailure("invalid_input", "The local socket path is too long.") }
        path.withCString { _ = strlcpy(&a.sun_path.0, $0, MemoryLayout.size(ofValue: a.sun_path)) }; return a
    }
    static func wait(_ fd: Int32, event: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AutomationFailure("timeout", "The local service deadline expired.") }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let n = poll(&p, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw AutomationFailure("timeout", "The local service deadline expired.") }
            guard p.revents & event != 0 else { throw AutomationFailure("unavailable", "The local service disconnected.") }; return
        }
    }
    static func write(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, event: Int16(POLLOUT), until: deadline)
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { throw AutomationFailure("unavailable", "The local service disconnected.") }; offset += n
            }
        }
    }
    static func read(_ count: Int, fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(fd, event: Int16(POLLIN), until: deadline)
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { throw AutomationFailure("unavailable", "The local service disconnected.") }; offset += n
            }
        }
        return data
    }
    static func readFrame(fd: Int32, deadline: TimeInterval) throws -> Data {
        let header = try read(4, fd: fd, deadline: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= SocketLimits.maximumFrameBytes else { throw AutomationFailure("payload_too_large", "Local messages must be at most 1 MiB; paginate lists and transfer files separately.") }
        return try read(Int(length), fd: fd, deadline: deadline)
    }
    static func writeFrame(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        guard !data.isEmpty, data.count <= SocketLimits.maximumFrameBytes else { throw AutomationFailure("payload_too_large", "Local messages must be at most 1 MiB; paginate lists and transfer files separately.") }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try write(Data($0), fd: fd, deadline: deadline) }
        try write(data, fd: fd, deadline: deadline)
    }
}

private final class SocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var canceled = false
    private var task: Task<Void, Never>?
    func install(_ value: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        if canceled { close(value); throw CancellationError() }; fd = value
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }; canceled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        task?.cancel()
    }
    func installTask(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }; self.task = task
        if canceled { task.cancel() }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
        task = nil
    }
    deinit { finish() }
}
private final class SocketPool: @unchecked Sendable {
    static let client = SocketPool()
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = SocketLimits.maximumConnections; q.qualityOfService = .userInitiated; return q }()
    private let lock = NSLock(); private var count = 0
    func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard count < SocketLimits.maximumConnections else { return false }; count += 1; return true }
    func release() { lock.lock(); count -= 1; lock.unlock() }
}

public enum AutomationSocketClient {
    public static func send(_ request: AutomationRequest, path: String, timeout: TimeInterval = SocketLimits.requestTimeout) async throws -> AutomationResponse {
        let data = try AutomationCoding.encoder.encode(request)
        guard data.count <= SocketLimits.maximumFrameBytes else { throw AutomationFailure("payload_too_large", "The request exceeds 1 MiB.") }
        guard SocketPool.client.acquire() else { throw AutomationFailure("busy", "Too many concurrent local requests.") }
        let connection = SocketConnection()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                SocketPool.client.queue.addOperation {
                    defer { connection.finish(); SocketPool.client.release() }
                    var dispatched = false
                    do {
                        let deadline = ProcessInfo.processInfo.systemUptime + timeout
                        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                        guard fd >= 0 else { throw AutomationFailure("unavailable", "Could not create a local connection.") }
                        try connection.install(fd); SocketIO.configure(fd)
                        var address = try SocketIO.address(path)
                        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                        if result != 0 {
                            guard errno == EINPROGRESS else { throw AutomationFailure("unavailable", "The app is not running or its local service is unavailable.") }
                            try SocketIO.wait(fd, event: Int16(POLLOUT), until: deadline)
                            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw AutomationFailure("unavailable", "Could not connect to the app.") }
                        }
                        dispatched = true
                        try SocketIO.writeFrame(data, fd: fd, deadline: deadline)
                        let response = try AutomationCoding.decoder.decode(AutomationResponse.self, from: SocketIO.readFrame(fd: fd, deadline: deadline))
                        _ = try response.checked(for: request)
                        continuation.resume(returning: response)
                    } catch {
                        var failure = error is DecodingError ? AutomationFailure("incompatible_backend", "The running app uses a different protocol. Relaunch the app bundled with this CLI.") : AutomationFailure.normalize(error)
                        if dispatched && ["unavailable", "timeout", "canceled"].contains(failure.code) {
                            failure = AutomationFailure("outcome_unknown", "The response was lost after dispatch. The operation may have completed; inspect state before retrying.", details: ["requestId": request.requestId.uuidString])
                        }
                        continuation.resume(throwing: failure)
                    }
                }
            }
        } onCancel: { connection.cancel() }
    }
}

public final class AutomationSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse
    private let path: String, handler: Handler
    private let queue = DispatchQueue(label: "app-automation.accept")
    private let workers = SocketPool()
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var active: [UUID: SocketConnection] = [:]
    public init(path: String, handler: @escaping Handler) { self.path = path; self.handler = handler }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(parent.path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o077 == 0 else {
            throw AutomationFailure("permission_denied", "The socket directory must be owned by this user with mode 0700.")
        }
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else { throw AutomationFailure("permission_denied", "An unrelated file occupies the service socket path.") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0); defer { if probe >= 0 { close(probe) } }
            guard probe >= 0 else { throw AutomationFailure("unavailable", "Could not inspect the existing local service.") }
            SocketIO.configure(probe); var address = try SocketIO.address(path)
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result != 0, errno == ECONNREFUSED || errno == ENOENT else { throw AutomationFailure("busy", "Another app already owns this local service.") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationFailure("unavailable", "Could not create the service socket.") }
        SocketIO.configure(fd)
        do {
            var address = try SocketIO.address(path)
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { throw AutomationFailure("unavailable", "Could not bind the local service.") }
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [weak self] in self?.accept(fd) }
            s.setCancelHandler { close(fd) }
            source = s; s.resume()
        } catch { close(fd); throw error }
    }
    public func stop() {
        lock.lock(); let s = source; source = nil; let clients = Array(active.values); lock.unlock()
        if s != nil { unlink(path); s?.cancel() }
        clients.forEach { $0.cancel() }
    }
    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard workers.acquire() else { close(fd); continue }
            SocketIO.configure(fd)
            let id = UUID(), connection = SocketConnection()
            do { try connection.install(fd) } catch { workers.release(); continue }
            lock.lock(); let running = source != nil; if running { active[id] = connection }; lock.unlock()
            guard running else { connection.finish(); workers.release(); continue }
            workers.queue.addOperation { [self] in
                do {
                    let bytes = try SocketIO.readFrame(fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 10)
                    let request = try AutomationCoding.decoder.decode(AutomationRequest.self, from: bytes)
                    let task = Task {
                        let response: AutomationResponse
                        if request.protocolVersion != AutomationVersion.protocolVersion {
                            response = .init(requestId: request.requestId, error: .init("incompatible_backend", "Use the CLI bundled with this app."))
                        } else { response = await handler(request) }
                        workers.queue.addOperation { [self] in
                            defer { finish(id, connection) }
                            do { try SocketIO.writeFrame(AutomationCoding.encoder.encode(response), fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 10) }
                            catch {
                                let failure = AutomationResponse(requestId: request.requestId, error: AutomationFailure.normalize(error))
                                try? SocketIO.writeFrame(AutomationCoding.encoder.encode(failure), fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 2)
                            }
                        }
                    }
                    connection.installTask(task)
                } catch { finish(id, connection) }
            }
        }
    }
    private func finish(_ id: UUID, _ connection: SocketConnection) {
        connection.finish(); lock.lock(); active.removeValue(forKey: id); lock.unlock(); workers.release()
    }
    deinit { stop() }
}
#endif
