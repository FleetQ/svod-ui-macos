import AppKit

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════
//
// Real, aligned table rendering for the live editor WITHOUT touching the source.
//
// The highlighter tags each source line of a markdown table with a `.svodTableLine`
// attribute (carrying the parsed table + block range). `TableLayoutManager` then:
//   • nulls the raw glyphs of those lines so the pipes/dashes don't show,
//   • reserves the grid's height on the block's FIRST line and collapses the rest
//     to zero height (so the drawn grid occupies exactly the right space),
//   • draws an aligned, bordered grid in that reserved rect,
//   • EXCEPT the block the caret is in, which is "revealed" as raw editable text.
// The NSTextStorage / `text` binding are never modified — the file round-trips.

extension NSAttributedString.Key {
    static let svodTableLine = NSAttributedString.Key("svodTableLine")
}

final class TableLineInfo: NSObject {
    let table: MarkdownTable
    let blockId: Int
    let blockRange: NSRange
    let isFirstLine: Bool
    init(table: MarkdownTable, blockId: Int, blockRange: NSRange, isFirstLine: Bool) {
        self.table = table; self.blockId = blockId; self.blockRange = blockRange; self.isFirstLine = isFirstLine
    }
}

// MARK: - Parsed model

struct MarkdownTable {
    enum Align { case left, right, center }
    var columns: Int
    var aligns: [Align]
    var rows: [[String]]          // row 0 = header; separator dropped; cells are display strings

    static func parse(_ lines: [String]) -> MarkdownTable? {
        guard lines.count >= 2 else { return nil }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        guard sep.contains("-"), sep.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { display($0.trimmingCharacters(in: .whitespaces)) }
        }
        let aligns: [Align] = sep.split(separator: "|", omittingEmptySubsequences: true).map {
            let t = $0.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(":"), t.hasSuffix(":") { return .center }
            if t.hasSuffix(":") { return .right }
            return .left
        }
        var rows = [cells(lines[0])]
        for line in lines.dropFirst(2) where line.contains("|") { rows.append(cells(line)) }
        let cols = max(rows.map(\.count).max() ?? 0, aligns.count)
        return MarkdownTable(columns: cols,
                             aligns: (0..<cols).map { $0 < aligns.count ? aligns[$0] : .left },
                             rows: rows)
    }

    /// `[[target|alias]]`→alias, `[[note]]`→note, `[text](url)`→text.
    private static func display(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[^|]*\|"#, with: "", options: .regularExpression)      // alias
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Layout manager

final class TableLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Block char range currently revealed (caret inside) — drawn as raw text.
    private(set) var revealedBlock: NSRange?

    private let padH: CGFloat = 10
    private let padV: CGFloat = 5
    private var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    private var headFont: NSFont { NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold) }
    private var rowHeight: CGFloat { ceil(bodyFont.boundingRectForFont.height) + padV * 2 }
    private func gridHeight(_ t: MarkdownTable) -> CGFloat { CGFloat(t.rows.count) * rowHeight }

    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func setRevealed(_ block: NSRange?) {
        guard block?.location != revealedBlock?.location || block?.length != revealedBlock?.length else { return }
        let affected = [revealedBlock, block].compactMap { $0 }
        revealedBlock = block
        for r in affected where r.location + r.length <= (textStorage?.length ?? 0) {
            invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        }
    }

    private func info(at charIndex: Int) -> TableLineInfo? {
        guard let storage = textStorage, charIndex < storage.length else { return nil }
        return storage.attribute(.svodTableLine, at: charIndex, effectiveRange: nil) as? TableLineInfo
    }
    private func isRevealed(_ info: TableLineInfo) -> Bool {
        guard let rev = revealedBlock else { return false }
        return NSIntersectionRange(rev, info.blockRange).length > 0
    }

    // Hide raw table glyphs (keep newlines so line structure survives).
    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else {
            setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return glyphRange.length
        }
        let str = storage.string as NSString
        let out = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { out.deallocate() }
        for i in 0..<glyphRange.length {
            var p = props[i]
            let ci = characterIndexes[i]
            if let inf = info(at: ci), !isRevealed(inf), str.character(at: ci) != 0x0A {
                p.insert(.null)
            }
            out[i] = p
        }
        setGlyphs(glyphs, properties: out, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // Reserve grid height on the block's first line; collapse the rest to zero.
    func layoutManager(_ lm: NSLayoutManager,
                       shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect usedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in container: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        let ci = characterIndexForGlyph(at: glyphRange.location)
        guard let inf = info(at: ci), !isRevealed(inf) else { return false }
        if inf.isFirstLine {
            let h = gridHeight(inf.table)
            rect.pointee.size.height = h
            usedRect.pointee.size.height = h
            return true
        } else {
            rect.pointee.size.height = 0
            usedRect.pointee.size.height = 0
            return true
        }
    }

    // Draw the grid over each non-revealed block's reserved first-line rect.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var drawn = Set<Int>()
        storage.enumerateAttribute(.svodTableLine, in: charRange) { value, _, _ in
            guard let inf = value as? TableLineInfo, !isRevealed(inf), !drawn.contains(inf.blockId) else { return }
            drawn.insert(inf.blockId)
            drawTable(inf, origin: origin)
        }
    }

    private func drawTable(_ inf: TableLineInfo, origin: NSPoint) {
        let firstGlyph = glyphIndexForCharacter(at: inf.blockRange.location)
        let frag = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let t = inf.table
        // column widths from display cells
        var colW = [CGFloat](repeating: 0, count: t.columns)
        for (ri, row) in t.rows.enumerated() {
            let f = ri == 0 ? headFont : bodyFont
            for c in 0..<t.columns where c < row.count {
                colW[c] = max(colW[c], (row[c] as NSString).size(withAttributes: [.font: f]).width + padH * 2)
            }
        }
        let border = nsColor(ThemeColor.borderSubtle)
        let headerBg = nsColor(ThemeColor.surfaceRaised)
        let tableW = colW.reduce(0, +)
        var y = frag.minY + origin.y
        let x0 = frag.minX + origin.x
        for (ri, row) in t.rows.enumerated() {
            let isHeader = ri == 0
            let rowRect = NSRect(x: x0, y: y, width: tableW, height: rowHeight)
            if isHeader { headerBg.setFill(); rowRect.fill() }
            var x = x0
            for c in 0..<t.columns {
                let w = colW[c]
                border.setStroke(); NSBezierPath(rect: NSRect(x: x, y: y, width: w, height: rowHeight)).stroke()
                let text = (c < row.count ? row[c] : "") as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isHeader ? headFont : bodyFont,
                    .foregroundColor: nsColor(isHeader ? ThemeColor.textPrimary : ThemeColor.textSecondary),
                ]
                let sz = text.size(withAttributes: attrs)
                var tx = x + padH
                switch t.aligns[c] {
                case .right:  tx = x + w - padH - sz.width
                case .center: tx = x + (w - sz.width) / 2
                case .left:   break
                }
                text.draw(at: NSPoint(x: tx, y: y + (rowHeight - sz.height) / 2), withAttributes: attrs)
                x += w
            }
            y += rowHeight
        }
    }
}
