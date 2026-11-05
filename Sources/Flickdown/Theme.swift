import AppKit

/// The app's colours, shared by the native views and the preview page.
/// Keep these in step with the `:root` variables in web/index.html.
@MainActor
enum Theme {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x1E1F22)
    static let sidebar = dynamic(light: 0xF6F8FA, dark: 0x191A1D)
    static let text = dynamic(light: 0x1F2328, dark: 0xE4E6EA)
    static let muted = dynamic(light: 0x59636E, dark: 0x9BA3AE)
    static let border = dynamic(light: 0xD1D9E0, dark: 0x3D4148)
    /// Links, and Markdown markers (`#`, list bullets, `>`) in the editor.
    static let accent = dynamic(light: 0x0969DA, dark: 0x58A6FF)

    // Markdown source colouring in the editor.
    static let code = dynamic(light: 0x8250DF, dark: 0xD2A8FF)
    static let htmlTag = dynamic(light: 0x1A7F37, dark: 0x7EE787)
    static let syntaxPunctuation = dynamic(light: 0x8C959F, dark: 0x6E7681)

    private nonisolated static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private nonisolated static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
