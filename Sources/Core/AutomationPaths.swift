import Foundation
import AutomationRuntime

public enum BouncerAutomationPaths {
    public static var directory: URL {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["APP_AUTOMATION_ROOT"], root.hasPrefix("/") {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bouncer/Automation", isDirectory: true)
    }
    public static var socket: URL { directory.appendingPathComponent("automation.sock") }
    public static var transfers: TransferStore { TransferStore(directory: directory.appendingPathComponent("Transfers", isDirectory: true)) }
}
