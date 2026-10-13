import Foundation

// Bouncer's privileged helper. launchd runs it as root (see HelperInstaller in
// Core). It owns the two things that need root: listening on 127.0.0.1:53 and
// pointing every network service's DNS at it. Blocking lasts only as long as the
// app's control connection; any disconnect, signal, or restart restores DNS.

struct HelperArguments {
    var ownerUID: uid_t?
    var socketPath = HelperConstants.socketPath
    var stateDirectory = HelperConstants.stateDirectory
    var dnsPort: UInt16 = 53
    /// Development mode: run the filter without touching system DNS settings.
    var manageSystemDNS = true
    var requireSignedClients = true

    static func parse(_ arguments: [String]) -> HelperArguments {
        var result = HelperArguments()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--owner-uid": result.ownerUID = iterator.next().flatMap { uid_t($0) }
            case "--socket": result.socketPath = iterator.next() ?? result.socketPath
            case "--state-dir": result.stateDirectory = iterator.next() ?? result.stateDirectory
            case "--dns-port": result.dnsPort = iterator.next().flatMap { UInt16($0) } ?? result.dnsPort
            case "--no-system-dns": result.manageSystemDNS = false
            case "--allow-unsigned-clients": result.requireSignedClients = false
            default:
                log("Ignoring unknown argument \(argument)")
            }
        }
        return result
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[BouncerHelper] \(message)\n".utf8))
}

signal(SIGPIPE, SIG_IGN)
let arguments = HelperArguments.parse(CommandLine.arguments)
guard let ownerUID = arguments.ownerUID ?? (getuid() == 0 ? nil : getuid()) else {
    log("Missing --owner-uid; refusing to start without a controlling user.")
    exit(64)
}
if arguments.manageSystemDNS && geteuid() != 0 {
    log("System DNS management requires root; pass --no-system-dns for development.")
    exit(77)
}

let helper = Helper(arguments: arguments, ownerUID: ownerUID)
do {
    try helper.start()
} catch {
    log("Startup failed: \(error.localizedDescription)")
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []
for value in [SIGTERM, SIGINT, SIGHUP] {
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler {
        helper.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}
dispatchMain()
