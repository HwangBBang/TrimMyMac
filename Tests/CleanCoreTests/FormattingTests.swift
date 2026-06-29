import Testing
@testable import CleanCore

@Suite("Formatting")
struct FormattingTests {

    // MARK: - humanReadableBytes (Int64)

    @Test func bytesUnderOneKilobyteShowsRawBytes() {
        #expect(humanReadableBytes(Int64(0)) == "0 B")
        #expect(humanReadableBytes(Int64(1)) == "1 B")
        #expect(humanReadableBytes(Int64(1023)) == "1023 B")
    }

    @Test func exactKilobyteHasNoDecimal() {
        // rounding rule: round to 1 decimal place, then drop a trailing ".0"
        #expect(humanReadableBytes(Int64(1024)) == "1 KB")
    }

    @Test func fractionalKilobyteKeepsOneDecimal() {
        // 1536 / 1024 == 1.5
        #expect(humanReadableBytes(Int64(1536)) == "1.5 KB")
    }

    @Test func roundingToOneDecimal() {
        // 1126 / 1024 = 1.0996... -> rounds to 1.1
        #expect(humanReadableBytes(Int64(1126)) == "1.1 KB")
        // 1075 / 1024 = 1.0498... -> rounds to 1.0 -> "1 KB"
        #expect(humanReadableBytes(Int64(1075)) == "1 KB")
    }

    @Test func largerUnitsClimb() {
        #expect(humanReadableBytes(Int64(1024 * 1024)) == "1 MB")
        #expect(humanReadableBytes(Int64(1024 * 1024 * 1024)) == "1 GB")
        // 1.5 GB
        let oneAndHalfGB = Int64(1024 * 1024 * 1024) + Int64(512 * 1024 * 1024)
        #expect(humanReadableBytes(oneAndHalfGB) == "1.5 GB")
    }

    // MARK: - Negative inputs

    @Test func negativeBytesBelowOneKilobyte() {
        // magnitude 1 < 1024 → raw byte path, prepend "-"
        #expect(humanReadableBytes(Int64(-1)) == "-1 B")
    }

    @Test func negativeKilobytes() {
        // -1536 → magnitude 1536, 1536/1024 = 1.5 → "-1.5 KB"
        #expect(humanReadableBytes(Int64(-1536)) == "-1.5 KB")
    }

    // MARK: - KB→MB boundary

    @Test func justBelowOneMegabyte() {
        // 1 048 575 B → 1023.999… KB, rounds (at 1 decimal) to 1024.0 KB → "1024 KB"
        #expect(humanReadableBytes(Int64(1024 * 1024 - 1)) == "1024 KB")
    }

    @Test func exactlyOneMegabyte() {
        // 1 048 576 B → loops twice (÷1024 → KB, ÷1024 → MB) → "1 MB"
        #expect(humanReadableBytes(Int64(1024 * 1024)) == "1 MB")
    }

    // MARK: - humanReadableBytes (UInt64)

    @Test func unsignedOverloadMatchesSigned() {
        #expect(humanReadableBytes(UInt64(1536)) == "1.5 KB")
        #expect(humanReadableBytes(UInt64(1024)) == "1 KB")
    }

    // MARK: - memoryUsagePercent

    @Test func memoryUsagePercentBasicCases() {
        #expect(memoryUsagePercent(used: 0, total: 100) == 0)
        #expect(memoryUsagePercent(used: 50, total: 100) == 50)
        #expect(memoryUsagePercent(used: 100, total: 100) == 100)
    }

    @Test func memoryUsagePercentRoundsToNearestInt() {
        // 1/3 = 0.3333... -> rounds to 33
        #expect(memoryUsagePercent(used: 1, total: 3) == 33)
    }

    @Test func memoryUsagePercentDivideByZeroReturnsZero() {
        #expect(memoryUsagePercent(used: 10, total: 0) == 0)
    }
}
