import SwiftUI

// MARK: - Theme namespace
//
// Svod's design language: calm, archival-yet-modern, content-first, dark-first.
// One accent, semantic colors for the engine's domain (conflict / sync / agent),
// an 8pt spatial grid, a typographic scale tuned for long-form reading, and a
// small set of motion springs so live engine updates settle in gently.
//
// Everything is a token. Feature code must reference `Theme.*` rather than raw
// Color/CGFloat literals so the whole surface stays coherent and themeable.

public enum Theme {
    public typealias Palette = ThemeColor
    public typealias Space = Spacing
    public typealias Typo = Typography
    public typealias Radius = Radii
    public typealias Move = Motion
}
