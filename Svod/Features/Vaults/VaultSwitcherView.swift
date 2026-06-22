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
        // Always shown — even with a single vault — so "New Vault" and "Import" are
        // reachable. (Switch targets only appear when there's more than one vault.)
        Menu {
            if model.hasMultipleVaults {
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
            }
            newVaultMenuItem
            importMenuItem
            deleteVaultMenuItem
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
        .help("Vault: \(model.activeVault?.name ?? "—") — switch, create, or import")
        .accessibilityLabel("Vault menu, current vault \(model.activeVault?.name ?? "none")")
    }

    // Dot color for a vault's live sync state. nil ⇒ not synced (solo) ⇒ no dot,
    // so a green "synced" dot never misrepresents a one-way / solo vault.
    private func dotColor(_ s: SyncStatus) -> Color? {
        if s.conflicts > 0 { return ThemeColor.conflict }
        switch s.syncStatus {
        case "inSync", "syncing": return ThemeColor.sync
        case "conflicts":         return ThemeColor.conflict
        case "offline":           return ThemeColor.offline
        case "error":             return ThemeColor.warning
        default:                  return s.role == "solo" ? nil : ThemeColor.sync
        }
    }

    private func dotHelp(_ s: SyncStatus) -> String {
        if s.conflicts > 0 { return "\(s.conflicts) conflict\(s.conflicts == 1 ? "" : "s")" }
        switch s.syncStatus {
        case "syncing": return "Syncing…"
        case "offline": return "Offline"
        case "error":   return "Sync error"
        case "inSync":  return "In sync"
        default:        return "Synced (\(s.role))"
        }
    }

    // Tiny dot for the toolbar button label
    @ViewBuilder private func inlineSyncDot(_ s: SyncStatus) -> some View {
        if let c = dotColor(s) {
            Circle()
                .fill(c)
                .frame(width: 6, height: 6)
                .help(dotHelp(s))
                .accessibilityLabel(dotHelp(s))
        }
    }

    // Text-based indicator inside menu items (SwiftUI menus don't render Circle well).
    // Uses a shape-distinct glyph per state — not color alone — so the status survives
    // for color-blind users and VoiceOver (via the label).
    @ViewBuilder private func syncDotLabel(_ s: SyncStatus) -> some View {
        if s.conflicts > 0 {
            Text("⚠ \(s.conflicts)")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.conflict)
                .accessibilityLabel(dotHelp(s))
        } else if let c = dotColor(s) {
            Text(dotGlyph(s))
                .font(Typography.caption)
                .foregroundStyle(c)
                .accessibilityLabel(dotHelp(s))
        }
    }

    /// Shape-distinct glyph per sync state (✓ in sync, ↻ syncing, ◦ offline, ⚠ error).
    private func dotGlyph(_ s: SyncStatus) -> String {
        switch s.syncStatus {
        case "syncing": return "↻"
        case "offline": return "◦"
        case "error":   return "⚠"
        case "inSync":  return "✓"
        default:        return "✓"
        }
    }

    // "New Vault…" — creates a fresh, empty vault. Hidden on engines without
    // multi-vault support (where creation isn't possible). A `.sheet` inside a Menu
    // never presents, so this only flips an AppModel flag; RootView owns the sheet.
    @ViewBuilder private var newVaultMenuItem: some View {
        if !model.multiVaultUnavailable {
            Button {
                app.newVaultPresented = true
            } label: {
                Label("New Vault…", systemImage: "plus.rectangle.on.folder")
            }
        }
    }

    // "Delete <active>…" — removes the ACTIVE vault (files go to the Trash). Hidden for
    // the default vault and when only one vault exists (the engine refuses both → 409),
    // and on engines without multi-vault support. Confirmation is owned by RootView.
    @ViewBuilder private var deleteVaultMenuItem: some View {
        if !model.multiVaultUnavailable, model.hasMultipleVaults,
           let v = model.activeVault, !v.isDefault {
            Divider()
            Button(role: .destructive) {
                app.vaultPendingDeletion = v
            } label: {
                Label("Delete “\(v.name)”…", systemImage: "trash")
            }
        }
    }

    // "Import notes into <vault>…" — adds Obsidian notes to the ACTIVE vault; it does
    // NOT create a vault (use "New Vault" for that). Flips an AppModel flag; RootView
    // owns the actual sheet (a `.sheet` inside a Menu never presents).
    private var importMenuItem: some View {
        Button {
            app.importPresented = true
        } label: {
            Label("Import notes into \(model.activeVault?.name ?? "this vault")…",
                  systemImage: "square.and.arrow.down")
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
