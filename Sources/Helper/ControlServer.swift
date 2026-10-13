import Darwin
import Foundation
import Security

/// A Unix stream socket owned by the installing user (mode 0600). Every accepted
/// peer must also pass `PeerVerifier`, so only that user's Bouncer app can steer DNS.
final class ControlServer: @unchecked Sendable {
    private let path: String
    private let ownerUID: uid_t
    private let verifier: PeerVerifier
    private let queue: DispatchQueue
    private let onSession: (ControlSession) -> Void
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, ownerUID: uid_t, verifier: PeerVerifier, queue: DispatchQueue, onSession: @escaping (ControlSession) -> Void) {
        self.path = path
        self.ownerUID = ownerUID
        self.verifier = verifier
        self.queue = queue
        self.onSession = onSession
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let error = POSIXError.current("bind \(path)"); close(fd); throw error }
        if geteuid() == 0 { chown(path, ownerUID, 0) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let error = POSIXError.current("listen"); close(fd); throw error }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        descriptor = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            guard verifier.verify(client) else {
                log("Rejected an unauthorized control connection.")
                close(client)
                continue
            }
            onSession(ControlSession(descriptor: client, queue: queue))
        }
    }
}

final class ControlSession: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()
    private var closed = false
    var onRequest: ((HelperRequest) -> Void)?
    var onClose: (() -> Void)?

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
        // Never let a stalled client block the helper's state queue.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    func send(_ message: HelperMessage) {
        guard !closed, let data = try? HelperCoding.encode(message) else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        if !ok { close() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0 else { close(); return }
        guard let lines = buffer.append(Data(chunk[0..<count])) else { close(); return }
        for line in lines {
            guard let request = try? HelperCoding.decode(HelperRequest.self, from: line) else {
                send(HelperMessage(error: "Malformed request."))
                continue
            }
            onRequest?(request)
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        onClose?()
    }
}

/// Accepts only the owning user (or root) running a correctly signed Bouncer app.
struct PeerVerifier {
    let ownerUID: uid_t
    let requireSignature: Bool
    private let requirement: SecRequirement?

    init(ownerUID: uid_t, requireSignature: Bool) {
        self.ownerUID = ownerUID
        self.requireSignature = requireSignature
        var text = "identifier \"\(HelperConstants.clientIdentifier)\""
        // When the helper carries a Team ID, the app must be signed by the same team.
        if let team = Self.ownTeamIdentifier() {
            text += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        var requirement: SecRequirement?
        SecRequirementCreateWithString(text as CFString, [], &requirement)
        self.requirement = requirement
    }

    func verify(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == ownerUID || uid == 0 else { return false }
        guard requireSignature else { return true }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, let requirement else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

extension POSIXError {
    static func current(_ context: String) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(code)))"])
    }
}
