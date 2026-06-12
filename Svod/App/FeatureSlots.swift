import SwiftUI

// MARK: - Feature slots
//
// Thin seams between the frozen shell (RootView) and the feature views built by
// the parallel teammates. RootView references ONLY these slots, so it never has
// to change as features land. Each slot delegates to its feature's entry view;
// the views read `@EnvironmentObject AppModel` (injected by RootView) and own
// their own load/empty/loading/error states.

struct EditorSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View { EditorView(model: app.editor) }
}

struct SidebarSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View { SidebarView(model: app.sidebar) }
}

struct InspectorSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View { InspectorView() }
}

struct GraphSlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View { GraphView(model: app.graph) }
}

struct HistorySlot: View {
    @EnvironmentObject var app: AppModel
    var body: some View { HistoryView(model: app.history) }
}

struct CommandPaletteSlot: View {
    @EnvironmentObject var app: AppModel
    // CommandPaletteView brings its own panel chrome (material, radius, shadow);
    // RootView supplies only the dimmed overlay + positioning.
    var body: some View { CommandPaletteView(model: app.search) }
}

struct ConflictSlot: View {
    @EnvironmentObject var app: AppModel
    let conflict: ConflictBody
    var body: some View { ConflictMergeView(conflict: conflict, model: app.history) }
}
