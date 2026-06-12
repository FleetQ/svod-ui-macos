import SwiftUI
import AppKit

// MARK: - ImportView  (Teammate 5 — Features/Import)
//
// "Import Obsidian vault": folder picker → POST /import → imported/unchanged/skipped
// counts, targeting the active vault. PLACEHOLDER built in the foundation so the
// menu command and Settings can reach it; Teammate 5 owns and refines this file.

struct ImportView: View {
    @EnvironmentObject var app: AppModel
    @State private var result: ImportResult?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Import Obsidian Vault")
                .font(Typography.headline)
            Text("Markdown + attachments are imported through the engine. Re-running is idempotent; differing files are skipped, never clobbered.")
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textSecondary)

            Button {
                pickAndImport()
            } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus")
            }
            .disabled(busy)

            if busy { ProgressView().controlSize(.small) }
            if let r = result {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Label("\(r.imported.count) imported", systemImage: "plus.circle").foregroundStyle(ThemeColor.sync)
                    Label("\(r.unchanged.count) unchanged", systemImage: "equal.circle").foregroundStyle(ThemeColor.textSecondary)
                    Label("\(r.skipped.count) skipped", systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColor.conflict)
                }
                .font(Typography.callout)
            }
            if let error {
                Text(error).font(Typography.caption).foregroundStyle(ThemeColor.danger)
            }
        }
        .padding(Spacing.md)
        .frame(minWidth: 360)
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runImport(source: url.path) }
    }

    private func runImport(source: String) async {
        busy = true; error = nil; result = nil
        defer { busy = false }
        do {
            result = try await app.client.importVault(source: source, into: nil, vault: app.vault.activeVaultId)
            app.reloadVaults()
        } catch let e as SvodClientError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    ImportView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
}
