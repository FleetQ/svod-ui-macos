import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 2 — Search & ⌘K Command Palette
// ════════════════════════════════════════════════════════════════════════

// MARK: - SearchResultRow
//
// One hit in the palette: heading + path on the first line, highlighted snippet
// below, and a trailing why-matched cluster (keyword/semantic badges + a subtle
// relevance dot derived from `score`). Selection wash mirrors ListRow so rows feel
// native; the whole row is one VoiceOver element with an announced selection.

struct SearchResultRow: View {
    let hit: SearchHit
    let isSelected: Bool
    let onActivate: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? ThemeColor.accent : ThemeColor.textTertiary)
                    .frame(width: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.sm) {
                        Text(hit.heading)
                            .font(Typography.callout.weight(.medium))
                            .foregroundStyle(ThemeColor.textPrimary)
                            .lineLimit(1)
                        Text(prettyPath)
                            .font(Typography.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.sm)
                        relevanceDot
                    }
                    SnippetText(snippet: hit.snippet)
                    if !matchBadges.isEmpty || !hit.tags.isEmpty || hit.vault != nil {
                        HStack(spacing: Spacing.xs) {
                            if let vaultId = hit.vault {
                                StatusPill(vaultId, tone: .neutral, showsDot: false)
                            }
                            ForEach(matchBadges, id: \.self) { badge in
                                StatusPill(badge, tone: .accent, showsDot: false)
                            }
                            ForEach(hit.tags.prefix(3), id: \.self) { tag in
                                StatusPill("#\(tag)", tone: .neutral, showsDot: false)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("Press Return to open")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // The vault-relative path reads cleaner without the leading "vault/".
    private var prettyPath: String {
        hit.path.hasPrefix("vault/") ? String(hit.path.dropFirst("vault/".count)) : hit.path
    }

    private var matchBadges: [String] {
        var b: [String] = []
        if hit.matchedKeyword { b.append("keyword") }
        if hit.matchedSemantic { b.append("semantic") }
        return b
    }

    // Score → three calm relevance tiers, shown as a filled dot + help text.
    private var relevanceTone: StatusPill.Tone {
        switch hit.score {
        case 0.8...:  return .success
        case 0.5...:  return .accent
        default:      return .neutral
        }
    }

    private var relevanceDot: some View {
        Circle()
            .fill(relevanceTone.fg)
            .frame(width: 6, height: 6)
            .help("Relevance \(Int((hit.score * 100).rounded()))%")
            .accessibilityHidden(true)
    }

    private var rowBackground: Color {
        if isSelected { return ThemeColor.surfaceSelected }
        if hovering { return ThemeColor.surfaceHover }
        return .clear
    }

    private var a11yLabel: String {
        var parts = ["\(hit.heading), \(prettyPath)"]
        if let vaultId = hit.vault { parts.append("vault \(vaultId)") }
        parts.append(SnippetText.plain(hit.snippet))
        if hit.matchedKeyword && hit.matchedSemantic { parts.append("keyword and semantic match") }
        else if hit.matchedKeyword { parts.append("keyword match") }
        else if hit.matchedSemantic { parts.append("semantic match") }
        parts.append("relevance \(Int((hit.score * 100).rounded())) percent")
        if !hit.tags.isEmpty { parts.append("tags \(hit.tags.joined(separator: ", "))") }
        return parts.joined(separator: ". ")
    }
}

#Preview("SearchResultRow") {
    let federatedHits = MockSvodClient.hits(for: "method", vault: "research", tagged: true)
    VStack(spacing: Spacing.xs) {
        SearchResultRow(hit: MockSvodClient.hits(for: "write").first!, isSelected: true) {}
        SearchResultRow(hit: MockSvodClient.hits(for: "write")[1], isSelected: false) {}
        SearchResultRow(hit: MockSvodClient.hits(for: "write")[2], isSelected: false) {}
        if let fedHit = federatedHits.first {
            SearchResultRow(hit: fedHit, isSelected: false) {}
        }
    }
    .padding(Spacing.md)
    .frame(width: 560)
    .background(ThemeColor.surfaceRaised)
}
