import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Sidebar (Features/Sidebar/)
//
// Three sections in one scroll: the file tree (collapsible dirs, selectable
// files), the tag taxonomy (tag + count → seeds a search), and saved searches.
// Loading / empty / error are handled up front. The tree is keyboard-navigable
// (arrows move, ←/→ collapse/expand dirs) and VoiceOver-labeled.
// ════════════════════════════════════════════════════════════════════════

/// The sidebar's two navigators. Notes (the file tree + saved searches) and Tags
/// (the tag taxonomy) used to stack in one scroll; splitting them into tabs keeps
/// the tree uncluttered and gives the (often long) tag list room to breathe.
enum SidebarTab: String, CaseIterable, Identifiable {
    case notes, tags
    var id: String { rawValue }
    var label: String { self == .notes ? "Notes" : "Tags" }
    var icon: String { self == .notes ? "folder" : "number" }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @EnvironmentObject var app: AppModel

    /// Persisted across launches so the user returns to the navigator they last used.
    @AppStorage("svod.sidebar.tab") private var tab: SidebarTab = .notes
    @State private var tagFilter = ""
    @State private var treeFilter = ""

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
        .onChange(of: app.latestEvent) { _, event in
            guard let event else { return }
            switch event.type {
            case .commitCreated, .fileChanged, .sourceSynced:
                model.scheduleRefresh()
            default: break
            }
        }
    }

    private var isEmptyTree: Bool {
        guard let tree = model.tree else { return false }
        return (tree.children ?? []).isEmpty
    }

    private var content: some View {
        VStack(spacing: 0) {
            if app.vault.hasMultipleVaults { vaultHeader }
            tabPicker
            Divider().overlay(ThemeColor.separator)
            switch tab {
            case .notes: notesTab
            case .tags:  tagsTab
            }
        }
    }

    // Segmented switcher between the Notes tree and the Tags taxonomy.
    private var tabPicker: some View {
        Picker("Sidebar section", selection: $tab) {
            ForEach(SidebarTab.allCases) { t in
                Text(t.label).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .accessibilityLabel("Sidebar section")
    }

    // MARK: Notes tab — the file tree. Its header (label + reveal/refresh) and the
    // filter stay pinned above the scroll area, so they're reachable from anywhere
    // in a long tree instead of scrolling away with the first rows.
    private var notesTab: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                treeHeader
                if app.themeFilter != nil { themeFilterBanner }
                treeFilterField
                Divider().overlay(ThemeColor.separator)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if showsPinned { pinnedSection }
                        fileTreeSection
                    }
                    .padding(Spacing.sm)
                }
            }
            // Fires after the ancestor folders from reveal(_:) are expanded, so the
            // target row exists by the time we scroll.
            .onChange(of: model.revealTarget) { _, target in
                guard let target else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(target, anchor: .center) }
                model.revealTarget = nil
            }
        }
    }

    /// Why the tree is showing a subset. Without this the filtered tree looks like a bug or an
    /// unexpectedly small vault, and there is no obvious way back.
    @ViewBuilder
    private var themeFilterBanner: some View {
        if let theme = app.themeFilter {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .imageScale(.small)
                    .foregroundStyle(ThemeColor.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(theme.title)
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(1)
                    Text("\(theme.paths.count) бележки")
                        .font(Typography.caption2)
                        .foregroundStyle(ThemeColor.textTertiary)
                }
                Spacer(minLength: Spacing.xs)
                Button {
                    withAnimation(Motion.standard) { app.themeFilter = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Покажи всички бележки отново")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)
            .background(ThemeColor.accentSubtle)
        }
    }

    private var treeFilterField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "line.3.horizontal.decrease")
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
            TextField("Filter notes and folders", text: $treeFilter)
                .textFieldStyle(.plain)
                .font(Typography.callout)
            if !treeFilter.isEmpty {
                Button { treeFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ThemeColor.textTertiary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
    }

    private var trimmedTreeFilter: String {
        treeFilter.trimmingCharacters(in: .whitespaces)
    }

    /// The filtered projection: the rows to render, plus the folders to open automatically.
    private struct FilteredTree {
        var roots: [TreeNode] = []
        /// Folders rendered open — ONLY those that survived because a descendant matched, so the
        /// deep hit is visible without clicking through every ancestor.
        ///
        /// A folder that matched on its own NAME is deliberately absent. It still keeps its whole
        /// subtree (so you can browse into a hit) but renders collapsed, because expanding it means
        /// rendering that entire subtree: on this vault, filtering by "proj" rendered 3,113 of 3,558
        /// nodes — the whole tree, not a filter result — and the tree is a non-lazy VStack, so every
        /// keystroke rebuilt all of them. Keeping name-matched folders shut takes that to 17.
        var autoExpand: Set<String> = []
    }

    /// Top-level rows to render: the whole tree, or its filtered projection.
    ///
    /// A selected theme narrows the tree to that theme's notes; the text filter then applies on top,
    /// so you can search *within* a theme. Order matters — the theme is the coarse cut.
    private var filteredTree: FilteredTree {
        var roots = model.tree?.children ?? []
        var result = FilteredTree()

        if let theme = app.themeFilter {
            roots = roots.compactMap { keepingPaths($0, paths: theme.paths, autoExpand: &result.autoExpand) }
        }
        let q = trimmedTreeFilter
        guard !q.isEmpty else {
            result.roots = roots
            return result
        }
        result.roots = roots.compactMap { pruned($0, query: q, autoExpand: &result.autoExpand) }
        return result
    }

    /// Keep only files in [paths], and the folders on the way to them.
    ///
    /// Unlike the name filter, EVERY surviving folder is auto-expanded: a theme's notes are scattered
    /// across the tree, so leaving the folders shut would show a handful of closed directories and
    /// hide the very thing the user selected. The counts stay small because the set is bounded by the
    /// theme's membership, not by a substring that might match half the vault.
    private func keepingPaths(_ node: TreeNode, paths: Set<String>, autoExpand: inout Set<String>) -> TreeNode? {
        guard node.type == .dir else { return paths.contains(node.path) ? node : nil }
        let kids = (node.children ?? []).compactMap { keepingPaths($0, paths: paths, autoExpand: &autoExpand) }
        guard !kids.isEmpty else { return nil }
        autoExpand.insert(node.path)
        var copy = node
        copy.children = kids
        return copy
    }

    /// Keep a node when its own name matches, or when any descendant does — a matching
    /// folder keeps its full subtree so you can browse into it. `localizedStandardContains`
    /// is case- and diacritic-insensitive, which matters for the Cyrillic vault paths.
    ///
    /// Only folders kept for a DESCENDANT's sake are recorded in [autoExpand]; a name match
    /// returns early without recording, which is what keeps a common substring from unfolding
    /// an entire subtree.
    private func pruned(_ node: TreeNode, query: String, autoExpand: inout Set<String>) -> TreeNode? {
        let matches = node.name.localizedStandardContains(query)
        guard node.type == .dir else { return matches ? node : nil }
        if matches { return node }
        let kids = (node.children ?? []).compactMap { pruned($0, query: query, autoExpand: &autoExpand) }
        guard !kids.isEmpty else { return nil }
        autoExpand.insert(node.path)
        var copy = node
        copy.children = kids
        return copy
    }

    // MARK: Tags tab — saved searches + the tag taxonomy (the "find by metadata" pane,
    // as opposed to Notes which is the file structure). Tags get a filter for large vaults.
    @ViewBuilder private var tagsTab: some View {
        if model.tags.isEmpty && model.savedSearches.isEmpty {
            EmptyStateView(icon: "number", title: "No tags yet",
                           message: "Tags from your notes show up here. Add #tags or a frontmatter tags: list.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if !model.savedSearches.isEmpty { savedSearchSection }
                    if !model.tags.isEmpty { tagsList }
                }
                .padding(Spacing.sm)
            }
        }
    }

    private var tagsList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Tags", systemImage: "number")
                .padding(.horizontal, Spacing.sm)
            if model.tags.count > 12 { tagFilterField }
            LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(filteredTags) { tag in tagRow(tag) }
            }
        }
    }

    private var tagFilterField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
            TextField("Filter tags", text: $tagFilter)
                .textFieldStyle(.plain)
                .font(Typography.callout)
            if !tagFilter.isEmpty {
                Button { tagFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ThemeColor.textTertiary)
                .accessibilityLabel("Clear tag filter")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .padding(.horizontal, Spacing.sm)
    }

    private var filteredTags: [Tags.Tag] {
        let q = tagFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.tags }
        return model.tags.filter { $0.tag.lowercased().contains(q) }
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
    private var treeHeader: some View {
        HStack {
            SectionLabel("Notes", systemImage: "folder")
            Spacer(minLength: 0)
            Button {
                if let path = app.selectedPath {
                    withAnimation(Motion.quick) { model.reveal(path) }
                }
            } label: {
                Image(systemName: "scope")
                    .imageScale(.small)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(app.selectedPath == nil)
            .help("Reveal the open note in the tree")
            .accessibilityLabel("Reveal open note in the tree")
            Button { Task { await model.load() } } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
            .help("Refresh file list")
            .accessibilityLabel("Refresh notes")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
    }

    private var fileTreeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if model.tree != nil {
                let filtered = filteredTree
                let roots = filtered.roots
                if roots.isEmpty && !trimmedTreeFilter.isEmpty {
                    Text("No notes or folders match “\(trimmedTreeFilter)”.")
                        .font(Typography.callout)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .padding(.horizontal, Spacing.sm)
                } else {
                    // Render the root's children directly; the "vault" root itself is
                    // implied by the pane, so we don't show it as a row.
                    // While filtering, only the folders leading to a deeper match open
                    // automatically — see FilteredTree.autoExpand.
                    ForEach(roots) { node in
                        TreeNodeRow(node: node, depth: 0, model: model, app: app,
                                    autoExpand: filtered.autoExpand)
                    }
                }
            }
        }
    }

    // MARK: pinned notes — the few you reach for daily, one click away above the tree.
    // Hidden while a filter or theme narrows the tree: the tree IS the answer then.
    private var showsPinned: Bool {
        trimmedTreeFilter.isEmpty && app.themeFilter == nil && !model.pinnedNotes.isEmpty
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Pinned", systemImage: "pin")
                .padding(.horizontal, Spacing.sm)
            ForEach(model.pinnedNotes, id: \.self) { path in
                ListRow(title: (path as NSString).lastPathComponent,
                        subtitle: (path as NSString).deletingLastPathComponent,
                        isSelected: app.selectedPath == path) {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(ThemeColor.accentMuted)
                } action: {
                    app.open(path: path)
                }
                .contextMenu {
                    Button { model.togglePin(path) } label: { Label("Unpin", systemImage: "pin.slash") }
                    Button { model.reveal(path) } label: { Label("Reveal in Tree", systemImage: "scope") }
                }
                .accessibilityLabel("Pinned note \((path as NSString).lastPathComponent)")
            }
        }
    }

    // MARK: tags
    private func tagRow(_ tag: Tags.Tag) -> some View {
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
        .help("Import Obsidian notes into \(app.vault.activeVault?.name ?? "this vault")…")
        .accessibilityLabel("Import notes into current vault")
    }
}

// MARK: - Tree row (recursive)
private struct TreeNodeRow: View {
    let node: TreeNode
    let depth: Int
    @ObservedObject var model: SidebarModel
    let app: AppModel
    /// Folders the sidebar filter wants open — those holding a deeper match. Empty when no
    /// filter is active. A folder that matched on its own name is NOT in here: it renders
    /// collapsed so a common substring can't unfold its whole subtree.
    var autoExpand: Set<String> = []

    @FocusState private var focused: Bool
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private var isDir: Bool { node.type == .dir }
    private var isExpanded: Bool { autoExpand.contains(node.path) || model.expanded.contains(node.path) }
    private var isSelected: Bool { app.selectedPath == node.path }
    private var hovering: Bool { model.hoveredPath == node.path }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            row
                .id(node.path)   // scroll anchor for SidebarModel.reveal(_:)
            if isDir && isExpanded {
                ForEach(node.children ?? []) { child in
                    TreeNodeRow(node: child, depth: depth + 1, model: model, app: app,
                                autoExpand: autoExpand)
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
    // Both carry "Copy Path" — the vault-relative path is the reference you hand an AI agent.
    @ViewBuilder private var contextMenuContent: some View {
        if isDir {
            Button {
                withAnimation(Motion.quick) { model.toggle(node.path) }
            } label: {
                Label(isExpanded ? "Collapse" : "Expand",
                      systemImage: isExpanded ? "chevron.down" : "chevron.right")
            }
            Divider()
            copyPathButton
            if noteCount > 0 {
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Folder…", systemImage: "trash")
                }
            }
        } else {
            Button { app.open(path: node.path) } label: { Label("Open", systemImage: "doc.text") }
            Button { model.togglePin(node.path) } label: {
                model.isPinned(node.path)
                    ? Label("Unpin", systemImage: "pin.slash")
                    : Label("Pin", systemImage: "pin")
            }
            Divider()
            copyPathButton
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete Note…", systemImage: "trash")
            }
        }
    }

    private var copyPathButton: some View {
        Button { copyPath() } label: { Label("Copy Path", systemImage: "doc.on.doc") }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
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

    /// Recursively soft-delete every note in the folder. Continues past failures and
    /// reports how many of the total couldn't be deleted (not just the first error), so
    /// a partial failure isn't silently hidden. The engine serializes the writes.
    private func deleteFolder() async {
        let paths = notePaths(node)
        var failed = 0
        var firstError: String?
        for path in paths {
            do {
                try await trash(path)
                if app.selectedPath == path { app.selectedPath = nil }
            } catch let e as SvodClientError {
                failed += 1; if firstError == nil { firstError = e.errorDescription }
            } catch {
                failed += 1; if firstError == nil { firstError = error.localizedDescription }
            }
        }
        app.refreshActiveVault()
        if failed > 0 {
            deleteError = failed == 1
                ? (firstError ?? "One note couldn’t be deleted.")
                : "\(failed) of \(paths.count) notes couldn’t be deleted. \(firstError ?? "")"
        }
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
