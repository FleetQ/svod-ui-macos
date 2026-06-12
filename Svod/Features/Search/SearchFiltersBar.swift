import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 2 — Search & ⌘K Command Palette
// ════════════════════════════════════════════════════════════════════════

// MARK: - SearchFiltersBar
//
// Mode segmented control + tag chips + a path-prefix affordance. Everything here
// mutates the model and re-runs the (debounced) search, so filters feel live.
//
// Contract note: the engine's `search` takes `tags` and `pathPrefix` but NO date
// parameter, so there is intentionally no date affordance — adding one would have
// nothing to bind to.

struct SearchFiltersBar: View {
    @ObservedObject var model: SearchModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                modePicker
                if app.vault.hasMultipleVaults {
                    allVaultsToggle
                }
                pathPrefixField
            }
            if !model.availableTags.isEmpty {
                tagChips
            }
        }
    }

    // MARK: all vaults toggle
    private var allVaultsToggle: some View {
        Button {
            model.allVaults.toggle()
            model.search()
        } label: {
            AllVaultsChip(active: model.allVaults)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search all vaults")
        .accessibilityAddTraits(model.allVaults ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(model.allVaults ? "Selected. Activate to search active vault only" : "Activate to search across all vaults")
    }

    // MARK: mode
    private var modePicker: some View {
        Picker("Search mode", selection: Binding(
            get: { model.mode },
            set: { model.mode = $0; model.search() }
        )) {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Search mode")
    }

    // MARK: path prefix
    private var pathPrefixField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(ThemeColor.textTertiary)
            TextField("Path prefix", text: Binding(
                get: { model.pathPrefix ?? "" },
                set: { model.pathPrefix = $0.isEmpty ? nil : $0; model.search() }
            ))
            .textFieldStyle(.plain)
            .font(Typography.caption)
            .foregroundStyle(ThemeColor.textPrimary)
            if model.pathPrefix != nil {
                Button {
                    model.pathPrefix = nil; model.search()
                } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ThemeColor.textTertiary)
                .accessibilityLabel("Clear path prefix")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: Radii.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
            .strokeBorder(ThemeColor.borderSubtle))
        .frame(maxWidth: 200)
        .accessibilityHint("Limit results to a folder")
    }

    // MARK: tag chips
    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(model.availableTags) { tag in
                    let active = model.filterTags.contains(tag.tag)
                    Button { model.toggleTag(tag.tag) } label: {
                        TagChip(tag: tag.tag, count: tag.count, active: active)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tag \(tag.tag), \(tag.count) notes")
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(active ? "Selected. Activate to remove filter" : "Activate to filter by this tag")
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }
}

// MARK: - AllVaultsChip
private struct AllVaultsChip: View {
    let active: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "books.vertical")
                .imageScale(.small)
            Text("All vaults")
                .font(Typography.caption)
        }
        .foregroundStyle(active ? ThemeColor.textOnAccent : ThemeColor.textSecondary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(active ? ThemeColor.accent : ThemeColor.surfaceHover, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? .clear : ThemeColor.borderSubtle))
        .animation(Motion.quick, value: active)
    }
}

// MARK: - TagChip
private struct TagChip: View {
    let tag: String
    let count: Int
    let active: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text("#\(tag)")
                .font(Typography.caption)
            Text("\(count)")
                .font(Typography.caption2)
                .foregroundStyle(active ? ThemeColor.textOnAccent.opacity(0.8) : ThemeColor.textTertiary)
        }
        .foregroundStyle(active ? ThemeColor.textOnAccent : ThemeColor.textSecondary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(active ? ThemeColor.accent : ThemeColor.surfaceHover, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? .clear : ThemeColor.borderSubtle))
        .animation(Motion.quick, value: active)
    }
}

@MainActor private func filtersPreviewApp() -> AppModel {
    let app = AppModel(client: MockSvodClient.preview)
    app.search.availableTags = [
        .init(tag: "svod", count: 14), .init(tag: "architecture", count: 8),
        .init(tag: "agents", count: 6), .init(tag: "index", count: 5),
    ]
    app.search.filterTags = ["architecture"]
    app.search.pathPrefix = "vault/adr"
    return app
}

#Preview("Filters") {
    let app = filtersPreviewApp()
    SearchFiltersBar(model: app.search)
        .environmentObject(app)
        .padding(Spacing.lg)
        .frame(width: 560)
        .background(ThemeColor.surfaceRaised)
}

#Preview("Filters – All vaults toggle") {
    let app = filtersPreviewApp()
    app.search.allVaults = true
    return SearchFiltersBar(model: app.search)
        .environmentObject(app)
        .padding(Spacing.lg)
        .frame(width: 560)
        .background(ThemeColor.surfaceRaised)
}
