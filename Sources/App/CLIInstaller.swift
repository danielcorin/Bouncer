import Foundation
import BouncerCore

enum CLIInstaller {
    static var destinationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("bouncer")
    }

    static var bundledCLIURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("bouncer")
    }

    static func install() throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bundledCLIURL.path) else {
            throw CompanionError.unavailable(
                "The bundled bouncer CLI is missing. Rebuild or reinstall Bouncer."
            )
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let isSymbolicLink = (
            try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                .isSymbolicLink
        ) == true
        if fileManager.fileExists(atPath: destinationURL.path) || isSymbolicLink {
            let existing = try? fileManager.destinationOfSymbolicLink(
                atPath: destinationURL.path
            )
            if existing == bundledCLIURL.path {
                return destinationURL
            }
            throw CompanionError.unavailable(
                "A file already exists at \(destinationURL.path). Move it before installing Bouncer's CLI."
            )
        }

        try fileManager.createSymbolicLink(
            at: destinationURL,
            withDestinationURL: bundledCLIURL
        )
        return destinationURL
    }
}
