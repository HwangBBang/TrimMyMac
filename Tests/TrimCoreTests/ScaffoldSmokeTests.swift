import Testing
@testable import TrimCore

// Proves the package compiles and the test pipeline is wired.
// TrimCore is an empty module in Task 0; later tasks add real tests.
// Note: Uses Swift Testing (not XCTest) — CommandLineTools does not ship XCTest.framework.
@Test func scaffoldSmokeTestTrimCoreImportsAndPipelineRuns() {
    #expect(Bool(true), "TrimCore imported and TrimCoreTests target built")
}
