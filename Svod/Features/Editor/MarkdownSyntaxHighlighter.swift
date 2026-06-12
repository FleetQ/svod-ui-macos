import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - MarkdownSyntaxHighlighter
//
// Applies live inline styling to an NSTextStorage as the user types — single
// surface, no split preview. Markup characters stay visible (this is an editor,
// not a renderer) but are dimmed; the styled text reads as formatted prose.
// Link styling consults a resolver so [[wikilinks]] colour by resolution.

struct MarkdownSyntaxHighlighter {

    /// Resolution lookup for `[[target]]` — true == resolves to a real note.
    var isResolved: (String) -> Bool = { _ in true }

    // Base metrics (resolved once; Dynamic Type handled by the SwiftUI font the
    // representable seeds, but inside NSTextView we work with NSFont).
    let baseFont: NSFont
    let monoFont: NSFont

    init(isResolved: @escaping (String) -> Bool = { _ in true }) {
        self.isResolved = isResolved
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        self.baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.monoFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // Theme colors resolved to NSColor for the text system.
    private let cText         = nsColor(ThemeColor.textPrimary)
    private let cFaint        = nsColor(ThemeColor.textTertiary)
    private let cSecondary    = nsColor(ThemeColor.textSecondary)
    private let cAccent       = nsColor(ThemeColor.accent)
    private let cLink         = nsColor(ThemeColor.link)
    private let cLinkBad      = nsColor(ThemeColor.linkUnresolved)
    private let cLinkCross    = nsColor(ThemeColor.accentMuted)   // cross-vault [[vault:note]]
    private let cCodeBg       = nsColor(ThemeColor.surfaceHover)
    private let cCode         = nsColor(ThemeColor.accent)

    // MARK: entry point — restyle the whole storage
    func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string

        storage.beginEditing()
        // baseline
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: cText,
        ], range: full)

        styleHeadings(storage, text)
        styleFencedCode(storage, text)
        styleBlockquotes(storage, text)
        styleTables(storage, text)
        styleLists(storage, text)
        styleInlineCode(storage, text)
        styleEmphasis(storage, text)
        styleWikilinks(storage, text)
        storage.endEditing()
    }

    // MARK: headings  — `# …` through `###### …`
    private func styleHeadings(_ s: NSTextStorage, _ text: String) {
        enumerateLines(text) { line, range in
            guard let hashes = line.leadingHashes, hashes >= 1, hashes <= 6 else { return }
            let level = hashes
            let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
            let scale: CGFloat = [0: 1.0, 1: 1.6, 2: 1.4, 3: 1.22, 4: 1.1, 5: 1.0, 6: 1.0][level] ?? 1.0
            let f = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * scale, weight: weight)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: cText, range: range)
            // dim the `### ` marker
            let markerLen = level + 1
            if range.length >= markerLen {
                s.addAttribute(.foregroundColor, value: cFaint,
                               range: NSRange(location: range.location, length: markerLen))
            }
        }
    }

    // MARK: fenced code  ``` … ```
    private func styleFencedCode(_ s: NSTextStorage, _ text: String) {
        applyRegex("(?m)^```[^\\n]*\\n([\\s\\S]*?)^```", to: text) { m in
            let block = m.range(at: 0)
            s.addAttribute(.font, value: monoFont, range: block)
            s.addAttribute(.foregroundColor, value: cSecondary, range: block)
            s.addAttribute(.backgroundColor, value: cCodeBg, range: block)
        }
    }

    // MARK: blockquotes  `> …`
    private func styleBlockquotes(_ s: NSTextStorage, _ text: String) {
        enumerateLines(text) { line, range in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix(">") else { return }
            s.addAttribute(.foregroundColor, value: cSecondary, range: range)
            if let qr = line.range(of: ">") {
                let off = line.distance(from: line.startIndex, to: qr.lowerBound)
                s.addAttribute(.foregroundColor, value: cAccent,
                               range: NSRange(location: range.location + off, length: 1))
            }
        }
    }

    // MARK: tables  — lines containing `|`
    private func styleTables(_ s: NSTextStorage, _ text: String) {
        enumerateLines(text) { line, range in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|") || (t.contains("|") && t.contains("---")) else { return }
            s.addAttribute(.font, value: monoFont, range: range)
            // separator row → faint
            if t.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces).isEmpty {
                s.addAttribute(.foregroundColor, value: cFaint, range: range)
            }
        }
    }

    // MARK: lists  — `- `, `* `, `1. `
    private func styleLists(_ s: NSTextStorage, _ text: String) {
        enumerateLines(text) { line, range in
            let t = line.drop { $0 == " " || $0 == "\t" }
            let indent = line.count - t.count
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                s.addAttribute(.foregroundColor, value: cAccent,
                               range: NSRange(location: range.location + indent, length: 1))
            } else if let dot = t.firstIndex(of: "."),
                      t[t.startIndex..<dot].allSatisfy(\.isNumber),
                      t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
                let markerLen = t.distance(from: t.startIndex, to: dot) + 1
                s.addAttribute(.foregroundColor, value: cAccent,
                               range: NSRange(location: range.location + indent, length: markerLen))
            }
        }
    }

    // MARK: inline code  `code`
    private func styleInlineCode(_ s: NSTextStorage, _ text: String) {
        applyRegex("`[^`\\n]+`", to: text) { m in
            s.addAttribute(.foregroundColor, value: cCode, range: m.range)
            s.addAttribute(.backgroundColor, value: cCodeBg, range: m.range)
        }
    }

    // MARK: emphasis  **bold**, *italic*, _italic_
    private func styleEmphasis(_ s: NSTextStorage, _ text: String) {
        applyRegex("\\*\\*([^*\\n]+)\\*\\*", to: text) { m in
            applyTrait(.bold, to: s, content: m.range(at: 1), markers: m.range(at: 0), markerWidth: 2)
        }
        applyRegex("(?<!\\*)\\*(?!\\*)([^*\\n]+)\\*(?!\\*)", to: text) { m in
            applyTrait(.italic, to: s, content: m.range(at: 1), markers: m.range(at: 0), markerWidth: 1)
        }
        applyRegex("(?<!_)_(?!_)([^_\\n]+)_(?!_)", to: text) { m in
            applyTrait(.italic, to: s, content: m.range(at: 1), markers: m.range(at: 0), markerWidth: 1)
        }
    }

    private func applyTrait(_ trait: NSFontDescriptor.SymbolicTraits, to s: NSTextStorage,
                            content: NSRange, markers full: NSRange, markerWidth: Int) {
        guard content.location != NSNotFound else { return }
        let existing = (s.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont) ?? baseFont
        let desc = existing.fontDescriptor.withSymbolicTraits(existing.fontDescriptor.symbolicTraits.union(trait))
        if let f = NSFont(descriptor: desc, size: existing.pointSize) {
            s.addAttribute(.font, value: f, range: content)
        }
        // dim the markers (leading + trailing)
        s.addAttribute(.foregroundColor, value: cFaint,
                       range: NSRange(location: full.location, length: markerWidth))
        s.addAttribute(.foregroundColor, value: cFaint,
                       range: NSRange(location: full.location + full.length - markerWidth, length: markerWidth))
    }

    // MARK: wikilinks  [[target]]  and  [[vault:note]]  — coloring by kind + resolution
    private func styleWikilinks(_ s: NSTextStorage, _ text: String) {
        applyRegex("\\[\\[([^\\]\\n]+)\\]\\]", to: text) { m in
            let inner = (text as NSString).substring(with: m.range(at: 1))
            // strip an optional `|alias` for resolution
            let target = inner.split(separator: "|").first.map(String.init) ?? inner
            let trimmed = target.trimmingCharacters(in: .whitespaces)

            // Detect qualified [[vault:note]] links — they contain a colon and
            // GlobalNoteRef can parse them (non-nil means it IS cross-vault).
            let isCrossVault = GlobalNoteRef(globalId: trimmed) != nil
            let color: NSColor
            if isCrossVault {
                // Cross-vault: accentMuted — distinct from same-vault link but calm.
                color = cLinkCross
            } else {
                color = isResolved(trimmed) ? cLink : cLinkBad
            }
            s.addAttribute(.foregroundColor, value: color, range: m.range)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            // dim the `[[` `]]` brackets
            s.addAttribute(.foregroundColor, value: cFaint,
                           range: NSRange(location: m.range.location, length: 2))
            s.addAttribute(.foregroundColor, value: cFaint,
                           range: NSRange(location: m.range.location + m.range.length - 2, length: 2))
            // tag the inner range with the full target (vault:path preserved for cross-vault)
            s.addAttribute(.link, value: "svodwiki://\(trimmed)", range: m.range(at: 1))
        }
    }

    // MARK: helpers
    private func applyRegex(_ pattern: String, to text: String, _ body: (NSTextCheckingResult) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m { body(m) }
        }
    }

    private func enumerateLines(_ text: String, _ body: (Substring, NSRange) -> Void) {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            ranges.append(lineRange)
        }
        for lineRange in ranges {
            body(Substring(ns.substring(with: lineRange)), lineRange)
        }
    }
}

// MARK: - resolve a SwiftUI Color to a concrete NSColor for the text system
func nsColor(_ color: Color) -> NSColor {
    NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
}

private extension StringProtocol {
    /// Number of leading `#` if this line is an ATX heading (`#` followed by space).
    var leadingHashes: Int? {
        var n = 0
        var idx = startIndex
        while idx < endIndex, self[idx] == "#" { n += 1; idx = index(after: idx) }
        guard n >= 1, idx < endIndex, self[idx] == " " else { return nil }
        return n
    }
}
