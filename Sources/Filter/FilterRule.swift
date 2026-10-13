import Foundation

/// One user-authored pattern. Allow rules override block rules, so a broad block
/// such as `/.*/` plus a few allow rules gives an allowlist-only mode.
public struct FilterRule: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Matches the domain itself and every subdomain; `*.example.com` matches subdomains only.
        case domain
        /// A case-insensitive, unanchored regular expression tested against the full domain.
        case regex
    }

    public enum Action: String, Codable, CaseIterable, Sendable {
        case block, allow
    }

    public var id: UUID
    public var pattern: String
    public var kind: Kind
    public var action: Action
    public var enabled: Bool

    public init(id: UUID = UUID(), pattern: String, kind: Kind, action: Action = .block, enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
        self.action = action
        self.enabled = enabled
    }
}

public enum FilterRuleError: LocalizedError, Equatable, Sendable {
    case empty
    case invalidDomain(String)
    case invalidRegex(String, reason: String)
    case unknownKind(String)
    case unknownAction(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a domain or pattern."
        case .invalidDomain(let value): "'\(value)' isn't a valid domain. Use letters, digits, hyphens, and dots (optionally starting with *.), or write a regex as /pattern/."
        case .invalidRegex(let value, let reason): "'\(value)' isn't a valid regular expression: \(reason)"
        case .unknownKind(let value): "Unknown rule kind '\(value)'. Use domain or regex."
        case .unknownAction(let value): "Unknown rule action '\(value)'. Use block or allow."
        }
    }
}

public enum FilterPattern {
    /// Lowercases and strips the trailing root dot from a DNS name.
    public static func normalizeDomain(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// Resolves free-form input into a validated pattern and kind.
    /// `kind == nil` infers regex for `/slashed/` input and domain otherwise.
    /// Domain input may be a URL; only its host is kept.
    public static func parse(_ raw: String, kind: FilterRule.Kind?) throws -> (pattern: String, kind: FilterRule.Kind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilterRuleError.empty }
        let slashed = trimmed.count >= 2 && trimmed.hasPrefix("/") && trimmed.hasSuffix("/")
        switch kind ?? (slashed ? .regex : .domain) {
        case .regex:
            let pattern = slashed ? String(trimmed.dropFirst().dropLast()) : trimmed
            guard !pattern.isEmpty else { throw FilterRuleError.empty }
            do { _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
            catch { throw FilterRuleError.invalidRegex(pattern, reason: (error as NSError).localizedFailureReason ?? "it doesn't compile") }
            return (pattern, .regex)
        case .domain:
            let domain = try validatedDomain(trimmed)
            return (domain, .domain)
        }
    }

    private static func validatedDomain(_ input: String) throws -> String {
        var value = input
        if value.contains("://"), let host = URL(string: value)?.host {
            value = host
        } else if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }
        value = normalizeDomain(value)
        var labels = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.first == "*" { labels.removeFirst() }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !labels.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw FilterRuleError.invalidDomain(input) }
        return value
    }

    public static func kind(_ raw: String?) throws -> FilterRule.Kind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty, raw != "auto" else { return nil }
        guard let kind = FilterRule.Kind(rawValue: raw) else { throw FilterRuleError.unknownKind(raw) }
        return kind
    }

    public static func action(_ raw: String?) throws -> FilterRule.Action? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        guard let action = FilterRule.Action(rawValue: raw) else { throw FilterRuleError.unknownAction(raw) }
        return action
    }
}
