import Foundation
import AutomationRuntime
import BouncerCore

/// Test behavior is authored in Swift against generated operation types. The exact
/// same inputs and assertions are driven through direct Swift, CLI, and HTTP.
@MainActor
struct ScenarioStep {
    let operation: OperationDefinition
    let prepare: () throws -> JSONValue
    let direct: (JSONValue, any ApplicationOperations, any ConfigurationOperations) async throws -> JSONValue
    let verify: (JSONValue) throws -> Void
    let expectedError: String?
    init<O: LocalAppOperation>(_ operation: O.Type, error: String? = nil,
                              input: @escaping () throws -> O.Input,
                              verify: @escaping (JSONValue) throws -> Void) {
        self.operation = O.definition; expectedError = error
        prepare = { try JSONValue.encode(input()) }
        direct = { value, app, config in
            try O.definition.validate(value)
            return try await JSONValue.encode(O.perform(value.decode(), application: app, configuration: config))
        }
        self.verify = { value in
            if !O.definition.download { _ = try value.decode(O.Output.self) }
            try verify(value)
        }
    }
}

@MainActor
final class ScenarioSuite {
    private let steps: [ScenarioStep]
    private let application: any ApplicationOperations
    private let configuration: any ConfigurationOperations
    private let transfers: TransferStore
    private let normalize: (Error) -> AutomationFailure
    private var index = 0
    private var prepared: JSONValue?
    private var verified = Set<String>()
    init(steps: [ScenarioStep], application: any ApplicationOperations, configuration: any ConfigurationOperations,
         transfers: TransferStore, normalize: @escaping (Error) -> AutomationFailure) throws {
        self.steps = steps; self.application = application; self.configuration = configuration
        self.transfers = transfers; self.normalize = normalize
        try Self.requireCompleteCoverage(Set(steps.map { $0.operation.id }))
    }
    static func requireCompleteCoverage(_ registered: Set<String>) throws {
        let required = Set(GeneratedCatalog.operations.map(\.id))
        guard required == registered else {
            throw AutomationFailure("scenario_coverage", "Missing scenarios: \(required.subtracting(registered).sorted()); unknown scenarios: \(registered.subtracting(required).sorted())")
        }
    }
    func handle(_ request: AutomationRequest) async throws -> JSONValue? {
        switch request.operation {
        case "$scenarioNext":
            guard index < steps.count else {
                guard verified == Set(GeneratedCatalog.operations.map(\.id)) else { throw AutomationFailure("scenario_coverage", "Some operations were not verified.") }
                return .object(["done": .bool(true), "verified": .array(verified.sorted().map(JSONValue.string)), "steps": .integer(index)])
            }
            guard prepared == nil else { throw AutomationFailure("scenario_order", "Assert the pending scenario before advancing.") }
            prepared = try steps[index].prepare()
            return .object(["definition": try .encode(steps[index].operation), "input": prepared!])
        case "$scenarioDirect":
            guard let prepared, index < steps.count else { throw AutomationFailure("scenario_order", "Prepare a scenario first.") }
            do {
                var result = try await steps[index].direct(prepared, application, configuration)
                if steps[index].operation.download {
                    let file = try result.decode(TransferFile.self)
                    defer { transfers.remove(file.handle) }
                    result = .object(["download": .string(try transfers.read(file.handle).base64EncodedString())])
                }
                return .object(["data": result])
            } catch { return .object(["error": try .encode(normalize(error))]) }
        case "$scenarioAssert":
            guard prepared != nil, index < steps.count else { throw AutomationFailure("scenario_order", "No pending scenario.") }
            let step = steps[index]
            if let expected = step.expectedError {
                guard request.input.object?["error"]?.object?["code"]?.string == expected else {
                    throw AutomationFailure("scenario_failed", "\(step.operation.id): expected error \(expected); received \(request.input)")
                }
            } else {
                guard request.input.object?["error"] == nil, let result = request.input.object?["data"] else {
                    throw AutomationFailure("scenario_failed", "\(step.operation.id): expected success; received \(request.input)")
                }
                try step.verify(result)
            }
            verified.insert(step.operation.id); index += 1; prepared = nil
            return .object(["verified": .string(step.operation.id)])
        default: return nil
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AutomationFailure("scenario_failed", message) }
}
extension JSONValue {
    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    var elements: [JSONValue] { if case .array(let a) = self { return a }; return [] }
}
