import XCTest
import Foundation
import AutomationRuntime
import AutomationCLI

final class RuntimeTests: XCTestCase {
    private enum CustomizableOperation: AutomationOperation {
        typealias Input = JSONValue
        typealias Output = String
        static let definition = OperationDefinition(id: "itemRead", command: ["item", "read"], summary: "Read", method: "GET", path: "/items", fields: [])
    }
    private enum SiblingOperation: AutomationOperation {
        typealias Input = JSONValue
        typealias Output = String
        static let definition = OperationDefinition(id: "otherRead", command: ["other", "read"], summary: "Read", method: "GET", path: "/other", fields: [])
    }
    private struct DefaultCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read")
    }
    private struct CustomCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read")
        @Option var format: String = "compact"
    }
    func testSwiftCommandReplacementKeepsUnrelatedCommands() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let environment = CLIEnvironment(client: AutomationClient { request in
            .init(requestId: request.requestId, data: .string("ok"))
        }, transfers: TransferStore(directory: directory))
        environment.replace(CustomizableOperation.self, with: CustomCommand.self)
        let replacement = environment.command(CustomizableOperation.self, default: DefaultCommand.self)
        let parsed = try replacement.parseAsRoot(["--format", "expanded"])
        XCTAssertEqual((parsed as? CustomCommand)?.format, "expanded")
        let sibling = environment.command(SiblingOperation.self, default: DefaultCommand.self)
        XCTAssertTrue(try sibling.parseAsRoot([]) is DefaultCommand)
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/automation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private let operation = OperationDefinition(id: "edit", command: ["edit"], summary: "Edit", method: "PATCH", path: "/items/{id}", fields: [
        .init(name: "id", location: "path", type: "string", required: true, argument: 0),
        .init(name: "due", location: "body", type: "string", required: false, nullable: true, option: "--due"),
        .init(name: "ids", location: "body", type: "string[]", required: false, option: "--ids")
    ])
    func testCLIPresenceAndCollectionInputs() throws {
        XCTAssertEqual(try CLIEnvironment.input(operation, values: ["id": "abc"], clear: [], inputFile: nil), .object(["id": .string("abc")]))
        XCTAssertEqual(try CLIEnvironment.input(operation, values: ["id": "abc", "ids": "[]"], clear: ["due"], inputFile: nil), .object(["id": .string("abc"), "ids": .array([]), "due": .null]))
        XCTAssertThrowsError(try CLIEnvironment.input(operation, values: ["due": "today"], clear: ["due"], inputFile: nil))
        XCTAssertThrowsError(try operation.validate(.object(["id": .null])))
        XCTAssertThrowsError(try operation.validate(.object(["id": .string("x"), "unexpected": .bool(true)])))
    }
    func testInputFileCannotSilentlyOverrideFlags() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.json")
        try Data("{\"id\":\"abc\",\"due\":null}".utf8).write(to: file)
        XCTAssertEqual(try CLIEnvironment.input(operation, values: [:], clear: [], inputFile: file.path).object?["due"], .null)
        XCTAssertThrowsError(try CLIEnvironment.input(operation, values: ["id":"other"], clear: [], inputFile: file.path))
    }
    func testTransferStreamingBeyondSocketLimitAndSymlinkRejection() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferStore(directory: directory.appendingPathComponent("Transfers"))
        let writer = try store.writer(filename: "photo.png")
        let chunk = Data(repeating: 0x55, count: 65_536)
        for _ in 0..<32 { try writer.append(chunk) }
        let file = try writer.finish()
        XCTAssertEqual(file.byteCount, 2_097_152)
        let reader = try store.reader(file)
        var count = 0
        while let next = try reader.next() { XCTAssertEqual(next, chunk); count += next.count }
        XCTAssertEqual(count, file.byteCount)
        XCTAssertThrowsError(try store.read("../outside"))
        let handle = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent(handle), withDestinationURL: directory.appendingPathComponent("outside"))
        XCTAssertThrowsError(try store.read(handle))
    }
    func testUploadLimitAndUnfinishedCleanup() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferStore(directory: directory.appendingPathComponent("Transfers"))
        do {
            let writer = try store.writer(filename: "data")
            XCTAssertThrowsError(try writer.append(Data(repeating: 0, count: TransferStore.maximumBytes + 1)))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }
    func testSocketDoesNotReplayAfterLostResponse() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        actor Counter { var value = 0; func increment() { value += 1 } }
        let count = Counter(), path = directory.appendingPathComponent("api.sock").path
        let server = AutomationSocketServer(path: path) { request in
            await count.increment()
            try? await Task.sleep(for: .milliseconds(150))
            return .init(requestId: request.requestId, data: .bool(true))
        }
        try server.start(); defer { server.stop() }
        let request = AutomationRequest(operation: "mutate")
        do { _ = try await AutomationSocketClient.send(request, path: path, timeout: 0.05); XCTFail("Expected a timeout") }
        catch let error as AutomationFailure {
            XCTAssertEqual(error.code, "outcome_unknown")
            XCTAssertEqual(error.details?["requestId"], request.requestId.uuidString)
        }
        let value = await count.value
        XCTAssertEqual(value, 1)
    }
    func testSocketCancellationAndLiveSocketOwnership() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("api.sock").path
        let server = AutomationSocketServer(path: path) { request in
            try? await Task.sleep(for: .milliseconds(200))
            return .init(requestId: request.requestId, data: .bool(true))
        }
        try server.start(); defer { server.stop() }
        let other = AutomationSocketServer(path: path) { .init(requestId: $0.requestId, data: .null) }
        XCTAssertThrowsError(try other.start())
        other.stop()
        let request = AutomationRequest(operation: "status")
        let task = Task { try await AutomationSocketClient.send(request, path: path) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as AutomationFailure { XCTAssertEqual(error.code, "outcome_unknown") }
        let response = try await AutomationSocketClient.send(request, path: path)
        XCTAssertEqual(response.requestId, request.requestId)
    }
    func testResponseValidationAndForce() throws {
        let request = AutomationRequest(operation: "delete")
        XCTAssertThrowsError(try AutomationResponse(requestId: UUID(), data: .null).checked(for: request))
        let deletion = OperationDefinition(id: "delete", command: ["delete"], summary: "Delete", method: "DELETE", path: "/items", fields: [
            .init(name: "force", location: "query", type: "boolean", required: true, option: "--force")
        ], destructive: true)
        XCTAssertThrowsError(try deletion.validate(.object(["force": .bool(false)])))
        XCTAssertNoThrow(try deletion.validate(.object(["force": .bool(true)])))
    }
}
