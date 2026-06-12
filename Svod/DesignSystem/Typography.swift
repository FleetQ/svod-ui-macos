import SwiftUI

// MARK: - Typography
//
// SF Pro for UI, SF Mono for editor/code/diff. Long-form text targets ~1.5
// line-height. All styles are relative so Dynamic Type continues to scale them.

public enum Typography {

    // UI scale (SF Pro, via system font with relative Dynamic Type sizing)
    public static var largeTitle: Font { .system(.largeTitle, design: .default).weight(.semibold) }
    public static var title:      Font { .system(.title2, design: .default).weight(.semibold) }
    public static var title3:     Font { .system(.title3, design: .default).weight(.semibold) }
    public static var headline:   Font { .system(.headline, design: .default) }
    public static var body:       Font { .system(.body, design: .default) }
    public static var callout:    Font { .system(.callout, design: .default) }
    public static var subheadline:Font { .system(.subheadline, design: .default) }
    public static var footnote:   Font { .system(.footnote, design: .default) }
    public static var caption:    Font { .system(.caption, design: .default) }
    public static var caption2:   Font { .system(.caption2, design: .default) }

    // Editor / code scale (SF Mono)
    public static var editor:     Font { .system(.body, design: .monospaced) }
    public static var editorSmall:Font { .system(.callout, design: .monospaced) }
    public static var code:       Font { .system(.callout, design: .monospaced) }
    public static var codeSmall:  Font { .system(.caption, design: .monospaced) }

    // Long-form line spacing. SwiftUI `lineSpacing` is *extra* leading on top of
    // the font's natural line height; ~0.5x the point size approximates 1.5 lh.
    public static let bodyLineSpacing: CGFloat = 7
    public static let editorLineSpacing: CGFloat = 6
}

public extension View {
    /// Long-form reading: comfortable leading + primary text color.
    func readingText() -> some View {
        self.font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
            .foregroundStyle(ThemeColor.textPrimary)
    }
}
