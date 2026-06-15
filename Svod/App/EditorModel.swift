import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter (Features/Editor/)
// Foundation provides this stub + its public surface. Flesh out the body here;
// keep `load(path:)` / `save()` signatures so the shell keeps working.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class EditorModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var file: FileContent?
    @Published public var draft: String = "" {
        didSet {
            guard !suppressAutosave, draft != oldValue else { return }
            if !dirty { dirty = true }
            scheduleAutosave()
        }
    }
    @Published public var isLoading = false
    @Published public var isSaving = false
    @Published public var errorMessage: String?
    @Published public var focusMode = false
    /// Edit (CodeMirror source) vs Preview (rendered markdown) in the web editor.
    @Published public var previewMode = true
    @Published public var dirty = false

    // Editor-feature state (added by Teammate 1; foundation surface above is intact).
    /// Bare note names in the vault (for [[wikilink]] autocomplete), e.g. "architecture".
    @Published public var noteNames: [String] = []
    /// Full note paths in the vault, for resolving wikilink targets to a path without
    /// waiting on the (slow) /file/links call.
    @Published public var notePaths: Set<String> = []
    /// Resolution of this note's outlinks: target → resolved path (nil == unresolved).
    @Published public var linkResolution: [String: String?] = [:]

    public init(client: SvodClient) { self.client = client }

    public var currentRevision: String? { file?.revision }

    private var suppressAutosave = false
    private var autosaveTask: Task<Void, Never>?

    /// Debounced autosave, only when the setting is on. Cancels any in-flight wait
    /// so a burst of keystrokes collapses into one write.
    private func scheduleAutosave() {
        guard app?.settings.autosave == true else { return }
        autosaveTask?.cancel()
        let ms = app?.settings.autosaveDebounceMs ?? 1200
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(200, ms)) * 1_000_000)
            if Task.isCancelled { return }
            await self?.save()
        }
    }

    public func load(path: String) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let f = try await client.readFile(path: path)
            self.file = f
            suppressAutosave = true
            self.draft = f.content
            suppressAutosave = false
            self.dirty = false
            // Sidecar (vault note list + this note's link resolution) is non-essential for
            // display and can take seconds on link-heavy notes — load it off the critical
            // path so the note opens immediately instead of blocking on /file/links.
            Task { [weak self] in await self?.loadSidecar(path: path) }
        } catch let e as SvodClientError {
            if Task.isCancelled { return }   // superseded by a newer load — not a real error
            self.errorMessage = e.errorDescription
        } catch {
            if Task.isCancelled { return }
            self.errorMessage = error.localizedDescription
        }
    }

    /// Vault note list + this note's link resolution, used for autocomplete and
    /// link coloring. Failures here are non-fatal — the note still loads.
    private func loadSidecar(path: String) async {
        if let root = try? await client.tree() {
            noteNames = Self.noteNames(in: root)
            notePaths = Self.notePaths(in: root)
        }
        if let links = try? await client.fileLinks(path: path) {
            guard app?.selectedPath == path else { return }   // superseded by a newer selection
            var map: [String: String?] = [:]
            for l in links.outlinks { map[l.target] = l.resolved }
            linkResolution = map
        }
    }

    /// True when `target` resolves to a real note. Falls back to a name match
    /// against the vault list when the engine hasn't reported this link yet.
    public func resolves(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let entry = linkResolution[t] { return entry != nil }
        return noteNames.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
    }

    /// Resolved path for a wikilink target, if known. Prefers the engine's resolution,
    /// then falls back to the vault tree — so links work before /file/links loads (slow
    /// on link-heavy notes) and for links the engine reports unresolved but that exist.
    public func resolvedPath(for target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let entry = linkResolution[t], let p = entry { return p }   // engine-resolved
        guard !t.isEmpty else { return nil }
        let candidate = t.hasSuffix(".md") ? t : t + ".md"
        if notePaths.contains(candidate) { return candidate }          // path-qualified target
        if notePaths.contains(t) { return t }
        let base = (candidate as NSString).lastPathComponent             // bare name → any match
        return notePaths.first { ($0 as NSString).lastPathComponent.caseInsensitiveCompare(base) == .orderedSame }
    }

    public func markDirty() { if !dirty { dirty = true } }

    private static func noteNames(in node: TreeNode) -> [String] {
        var out: [String] = []
        func walk(_ n: TreeNode) {
            if n.type == .file {
                let base = (n.name as NSString).deletingPathExtension
                out.append(base)
            }
            n.children?.forEach(walk)
        }
        walk(node)
        return out.sorted()
    }

    private static func notePaths(in node: TreeNode) -> Set<String> {
        var out = Set<String>()
        func walk(_ n: TreeNode) {
            if n.type == .file { out.insert(n.path) }
            n.children?.forEach(walk)
        }
        walk(node)
        return out
    }

    public func save() async {
        guard let path = file?.path ?? app?.selectedPath else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await client.writeFile(path: path, content: draft, expectedRevision: file?.revision)
            self.file = FileContent(path: result.path, revision: result.revision, content: draft)
            self.dirty = false
        } catch let SvodClientError.conflict(body) {
            app?.presentConflict(body)
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
