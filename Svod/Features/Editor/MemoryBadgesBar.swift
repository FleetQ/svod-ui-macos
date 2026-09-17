import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════
//
// Lifecycle badges for the memory system (contract 0.14.0). Reads the reserved
// frontmatter keys — `type`, `status`, `superseded_by`, `expires_at` — already
// parsed by the editor, so no new endpoint is needed. Renders nothing for notes
// without these keys (the common case), so ordinary notes are unaffected.

struct MemoryBadgesBar: View {
    let frontmatter: Frontmatter
    /// Open a linked note (a vault path) when its badge is tapped.
    var onOpenNote: (String) -> Void
    /// Approve / decline this memory (contract 0.33.0). nil hides the buttons — an older engine
    /// or a read-only vault.
    var onReview: ((MemoryReviewVerb) -> Void)? = nil
    var reviewing = false
    var reviewMessage: String? = nil

    private func scalar(_ key: String) -> String? {
        if case let .scalar(s)? = frontmatter[key], !s.isEmpty { return s }
        return nil
    }
    private var type: String? { scalar("type") }
    private var status: String? { scalar("status") }
    private var supersededBy: String? { scalar("superseded_by") }
    private var expiresAt: String? { scalar("expires_at") }
    private var contradicts: String? { scalar("contradicts").map(Self.linkPath) }
    private var supersedes: String? { scalar("supersedes").map(Self.linkPath) }
    private var needsReview: Bool {
        (scalar("needs-review") ?? scalar("needsReview"))?.lowercased() == "true"
    }
    private var awaitsReview: Bool { status?.lowercased() == "provisional" || needsReview }

    private var hasAny: Bool {
        type != nil || status != nil || supersededBy != nil || expiresAt != nil
            || contradicts != nil || supersedes != nil || needsReview
    }

    var body: some View {
        if hasAny {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    if let type { chip(type.capitalized, "tag", ThemeColor.accentSubtle, ThemeColor.textSecondary) }
                    if let status { statusBadge(status) }
                    if needsReview { chip("Needs review", "exclamationmark.bubble", ThemeColor.surfaceRaised, ThemeColor.warning) }
                    if let supersededBy { link("superseded → ", supersededBy, "arrow.uturn.forward",
                                               help: "Open the note that supersedes this one") }
                    if let supersedes { link("supersedes ", supersedes, "arrow.uturn.backward",
                                             help: "Open the note this one replaces") }
                    if let contradicts { link("contradicts ", contradicts, "exclamationmark.arrow.triangle.2.circlepath",
                                              help: "Open the note this one contradicts") }
                    if let expiresAt { expiresBadge(expiresAt) }
                    Spacer(minLength: 0)
                    if awaitsReview, let onReview {
                        Button("Decline", role: .destructive) { onReview(.decline) }
                            .buttonStyle(.borderless)
                            .help("Mark this memory revoked — recall keeps leaving it out")
                        Button("Approve") { onReview(.approve) }
                            .buttonStyle(.borderless)
                            .help("Mark this memory active — search and recall start using it")
                    }
                }
                .disabled(reviewing)
                if let reviewMessage {
                    Text(reviewMessage).font(Typography.caption).foregroundStyle(ThemeColor.warning)
                }
            }
        }
    }

    // MARK: status
    @ViewBuilder private func statusBadge(_ status: String) -> some View {
        let (bg, fg): (Color, Color) = {
            switch status.lowercased() {
            case "active":      return (ThemeColor.syncSubtle, ThemeColor.sync)
            case "provisional": return (ThemeColor.surfaceRaised, ThemeColor.warning)
            case "revoked":     return (ThemeColor.conflictSubtle, ThemeColor.danger)
            default:            return (ThemeColor.surfaceRaised, ThemeColor.textSecondary)
            }
        }()
        chip(status.capitalized, "circle.lefthalf.filled", bg, fg)
    }

    // MARK: superseded_by / supersedes / contradicts → tappable link to that note
    private func link(_ prefix: String, _ path: String, _ icon: String, help: String) -> some View {
        Button { onOpenNote(path) } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: icon).imageScale(.small)
                Text(prefix + (path as NSString).lastPathComponent)
                    .font(Typography.caption).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(ThemeColor.link)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
            .background(ThemeColor.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(help): \(path)")
    }

    /// `[[memory/x]]` and `memory/x.md` both name the same note.
    static func linkPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[["), s.hasSuffix("]]") { s = String(s.dropFirst(2).dropLast(2)) }
        return s
    }

    // MARK: expires_at (epoch or ISO-8601) → "expires <date>" / "expired"
    @ViewBuilder private func expiresBadge(_ raw: String) -> some View {
        let date = Self.parseDate(raw)
        let past = date.map { $0 < Date() } ?? false
        chip(past ? "expired" : "expires \(Self.short(date) ?? raw)",
             past ? "clock.badge.xmark" : "clock",
             past ? ThemeColor.conflictSubtle : ThemeColor.surfaceRaised,
             past ? ThemeColor.danger : ThemeColor.textSecondary)
    }

    // MARK: chip primitive
    private func chip(_ text: String, _ icon: String, _ bg: Color, _ fg: Color) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon).imageScale(.small)
            Text(text).font(Typography.caption)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
        .background(bg, in: Capsule())
    }

    static func parseDate(_ raw: String) -> Date? {
        if let epoch = Double(raw) { return Date(timeIntervalSince1970: epoch) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    static func short(_ date: Date?) -> String? {
        date.map { $0.formatted(date: .abbreviated, time: .omitted) }
    }
}

#Preview("Memory badges") {
    let fm = Frontmatter.parse("""
    type: policy
    status: provisional
    needs-review: true
    contradicts: vault/policies/old-policy.md
    superseded_by: vault/policies/new-policy.md
    expires_at: 1700000000
    """)
    return MemoryBadgesBar(frontmatter: fm, onOpenNote: { _ in }, onReview: { _ in })
        .padding()
        .frame(width: 520)
        .background(ThemeColor.editorSurface)
}
