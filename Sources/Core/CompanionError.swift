import Foundation

public enum CompanionError: LocalizedError, Sendable {
    case invalidArgument(String)
    case unavailable(String)
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
             .unavailable(let message),
             .protocolFailure(let message):
            return message
        }
    }

    public var code: String {
        switch self {
        case .invalidArgument: return "invalid_argument"
        case .unavailable: return "unavailable"
        case .protocolFailure: return "protocol_failure"
        }
    }
}
