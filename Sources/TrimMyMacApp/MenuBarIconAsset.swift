import AppKit

/// Custom menu-bar glyph (squeegee), embedded as a base64 PNG so no SPM
/// resource bundle is needed. Rendered as a template image so it adopts the
/// menu bar's light/dark tint automatically. Solid silhouette: reads crisply
/// at 16-18pt where the thin-outline version turned to mud.
enum MenuBarIcon {
    /// Template NSImage of the app glyph. `isTemplate = true` -> menu-bar tinted.
    static func image(size: CGFloat = 18) -> NSImage {
        guard let data = Data(base64Encoded: base64PNG, options: .ignoreUnknownCharacters),
              let img = NSImage(data: data) else { return NSImage() }
        img.isTemplate = true
        img.size = NSSize(width: size, height: size)
        return img
    }

    private static let base64PNG = "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"
}
