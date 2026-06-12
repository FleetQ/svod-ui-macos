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
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
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
