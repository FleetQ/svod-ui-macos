import SwiftUI
import AppKit

// MARK: - ImportView  (Teammate 5 — Features/Import)
//
// "Import Obsidian vault": folder picker → POST /import → imported/unchanged/skipped
// counts, targeting the active vault. PLACEHOLDER built in the foundation so the
// menu command and Settings can reach it; Teammate 5 owns and refines this file.

struct ImportView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: ImportResult?
    @State private var busy = false
    @State private var error: String?
    @State private var chosenName: String?

    private var targetVaultName: String { app.vault.activeVault?.name ?? "the default vault" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Import Obsidian Vault").font(Typography.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Markdown + attachments are imported into **\(targetVaultName)** through the engine. Re-running is idempotent; differing files are skipped, never clobbered.")
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                Button {
                    pickAndImport()
                } label: {
                    Label(chosenName == nil ? "Choose folder…" : "Choose another folder…", systemImage: "folder.badge.plus")
                }
                .disabled(busy)
                if let chosenName { Text(chosenName).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary) }
                if busy { ProgressView().controlSize(.small) }
            }

            if let r = result {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Label("\(r.imported.count) imported", systemImage: "plus.circle").foregroundStyle(ThemeColor.sync)
                    Label("\(r.unchanged.count) unchanged", systemImage: "equal.circle").foregroundStyle(ThemeColor.textSecondary)
                    Label("\(r.skipped.count) skipped", systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColor.conflict)
                }
                .font(Typography.callout)
                .padding(.top, Spacing.xxs)
            }
            if let error {
                Text(error).font(Typography.caption).foregroundStyle(ThemeColor.danger)
            }
        }
        .padding(Spacing.lg)
        .frame(minWidth: 420)
        .background(
            Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden()
        )
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose an Obsidian vault folder to import."
        // Async (begin) rather than runModal so a slow disk never freezes the window.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            chosenName = url.lastPathComponent
            Task { await runImport(source: url.path) }
        }
    }

    private func runImport(source: String) async {
        busy = true; error = nil; result = nil
        defer { busy = false }
        do {
            result = try await app.client.importVault(source: source, into: nil, vault: app.vault.activeVaultId)
            app.refreshActiveVault()   // show the new files in the tree
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
