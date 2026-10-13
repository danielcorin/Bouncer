import Foundation

public protocol AppConfigurationStoreReadAccess {
    static var changeNotification: Notification.Name { get }
    var fileURL: URL { get }
    static func defaultFileURL(environment: [String: String], homeDirectory: URL) -> URL
    func prepareDirectory() throws
    func load() throws -> AppConfiguration
    func validate(content: String) throws
    func validate() throws
    func entry(for key: AppConfigurationKey) throws -> AppConfigurationEntry
    func entries(changesOnly: Bool) throws -> [AppConfigurationEntry]
}
