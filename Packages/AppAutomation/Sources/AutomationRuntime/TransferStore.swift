import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct TransferFile: Codable, Sendable {
    public var handle: String
    public var filename: String
    public var byteCount: Int
    public init(handle: String, filename: String, byteCount: Int) { self.handle = handle; self.filename = filename; self.byteCount = byteCount }
}

/// Transient local transfers, never an alternate work store. Handles are UUIDs,
/// not paths supplied by HTTP clients. File descriptors are opened without following symlinks.
public struct TransferStore: Sendable {
    public static let maximumBytes = 25 * 1024 * 1024
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AutomationFailure("invalid_input", "The transfer directory must be a private regular directory.") }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw AutomationFailure("permission_denied", "The transfer directory must be owned by this user with mode 0700.")
        }
    }
    fileprivate func path(_ handle: String) throws -> String {
        guard let id = UUID(uuidString: handle), id.uuidString == handle else { throw AutomationFailure("invalid_input", "Invalid transfer handle.") }
        return directory.appendingPathComponent(handle).path
    }
    public func stage(_ data: Data, filename: String) throws -> TransferFile {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw AutomationFailure("payload_too_large", "Files must contain 1 byte through 25 MiB.") }
        try prepare()
        let handle = UUID().uuidString, path = try path(handle)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationFailure("unavailable", "Could not create a temporary transfer.") }
        var complete = false
        defer { close(fd); if !complete { unlink(path) } }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AutomationFailure("unavailable", "Could not stage the upload.") }; count += n
            }
        }
        complete = true
        return TransferFile(handle: handle, filename: URL(fileURLWithPath: filename).lastPathComponent, byteCount: data.count)
    }
    public func stage(file: URL, filename: String? = nil) throws -> TransferFile {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maximumBytes else {
            throw AutomationFailure("payload_too_large", "Choose a regular file containing 1 byte through 25 MiB.")
        }
        return try stage(Data(contentsOf: file), filename: filename ?? file.lastPathComponent)
    }
    public func read(_ handle: String) throws -> Data {
        try prepare()
        let fd = open(try path(handle), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationFailure("not_found", "Transfer not found or expired.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              st.st_size > 0, st.st_size <= Self.maximumBytes else { throw AutomationFailure("invalid_input", "Invalid transfer file.") }
        var data = Data(count: Int(st.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var count = 0
            while count < bytes.count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AutomationFailure("unavailable", "Transfer ended unexpectedly.") }; count += n
            }
        }
        return data
    }
    public func remove(_ handle: String) { if let path = try? path(handle) { unlink(path) } }
    public func cleanExpired(now: Date = .now) throws {
        try prepare()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard UUID(uuidString: url.lastPathComponent) != nil else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, now.timeIntervalSince(date) > 3600 { remove(url.lastPathComponent) }
        }
    }
    public func writer(filename: String) throws -> TransferWriter { try TransferWriter(store: self, filename: filename) }
    public func reader(_ file: TransferFile) throws -> TransferReader { try TransferReader(store: self, file: file) }
}

/// Call methods sequentially on BlockingIO. An unfinished upload is removed on release.
public final class TransferWriter: @unchecked Sendable {
    private let store: TransferStore
    private let handle = UUID().uuidString
    private let filename: String
    private let fd: Int32
    private var count = 0
    private var finished = false
    fileprivate init(store: TransferStore, filename: String) throws {
        self.store = store; self.filename = URL(fileURLWithPath: filename).lastPathComponent
        try store.prepare()
        fd = open(try store.path(handle), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationFailure("unavailable", "Could not create an upload.") }
    }
    deinit { close(fd); if !finished { store.remove(handle) } }
    public func append(_ data: Data) throws {
        guard !finished, count + data.count <= TransferStore.maximumBytes else { throw AutomationFailure("payload_too_large", "Uploads are limited to 25 MiB.") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AutomationFailure("unavailable", "Could not write the upload.") }; offset += n
            }
        }
        count += data.count
    }
    public func finish() throws -> TransferFile {
        guard !finished, count > 0 else { throw AutomationFailure("invalid_input", "An upload must contain at least one byte.") }
        finished = true
        return .init(handle: handle, filename: filename, byteCount: count)
    }
}

/// Retains a verified file descriptor until streaming finishes; releases the temporary export.
public final class TransferReader: @unchecked Sendable {
    private let store: TransferStore
    private let handle: String
    private let fd: Int32
    private var remaining: Int
    fileprivate init(store: TransferStore, file: TransferFile) throws {
        self.store = store; handle = file.handle; remaining = file.byteCount
        try store.prepare()
        fd = open(try store.path(handle), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationFailure("not_found", "The export is missing or expired.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size == remaining, remaining > 0, remaining <= TransferStore.maximumBytes else {
            close(fd); throw AutomationFailure("invalid_input", "Invalid export file.")
        }
    }
    deinit { close(fd); store.remove(handle) }
    public func next() throws -> Data? {
        guard remaining > 0 else { return nil }
        var bytes = Data(count: min(65_536, remaining))
        let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        if n < 0 && errno == EINTR { return try next() }
        guard n > 0 else { throw AutomationFailure("unavailable", "The export ended unexpectedly.") }
        bytes.count = n; remaining -= n
        return bytes
    }
}
