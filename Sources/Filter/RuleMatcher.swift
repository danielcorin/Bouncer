import Foundation

public enum FilterDecision: Equatable, Sendable {
    case blocked(FilterRule)
    case allowed(FilterRule)
    case unmatched

    public var isBlocked: Bool { if case .blocked = self { return true }; return false }
}

/// Immutable compiled rule set. `NSRegularExpression` is immutable and thread-safe,
/// so one matcher can be shared by every DNS worker.
public struct RuleMatcher: @unchecked Sendable {
    private struct Compiled {
        let rule: FilterRule
        let domain: String?
        let subdomainsOnly: Bool
        let regex: NSRegularExpression?
    }

    private let allows: [Compiled]
    private let blocks: [Compiled]
    public let rules: [FilterRule]

    public static let empty = RuleMatcher(rules: [])

    /// Rules that fail to compile are skipped; the stores validate input before saving.
    public init(rules: [FilterRule]) {
        self.rules = rules
        let compiled = rules.filter(\.enabled).compactMap { rule -> Compiled? in
            switch rule.kind {
            case .domain:
                let normalized = FilterPattern.normalizeDomain(rule.pattern)
                let subdomainsOnly = normalized.hasPrefix("*.")
                let domain = subdomainsOnly ? String(normalized.dropFirst(2)) : normalized
                return domain.isEmpty ? nil : Compiled(rule: rule, domain: domain, subdomainsOnly: subdomainsOnly, regex: nil)
            case .regex:
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return nil }
                return Compiled(rule: rule, domain: nil, subdomainsOnly: false, regex: regex)
            }
        }
        allows = compiled.filter { $0.rule.action == .allow }
        blocks = compiled.filter { $0.rule.action == .block }
    }

    public var isEmpty: Bool { blocks.isEmpty }

    public func evaluate(_ name: String) -> FilterDecision {
        let domain = FilterPattern.normalizeDomain(name)
        guard !domain.isEmpty else { return .unmatched }
        if let allow = allows.first(where: { Self.matches($0, domain) }) { return .allowed(allow.rule) }
        if let block = blocks.first(where: { Self.matches($0, domain) }) { return .blocked(block.rule) }
        return .unmatched
    }

    private static func matches(_ entry: Compiled, _ domain: String) -> Bool {
        if let pattern = entry.domain {
            if domain == pattern { return !entry.subdomainsOnly }
            return domain.hasSuffix("." + pattern)
        }
        guard let regex = entry.regex else { return false }
        return regex.firstMatch(in: domain, range: NSRange(domain.startIndex..., in: domain)) != nil
    }
}
