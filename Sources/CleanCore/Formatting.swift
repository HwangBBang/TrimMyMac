import Foundation

/// Human-readable byte string with a fixed rounding rule:
/// values < 1024 are shown as raw bytes ("0 B", "1023 B"); otherwise the value
/// is divided by 1024 until it is < 1024 (or the largest unit is reached), then
/// rounded to ONE decimal place. A trailing ".0" is dropped ("1 KB", not "1.0 KB").
public func humanReadableBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    let negative = bytes < 0
    let magnitude: UInt64 = bytes == Int64.min
        ? UInt64(Int64.max) + 1
        : UInt64(abs(bytes))

    if magnitude < 1024 {
        return "\(negative ? "-" : "")\(magnitude) B"
    }

    var value = Double(magnitude)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }

    // Round to one decimal place, then drop trailing ".0".
    let rounded = (value * 10).rounded() / 10
    let sign = negative ? "-" : ""
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
        return "\(sign)\(Int(rounded)) \(units[unitIndex])"
    } else {
        return "\(sign)" + String(format: "%.1f", rounded) + " \(units[unitIndex])"
    }
}

/// Unsigned convenience overload (memory sizes are UInt64 in the contract).
public func humanReadableBytes(_ bytes: UInt64) -> String {
    let clamped: Int64 = bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
    return humanReadableBytes(clamped)
}

/// Memory usage as a whole-number percent, rounded to nearest. Returns 0 if total == 0.
public func memoryUsagePercent(used: UInt64, total: UInt64) -> Int {
    guard total > 0 else { return 0 }
    let fraction = Double(used) / Double(total)
    return Int((fraction * 100).rounded())
}
