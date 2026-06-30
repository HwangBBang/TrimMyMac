import Foundation

/// Path-based exclusion rules applied during scanning. A path is ignored if any
/// built-in default rule matches one of its components, or if any `extraGlobs`
/// entry matches (simple suffix `*.ext`, or an exact component name).
public struct IgnoreRules: Sendable {

    private let extraGlobs: [String]

    public init(extraGlobs: [String]) {
        self.extraGlobs = extraGlobs
    }

    /// Default rules: ignores node_modules, *.photoslibrary internals,
    /// com.apple.* cache bundle dirs, and .Trash.
    public static let `default` = IgnoreRules(extraGlobs: [])

    /// Returns `true` if the given URL should be excluded from scanning.
    public func shouldIgnore(_ url: URL) -> Bool {
        let components = url.pathComponents
        for component in components {
            if Self.matchesDefault(component) {
                return true
            }
        }
        for glob in extraGlobs {
            if Self.matches(glob: glob, components: components) {
                return true
            }
        }
        return false
    }

    // MARK: - Built-in default rules

    private static func matchesDefault(_ component: String) -> Bool {
        if component == "node_modules" { return true }
        if component == ".Trash" { return true }
        if component.hasSuffix(".photoslibrary") { return true }
        if component.hasPrefix("com.apple.") { return true }
        return false
    }

    // MARK: - extraGlobs

    private static func matches(glob: String, components: [String]) -> Bool {
        if glob.hasPrefix("*") {
            // Simple suffix match: "*.ext" -> any component ending in ".ext"
            let suffix = String(glob.dropFirst())
            guard !suffix.isEmpty else { return false }
            return components.contains { $0.hasSuffix(suffix) }
        }
        // Exact-component match
        return components.contains(glob)
    }
}
