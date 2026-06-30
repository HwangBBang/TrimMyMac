import Foundation
import Testing
@testable import TrimCore

@Suite("DiskMetrics")
struct DiskMetricsTests {

    // Root volume always exists and is a real mounted volume.
    @Test func rootVolumeSampleIsConsistent() {
        let metrics = DiskMetrics()
        guard let sample = metrics.sample(volume: URL(fileURLWithPath: "/")) else {
            Issue.record("expected a DiskSample for the root volume")
            return
        }
        #expect(sample.total > 0, "total capacity must be positive")
        #expect(sample.availableImportant >= 0, "availableImportant must be non-negative")
        #expect(sample.availableImportant <= sample.total,
                "availableImportant cannot exceed total capacity")
    }

    @Test func bogusPathReturnsNil() {
        let metrics = DiskMetrics()
        let bogus = URL(fileURLWithPath: "/this/path/does/not/exist/xyz-\(Int.random(in: 1000...9999))")
        #expect(metrics.sample(volume: bogus) == nil, "a non-existent path must return nil")
    }
}
