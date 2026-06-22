import SwiftUI
import AppKit

// MARK: - NewVaultView  (Features/Vaults)
//
// Creates a brand-new, empty vault via `POST /api/v1/vaults` (engine ≥ contract
// 0.15.0). This is distinct from ImportView, which adds notes to an EXISTING
// vault. Presented from RootView via `AppModel.newVaultPresented` (a `.sheet`
// inside a Menu never presents on macOS — see VaultSwitcherView).
//
// Degrades gracefully: engines that predate the create endpoint return 404/501,
// which we surface as a "needs a newer engine" note instead of a raw error.

struct NewVaultView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false          // once the user types an id, stop auto-deriving it
    @State private var customPath: String?
    @State private var busy = false
    @State private var error: String?

    private var effectiveId: String { idEdited ? id : Self.slug(name) }
    private var idValid: Bool { Self.isValidId(effectiveId) }
    private var canCreate: Bool { !busy && idValid }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("New Vault").font(Typography.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Text("Creates a new, empty vault — its own git repo, search index, and sync. This is different from **Import**, which adds notes to a vault that already exists.")
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, _ in if !idEdited { id = Self.slug(name) } }

                TextField("Identifier", text: $id)
                    .font(Typography.code)
                    .onChange(of: id) { _, _ in idEdited = true }
                    .help("A unique slug used in URLs and on disk. Auto-filled from the name; edit to override.")

                if !effectiveId.isEmpty && !idValid {
                    Text("Identifier must start with a lowercase letter or digit and contain only a–z, 0–9, “-” or “_”.")
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Location") {
                    HStack(spacing: Spacing.xs) {
                        Text(customPath ?? "Default (managed by the engine)")
                            .font(Typography.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Spacing.xs)
                        Button("Choose…") { pickFolder() }
                        if customPath != nil {
                            Button("Reset") { customPath = nil }
                        }
                    }
                }
            }
            .formStyle(.columns)
            .disabled(busy)

            if let error {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Create Vault") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Spacing.lg)
        .frame(minWidth: 460)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose an empty folder to hold the new vault's files."
        panel.begin { response in
            if response == .OK, let url = panel.url { customPath = url.path }
        }
    }

    private func create() async {
        let vid = effectiveId
        guard Self.isValidId(vid) else { return }
        busy = true; error = nil
        defer { busy = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await app.vault.createVault(id: vid,
                                            name: trimmedName.isEmpty ? nil : trimmedName,
                                            path: customPath)
            dismiss()   // VaultModel already refreshed the list and switched to it
        } catch let e as SvodClientError {
            switch e {
            case .notImplemented, .notFound:
                error = "Creating vaults needs a newer Svod engine."
            case .conflict, .http(409, _):
                error = "A vault with that identifier already exists, or the chosen folder isn’t empty."
            default:
                error = e.errorDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: id helpers

    /// Derive a slug from a display name: lowercase, ASCII alphanumerics kept,
    /// spaces → "-", "-"/"_" preserved, repeats collapsed, leading junk trimmed.
    static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if (ch.isLetter || ch.isNumber), ch.isASCII { out.append(ch) }
            else if ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while let f = out.first, !(f.isLetter || f.isNumber) { out.removeFirst() }
        return out
    }

    static func isValidId(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }
}

#Preview {
    NewVaultView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
}
