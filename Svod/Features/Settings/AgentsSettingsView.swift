import SwiftUI
import AppKit
import Security

// LLM Access — manage the MCP agents the engine authorizes (engine ≥ contract 0.17.0).
// Each agent is one LLM client (Claude Desktop, LM Studio, a Foundry, …) with a bearer
// token, a role (read-only / read-write), and the vaults it may reach. Adding or revoking
// here is hot-applied by the engine — no restart. The token is generated locally, written
// to a 0600 file, and handed to the engine only as a `file:` Secrets reference; the raw
// value never crosses the App API (same model as the embedder key and the GitHub token).
// Degrades to a calm note on engines without /agents (apiVersion < 0.17.0).

struct AgentsSettingsView: View {
    @EnvironmentObject var app: AppModel

    @State private var info: AgentsInfo?
    @State private var unavailable = false
    @State private var busy = false
    @State private var statusMsg: String?
    @State private var editing: AgentDraft?
    @State private var pendingDelete: Agent?

    private var client: SvodClient { app.client }

    var body: some View {
        Form {
            if unavailable {
                Section {
                    Label("LLM access needs a newer Svod engine.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("Update the engine to contract 0.17.0+ to manage which LLMs may reach your vaults over MCP.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                connectionSection
                agentsSection
            }
            if let statusMsg {
                Section { Text(statusMsg).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .sheet(item: $editing) { draft in
            AgentEditSheet(draft: draft, vaults: app.vault.vaults) { result in
                editing = nil
                if let result { Task { await save(result) } }
            }
        }
        .confirmationDialog("Revoke access for this LLM?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { agent in
            Button("Revoke \(agent.name)", role: .destructive) { Task { await delete(agent) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { agent in
            Text("“\(agent.name)” will no longer be able to reach your vaults on its next request. The stored token file is deleted too.")
        }
    }

    // MARK: connection

    @ViewBuilder private var connectionSection: some View {
        if let url = info?.mcpUrl, !url.isEmpty {
            Section("MCP endpoint") {
                HStack {
                    Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy MCP URL")
                }
                Text("Point an LLM client's MCP server at this URL and authenticate with the agent's token.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: agents

    @ViewBuilder private var agentsSection: some View {
        Section("Authorized LLMs") {
            let agents = info?.agents ?? []
            if agents.isEmpty {
                Text("No LLMs are authorized yet. Add one to let it reach your vaults over MCP.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(agents) { agent in
                AgentRow(agent: agent)
                    .contextMenu { rowMenu(agent) }
                    .swipeActions { Button("Revoke", role: .destructive) { pendingDelete = agent } }
            }
        }
        Section {
            Button { editing = .new(defaultVault: app.vault.activeVaultId) } label: {
                Label("Add LLM…", systemImage: "plus")
            }
            .disabled(busy)
        }
    }

    @ViewBuilder private func rowMenu(_ agent: Agent) -> some View {
        Button("Edit…") { editing = .edit(agent) }
        Button("Copy token") { copyToken(agent) }
        Button("Copy connection") { copyConnection(agent) }
        Divider()
        Button("Revoke…", role: .destructive) { pendingDelete = agent }
    }

    // MARK: actions

    private func load() async {
        do {
            info = try await client.agents()
            unavailable = false
        } catch let e as SvodClientError where e.isNotImplemented { unavailable = true }
        catch let e as SvodClientError where isNotFound(e) { unavailable = true }
        catch let e as SvodClientError where e.isOffline { _ = e }   // keep last good list
        catch let e as SvodClientError { statusMsg = e.errorDescription }
        catch { statusMsg = error.localizedDescription }
    }

    private func save(_ result: AgentDraft.Result) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            // Generated a fresh token ⇒ write the 0600 file and hand over only a `file:` ref.
            let tokenRef: String?
            if let raw = result.newToken {
                tokenRef = try Self.storeToken(raw, agentId: result.agentId)
            } else { tokenRef = nil }   // editing without rotating ⇒ keep existing ref

            if result.isNew {
                _ = try await client.createAgent(CreateAgentRequest(
                    agentId: result.agentId, name: result.name, role: result.role,
                    vaults: result.vaults, tokenRef: tokenRef ?? "", prompt: result.prompt))
            } else {
                _ = try await client.updateAgent(id: result.agentId, UpdateAgentRequest(
                    name: result.name, role: result.role, vaults: result.vaults,
                    tokenRef: tokenRef, prompt: result.prompt))
            }
            await load()
        } catch let e as SvodClientError where e.isNotImplemented { unavailable = true }
        catch let e as SvodClientError { statusMsg = mapError(e) }
        catch { statusMsg = error.localizedDescription }
    }

    private func delete(_ agent: Agent) async {
        busy = true; defer { busy = false }
        pendingDelete = nil
        do {
            try await client.deleteAgent(id: agent.agentId)
            Self.removeTokenFile(for: agent.tokenRef)
            await load()
        } catch let e as SvodClientError where isNotFound(e) { await load() }   // already gone
        catch let e as SvodClientError { statusMsg = mapError(e) }
        catch { statusMsg = error.localizedDescription }
    }

    private func mapError(_ e: SvodClientError) -> String {
        switch e {
        case .http(409, _), .conflict: return "An LLM with that identifier already exists."
        case .http(422, _): return "The token must be a Secrets reference (the app handles this automatically)."
        case .notFound: return "That LLM no longer exists — refreshing."
        default: return e.errorDescription ?? "Something went wrong."
        }
    }

    private func isNotFound(_ e: SvodClientError) -> Bool {
        if case .notFound = e { return true }
        if case .http(404, _) = e { return true }
        return false
    }

    // MARK: clipboard

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyToken(_ agent: Agent) {
        if let raw = Self.readToken(agent.tokenRef) { copy(raw); statusMsg = "Token for \(agent.name) copied." }
        else { copy(agent.tokenRef); statusMsg = "Token isn't a local file — copied its reference instead." }
    }

    private func copyConnection(_ agent: Agent) {
        let url = info?.mcpUrl ?? ""
        let token = Self.readToken(agent.tokenRef) ?? agent.tokenRef
        var lines = ["MCP URL: \(url)", "Token: \(token)"]
        if let p = agent.prompt, !p.isEmpty { lines.append("System prompt:\n\(p)") }
        copy(lines.joined(separator: "\n"))
        statusMsg = "Connection details for \(agent.name) copied."
    }

    // MARK: token secret storage — a local 0600 file handed to the engine as a `file:`
    // ref (mirrors the embedder key + GitHub token). The raw token never crosses the API.

    static func tokenFileURL(agentId: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Svod", isDirectory: true)
            .appendingPathComponent("agent-\(agentId)-token.secret")
    }

    static func storeToken(_ token: String, agentId: String) throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Svod", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("agent-\(agentId)-token.secret")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try token.write(to: file, atomically: false, encoding: .utf8)
        return "file:\(file.path)"
    }

    /// Read back the raw token from a `file:` ref so it can be copied. Non-file refs
    /// (`env:`/`keychain:`) resolve outside the app → nil (caller copies the ref instead).
    static func readToken(_ ref: String) -> String? {
        guard ref.hasPrefix("file:") else { return nil }
        let path = String(ref.dropFirst("file:".count))
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeTokenFile(for ref: String) {
        guard ref.hasPrefix("file:") else { return }
        let path = String(ref.dropFirst("file:".count))
        // Only remove files the app itself manages (under Application Support/Svod).
        guard path.contains("/Svod/agent-") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A 256-bit URL-safe random bearer token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Row

private struct AgentRow: View {
    let agent: Agent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).fontWeight(.medium)
                Text(agent.vaults.isEmpty ? "default vault" : agent.vaults.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(agent.role == "WRITE" ? "Read · Write" : "Read only")
                .font(.caption2).monospaced()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

// MARK: - Add / Edit sheet

/// The sheet's working state. Identifiable so `.sheet(item:)` drives presentation.
struct AgentDraft: Identifiable {
    let id = UUID()
    let isNew: Bool
    var name: String
    var agentId: String
    var role: String
    var selectedVaults: Set<String>
    var prompt: String
    let existingTokenRef: String?

    struct Result {
        let isNew: Bool
        let agentId: String
        let name: String
        let role: String
        let vaults: [String]
        let prompt: String?
        /// A freshly generated raw token to persist (nil ⇒ keep the existing ref on edit).
        let newToken: String?
    }

    static func new(defaultVault: String?) -> AgentDraft {
        AgentDraft(isNew: true, name: "", agentId: "", role: "WRITE",
                   selectedVaults: Set([defaultVault].compactMap { $0 }), prompt: "", existingTokenRef: nil)
    }
    static func edit(_ a: Agent) -> AgentDraft {
        AgentDraft(isNew: false, name: a.name, agentId: a.agentId, role: a.role,
                   selectedVaults: Set(a.vaults), prompt: a.prompt ?? "", existingTokenRef: a.tokenRef)
    }
}

private struct AgentEditSheet: View {
    @State var draft: AgentDraft
    let vaults: [Vault]
    let onDone: (AgentDraft.Result?) -> Void

    @State private var idEdited = false
    @State private var regenerate = false
    @State private var generatedToken: String = AgentsSettingsView.generateToken()

    private var idValid: Bool { draft.agentId.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil }
    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && idValid }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                        .onChange(of: draft.name) { _, v in if draft.isNew && !idEdited { draft.agentId = slug(v) } }
                    TextField("Identifier", text: $draft.agentId)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!draft.isNew)        // id is the config key — immutable once created
                        .onChange(of: draft.agentId) { _, _ in if draft.isNew { idEdited = true } }
                    if draft.isNew && !draft.agentId.isEmpty && !idValid {
                        Text("Lowercase letters, digits, “-” and “_”; must start with a letter or digit.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Access") {
                    Picker("Role", selection: $draft.role) {
                        Text("Read only").tag("READ_ONLY")
                        Text("Read · Write").tag("WRITE")
                    }
                    if vaults.isEmpty {
                        Text("Default vault").foregroundStyle(.secondary)
                    } else {
                        ForEach(vaults) { v in
                            Toggle(v.name, isOn: Binding(
                                get: { draft.selectedVaults.contains(v.id) },
                                set: { on in if on { draft.selectedVaults.insert(v.id) } else { draft.selectedVaults.remove(v.id) } }))
                        }
                        Text("No vault selected ⇒ the default vault only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                tokenSection

                Section("System prompt (optional)") {
                    TextEditor(text: $draft.prompt).frame(minHeight: 70).font(.callout)
                    Text("Copied alongside the connection details for you to paste into the client. Not enforced by the engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.isNew ? "Add LLM" : "Save") { onDone(buildResult()) }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(Spacing.md)
        }
        .frame(width: 460, height: 540)
    }

    @ViewBuilder private var tokenSection: some View {
        Section("Token") {
            if draft.isNew || regenerate {
                HStack {
                    Text(generatedToken).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { copy(generatedToken) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy token")
                }
                Text("Copy this now and paste it into the LLM client — it's stored in a local 0600 file and the engine only ever sees a file reference.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("A token is already set. Regenerate to issue a new one (the old token stops working).")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Regenerate token") { regenerate = true; generatedToken = AgentsSettingsView.generateToken() }
            }
        }
    }

    private func buildResult() -> AgentDraft.Result {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String? = (draft.isNew || regenerate) ? generatedToken : nil
        return .init(isNew: draft.isNew, agentId: draft.agentId, name: name, role: draft.role,
                     vaults: draft.selectedVaults.sorted(), prompt: prompt.isEmpty ? nil : prompt, newToken: token)
    }

    private func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        return out
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

#Preview("LLM Access") {
    AgentsSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 720, height: 560)
}
