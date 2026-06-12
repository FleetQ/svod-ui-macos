import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Parses unified-diff text into structured rows the diff views render. Pure,
// value-typed, and testable; no I/O. The engine returns unified diff text
// (`DiffResult.diff`); for a first commit the model renders the full revision
// as all-added (see ParsedDiff.allAdded).
// ════════════════════════════════════════════════════════════════════════

/// One classified line from a unified diff.
struct DiffLine: Identifiable, Hashable {
    enum Kind: Hashable { case context, add, del, hunk, meta }
    let id = UUID()
    let kind: Kind
    let text: String          // line content WITHOUT the leading +/-/space marker
    let oldNumber: Int?       // 1-based line number on the "from" side (nil for adds/meta/hunk)
    let newNumber: Int?       // 1-based line number on the "to" side (nil for dels/meta/hunk)

    var color: Color {
        switch kind {
        case .add:  ThemeColor.diffAdd
        case .del:  ThemeColor.diffDel
        case .hunk: ThemeColor.diffHunk
        case .meta: ThemeColor.diffMeta
        case .context: ThemeColor.textPrimary
        }
    }
    var background: Color {
        switch kind {
        case .add: ThemeColor.diffAddBg
        case .del: ThemeColor.diffDelBg
        default:   .clear
        }
    }
    /// VoiceOver phrasing for this row.
    var accessibilityLabel: String {
        switch kind {
        case .add:     "added line \(newNumber.map(String.init) ?? ""): \(text)"
        case .del:     "removed line \(oldNumber.map(String.init) ?? ""): \(text)"
        case .hunk:    "section \(text)"
        case .meta:    "diff header"
        case .context: "unchanged line \(newNumber.map(String.init) ?? ""): \(text)"
        }
    }
}

/// One row in the side-by-side view: aligned old (left) and new (right) cells.
struct SideBySideRow: Identifiable, Hashable {
    let id = UUID()
    let left: DiffLine?       // nil = blank gutter (line added on the right)
    let right: DiffLine?      // nil = blank gutter (line removed on the left)
}

/// Structured result of parsing a unified diff.
struct ParsedDiff: Hashable {
    let lines: [DiffLine]             // flat, in document order (unified view)
    let rows: [SideBySideRow]         // aligned pairs (side-by-side view)
    let addCount: Int
    let delCount: Int
    /// Empty means the diff carried no textual change.
    var isEmpty: Bool { lines.allSatisfy { $0.kind == .meta || $0.kind == .hunk } }

    /// Parse unified-diff text. Meta/hunk headers are kept so the surface can show
    /// section markers, but they don't participate in side-by-side alignment.
    static func parse(_ raw: String) -> ParsedDiff {
        var lines: [DiffLine] = []
        var oldNo = 0
        var newNo = 0

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                (oldNo, newNo) = hunkStarts(line) ?? (oldNo, newNo)
                lines.append(DiffLine(kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ")
                        || line.hasPrefix("+++") || line.hasPrefix("---")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                        || line.hasPrefix("similarity ") || line.hasPrefix("rename ") {
                lines.append(DiffLine(kind: .meta, text: line, oldNumber: nil, newNumber: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .add, text: String(line.dropFirst()), oldNumber: nil, newNumber: newNo))
                newNo += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .del, text: String(line.dropFirst()), oldNumber: oldNo, newNumber: nil))
                oldNo += 1
            } else {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append(DiffLine(kind: .context, text: content, oldNumber: oldNo, newNumber: newNo))
                oldNo += 1; newNo += 1
            }
        }
        return ParsedDiff(lines: lines,
                          rows: align(lines),
                          addCount: lines.filter { $0.kind == .add }.count,
                          delCount: lines.filter { $0.kind == .del }.count)
    }

    /// Render a full file revision as an all-added diff (used when the engine can't
    /// diff a first commit and we fall back to the revision content).
    static func allAdded(_ content: String) -> ParsedDiff {
        var lines: [DiffLine] = []
        var n = 1
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(DiffLine(kind: .add, text: String(rawLine), oldNumber: nil, newNumber: n))
            n += 1
        }
        return ParsedDiff(lines: lines, rows: align(lines), addCount: lines.count, delCount: 0)
    }

    // Parse "@@ -a,b +c,d @@" → (a, c) one-based starts.
    private static func hunkStarts(_ header: String) -> (Int, Int)? {
        // header form: @@ -<oldStart>[,<oldLen>] +<newStart>[,<newLen>] @@ …
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func start(_ token: Substring, sign: Character) -> Int? {
            guard token.first == sign else { return nil }
            let body = token.dropFirst()
            let num = body.split(separator: ",").first ?? body
            return Int(num)
        }
        guard let o = start(parts[1], sign: "-"), let n = start(parts[2], sign: "+") else { return nil }
        return (o, n)
    }

    // Pair deletes with the following adds so equal-length edits sit on the same row;
    // remaining adds/dels fall through into half-empty rows. Context lines align 1:1.
    private static func align(_ lines: [DiffLine]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var pendingDels: [DiffLine] = []
        var pendingAdds: [DiffLine] = []

        func flush() {
            let count = Swift.max(pendingDels.count, pendingAdds.count)
            for i in 0..<count {
                rows.append(SideBySideRow(left: i < pendingDels.count ? pendingDels[i] : nil,
                                          right: i < pendingAdds.count ? pendingAdds[i] : nil))
            }
            pendingDels.removeAll(keepingCapacity: true)
            pendingAdds.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.kind {
            case .meta, .hunk:
                flush()
                rows.append(SideBySideRow(left: line, right: line))   // span both columns
            case .del:
                pendingDels.append(line)
            case .add:
                pendingAdds.append(line)
            case .context:
                flush()
                rows.append(SideBySideRow(left: line, right: line))
            }
        }
        flush()
        return rows
    }
}
