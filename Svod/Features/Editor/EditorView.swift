import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// Entry view. Wire into EditorSlot as `EditorView(model: app.editor)`.
// ════════════════════════════════════════════════════════════════════════

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        // `.task` must hang off a STABLE container — attaching it to `content`
        // (whose concrete type changes between empty/loading/editor) makes SwiftUI
        // treat each branch as a new identity and restart the task in a tight loop.
        ZStack {
            ThemeColor.editorSurface
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: app.selectedPath) {
            guard let path = app.selectedPath else { return }
            await model.load(path: path)
        }
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
                    MemoryBadgesBar(frontmatter: split.frontmatter) { handleOpenLink($0) }
                        .frame(maxWidth: Spacing.readingMeasure)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.lg)
                    if !split.frontmatter.entries.isEmpty {
                        FrontmatterPanel(frontmatter: split.frontmatter) { updated in
                            recompose(frontmatter: updated, body: split.body)
                        }
                        .frame(maxWidth: Spacing.readingMeasure)
                        .padding(.horizontal, Spacing.xl)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: split.frontmatter.entries.isEmpty ? 0 : nil)
            .fixedSize(horizontal: false, vertical: true)

            WebEditorView(
                text: bodyBinding,
                previewMode: model.previewMode,
                focusMode: model.focusMode,
                noteNames: model.noteNames,
                onOpenLink: handleOpenLink
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            .disabled(model.previewMode)
            ToolbarIconButton(model.previewMode ? "pencil" : "eye",
                              help: model.previewMode ? "Edit (⌘⇧P)" : "Preview (⌘⇧P)",
                              isActive: model.previewMode) {
                withAnimation(Motion.standard) { model.previewMode.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
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
