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
    @Published public var draft: String = ""
    @Published public var isLoading = false
    @Published public var isSaving = false
    @Published public var errorMessage: String?
    @Published public var focusMode = false
    @Published public var dirty = false

    // Editor-feature state (added by Teammate 1; foundation surface above is intact).
    /// Bare note names in the vault (for [[wikilink]] autocomplete), e.g. "architecture".
    @Published public var noteNames: [String] = []
    /// Resolution of this note's outlinks: target → resolved path (nil == unresolved).
    @Published public var linkResolution: [String: String?] = [:]

    public init(client: SvodClient) { self.client = client }

    public var currentRevision: String? { file?.revision }

    public func load(path: String) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let f = try await client.readFile(path: path)
            self.file = f
            self.draft = f.content
            self.dirty = false
            await loadSidecar(path: path)
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Vault note list + this note's link resolution, used for autocomplete and
    /// link coloring. Failures here are non-fatal — the note still loads.
    private func loadSidecar(path: String) async {
        if let root = try? await client.tree() {
            noteNames = Self.noteNames(in: root)
        }
        if let links = try? await client.fileLinks(path: path) {
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

    /// Resolved path for a wikilink target, if known.
    public func resolvedPath(for target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let entry = linkResolution[t], let p = entry { return p }
        return nil
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
