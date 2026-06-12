import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Backs ConflictMergeView. Assembles 3-way data from the 409 ConflictBody:
//   BASE   = client.revision(path, revision: conflict.expected)
//   THEIRS = conflict.currentContent (rev conflict.current)
//   YOURS  = app.editor.draft (fallback client.readFile)
// "Save merged" writes the editable buffer with expectedRevision = conflict.current
// so it lands on top of theirs without losing their change.
// ════════════════════════════════════════════════════════════════════════

@MainActor
final class ConflictMergeModel: ObservableObject {
    private let client: SvodClient
    private weak var app: AppModel?
    let conflict: ConflictBody

    @Published var base: String = ""
    @Published var yours: String = ""
    @Published var theirs: String = ""
    @Published var merged: String = ""
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    /// Set once the user picks a side or hand-edits, so we don't clobber their choice on reload.
    @Published private(set) var resolved = false

    init(conflict: ConflictBody, client: SvodClient, app: AppModel?) {
        self.conflict = conflict
        self.client = client
        self.app = app
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // THEIRS comes inline on the 409 body.
        theirs = conflict.currentContent ?? ""

        // YOURS = the in-flight editor draft for this path; fall back to disk.
        if let draft = app?.editor.draft, app?.editor.file?.path == conflict.path, !draft.isEmpty {
            yours = draft
        } else {
            yours = (try? await client.readFile(path: conflict.path).content) ?? ""
        }

        // BASE = the revision the client started from.
        if let expected = conflict.expected,
           let baseContent = try? await client.revision(path: conflict.path, revision: expected).content {
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

    /// Write the merged buffer on top of THEIRS so neither side is silently dropped.
    /// Returns true on success (caller dismisses).
    func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await client.writeFile(path: conflict.path, content: merged,
                                                    expectedRevision: conflict.current)
            // Keep the editor coherent with what we just wrote.
            app?.editor.file = FileContent(path: result.path, revision: result.revision, content: merged)
            app?.editor.draft = merged
            app?.editor.dirty = false
            return true
        } catch let SvodClientError.conflict(body) {
            // It moved again underneath us; re-seat on the newer "theirs".
            theirs = body.currentContent ?? theirs
            errorMessage = "It changed again while you were merging — review the new “Theirs” and save once more."
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
