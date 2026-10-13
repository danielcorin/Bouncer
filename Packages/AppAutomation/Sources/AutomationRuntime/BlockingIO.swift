import Foundation

/// File I/O is bounded and never blocks NIO or a cooperative Swift worker.
public final class BlockingIO: @unchecked Sendable {
    public static let shared = BlockingIO()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "AppAutomation.files"; queue.maxConcurrentOperationCount = 4; return queue
    }()
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { continuation.resume(with: Result(catching: body)) }
        }
    }
}
