import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 2 — Search & ⌘K Command Palette
// ════════════════════════════════════════════════════════════════════════

// MARK: - SnippetText
//
// Renders a search snippet, turning `**matched terms**` (the engine wraps matched
// keywords in markdown bold) into accent-tinted highlights. We parse the markers
// by hand rather than via AttributedString(markdown:) so an unbalanced `**` from
// the engine degrades to plain text instead of throwing.

struct SnippetText: View {
    let snippet: String

    var body: some View {
        Self.attributed(snippet)
            .font(Typography.callout)
            .foregroundStyle(ThemeColor.textSecondary)
            .lineLimit(2)
            .accessibilityLabel(Self.plain(snippet))
    }

    /// Build an `AttributedString` where `**…**` spans carry the accent color and
    /// semibold weight. Unpaired markers fall through as literal text.
    static func attributed(_ s: String) -> Text {
        var result = Text("")
        var bold = false
        for segment in s.components(separatedBy: "**") {
            guard !segment.isEmpty else { bold.toggle(); continue }
            let piece = bold
                ? Text(segment).foregroundStyle(ThemeColor.accent).fontWeight(.semibold)
                : Text(segment)
            result = result + piece
            bold.toggle()
        }
        return result
    }

    /// Marker-stripped text for VoiceOver.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }
}

#Preview("SnippetText") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        SnippetText(snippet: "Serialize through the **write-actor**. Atomic tmp → fsync → rename.")
        SnippetText(snippet: "BM25 is the guaranteed baseline; **semantics** are opt-in.")
        SnippetText(snippet: "No markers here at all, just plain prose.")
    }
    .padding(Spacing.lg)
    .frame(width: 480)
    .background(ThemeColor.surface)
}
