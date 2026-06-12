import SwiftUI

// MARK: - Feature slots
//
// Thin seams between the frozen shell (RootView) and the feature views built by
// the parallel teammates. RootView references ONLY these slots, so it never has
// to change as features land. During integration the lead rewires each slot's
// body to delegate to the teammate's real view (e.g. `EditorView(model: app.editor)`).
//
// Until then each slot renders a calm placeholder so the whole app compiles,
// runs, and previews from day one. This file is owned by foundation/integration,
// NOT by feature teammates.

struct EditorSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → EditorView(model: app.editor)
        Group {
            if app.selectedPath == nil {
                EmptyStateView(icon: "doc.text", title: "No note open",
                               message: "Choose a note from the sidebar, or press ⌘K to search.")
            } else {
                EmptyStateView(icon: "pencil.and.outline", title: "Editor",
                               message: app.selectedPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.editorSurface)
    }
}

struct SidebarSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → SidebarView(model: app.sidebar)
        EmptyStateView(icon: "sidebar.left", title: "Sidebar",
                       message: "File tree · tags · saved searches")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.surface)
    }
}

struct InspectorSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → InspectorView()
        EmptyStateView(icon: "info.circle", title: "Inspector",
                       message: "Backlinks · history · agent activity")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.surface)
    }
}

struct GraphSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → GraphView(model: app.graph)
        EmptyStateView(icon: "point.3.connected.trianglepath.dotted", title: "Graph",
                       message: "Force-directed wikilink graph")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.background)
    }
}

struct HistorySlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → HistoryView(model: app.history)
        EmptyStateView(icon: "clock.arrow.circlepath", title: "History",
                       message: app.selectedPath.map { "Timeline for \($0)" } ?? "Select a note to see its history")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.background)
    }
}

struct CommandPaletteSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        // INTEGRATION: → CommandPaletteView(model: app.search)
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColor.textTertiary)
                Text("Search… (⌘K)").foregroundStyle(ThemeColor.textTertiary)
                Spacer()
            }
            .padding(Spacing.md)
            .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.md, style: .continuous))
        }
        .padding(Spacing.lg)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radii.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.lg, style: .continuous).strokeBorder(ThemeColor.borderSubtle))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
    }
}

struct ConflictSlot: View {
    @EnvironmentObject var app: AppModel
    let conflict: ConflictBody
    var body: some View {
        // INTEGRATION: → ConflictMergeView(conflict: conflict, model: app.history)
        VStack(spacing: Spacing.lg) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 32)).foregroundStyle(ThemeColor.conflict)
            Text("Conflict — \(conflict.path)").font(Typography.title3).foregroundStyle(ThemeColor.textPrimary)
            Text("This note changed underneath you. A 3-way merge will go here.")
                .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Dismiss") { app.dismissConflict() }
                .buttonStyle(SvodButtonStyle(.secondary))
        }
        .padding(Spacing.xxl)
        .frame(width: 640, height: 420)
        .background(ThemeColor.surface)
    }
}
