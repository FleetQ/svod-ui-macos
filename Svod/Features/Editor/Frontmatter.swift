import Foundation

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - Frontmatter
//
// A leading `---` … `---` YAML block. We parse it into ordered key/value rows
// (a deliberately small subset: scalars + flow/block sequences) so the panel can
// render typed rows, and serialize back so an edit round-trips without disturbing
// the markdown body or untouched keys. Unknown / nested structures fall back to
// their verbatim source so we never lose data.

struct Frontmatter: Equatable {

    enum Value: Equatable {
        case scalar(String)        // title, status, a date…
        case list([String])        // tags, aliases…

        var isList: Bool { if case .list = self { return true } else { return false } }
    }

    /// One key in source order. `rawLines` is the verbatim source for this entry,
    /// used when we can't model the value (nested map, multiline) — re-emitted as-is.
    struct Entry: Equatable {
        var key: String
        var value: Value
        var modeled: Bool          // false → re-emit rawLines untouched
        var rawLines: [String]
    }

    var entries: [Entry]

    subscript(_ key: String) -> Value? {
        get { entries.first(where: { $0.key == key })?.value }
    }

    // MARK: split note into (frontmatter source, body)
    //
    // Returns nil frontmatter when the note doesn't open with a `---` fence.
    static func split(_ text: String) -> (frontmatter: String?, body: String) {
        guard text.hasPrefix("---") else { return (nil, text) }
        let lines = text.components(separatedBy: "\n")
        // first line must be exactly `---` (allow trailing whitespace)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, text) }
        // find the closing fence
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                let fmLines = Array(lines[1..<i])
                let bodyLines = Array(lines[(i + 1)...])
                return (fmLines.joined(separator: "\n"), bodyLines.joined(separator: "\n"))
            }
        }
        return (nil, text)   // unterminated → treat whole thing as body
    }

    // MARK: parse the frontmatter source (without the fences)
    static func parse(_ source: String) -> Frontmatter {
        var entries: [Entry] = []
        let lines = source.isEmpty ? [] : source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // a top-level `key:` (no leading whitespace, contains a colon)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else {
                // stray line (comment, blank) — attach as an unmodeled passthrough entry
                entries.append(Entry(key: "", value: .scalar(line), modeled: false, rawLines: [line]))
                i += 1
                continue
            }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let after = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if after.isEmpty {
                // could be a block sequence:  key:\n  - a\n  - b
                var seq: [String] = []
                var raw = [line]
                var j = i + 1
                while j < lines.count, lines[j].hasPrefix(" ") || lines[j].hasPrefix("\t") {
                    let item = lines[j].trimmingCharacters(in: .whitespaces)
                    raw.append(lines[j])
                    if item.hasPrefix("-") {
                        seq.append(String(item.dropFirst()).trimmingCharacters(in: .whitespaces).strippedQuotes)
                    }
                    j += 1
                }
                if seq.isEmpty {
                    entries.append(Entry(key: key, value: .scalar(""), modeled: true, rawLines: [line]))
                    i += 1
                } else {
                    entries.append(Entry(key: key, value: .list(seq), modeled: true, rawLines: raw))
                    i = j
                }
            } else if after.hasPrefix("[") && after.hasSuffix("]") {
                // flow sequence:  tags: [a, b, c]
                let inner = String(after.dropFirst().dropLast())
                let items = inner.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).strippedQuotes }
                    .filter { !$0.isEmpty }
                entries.append(Entry(key: key, value: .list(items), modeled: true, rawLines: [line]))
                i += 1
            } else {
                entries.append(Entry(key: key, value: .scalar(after.strippedQuotes), modeled: true, rawLines: [line]))
                i += 1
            }
        }
        return Frontmatter(entries: entries)
    }

    // MARK: serialize back to source (without fences)
    func serialized() -> String {
        var out: [String] = []
        for e in entries {
            guard e.modeled else { out.append(contentsOf: e.rawLines); continue }
            switch e.value {
            case .scalar(let s):
                out.append("\(e.key): \(s.yamlScalar)")
            case .list(let items):
                if items.isEmpty {
                    out.append("\(e.key): []")
                } else {
                    out.append("\(e.key): [\(items.map { $0.yamlScalar }.joined(separator: ", "))]")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: produce a full note with this frontmatter spliced ahead of `body`
    func recompose(body: String) -> String {
        let fm = serialized()
        if entries.isEmpty { return body }
        return "---\n\(fm)\n---\n\(body.hasPrefix("\n") ? String(body.dropFirst()) : body)"
    }

    // MARK: in-place edits (panel callbacks)
    mutating func setScalar(_ key: String, _ newValue: String) {
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries[idx].value = .scalar(newValue)
            entries[idx].modeled = true
        } else {
            entries.append(Entry(key: key, value: .scalar(newValue), modeled: true, rawLines: []))
        }
    }

    mutating func setList(_ key: String, _ items: [String]) {
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries[idx].value = .list(items)
            entries[idx].modeled = true
        } else {
            entries.append(Entry(key: key, value: .list(items), modeled: true, rawLines: []))
        }
    }
}

private extension String {
    var strippedQuotes: String {
        var s = self
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Quote a scalar only when YAML would otherwise mis-parse it.
    var yamlScalar: String {
        guard !isEmpty else { return "\"\"" }
        let needsQuote = first == " " || last == " " ||
            contains(":") || contains("#") || contains("[") || contains("]") ||
            contains("{") || contains("}") || first == "\"" || first == "'" || first == "-"
        return needsQuote ? "\"\(replacingOccurrences(of: "\"", with: "\\\""))\"" : self
    }
}
