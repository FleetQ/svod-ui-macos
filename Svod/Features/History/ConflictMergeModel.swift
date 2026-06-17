import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Backs ConflictMergeView. Two init paths:
//
// 1. ConflictBody (write 409):
//    BASE   = client.revision(path, revision: conflict.expected)
//    THEIRS = conflict.currentContent (rev conflict.current)
//    YOURS  = app.editor.draft (fallback client.readFile)
//    Save: writeFile with expectedRevision = conflict.current
//
// 2. Conflicts.Item (GET /conflicts v0.3.0+):
//    BASE / OURS / THEIRS arrive inline — no network fetch needed.
//    Save: resolveConflict via ConflictsListModel.resolve(path:content:expectedRevision:)
// ════════════════════════════════════════════════════════════════════════

/// Which source drove this merge session.
private enum MergeSource {
    case writeConflict(ConflictBody)
    case conflictItem(Conflicts.Item, listModel: ConflictsListModel)
}

@MainActor
final class ConflictMergeModel: ObservableObject {
    private let client: SvodClient
    private weak var app: AppModel?
    private let source: MergeSource

    // Public path for both init paths — the header and accessibility labels use it.
    let path: String

    // The original ConflictBody, nil when driven from Conflicts.Item.
    var conflict: ConflictBody? {
        guard case .writeConflict(let body) = source else { return nil }
        return body
    }

    @Published var base: String = ""
    @Published var yours: String = ""
    @Published var theirs: String = ""
    @Published var merged: String = ""
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    /// Set once the user picks a side or hand-edits, so we don't clobber their choice on reload.
    @Published private(set) var resolved = false

    // MARK: Init — write 409 path (existing)
    init(conflict: ConflictBody, client: SvodClient, app: AppModel?) {
        self.source = .writeConflict(conflict)
        self.path = conflict.path
        self.client = client
        self.app = app
    }

    // MARK: Init — GET /conflicts item path (v0.3.0+)
    init(item: Conflicts.Item, listModel: ConflictsListModel, client: SvodClient) {
        self.source = .conflictItem(item, listModel: listModel)
        self.path = item.path
        self.client = client
        self.app = nil
        // Content arrives inline — mark loading false immediately.
        self.isLoading = false
        self.base   = item.base   ?? ""
        self.yours  = item.ours   ?? ""   // "ours" in the contract maps to "yours" in the view
        self.theirs = item.theirs ?? ""
        self.merged = item.ours   ?? ""   // seed from ours — the common case
    }

    // MARK: -

    func load() async {
        switch source {
        case .writeConflict(let body):
            await loadFromConflictBody(body)
        case .conflictItem:
            // Content already seeded in init — nothing to fetch.
            isLoading = false
        }
    }

    private func loadFromConflictBody(_ body: ConflictBody) async {
        isLoading = true
        defer { isLoading = false }

        // THEIRS comes inline on the 409 body.
        theirs = body.currentContent ?? ""

        // YOURS = the in-flight editor draft for this path; fall back to disk.
        if let draft = app?.editor.draft, app?.editor.file?.path == body.path, !draft.isEmpty {
            yours = draft
        } else {
            yours = (try? await client.readFile(path: body.path).content) ?? ""
        }

        // BASE = the revision the client started from.
        if let expected = body.expected,
           let baseContent = try? await client.revision(path: body.path, revision: expected).content {
            base = baseContent
        } else {
            base = ""
        }

        // Seed the editable result with YOURS — the common case is "I want my edit,
        // reconciled against theirs". The user can switch with the buttons below.
        if !resolved { merged = yours }
    }

    func keepYours() { merged = yours; resolved = true }
    func keepTheirs() { merged = theirs; resolved = true }
    func mergedEdited() { resolved = true }

    /// Write the merged buffer. Returns true on success (caller dismisses).
    func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        switch source {
        case .writeConflict(let body):
            return await saveWriteConflict(body)
        case .conflictItem(let item, let listModel):
            return await listModel.resolve(path: item.path, content: merged, expectedRevision: nil)
        }
    }

    private func saveWriteConflict(_ body: ConflictBody) async -> Bool {
        do {
            let result = try await client.writeFile(path: body.path, content: merged,
                                                    expectedRevision: body.current)
            // Keep the editor coherent with what we just wrote — but only if it's still
            // showing this note. If the user navigated to a different note, don't clobber
            // that buffer with the merged content of another file.
            if app?.editor.file?.path == body.path || app?.selectedPath == body.path {
                app?.editor.file = FileContent(path: result.path, revision: result.revision, content: merged)
                app?.editor.draft = merged
                app?.editor.dirty = false
            }
            return true
        } catch let SvodClientError.conflict(newBody) {
            // It moved again underneath us; re-seat on the newer "theirs".
            theirs = newBody.currentContent ?? theirs
            errorMessage = "It changed again while you were merging \u{2014} review the new \u{201C}Theirs\u{201D} and save once more."
            return false
        } catch let e as SvodClientError {
            errorMessage = e.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
