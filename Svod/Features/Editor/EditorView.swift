import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// Entry view. Wire into EditorSlot as `EditorView(model: app.editor)`.
// ════════════════════════════════════════════════════════════════════════

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject var app: AppModel

    @StateObject private var autocomplete = WikilinkAutocomplete()
    @StateObject private var preview: LinkPreview
    @State private var coordinator: MarkdownTextView.Coordinator?

    init(model: EditorModel) {
        self.model = model
        _preview = StateObject(wrappedValue: LinkPreview(client: model.client))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content
                overlays(in: geo.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeColor.editorSurface)
        .task(id: app.selectedPath) {
            guard let path = app.selectedPath else { return }
            await model.load(path: path)
            autocomplete.setNames(model.noteNames)
        }
        .onChange(of: model.noteNames) { _, names in autocomplete.setNames(names) }
    }

    // MARK: states
    @ViewBuilder private var content: some View {
        if app.selectedPath == nil {
            EmptyStateView(icon: "doc.text", title: "No note open",
                           message: "Choose a note from the sidebar, or press ⌘K to search.")
        } else if model.isLoading {
            LoadingStateView("Opening note…")
        } else if let error = model.errorMessage {
            ErrorStateView(message: error) {
                Task { if let p = app.selectedPath { await model.load(path: p) } }
            }
        } else {
            editor
        }
    }

    // MARK: editor surface
    private var editor: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model)
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if !split.frontmatter.entries.isEmpty {
                        FrontmatterPanel(frontmatter: split.frontmatter) { updated in
                            recompose(frontmatter: updated, body: split.body)
                        }
                        .frame(maxWidth: Spacing.readingMeasure)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.lg)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: split.frontmatter.entries.isEmpty ? 0 : nil)
            .fixedSize(horizontal: false, vertical: true)

            MarkdownTextView(
                text: bodyBinding,
                focusMode: model.focusMode,
                isResolved: { model.resolves($0) },
                onAutocomplete: handleAutocomplete,
                onHoverLink: handleHover,
                onOpenLink: handleOpenLink,
                register: { coord in
                    coordinator = coord
                    coord.onMove = { autocomplete.moveSelection($0) }
                    coord.onChoose = { autocomplete.selectedMatch }
                    coord.onCancel = { autocomplete.dismiss() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: overlays — autocomplete popover + hover preview (clamped to the editor bounds)
    @ViewBuilder private func overlays(in size: CGSize) -> some View {
        if autocomplete.isActive {
            let estHeight = min(CGFloat(autocomplete.matches.count) * 30 + 16, 300)
            WikilinkPopover(model: autocomplete, resolves: { model.resolves($0) }) { name in
                coordinator?.insertWikilink(name)
                autocomplete.dismiss()
            }
            .offset(clampedOffset(autocomplete.anchor, in: size, width: 260, height: estHeight))
            .transition(.opacity)
        }
        if preview.target != nil {
            LinkPreviewCard(model: preview)
                .offset(clampedOffset(preview.anchor, in: size, width: 280, height: 240))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Keep a floating popover fully on-screen: clamp X to the editor width, and
    /// flip the popover above its anchor when it would overflow the bottom edge.
    private func clampedOffset(_ anchor: CGRect, in size: CGSize, width: CGFloat, height: CGFloat) -> CGSize {
        let margin = Spacing.sm
        let x = min(max(margin, anchor.minX), max(margin, size.width - width - margin))
        let below = anchor.maxY + Spacing.xs
        let y = (below + height > size.height) ? max(margin, anchor.minY - height - Spacing.xs) : below
        return CGSize(width: x, height: y)
    }

    // MARK: frontmatter / body split + recompose (round-trip safe)
    private var split: (frontmatter: Frontmatter, body: String) {
        let parts = Frontmatter.split(model.draft)
        return (Frontmatter.parse(parts.frontmatter ?? ""), parts.body)
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { split.body },
            set: { recompose(frontmatter: split.frontmatter, body: $0) }
        )
    }

    private func recompose(frontmatter: Frontmatter, body: String) {
        model.draft = frontmatter.recompose(body: body)
        model.markDirty()
    }

    // MARK: callbacks
    private func handleAutocomplete(_ query: String?, _ rect: CGRect) {
        if let query {
            autocomplete.begin(query: query, anchor: rect)
        } else {
            autocomplete.dismiss()
        }
        coordinator?.autocompleteActive = autocomplete.isActive
    }

    private func handleHover(_ target: String?, _ resolvedPath: String?, _ rect: CGRect) {
        guard let target else { preview.hide(); return }
        if let ref = GlobalNoteRef(globalId: target) {
            // Cross-vault [[vault:note]]: preview from the other vault without switching.
            preview.showCrossVault(ref: ref, anchor: rect)
        } else {
            preview.show(target: target, resolvedPath: model.resolvedPath(for: target), anchor: rect)
        }
    }

    private func handleOpenLink(_ target: String) {
        if let ref = GlobalNoteRef(globalId: target) {
            // Qualified [[vault:note]]: switch vault then open path.
            app.openGlobal(ref)
        } else if let path = model.resolvedPath(for: target) {
            app.open(path: path)
        }
        // Unresolved same-vault link: no-op (note doesn't exist yet).
    }
}

// MARK: - EditorToolbar (in-pane, secondary chrome)
private struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ToolbarSurface {
            Text(filename)
                .font(Typography.callout.weight(.medium))
                .foregroundStyle(ThemeColor.textSecondary)
                .lineLimit(1)
            if model.dirty {
                Circle().fill(ThemeColor.accent).frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer()
            if model.isSaving {
                ProgressView().controlSize(.small)
            }
            ToolbarIconButton("text.aligncenter", help: "Focus mode (⌥⌘F)", isActive: model.focusMode) {
                withAnimation(Motion.standard) { model.focusMode.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            ToolbarIconButton("square.and.arrow.down", help: "Save (⌘S)") {
                Task { await model.save() }
            }
        }
    }

    private var filename: String {
        guard let path = model.file?.path ?? model.app?.selectedPath else { return "Untitled" }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Previews
#Preview("Loaded note") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    return EditorView(model: app.editor)
        .environmentObject(app)
        .frame(width: 900, height: 680)
}

#Preview("Focus mode") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    app.editor.focusMode = true
    return EditorView(model: app.editor)
        .environmentObject(app)
        .frame(width: 900, height: 680)
}

#Preview("Frontmatter panel") {
    let fm = Frontmatter.parse("""
    title: Architecture
    tags: [architecture, svod]
    status: design-complete
    updated: 2026-06-12
    """)
    return FrontmatterPanel(frontmatter: fm) { _ in }
        .frame(width: 520)
        .padding(Spacing.xl)
        .background(ThemeColor.editorSurface)
}

#Preview("Empty") {
    let app = AppModel(client: MockSvodClient.preview)
    return EditorView(model: app.editor)
        .environmentObject(app)
        .frame(width: 900, height: 680)
}

#Preview("Loading") {
    let app = AppModel(client: MockSvodClient(behavior: .slow))
    app.selectedPath = "vault/architecture.md"
    return EditorView(model: app.editor)
        .environmentObject(app)
        .frame(width: 900, height: 680)
}

#Preview("Error") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/does-not-exist.md"
    return EditorView(model: app.editor)
        .environmentObject(app)
        .frame(width: 900, height: 680)
}
