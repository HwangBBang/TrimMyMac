import Testing
@testable import CleanCore

// Proves the package compiles and the test pipeline is wired.
// CleanCore is an empty module in Task 0; later tasks add real tests.
// Note: Uses Swift Testing (not XCTest) — CommandLineTools does not ship XCTest.framework.
@Test func scaffoldSmokeTestCleanCoreImportsAndPipelineRuns() {
    #expect(Bool(true), "CleanCore imported and CleanCoreTests target built")
}
