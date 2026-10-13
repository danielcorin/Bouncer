import Combine
import Foundation

public struct SiteDenials: Codable, Equatable, Identifiable, Sendable {
    public var site: String
    /// Times you were denied: blocked lookups for the site within
    /// `DenialStatsStore.attemptWindow` of each other count once.
    public var attempts: Int
    /// Raw blocked DNS lookups; a single page visit makes several.
    public var lookups: Int
    public var lastDenied: Date
    public var id: String { site }
}

public struct DayDenials: Codable, Equatable, Identifiable, Sendable {
    /// Local calendar day, `yyyy-MM-dd`.
    public var date: String
    public var sites: [SiteDenials]
    public var id: String { date }
    public var attempts: Int { sites.reduce(0) { $0 + $1.attempts } }
    public var lookups: Int { sites.reduce(0) { $0 + $1.lookups } }
    /// Most-denied first, ties by name.
    public var ranked: [SiteDenials] {
        sites.sorted { $0.attempts != $1.attempts ? $0.attempts > $1.attempts : $0.site < $1.site }
    }
}

@MainActor
public protocol DenialStatsStoreReadAccess: ObservableObject {
    var days: [DayDenials] { get }
    var totalAttempts: Int { get }
    func day(_ key: String) -> DayDenials
    func recentDays(_ count: Int, endingOn: Date) -> [DayDenials]
    static func dayKey(for date: Date) -> String
    static func date(forKey key: String) -> Date?
    static var attemptWindow: TimeInterval { get }
    static var defaultFileURL: URL { get }
}

/// Persistent per-day, per-site counts of blocked attempts (`stats.json`).
@MainActor
public final class DenialStatsStore: DenialStatsStoreReadAccess {
    /// Oldest first.
    @Published public private(set) var days: [DayDenials] = []
    nonisolated public static let attemptWindow: TimeInterval = 10
    static let retentionDays = 400

    private let fileURL: URL
    private var lastLookup: [String: Date] = [:]
    private var saveTask: Task<Void, Never>?

    private struct File: Codable {
        var version = 1
        var days: [DayDenials]
    }

    nonisolated public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bouncer/stats.json")
    }

    public init(fileURL: URL = DenialStatsStore.defaultFileURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let file = try? decoder.decode(File.self, from: data) {
            days = file.days.sorted { $0.date < $1.date }
        }
    }

    public var totalAttempts: Int { days.reduce(0) { $0 + $1.attempts } }

    public func day(_ key: String) -> DayDenials {
        days.first { $0.date == key } ?? DayDenials(date: key, sites: [])
    }

    /// `count` consecutive days ending on `endingOn`, oldest first, empty days included.
    public func recentDays(_ count: Int, endingOn: Date = Date()) -> [DayDenials] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: endingOn)
        return (0..<max(count, 0)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map { day(Self.dayKey(for: $0)) }
        }
    }

    nonisolated public static func dayKey(for date: Date) -> String { formatter.string(from: date) }
    nonisolated public static func date(forKey key: String) -> Date? { formatter.date(from: key) }

    nonisolated private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    // MARK: - Recording (internal: driven by BlockingStore)

    func record(site: String, at date: Date) {
        let key = Self.dayKey(for: date)
        let newAttempt = lastLookup[site].map { date.timeIntervalSince($0) >= Self.attemptWindow || $0 > date } ?? true
        lastLookup[site] = date
        var day = self.day(key)
        if let index = day.sites.firstIndex(where: { $0.site == site }) {
            day.sites[index].lookups += 1
            if newAttempt { day.sites[index].attempts += 1 }
            day.sites[index].lastDenied = max(day.sites[index].lastDenied, date)
        } else {
            day.sites.append(SiteDenials(site: site, attempts: 1, lookups: 1, lastDenied: date))
        }
        if let index = days.firstIndex(where: { $0.date == key }) {
            days[index] = day
        } else {
            days.append(day)
            days.sort { $0.date < $1.date }
            prune(relativeTo: date)
        }
        scheduleSave()
    }

    func clear() {
        days = []
        lastLookup = [:]
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func prune(relativeTo date: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: date) else { return }
        let key = Self.dayKey(for: cutoff)
        days.removeAll { $0.date < key }
    }

    /// Lookups can arrive in bursts; write at most every couple of seconds.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(days: days)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Bouncer couldn't save stats: \(error.localizedDescription)")
        }
    }
}

/// Which "site" a blocked lookup counts toward.
public enum DenialSite {
    /// Two-label public suffixes common enough to special-case without a full list.
    static let secondLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp",
        "com.br", "com.cn", "com.mx", "co.in", "co.kr", "com.tr", "com.sg", "com.hk", "co.za",
    ]

    /// The domain in a domain rule (`linkedin.com` for `www.linkedin.com`), or the
    /// looked-up name's main domain for regex rules.
    public static func name(for domain: String, rule: FilterRule?) -> String {
        if let rule, rule.kind == .domain {
            let pattern = FilterPattern.normalizeDomain(rule.pattern)
            return pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        }
        return baseDomain(domain)
    }

    public static func baseDomain(_ domain: String) -> String {
        let labels = FilterPattern.normalizeDomain(domain).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return (secondLevelSuffixes.contains(lastTwo) ? labels.suffix(3) : labels.suffix(2)).joined(separator: ".")
    }
}
