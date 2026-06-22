import SwiftUI

// MARK: - VaultModel  (owned by Teammate 5 — Vaults/Import/Inspector/Activity/Engine)
//
// The active-vault authority. Loads the configured vaults, holds the active vault
// id, and switches it — which redirects the SHARED client (`setActiveVault`) so
// every subsequent per-vault fetch targets the new vault. Switching also asks
// AppModel to reload vault-scoped panes (tree, graph, search) and clear the open note.
//
// Graceful degradation: an engine that predates multi-vault returns 404/“not found”
// for GET /vaults. We then synthesize a single default vault so the rest of the app
// works unchanged (activeVault stays nil ⇒ the engine's implicit default).

@MainActor
public final class VaultModel: ObservableObject {
    public weak var app: AppModel?
    private let client: SvodClient

    @Published public private(set) var vaults: [Vault] = []
    @Published public private(set) var activeVaultId: String?
    @Published public private(set) var loadState: LoadState = .idle
    /// True when the engine doesn't expose /vaults (single-vault / older engine).
    @Published public private(set) var multiVaultUnavailable = false

    public enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    public init(client: SvodClient) { self.client = client }

    public var activeVault: Vault? {
        vaults.first { $0.id == activeVaultId } ?? vaults.first(where: \.isDefault) ?? vaults.first
    }
    public var hasMultipleVaults: Bool { vaults.count > 1 }

    /// Load the vault list. Selects the default vault as active. Falls back to a
    /// synthetic single vault when the engine doesn't support /vaults.
    public func load() async {
        loadState = .loading
        do {
            let result = try await client.vaults()
            vaults = result.vaults
            multiVaultUnavailable = false
            // Keep the current selection if still valid, else pick the default.
            if activeVaultId == nil || !vaults.contains(where: { $0.id == activeVaultId }) {
                let def = result.defaultVault
                activeVaultId = def?.id
                client.setActiveVault(def?.isDefault == true ? nil : def?.id)
            }
            loadState = .loaded
        } catch let e as SvodClientError where e.isNotImplemented || e.isNotFoundLike {
            // Engine has no multi-vault concept — present a single implicit vault.
            fallBackToSingleVault()
        } catch let e as SvodClientError where e.isOffline {
            loadState = .failed("offline")
        } catch {
            // Unknown failure — degrade to single vault rather than blocking the app.
            fallBackToSingleVault()
        }
    }

    private func fallBackToSingleVault() {
        vaults = [Vault(id: "default", name: "Vault", isDefault: true, sync: nil)]
        activeVaultId = "default"
        client.setActiveVault(nil)   // nil ⇒ engine default vault
        multiVaultUnavailable = true
        loadState = .loaded
    }

    /// Create a new vault via the engine, refresh the list, and switch to it.
    /// Re-throws so the caller (NewVaultView) can surface engine errors —
    /// duplicate id, an unsupported engine, a bad path, etc.
    @discardableResult
    public func createVault(id: String, name: String?, path: String?) async throws -> Vault {
        let created = try await client.createVault(id: id, name: name, path: path)
        await load()                 // re-fetch the authoritative list (now includes it)
        switchVault(created.id)      // make the new vault active
        return created
    }

    /// Switch the active vault and reload vault-scoped state across the app.
    public func switchVault(_ id: String) {
        guard id != activeVaultId, vaults.contains(where: { $0.id == id }) else { return }
        activeVaultId = id
        // The default vault is addressed by omitting ?vault=; others by id.
        let isDefault = vaults.first { $0.id == id }?.isDefault == true
        client.setActiveVault(isDefault ? nil : id)
        app?.didSwitchVault()
    }

    public func sync(for id: String) -> SyncStatus? { vaults.first { $0.id == id }?.sync }
}

private extension SvodClientError {
    /// A 404 (or transport "not found") — used to detect engines without /vaults.
    var isNotFoundLike: Bool {
        if case .notFound = self { return true }
        return false
    }
}
