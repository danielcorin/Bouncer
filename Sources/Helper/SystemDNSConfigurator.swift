import Foundation

/// Points every network service's DNS at 127.0.0.1 and restores the exact prior
/// settings. The backup is written before anything changes, so a crash, kill, or
/// reboot is repaired the next time launchd starts the helper.
final class SystemDNSConfigurator {
    struct Backup: Codable {
        /// Service name → manual DNS servers; empty means "use DHCP" (networksetup's Empty).
        var services: [String: [String]]
        var createdAt: Date
    }

    static let loopback = "127.0.0.1"
    private let backupURL: URL

    init(stateDirectory: URL) {
        backupURL = stateDirectory.appendingPathComponent("dns-backup.json")
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }
    var isApplied: Bool { hasBackup }

    func apply() throws {
        let services = try Self.networkServices()
        var backup = Backup(services: [:], createdAt: Date())
        for service in services {
            var servers = (try? Self.dnsServers(for: service)) ?? []
            // Never record our own resolver as the original setting.
            if servers == [Self.loopback] { servers = [] }
            backup.services[service] = servers
        }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
        for service in services {
            do { try Self.setDNSServers([Self.loopback], for: service) }
            catch { log("Couldn't set DNS for \(service): \(error.localizedDescription)") }
        }
    }

    func restore() throws {
        guard hasBackup else { return }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: backupURL))
        var failures: [String] = []
        for (service, servers) in backup.services.sorted(by: { $0.key < $1.key }) {
            do { try Self.setDNSServers(servers.isEmpty ? ["Empty"] : servers, for: service) }
            catch { failures.append(service) }
        }
        try? FileManager.default.removeItem(at: backupURL)
        if !failures.isEmpty { log("Couldn't restore DNS for \(failures.joined(separator: ", ")); they may have been removed.") }
    }

    func flushCaches() {
        _ = try? Self.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? Self.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    // MARK: - networksetup

    static func networkServices() throws -> [String] {
        try run("/usr/sbin/networksetup", ["-listallnetworkservices"])
            .split(separator: "\n")
            .dropFirst() // "An asterisk (*) denotes that a network service is disabled."
            .map { line in line.hasPrefix("*") ? String(line.dropFirst()) : String(line) }
            .filter { !$0.isEmpty }
    }

    static func dnsServers(for service: String) throws -> [String] {
        let output = try run("/usr/sbin/networksetup", ["-getdnsservers", service])
        if output.contains("aren't any DNS Servers") { return [] }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func setDNSServers(_ servers: [String], for service: String) throws {
        _ = try run("/usr/sbin/networksetup", ["-setdnsservers", service] + servers)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BouncerHelper", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return text
    }
}
