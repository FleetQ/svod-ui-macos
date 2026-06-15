import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 2 — Search & ⌘K Command Palette (Features/Search/)
// ════════════════════════════════════════════════════════════════════════

// MARK: - CommandPaletteView
//
// Spotlight-grade ⌘K palette. The shell (RootView) owns VISIBILITY via
// `app.commandPaletteVisible` and renders this inside a dimmed top overlay; this
// view owns the panel chrome and all behavior. Fast, keyboard-first, quiet.
//
// Keyboard contract:
//   • field auto-focuses on appear
//   • ↑ / ↓ move `selectedIndex` (handled on the field so they work while typing)
//   • ⏎ opens the selected hit (app.open closes the palette)
//   • Esc dismisses the palette (single press)
//
// Integration: CommandPaletteSlot's body becomes `CommandPaletteView(model: app.search)`.

struct CommandPaletteView: View {
    @ObservedObject var model: SearchModel
    @EnvironmentObject var app: AppModel

    @FocusState private var fieldFocused: Bool

    private let panelWidth: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(ThemeColor.separator)
            filtersSection
            Divider().overlay(ThemeColor.separator)
            resultsSection
            footer
        }
        .frame(width: panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radii.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.lg, style: .continuous)
            .strokeBorder(ThemeColor.borderSubtle))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear {
            fieldFocused = true
            Task { await model.loadTags() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search palette")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: search field
    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ThemeColor.textTertiary)
            TextField("Search notes…", text: $model.query)
                .textFieldStyle(.plain)
                .font(Typography.title3.weight(.regular))
                .foregroundStyle(ThemeColor.textPrimary)
                .focused($fieldFocused)
                .onChange(of: model.query) { _, _ in model.search() }
                .onSubmit { activateSelection() }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { handleEscape(); return .handled }
                .accessibilityLabel("Search notes")
            if model.isSearching {
                ProgressView().controlSize(.small)
            } else if !model.query.isEmpty {
                Button { model.query = ""; model.search(); fieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ThemeColor.textTertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: filters
    private var filtersSection: some View {
        SearchFiltersBar(model: model)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
    }

    // MARK: results
    @ViewBuilder private var resultsSection: some View {
        Group {
            if let error = model.errorMessage {
                ErrorStateView(message: error) { Task { await model.runSearch() } }
                    .frame(height: 240)
            } else if !model.results.isEmpty {
                resultsList   // show results whenever there are any — incl. tag-only browse
            } else if model.isSearching && !model.hasSearched {
                LoadingStateView("Searching…").frame(height: 240)
            } else if model.hasSearched {
                EmptyStateView(icon: "text.magnifyingglass", title: "No matches", message: noMatchMessage)
                    .frame(height: 240)
            } else {
                idlePrompt
            }
        }
    }

    private var noMatchMessage: String {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty
            ? "No notes match the current filters."
            : "Nothing matched “\(q)”. Try a different term or relax the filters."
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, hit in
                        SearchResultRow(hit: hit, isSelected: index == model.selectedIndex) {
                            model.selectedIndex = index
                            activateSelection()
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.selectedIndex) { _, idx in
                withAnimation(Motion.quick) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    private var idlePrompt: some View {
        let title = model.allVaults ? "Search all vaults" : "Search your vault"
        let msg = "Find notes by keyword or meaning. Use ↑ ↓ to move, Return to open."
        return EmptyStateView(icon: "magnifyingglass", title: title, message: msg)
            .frame(height: 240)
    }

    // MARK: footer
    private var footer: some View {
        HStack(spacing: Spacing.md) {
            if !model.results.isEmpty {
                Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")")
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            Spacer()
            KeyHint(symbol: "return", label: "Open")
            KeyHint(symbol: "arrow.up.arrow.down", label: "Navigate")
            KeyHint(symbol: "escape", label: "Close")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(ThemeColor.surface.opacity(0.5))
        .accessibilityHidden(true)
    }

    // MARK: actions
    private func activateSelection() {
        guard model.selectedHit != nil else { return }
        model.openSelected()   // app.open(path:) closes the palette
    }

    private func handleEscape() {
        // Esc always closes the palette (single press), regardless of query state.
        app.commandPaletteVisible = false
    }
}

// MARK: - KeyHint
private struct KeyHint: View {
    let symbol: String
    let label: String
    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
            Text(label)
                .font(Typography.caption2)
                .foregroundStyle(ThemeColor.textTertiary)
        }
    }
}

// MARK: - Previews
@MainActor private func palette(_ behavior: MockSvodClient.Behavior = .ok,
                                configure: (SearchModel) -> Void = { _ in }) -> some View {
    let app = AppModel(client: MockSvodClient(behavior: behavior))
    app.commandPaletteVisible = true
    configure(app.search)
    return CommandPaletteView(model: app.search)
        .environmentObject(app)
        .padding(Spacing.xxl)
        .frame(width: 720, height: 640)
        .background(ThemeColor.background)
}

#Preview("Populated") {
    palette { m in
        m.query = "write path"
        m.results = MockSvodClient.hits(for: "write")
        m.hasSearched = true
        m.availableTags = [.init(tag: "svod", count: 14), .init(tag: "architecture", count: 8),
                           .init(tag: "index", count: 5)]
    }
}

#Preview("Empty results") {
    palette { m in
        m.query = "nonexistent term"
        m.results = []
        m.hasSearched = true
    }
}

#Preview("Loading") {
    palette { m in
        m.query = "embeddings"
        m.isSearching = true
    }
}

#Preview("Error") {
    palette { m in
        m.query = "write"
        m.errorMessage = SvodClientError.offline.errorDescription
        m.hasSearched = true
    }
}

#Preview("Filters active") {
    palette { m in
        m.query = "index"
        m.results = MockSvodClient.hits(for: "index")
        m.hasSearched = true
        m.availableTags = [.init(tag: "svod", count: 14), .init(tag: "architecture", count: 8),
                           .init(tag: "index", count: 5), .init(tag: "agents", count: 6)]
        m.filterTags = ["index"]
        m.pathPrefix = "vault/adr"
    }
}

#Preview("Idle") {
    palette()
}

#Preview("Federated – all vaults") {
    palette { m in
        m.query = "retrieval"
        m.allVaults = true
        m.results = MockSvodClient.hits(for: "retrieval", vault: "notes", tagged: true)
                  + MockSvodClient.hits(for: "retrieval", vault: "research", tagged: true)
        m.hasSearched = true
    }
}
