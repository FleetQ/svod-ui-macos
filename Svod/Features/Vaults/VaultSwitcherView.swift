import SwiftUI

// MARK: - VaultSwitcherView  (Teammate 5 — Features/Vaults)
//
// Toolbar vault picker: shows the active vault name + its sync dot, and lets the
// user switch vaults. Hidden entirely when only one (or no) vault exists.
// Each menu item carries its own sync dot + checkmark for the active vault,
// and flags the default vault. Wired via VaultSwitcherSlot (frozen).

struct VaultSwitcherView: View {
    @ObservedObject var model: VaultModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        if model.hasMultipleVaults {
            Menu {
                ForEach(model.vaults) { v in
                    Button { model.switchVault(v.id) } label: {
                        HStack {
                            // Checkmark on active
                            if v.id == model.activeVaultId {
                                Image(systemName: "checkmark")
                            }
                            Text(v.name + (v.isDefault ? " (default)" : ""))
                            Spacer()
                            // Per-vault sync dot via text if conflicts
                            if let s = v.sync {
                                syncDotLabel(s)
                            }
                        }
                    }
                }
                Divider()
                importMenuItem
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "tray.full")
                        .imageScale(.small)
                    Text(model.activeVault?.name ?? "Vault")
                        .font(Typography.callout)
                    if let s = model.activeVault?.sync { inlineSyncDot(s) }
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(ThemeColor.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch vault — active: \(model.activeVault?.name ?? "—")")
            .accessibilityLabel("Vault switcher, current vault \(model.activeVault?.name ?? "none")")
        }
    }

    // Tiny dot for the toolbar button label
    @ViewBuilder private func inlineSyncDot(_ s: SyncStatus) -> some View {
        Circle()
            .fill(s.conflicts > 0 ? ThemeColor.conflict : ThemeColor.sync)
            .frame(width: 6, height: 6)
            .help(s.conflicts > 0 ? "\(s.conflicts) conflict(s)" : "Synced (\(s.role))")
            .accessibilityLabel(s.conflicts > 0 ? "\(s.conflicts) conflicts" : "synced")
    }

    // Text-based indicator inside menu items (SwiftUI menus don't render Circle well)
    @ViewBuilder private func syncDotLabel(_ s: SyncStatus) -> some View {
        if s.conflicts > 0 {
            Text("⚠ \(s.conflicts)")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.conflict)
        } else {
            Text("●")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.sync)
        }
    }

    // "Import Obsidian Vault…" — a `.sheet` inside a Menu never presents, so this
    // only flips an AppModel flag; RootView owns the actual sheet.
    private var importMenuItem: some View {
        Button {
            app.importPresented = true
        } label: {
            Label("Import Obsidian Vault…", systemImage: "folder.badge.plus")
        }
    }
}

#Preview {
    let app = AppModel(client: MockSvodClient.preview)
    return VaultSwitcherView(model: app.vault)
        .environmentObject(app)
        .task { await app.vault.load() }
        .padding()
}
