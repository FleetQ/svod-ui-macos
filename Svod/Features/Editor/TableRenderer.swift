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
    struct Cell { var display: String; var target: String? }   // target: "svodwiki://…" or "http(s)…"
    var columns: Int
    var aligns: [Align]
    var rows: [[Cell]]            // row 0 = header; separator dropped

    static func parse(_ lines: [String]) -> MarkdownTable? {
        guard lines.count >= 2 else { return nil }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        guard sep.contains("-"), sep.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let aligns: [Align] = splitPipes(sep).map {
            let t = $0.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(":"), t.hasSuffix(":") { return .center }
            if t.hasSuffix(":") { return .right }
            return .left
        }
        func cells(_ line: String) -> [Cell] {
            splitPipes(line).map { raw in
                let t = raw.trimmingCharacters(in: .whitespaces)
                return Cell(display: display(t), target: target(t))
            }
        }
        var rows = [cells(lines[0])]
        for line in lines.dropFirst(2) where line.contains("|") { rows.append(cells(line)) }
        let cols = max(rows.map(\.count).max() ?? 0, aligns.count)
        return MarkdownTable(columns: cols,
                             aligns: (0..<cols).map { $0 < aligns.count ? aligns[$0] : .left },
                             rows: rows)
    }

    /// Split a table row on `|`, ignoring pipes inside `[[ ]]` (wikilink aliases),
    /// inline code, and `\|` escapes. Trims the outer leading/trailing `|`.
    static func splitPipes(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        var out: [String] = []
        var cur = ""
        var wiki = false, code = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { cur.append(c); cur.append(chars[i + 1]); i += 2; continue }
            if !code, c == "[", i + 1 < chars.count, chars[i + 1] == "[" { wiki = true; cur += "[["; i += 2; continue }
            if !code, c == "]", i + 1 < chars.count, chars[i + 1] == "]" { wiki = false; cur += "]]"; i += 2; continue }
            if c == "`" { code.toggle(); cur.append(c); i += 1; continue }
            if c == "|", !wiki, !code { out.append(cur); cur = ""; i += 1; continue }
            cur.append(c); i += 1
        }
        out.append(cur)
        return out
    }

    /// `[[target|alias]]`→alias, `[[note]]`→note, `[text](url)`→text. Plain otherwise.
    private static func display(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[^|]*\|"#, with: "", options: .regularExpression)     // alias
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The click target of a cell: a wikilink → "svodwiki://<target>", a markdown
    /// link → its URL, else nil.
    private static func target(_ raw: String) -> String? {
        if let inner = firstGroup(#"\[\[([^\]]+)\]\]"#, raw) {
            let tgt = inner.split(separator: "|").first.map(String.init) ?? inner
            return "svodwiki://" + tgt.trimmingCharacters(in: .whitespaces)
        }
        if let url = firstGroup(#"\[[^\]]+\]\(([^)]+)\)"#, raw) { return url }
        return nil
    }
    private static func firstGroup(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
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

    private func columnWidths(_ t: MarkdownTable) -> [CGFloat] {
        var colW = [CGFloat](repeating: 0, count: t.columns)
        for (ri, row) in t.rows.enumerated() {
            let f = ri == 0 ? headFont : bodyFont
            for c in 0..<t.columns where c < row.count {
                colW[c] = max(colW[c], (row[c].display as NSString).size(withAttributes: [.font: f]).width + padH * 2)
            }
        }
        return colW
    }

    /// If `p` (in text-container coordinates) lands on a rendered grid cell that has a
    /// link, return its target ("svodwiki://…" or a URL). Used for click handling.
    func link(atContainerPoint p: NSPoint) -> String? {
        guard let storage = textStorage else { return nil }
        var found: String?
        storage.enumerateAttribute(.svodTableLine, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            guard let inf = v as? TableLineInfo, inf.isFirstLine, !isRevealed(inf) else { return }
            let frag = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: inf.blockRange.location), effectiveRange: nil)
            let t = inf.table
            let colW = columnWidths(t)
            let gridRect = NSRect(x: frag.minX, y: frag.minY, width: colW.reduce(0, +), height: rowHeight * CGFloat(t.rows.count))
            guard gridRect.contains(p) else { return }
            let rowIdx = min(t.rows.count - 1, max(0, Int((p.y - frag.minY) / rowHeight)))
            var x = frag.minX, colIdx = 0
            for (c, w) in colW.enumerated() { colIdx = c; if p.x < x + w { break }; x += w }
            let row = t.rows[rowIdx]
            if colIdx < row.count { found = row[colIdx].target }
            stop.pointee = true
        }
        return found
    }

    private func drawTable(_ inf: TableLineInfo, origin: NSPoint) {
        let firstGlyph = glyphIndexForCharacter(at: inf.blockRange.location)
        let frag = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let t = inf.table
        // column widths from display cells
        let colW = columnWidths(t)
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
                let cell = c < row.count ? row[c] : MarkdownTable.Cell(display: "", target: nil)
                let text = cell.display as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isHeader ? headFont : bodyFont,
                    .foregroundColor: nsColor(isHeader ? ThemeColor.textPrimary
                                              : (cell.target != nil ? ThemeColor.link : ThemeColor.textSecondary)),
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
