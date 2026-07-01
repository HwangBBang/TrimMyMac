import Foundation

/// Current app version from CFBundleShortVersionString, or "?" when the key is absent.
func appVersionString() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}
