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
    /// Open the superseding note (a vault path) when its badge is tapped.
    var onOpenNote: (String) -> Void

    private func scalar(_ key: String) -> String? {
        if case let .scalar(s)? = frontmatter[key], !s.isEmpty { return s }
        return nil
    }
    private var type: String? { scalar("type") }
    private var status: String? { scalar("status") }
    private var supersededBy: String? { scalar("superseded_by") }
    private var expiresAt: String? { scalar("expires_at") }

    private var hasAny: Bool {
        type != nil || status != nil || supersededBy != nil || expiresAt != nil
    }

    var body: some View {
        if hasAny {
            HStack(spacing: Spacing.xs) {
                if let type { chip(type.capitalized, "tag", ThemeColor.accentSubtle, ThemeColor.textSecondary) }
                if let status { statusBadge(status) }
                if let supersededBy { supersededLink(supersededBy) }
                if let expiresAt { expiresBadge(expiresAt) }
                Spacer(minLength: 0)
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

    // MARK: superseded_by → tappable link to that note
    private func supersededLink(_ path: String) -> some View {
        Button { onOpenNote(path) } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "arrow.uturn.forward").imageScale(.small)
                Text("superseded → \((path as NSString).lastPathComponent)")
                    .font(Typography.caption).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(ThemeColor.link)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
            .background(ThemeColor.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Open the note that supersedes this one: \(path)")
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
    status: revoked
    superseded_by: vault/policies/new-policy.md
    expires_at: 1700000000
    """)
    return MemoryBadgesBar(frontmatter: fm) { _ in }
        .padding()
        .frame(width: 520)
        .background(ThemeColor.editorSurface)
}
