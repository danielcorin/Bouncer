import Foundation
import NetworkExtension

// Terminal-driven controller for the tunnel proof of concept:
//   BouncerTunnelPOC install [--mode dns-only|nominal-default] [--upstream 192.168.1.1,1.1.1.1]
//   BouncerTunnelPOC start | stop | status | stats | remove

let providerID = "llc.wvlen.Bouncer.TunnelPOC.Tunnel"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func manager(create: Bool) async throws -> NETunnelProviderManager? {
    let all = try await NETunnelProviderManager.loadAllFromPreferences()
    if let existing = all.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }) {
        return existing
    }
    return create ? NETunnelProviderManager() : nil
}

func describe(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: "invalid"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .reasserting: "reasserting"
    case .disconnecting: "disconnecting"
    @unknown default: "unknown"
    }
}

func wait(for target: NEVPNStatus, _ manager: NETunnelProviderManager) async -> NEVPNStatus {
    for _ in 0..<100 {
        if manager.connection.status == target { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return manager.connection.status
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
do {
    switch command {
    case "install":
        let mode = option("--mode") ?? "dns-only"
        guard ["dns-only", "nominal-default"].contains(mode) else { fail("unknown mode \(mode)") }
        let upstream = (option("--upstream") ?? "192.168.1.1,1.1.1.1").split(separator: ",").map(String.init)
        let manager = try await manager(create: true)!
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerID
        proto.serverAddress = "Bouncer (on this Mac)"
        proto.providerConfiguration = ["mode": mode, "upstream": upstream]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Bouncer POC"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        print("installed configuration (mode \(mode), upstream \(upstream.joined(separator: ",")))")
    case "start":
        guard let manager = try await manager(create: false) else { fail("run install first") }
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        try manager.connection.startVPNTunnel()
        print("status: \(describe(await wait(for: .connected, manager)))")
    case "stop":
        guard let manager = try await manager(create: false) else { fail("not installed") }
        manager.connection.stopVPNTunnel()
        print("status: \(describe(await wait(for: .disconnected, manager)))")
    case "status":
        guard let manager = try await manager(create: false) else { print("not installed"); exit(0) }
        let mode = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["mode"] ?? "?"
        print("status: \(describe(manager.connection.status)) (mode \(mode), enabled \(manager.isEnabled))")
    case "stats":
        guard let manager = try await manager(create: false), let session = manager.connection as? NETunnelProviderSession else { fail("not installed") }
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            do { try session.sendProviderMessage(Data("stats".utf8)) { continuation.resume(returning: $0) } }
            catch { continuation.resume(throwing: error) }
        }
        print(data.map { String(decoding: $0, as: UTF8.self) } ?? "no response (tunnel not running?)")
    case "remove":
        guard let manager = try await manager(create: false) else { print("not installed"); exit(0) }
        manager.connection.stopVPNTunnel()
        try await manager.removeFromPreferences()
        print("removed")
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail(error.localizedDescription)
}
