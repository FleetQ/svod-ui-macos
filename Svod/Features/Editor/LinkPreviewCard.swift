import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - LinkPreview
//
// Hover state for a [[wikilink]]: fetches the target's first lines (body, sans
// frontmatter) and shows a small card. Unresolved targets show a "not yet a note"
// affordance instead.

@MainActor
final class LinkPreview: ObservableObject {
    @Published var target: String?
    @Published var anchor: CGRect = .zero
    @Published var snippet: String?
    @Published var resolvedPath: String?
    @Published var isLoading = false

    private let client: SvodClient
    private var loadTask: Task<Void, Never>?
    init(client: SvodClient) { self.client = client }

    func show(target: String, resolvedPath: String?, anchor: CGRect) {
        guard target != self.target else { self.anchor = anchor; return }
        self.target = target
        self.anchor = anchor
        self.resolvedPath = resolvedPath
        self.snippet = nil
        loadTask?.cancel()
        guard let path = resolvedPath else { isLoading = false; return }
        isLoading = true
        loadTask = Task {
            let content = try? await client.readFile(path: path)
            if Task.isCancelled { return }
            isLoading = false
            if let content { snippet = Self.firstLines(of: content.content) }
        }
    }

    func hide() {
        loadTask?.cancel()
        target = nil; snippet = nil; resolvedPath = nil; isLoading = false
    }

    /// Body preview: drop frontmatter, take the first non-empty lines.
    static func firstLines(of text: String, limit: Int = 6) -> String {
        let body = Frontmatter.split(text).body
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(limit)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Card view
struct LinkPreviewCard: View {
    @ObservedObject var model: LinkPreview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: model.resolvedPath == nil ? "doc.badge.plus" : "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(model.resolvedPath == nil ? ThemeColor.linkUnresolved : ThemeColor.link)
                Text(model.target ?? "")
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
            }
            if model.resolvedPath == nil {
                Text("Not yet a note — saving a link creates it.")
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textTertiary)
            } else if model.isLoading {
                ProgressView().controlSize(.small)
            } else if let snippet = model.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(Spacing.md)
        .frame(width: 280, alignment: .leading)
        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
            .strokeBorder(ThemeColor.borderSubtle))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(model.target ?? "note")")
    }
}
