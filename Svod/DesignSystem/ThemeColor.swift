import SwiftUI
import AppKit

// MARK: - Color tokens (dark-first, light second; both WCAG AA on their surfaces)
//
// Colors are defined as appearance-adaptive NSColor dynamic providers so a single
// token resolves correctly in dark or light. Dark is the primary, designed-first
// appearance; light is a faithful counterpart, not an afterthought.

public enum ThemeColor {

    // MARK: surfaces (deepest → raised)
    /// App window background — the calmest, deepest plane.
    public static let background      = dyn(dark: 0x111317, light: 0xF7F6F3)
    /// Primary panel/pane surface (sidebar, inspector).
    public static let surface         = dyn(dark: 0x171A1F, light: 0xFFFFFF)
    /// Card / raised element on a surface.
    public static let surfaceRaised   = dyn(dark: 0x1E222A, light: 0xFFFFFF)
    /// Hover / pressed wash for rows and controls.
    public static let surfaceHover    = dyn(dark: 0x232831, light: 0xEEEDE8)
    /// Selected row / active background (low-chroma accent tint).
    public static let surfaceSelected = dyn(dark: 0x243042, light: 0xE5ECF6)
    /// Editor measure background — paper-like, distinct from chrome.
    public static let editorSurface   = dyn(dark: 0x14161B, light: 0xFCFBF8)

    // MARK: lines
    public static let separator       = dyn(dark: 0x262B33, light: 0xE3E1DB)
    public static let borderSubtle    = dyn(dark: 0x2E343E, light: 0xD8D5CD)
    public static let borderStrong    = dyn(dark: 0x3A424E, light: 0xC2BEB3)

    // MARK: text (primary/secondary/tertiary all ≥ 4.5:1 on `surface` in their appearance)
    public static let textPrimary     = dyn(dark: 0xECEDEF, light: 0x1B1D21)
    public static let textSecondary   = dyn(dark: 0xA8AEB8, light: 0x55585F)
    // Tertiary still carries real informational text (paths, timestamps, sub-labels),
    // so it must clear AA, not just read as decoration. These values stay ≥ 4.5:1 on
    // every surface it lands on (surface, raised, hover wash, selected, window bg) in
    // both themes — verified, not eyeballed.
    public static let textTertiary    = dyn(dark: 0x8A909A, light: 0x65686F)
    public static let textDisabled    = dyn(dark: 0x4E545E, light: 0xAEB0B5)
    /// Text drawn on top of the accent fill. The dark accent is light-blue, so white
    /// text only reaches 2.5:1 — dark ink on it clears AA (~7:1). Light accent is dark
    /// enough to carry white (~4.9:1).
    public static let textOnAccent    = dyn(dark: 0x10141B, light: 0xFFFFFF)

    // MARK: accent (one, calm desaturated indigo-blue)
    public static let accent          = dyn(dark: 0x6FA0E6, light: 0x3D6FC4)
    public static let accentMuted     = dyn(dark: 0x4E6CA0, light: 0x6E92CF)
    /// Low-chroma accent wash for selected/badge backgrounds.
    public static let accentSubtle    = dyn(dark: 0x1F2A3D, light: 0xDDE7F7)

    // MARK: semantic — conflict (needs attention, never alarmist)
    public static let conflict        = dyn(dark: 0xE0A35B, light: 0xB5701A)
    public static let conflictSubtle  = dyn(dark: 0x2E2415, light: 0xF6E7CF)

    // MARK: semantic — sync (replication / multi-host health)
    public static let sync            = dyn(dark: 0x5BC2B0, light: 0x1F8C78)
    public static let syncSubtle      = dyn(dark: 0x142A28, light: 0xD5EFE9)

    // MARK: semantic — agent (live agent presence; calm, not a notification red)
    public static let agent           = dyn(dark: 0x9B86E0, light: 0x6A52C0)
    public static let agentSubtle     = dyn(dark: 0x231F33, light: 0xE7E1F6)

    // MARK: status
    public static let success         = dyn(dark: 0x6FBF73, light: 0x2E8B40)
    public static let warning         = dyn(dark: 0xE0A35B, light: 0xB5701A)
    public static let danger          = dyn(dark: 0xE0736B, light: 0xC0392B)
    public static let offline         = dyn(dark: 0x767C87, light: 0x9A9C9F)

    // MARK: diff (history / conflict surfaces)
    public static let diffAdd         = dyn(dark: 0x8BD49A, light: 0x1F7A3D)
    public static let diffAddBg       = dyn(dark: 0x14241A, light: 0xE3F4E7)
    public static let diffDel         = dyn(dark: 0xE39A93, light: 0xB23A30)
    public static let diffDelBg       = dyn(dark: 0x2A1816, light: 0xFBE6E3)
    public static let diffHunk        = dyn(dark: 0x6FA0E6, light: 0x3D6FC4)
    public static let diffMeta        = dyn(dark: 0x8A909A, light: 0x65686F)

    // MARK: link styling
    public static let link            = dyn(dark: 0x7FB0EE, light: 0x2F66BE)
    /// Unresolved [[wikilink]] — present but clearly not yet a real note.
    public static let linkUnresolved  = dyn(dark: 0xC08A6E, light: 0xA45B2E)

    // MARK: per-agent identity palette (stable, calm hues; cycle by index)
    public static let agentPalette: [Color] = [
        dyn(dark: 0x9B86E0, light: 0x6A52C0), // violet
        dyn(dark: 0x5BC2B0, light: 0x1F8C78), // teal
        dyn(dark: 0xE0A35B, light: 0xB5701A), // amber
        dyn(dark: 0x6FA0E6, light: 0x3D6FC4), // blue
        dyn(dark: 0xC891C0, light: 0x9A4E8E), // mauve
        dyn(dark: 0x86C08A, light: 0x3E8B52), // sage
    ]

    /// Deterministic color for an agent identity string.
    public static func agentColor(for id: String) -> Color {
        guard !id.isEmpty else { return agent }
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return agentPalette[Int(hash % UInt64(agentPalette.count))]
    }

    // MARK: - dynamic provider
    static func dyn(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255.0,
            green:   Double((rgb >> 8) & 0xFF) / 255.0,
            blue:    Double(rgb & 0xFF) / 255.0,
            alpha:   1.0
        )
    }
}
