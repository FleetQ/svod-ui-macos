import SwiftUI
import AppKit

/// Resolve a SwiftUI `Color` to a concrete sRGB `NSColor` for the AppKit text
/// system / WebKit bridging (snapshot backgrounds, web-editor theming).
func nsColor(_ color: Color) -> NSColor {
    NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
}
