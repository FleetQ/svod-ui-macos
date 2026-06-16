import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Sidebar (Features/Sidebar/)
//
// Three sections in one scroll: the file tree (collapsible dirs, selectable
// files), the tag taxonomy (tag + count → seeds a search), and saved searches.
// Loading / empty / error are handled up front. The tree is keyboard-navigable
// (arrows move, ←/→ collapse/expand dirs) and VoiceOver-labeled.
// ════════════════════════════════════════════════════════════════════════

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if model.isLoading && model.tree == nil {
                LoadingStateView("Loading vault…")
            } else if let error = model.errorMessage, model.tree == nil {
                ErrorStateView(message: error) { Task { await model.load() } }
            } else if isEmptyTree {
                EmptyStateView(icon: "tray", title: "Empty vault",
                               message: "No notes yet. Create one to get started.")
            } else {
                content
            }
        }
        .background(ThemeColor.surface)
        // Load on first appear; also reload whenever the active vault switches.
        .task { if model.tree == nil { await model.load() } }
        .task(id: app.reloadEpoch) {
            // reloadEpoch is bumped by AppModel.didSwitchVault(); skip the very
            // first trigger (epoch == 0) to avoid a redundant double-load on launch.
            guard app.reloadEpoch > 0 else { return }
            await model.load()
        }
    }

    private var isEmptyTree: Bool {
        guard let tree = model.tree else { return false }
        return (tree.children ?? []).isEmpty
    }

    private var content: some View {
        VStack(spacing: 0) {
            if app.vault.hasMultipleVaults { vaultHeader }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    fileTreeSection
                    if !model.tags.isEmpty { tagSection }
                    if !model.savedSearches.isEmpty { savedSearchSection }
                }
                .padding(Spacing.sm)
            }
        }
    }

    // Small vault context strip — only shown when multi-vault so single-vault setups
    // see zero extra chrome.
    @ViewBuilder private var vaultHeader: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "tray.full")
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
            Text(app.vault.activeVault?.name ?? "Vault")
                .font(Typography.caption.weight(.medium))
                .foregroundStyle(ThemeColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            SidebarImportButton()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(ThemeColor.surfaceRaised)
    }

    // MARK: file tree
    private var fileTreeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Notes", systemImage: "folder")
                .padding(.horizontal, Spacing.sm)
            if let root = model.tree {
                // Render the root's children directly; the "vault" root itself is
                // implied by the pane, so we don't show it as a row.
                ForEach(root.children ?? []) { node in
                    TreeNodeRow(node: node, depth: 0, model: model, app: app)
                }
            }
        }
    }

    // MARK: tags
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Tags", systemImage: "number")
                .padding(.horizontal, Spacing.sm)
            ForEach(model.tags) { tag in
                ListRow(title: "#\(tag.tag)", isSelected: false) {
                    Image(systemName: "number")
                        .imageScale(.small)
                        .foregroundStyle(ThemeColor.textTertiary)
                } trailing: {
                    Text("\(tag.count)")
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .monospacedDigit()
                } action: {
                    selectTag(tag.tag)
                }
                .accessibilityLabel("Tag \(tag.tag), \(tag.count) notes")
                .accessibilityHint("Searches notes with this tag")
            }
        }
    }

    // MARK: saved searches
    private var savedSearchSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Saved Searches", systemImage: "bookmark")
                .padding(.horizontal, Spacing.sm)
            ForEach(model.savedSearches) { saved in
                ListRow(title: saved.name, subtitle: saved.query) {
                    Image(systemName: "bookmark")
                        .imageScale(.small)
                        .foregroundStyle(ThemeColor.textTertiary)
                } action: {
                    runSavedSearch(saved)
                }
            }
        }
    }

    // MARK: actions
    private func selectTag(_ tag: String) {
        app.search.query = ""
        app.search.filterTags = [tag]
        app.commandPaletteVisible = true
        app.search.search()
    }

    private func runSavedSearch(_ saved: SidebarModel.SavedSearch) {
        app.search.query = saved.query
        app.commandPaletteVisible = true
    }
}

// MARK: - Sidebar import button

private struct SidebarImportButton: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Button {
            app.importPresented = true
        } label: {
            Image(systemName: "folder.badge.plus")
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Import Obsidian Vault…")
        .accessibilityLabel("Import Obsidian Vault")
    }
}

// MARK: - Tree row (recursive)
private struct TreeNodeRow: View {
    let node: TreeNode
    let depth: Int
    @ObservedObject var model: SidebarModel
    let app: AppModel

    @FocusState private var focused: Bool
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private var isDir: Bool { node.type == .dir }
    private var isExpanded: Bool { model.expanded.contains(node.path) }
    private var isSelected: Bool { app.selectedPath == node.path }
    private var hovering: Bool { model.hoveredPath == node.path }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            row
            if isDir && isExpanded {
                ForEach(node.children ?? []) { child in
                    TreeNodeRow(node: child, depth: depth + 1, model: model, app: app)
                }
            }
        }
    }

    private var row: some View {
        Button(action: activate) {
            HStack(spacing: Spacing.xs) {
                // disclosure chevron only for dirs
                Group {
                    if isDir {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    } else {
                        Color.clear.frame(width: 9)
                    }
                }
                .frame(width: 12)
                Image(systemName: isDir ? "folder" : "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(isDir ? ThemeColor.accentMuted : ThemeColor.textTertiary)
                Text(node.name)
                    .font(Typography.callout)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * Spacing.md + Spacing.xs)
            .padding(.trailing, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hoveredPath = node.path }
            else if model.hoveredPath == node.path { model.hoveredPath = nil }
        }
        .focusable(true)
        .focused($focused)
        .focusEffectDisabled()
        // ←/→ collapse/expand dirs; ⏎/space activate.
        .onKeyPress(.rightArrow) { if isDir && !isExpanded { withAnimation(Motion.quick) { model.toggle(node.path) }; return .handled }; return .ignored }
        .onKeyPress(.leftArrow)  { if isDir && isExpanded  { withAnimation(Motion.quick) { model.toggle(node.path) }; return .handled }; return .ignored }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space)  { activate(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isDir ? (isExpanded ? "Expanded folder. Activate to collapse." : "Collapsed folder. Activate to expand.") : "Opens this note")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu { contextMenuContent }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(isDir ? "Delete Folder" : "Delete", role: .destructive) {
                Task { if isDir { await deleteFolder() } else { await deleteNote() } }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
        .alert("Couldn’t delete note", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // Right-click menu: folders expand/collapse; notes open or delete (with confirm).
    @ViewBuilder private var contextMenuContent: some View {
        if isDir {
            Button {
                withAnimation(Motion.quick) { model.toggle(node.path) }
            } label: {
                Label(isExpanded ? "Collapse" : "Expand",
                      systemImage: isExpanded ? "chevron.down" : "chevron.right")
            }
            if noteCount > 0 {
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Folder…", systemImage: "trash")
                }
            }
        } else {
            Button { app.open(path: node.path) } label: { Label("Open", systemImage: "doc.text") }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete Note…", systemImage: "trash")
            }
        }
    }

    // All note (file) paths under this node, recursively. 1 for a file.
    private func notePaths(_ n: TreeNode) -> [String] {
        n.type == .file ? [n.path] : (n.children ?? []).flatMap(notePaths)
    }
    private var noteCount: Int { notePaths(node).count }

    private var deleteTitle: String {
        if isDir {
            return "Delete “\(node.name)” and its \(noteCount) note\(noteCount == 1 ? "" : "s")?"
        }
        return "Delete “\(node.name)”?"
    }
    private var deleteMessage: String {
        isDir
            ? "Every note in this folder is moved to the vault’s trash and can be restored later."
            : "It’s moved to the vault’s trash and can be restored later — the engine keeps full history."
    }

    private func deleteNote() async {
        do {
            try await trash(node.path)
            if app.selectedPath == node.path { app.selectedPath = nil }
            app.refreshActiveVault()   // reload the tree so the row disappears
        } catch let e as SvodClientError {
            deleteError = e.errorDescription
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Recursively soft-delete every note in the folder. Continues past a single
    /// failure and surfaces the first error; the engine serializes the writes.
    private func deleteFolder() async {
        var firstError: String?
        for path in notePaths(node) {
            do {
                try await trash(path)
                if app.selectedPath == path { app.selectedPath = nil }
            } catch let e as SvodClientError {
                if firstError == nil { firstError = e.errorDescription }
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        app.refreshActiveVault()
        deleteError = firstError
    }

    /// Soft-delete one note. The engine requires the current revision (optimistic
    /// concurrency), so read it first, then delete to .trash/.
    private func trash(_ path: String) async throws {
        let current = try await app.client.readFile(path: path)
        try await app.client.deleteFile(path: path, expectedRevision: current.revision)
    }

    private func activate() {
        if isDir {
            withAnimation(Motion.quick) { model.toggle(node.path) }
        } else {
            app.open(path: node.path)
        }
    }

    private var rowBackground: Color {
        // Only the open note stays highlighted; the pointer hover is transient. (Driving
        // this off per-row @FocusState left every clicked row stuck highlighted, since
        // button focus isn't cleared exclusively across the recursive tree.)
        if isSelected { return ThemeColor.surfaceSelected }
        if hovering { return ThemeColor.surfaceHover }
        return .clear
    }

    private var accessibilityLabel: String {
        isDir ? "Folder \(node.name)" : "Note \(node.name)"
    }
}

// MARK: - Previews
#Preview("Sidebar — loaded") {
    let app = AppModel(client: MockSvodClient.preview)
    app.sidebar.expanded = ["vault/adr"]
    app.selectedPath = "vault/architecture.md"
    app.sidebar.savedSearches = [.init(name: "Open ADRs", query: "tag:adr status:open")]
    return SidebarView(model: app.sidebar)
        .environmentObject(app)
        .frame(width: 260, height: 560)
}

#Preview("Sidebar — empty") {
    let app = AppModel(client: MockSvodClient.empty)
    return SidebarView(model: app.sidebar)
        .environmentObject(app)
        .frame(width: 260, height: 560)
}

#Preview("Sidebar — offline/error") {
    let app = AppModel(client: MockSvodClient.offline)
    return SidebarView(model: app.sidebar)
        .environmentObject(app)
        .frame(width: 260, height: 560)
}
