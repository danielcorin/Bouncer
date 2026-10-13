import XCTest
import BouncerCore

@MainActor
final class ScenarioCoverageTests: XCTestCase {
    func testCoverageRequiresEveryCatalogOperationAndRejectsUnknownIDs() throws {
        let complete = Set(GeneratedCatalog.operations.map(\.id))
        XCTAssertNoThrow(try ScenarioSuite.requireCompleteCoverage(complete))
        for operation in complete {
            XCTAssertThrowsError(try ScenarioSuite.requireCompleteCoverage(complete.subtracting([operation])), "Missing \(operation) must fail the gate")
        }
        XCTAssertThrowsError(try ScenarioSuite.requireCompleteCoverage(complete.union(["undeclaredOperation"])))
        XCTAssertThrowsError(try ScenarioSuite.requireCompleteCoverage([]))
    }
}
