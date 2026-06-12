import SwiftUI

// MARK: - VaultSwitcherView  (Teammate 5 — Features/Vaults)
//
// Toolbar vault picker: shows the active vault and switches the whole app to another.
// Hidden entirely when the engine exposes only one (or no) vault, so single-vault
// setups see no extra chrome. PLACEHOLDER built in the foundation so the shell
// compiles and works end-to-end; Teammate 5 owns and refines this file.

struct VaultSwitcherView: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        if model.hasMultipleVaults {
            Menu {
                ForEach(model.vaults) { v in
                    Button {
                        model.switchVault(v.id)
                    } label: {
                        Label {
                            Text(v.name) + Text(v.isDefault ? "  (default)" : "")
                        } icon: {
                            if v.id == model.activeVaultId { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "tray.full")
                    Text(model.activeVault?.name ?? "Vault")
                    if let s = model.activeVault?.sync { syncDot(s) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Active vault")
        }
    }

    @ViewBuilder private func syncDot(_ s: SyncStatus) -> some View {
        Circle()
            .fill(s.conflicts > 0 ? ThemeColor.conflict : ThemeColor.sync)
            .frame(width: 6, height: 6)
            .help(s.conflicts > 0 ? "\(s.conflicts) conflict(s)" : "Synced (\(s.role))")
    }
}

#Preview {
    let app = AppModel(client: MockSvodClient.preview)
    return VaultSwitcherView(model: app.vault)
        .task { await app.vault.load() }
        .padding()
}
