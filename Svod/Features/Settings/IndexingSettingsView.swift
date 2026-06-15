import SwiftUI

// Indexing & Embeddings — choose the embedding backend (engine v1.2.0 / contract
// 0.8.0) and watch the background semantic index. Keyword (BM25) search works the
// moment the engine is up; embeddings build in the background, throttled, and can
// be paused/resumed/rebuilt. The embedder is a global engine setting. Degrades to
// a calm note on engines without /embedder (apiVersion < 0.8.0).

struct IndexingSettingsView: View {
    @EnvironmentObject var app: AppModel

    // Provider catalog — label, privacy/speed note, and which fields it needs.
    private enum Provider: String, CaseIterable, Identifiable {
        case none = "none", onnx = "local-onnx", ollama = "local-ollama", openai = "remote-openai"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:   "Keyword only (no embeddings)"
            case .onnx:   "Local — onnx (in-process)"
            case .ollama: "Local — Ollama (Metal GPU)"
            case .openai: "Remote — OpenAI-compatible"
            }
        }
        var note: String {
            switch self {
            case .none:   "BM25 keyword search only. Zero embedding compute, fully private — semantic ranking off."
            case .onnx:   "Runs in-process on CPU. Private and offline; throttled so it won't take over the machine."
            case .ollama: "Uses your local Ollama via Metal GPU — fast and private, low CPU. Needs Ollama running."
            case .openai: "OpenAI-compatible /v1/embeddings (RunPod, OpenAI, Together…). Note: note content leaves your machine. Key is a Secrets reference."
            }
        }
        var needsModel: Bool { self != .none }
        var needsEndpoint: Bool { self == .ollama || self == .openai }
        var needsKey: Bool { self == .openai }
        var defaultModel: String {
            switch self {
            case .onnx: "multilingual-e5-small"
            case .ollama: "nomic-embed-text"
            case .openai: "text-embedding-3-small"
            case .none: ""
            }
        }
        var defaultEndpoint: String { self == .ollama ? "http://127.0.0.1:11434" : "" }
    }

    // Named remote services so the common case is a one-pick + paste-key, instead of
    // hand-typing an endpoint, a model, and a Secrets reference.
    private enum RemoteService: String, CaseIterable, Identifiable {
        case openai, together, custom
        var id: String { rawValue }
        var label: String {
            switch self { case .openai: "OpenAI"; case .together: "Together AI"; case .custom: "Custom / RunPod" }
        }
        var endpoint: String {
            switch self {
            case .openai:   "https://api.openai.com/v1"
            case .together: "https://api.together.xyz/v1"
            case .custom:   ""
            }
        }
        var defaultModel: String {
            switch self {
            case .openai:   "text-embedding-3-small"
            case .together: "BAAI/bge-large-en-v1.5"
            case .custom:   ""
            }
        }
        var isCustom: Bool { self == .custom }
    }

    @State private var provider: Provider = .onnx
    @State private var remoteService: RemoteService = .openai
    @State private var model = ""
    @State private var endpoint = ""          // ollama, or remote-custom
    @State private var apiKey = ""            // raw key the user pastes (never persisted in state)
    @State private var apiKeyRef = ""         // advanced: a Secrets reference typed directly
    @State private var useManualRef = false
    @State private var showAdvanced = false
    @State private var concurrency = 2        // maxThreads — parallel embed requests
    @State private var current: EmbedderInfo?
    @State private var status: IndexStatus?
    @State private var test: EmbedderTestResult?
    @State private var unavailable = false
    @State private var busy = false
    @State private var statusMsg: String?
    // Model picker — populated from the engine per provider; empty ⇒ manual entry.
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var customModel = false     // user chose "Custom…" to type a model not in the list

    /// Whether a remote key file already exists (so the user need not re-paste to tweak the model).
    private var hasStoredKey: Bool { FileManager.default.fileExists(atPath: Self.keyFileURL().path) }

    private var client: SvodClient { app.client }
    private var vaultID: String? { app.vault.activeVaultId }

    var body: some View {
        Form {
            if unavailable {
                Section {
                    Label("Embedding control needs a newer engine (v1.2+ / contract 0.8). Keyword search still works.",
                          systemImage: "lock").font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                }
            } else {
                indexSection
                providerSection
            }
            Section {
                Text("The embedder is a global engine setting. Changing the provider or model changes the vector size, so the vault is re-embedded in the background — keyword search keeps working throughout.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .task(id: app.reloadEpoch) { guard app.reloadEpoch > 0 else { return }; await load() }
        .task { await pollStatus() }
        .task(id: modelsKey) { await loadModels() }
    }

    /// Reloads the model list when the provider, remote service, or endpoint changes.
    private var modelsKey: String { "\(provider.rawValue)|\(remoteService.rawValue)|\(endpoint)" }

    // MARK: semantic index status + controls
    @ViewBuilder private var indexSection: some View {
        Section("Semantic index") {
            HStack(spacing: Spacing.sm) {
                Image(systemName: status?.keywordReady == false ? "hourglass" : "checkmark.circle.fill")
                    .foregroundStyle(status?.keywordReady == false ? ThemeColor.warning : ThemeColor.sync)
                Text(status?.keywordReady == false ? "Building keyword index…" : "Keyword search ready")
                    .font(Typography.callout)
            }
            if let e = status?.embedding {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        Text(embeddingLabel(e)).font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                        Spacer()
                        if let f = e.fraction { Text("\(Int(f * 100))%").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary) }
                    }
                    if e.state == .running || e.state == .paused, let f = e.fraction {
                        ProgressView(value: f).tint(ThemeColor.accent)
                    }
                    if let err = e.error {
                        Label(err, systemImage: "exclamationmark.triangle").font(Typography.caption).foregroundStyle(ThemeColor.danger)
                    }
                }
                HStack(spacing: Spacing.sm) {
                    if e.state == .running {
                        Button { Task { await act { try await client.pauseIndex(vault: vaultID) } } } label: { Label("Pause", systemImage: "pause") }
                    } else if e.state == .paused {
                        Button { Task { await act { try await client.resumeIndex(vault: vaultID) } } } label: { Label("Resume", systemImage: "play") }
                    }
                    Button { Task { await act { try await client.reembed(vault: vaultID) } } } label: { Label("Re-index", systemImage: "arrow.clockwise") }
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy)
            }
        }
    }

    private func embeddingLabel(_ e: EmbeddingStatus) -> String {
        switch e.state {
        case .idle:    return "Semantic index up to date"
        case .running: return "Embedding \(e.done) / \(e.total)"
        case .paused:  return "Paused — \(e.done) / \(e.total)"
        case .error:   return "Embedding stopped"
        case .unknown: return "Semantic index"
        }
    }

    // MARK: provider chooser
    @ViewBuilder private var providerSection: some View {
        Section("Embedding provider") {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { p in Text(p.label).tag(p) }
            }
            .onChange(of: provider) { _, p in onProviderChange(p) }
            Text(provider.note).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            switch provider {
            case .openai: remoteFields
            case .ollama:
                TextField("Endpoint", text: $endpoint, prompt: Text("http://127.0.0.1:11434")).textContentType(.URL)
            case .onnx, .none:
                EmptyView()
            }

            if provider != .none {
                Toggle("Advanced", isOn: $showAdvanced.animation())
                if showAdvanced { advancedFields }
            }

            HStack(spacing: Spacing.sm) {
                Button { Task { await runTest() } } label: { Label("Test", systemImage: "checkmark.seal") }
                Button { Task { await apply() } } label: { Label("Apply & re-index", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            if let t = test { testRow(t) }
            if let statusMsg { Text(statusMsg).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary) }
        }
    }

    // Remote — pick a named service, then just paste the key (common case).
    @ViewBuilder private var remoteFields: some View {
        Picker("Service", selection: $remoteService) {
            ForEach(RemoteService.allCases) { s in Text(s.label).tag(s) }
        }
        .onChange(of: remoteService) { _, _ in applyServiceDefaults(); test = nil }
        if remoteService.isCustom {
            TextField("Endpoint", text: $endpoint, prompt: Text("https://your-pod.example/v1")).textContentType(.URL)
            modelField()
        }
        if useManualRef {
            TextField("API key reference", text: $apiKeyRef, prompt: Text("keychain:… / env:… / file:…"))
        } else {
            SecureField("API key", text: $apiKey,
                        prompt: Text(hasStoredKey ? "•••• stored — leave blank to keep" : "Paste your API key"))
            Text("Stored in a local 0600 file; only a `file:` reference is sent to the engine — the raw key never crosses the API.")
                .font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Advanced — model override (hidden providers) + concurrency + manual ref escape hatch.
    @ViewBuilder private var advancedFields: some View {
        if provider == .onnx || provider == .ollama || (provider == .openai && !remoteService.isCustom) {
            modelField()
        }
        Stepper("Concurrency: \(concurrency)", value: $concurrency, in: 1...16)
        Text(provider == .openai
             ? "Parallel embed requests. For serverless remotes (RunPod) keep this low (1–2) — high concurrency wedges cold workers."
             : "Parallel embed workers. Higher = faster but more CPU/load.")
            .font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        if provider == .openai {
            Toggle("Use a Secrets reference instead of pasting a key", isOn: $useManualRef)
        }
    }

    // Model picker — a real dropdown of what the provider can serve, with a "Custom…"
    // escape hatch. When the engine can't enumerate (older engine, remote with no key,
    // Ollama unreachable) the list is empty and we fall back to a plain text field.
    @ViewBuilder private func modelField() -> some View {
        if availableModels.isEmpty {
            TextField("Model", text: $model,
                      prompt: Text(defaultModel.isEmpty ? "embedding model id" : defaultModel))
        } else {
            Picker("Model", selection: modelSelection) {
                ForEach(availableModels, id: \.self) { Text($0).tag(Optional($0)) }
                if !model.isEmpty && !availableModels.contains(where: { sameModel($0, model) }) {
                    Text("\(model) (custom)").tag(Optional(model))
                }
                Divider()
                Text("Custom…").tag(Optional<String>.none)
            }
            if customModel {
                TextField("Custom model", text: $model,
                          prompt: Text(defaultModel.isEmpty ? "embedding model id" : defaultModel))
            }
        }
    }

    /// Picker selection: a model id, or nil when "Custom…" is chosen (reveals the text field).
    /// Maps the active model onto its list entry ignoring an Ollama `:latest` tag, so e.g.
    /// a stored `bge-m3` selects the listed `bge-m3:latest` instead of showing as "(custom)".
    private var modelSelection: Binding<String?> {
        Binding(
            get: { customModel ? nil : (availableModels.first { sameModel($0, model) } ?? model) },
            set: { sel in
                if let sel { model = sel; customModel = false } else { customModel = true }
            }
        )
    }

    /// Two model ids refer to the same model if they match ignoring a trailing `:latest` tag.
    private func sameModel(_ a: String, _ b: String) -> Bool {
        func base(_ s: String) -> String { s.hasSuffix(":latest") ? String(s.dropLast(7)) : s }
        return base(a) == base(b)
    }

    @ViewBuilder private func testRow(_ t: EmbedderTestResult) -> some View {
        if t.ok {
            Label("OK — \(t.dimension ?? 0)-dim\(t.latencyMs.map { ", \($0) ms" } ?? "")",
                  systemImage: "checkmark.circle.fill").font(Typography.caption).foregroundStyle(ThemeColor.sync)
        } else {
            Label(t.error ?? "Probe failed", systemImage: "xmark.octagon").font(Typography.caption).foregroundStyle(ThemeColor.danger)
        }
    }

    // MARK: actions
    private var defaultModel: String {
        switch provider {
        case .onnx:   "multilingual-e5-small"
        case .ollama: "nomic-embed-text"
        case .openai: remoteService.defaultModel
        case .none:   ""
        }
    }

    private func onProviderChange(_ p: Provider) {
        test = nil
        // Serverless remotes wedge under parallelism → default to serial; local can parallelize.
        concurrency = (p == .openai) ? 1 : 2
        switch p {
        case .onnx:   model = "multilingual-e5-small"; endpoint = ""
        case .ollama: model = "nomic-embed-text"; endpoint = "http://127.0.0.1:11434"
        case .openai: applyServiceDefaults()
        case .none:   model = ""; endpoint = ""
        }
    }

    private func applyServiceDefaults() {
        endpoint = remoteService.endpoint
        let knownDefault = RemoteService.allCases.contains { !$0.defaultModel.isEmpty && $0.defaultModel == model }
        if model.isEmpty || knownDefault { model = remoteService.defaultModel }
    }

    /// Resolve the API-key reference for a remote provider: a pasted raw key is written
    /// to a local 0600 file and returned as a `file:` ref (raw key never crosses the API).
    private func resolveKeyRef() throws -> String? {
        guard provider == .openai else { return nil }
        if useManualRef { return apiKeyRef.trimmedOrNil }
        if let raw = apiKey.trimmedOrNil { return try Self.storeEmbedKey(raw) }
        if hasStoredKey { return "file:\(Self.keyFileURL().path)" }   // reuse the stored key
        return nil
    }

    /// Key reference for *listing* remote models — reuses a stored/manual ref but never
    /// writes the pasted key to disk just to enumerate (that happens only on Apply/Test).
    private func listingKeyRef() -> String? {
        guard provider == .openai else { return nil }
        if useManualRef { return apiKeyRef.trimmedOrNil }
        if hasStoredKey { return "file:\(Self.keyFileURL().path)" }
        return nil
    }

    /// Ask the engine which models this provider/endpoint can serve. Any failure (older
    /// engine, offline, can't enumerate) → empty list → the field degrades to manual entry.
    private func loadModels() async {
        guard !unavailable, provider != .none else { availableModels = []; customModel = false; return }
        loadingModels = true; defer { loadingModels = false }
        let req = EmbedderRequest(provider: provider.rawValue,
                                  endpoint: (provider == .ollama || provider == .openai) ? endpoint.trimmedOrNil : nil,
                                  apiKeyRef: listingKeyRef())
        availableModels = ((try? await client.embedderModels(req, vault: vaultID)) ?? []).map(\.id)
        // A model not in the list still shows via the picker's "(custom)" tag — no need to
        // force manual mode; only an explicit "Custom…" pick sets customModel.
        customModel = false
    }

    private func buildRequest(keyRef: String?) -> EmbedderRequest {
        EmbedderRequest(provider: provider.rawValue,
                        model: provider == .none ? nil : (model.trimmedOrNil ?? defaultModel.trimmedOrNil),
                        endpoint: (provider == .ollama || provider == .openai) ? endpoint.trimmedOrNil : nil,
                        apiKeyRef: keyRef,
                        maxThreads: provider == .none ? nil : concurrency)
    }

    private func runTest() async {
        busy = true; defer { busy = false }
        test = nil
        do {
            let req = buildRequest(keyRef: try resolveKeyRef())
            test = try await client.testEmbedder(req, vault: vaultID)
        } catch let e as SvodClientError { test = EmbedderTestResult(ok: false, dimension: nil, latencyMs: nil, error: e.errorDescription) }
        catch { test = EmbedderTestResult(ok: false, dimension: nil, latencyMs: nil, error: error.localizedDescription) }
    }

    private func apply() async {
        busy = true; defer { busy = false }
        do {
            let req = buildRequest(keyRef: try resolveKeyRef())
            current = try await client.setEmbedder(req, vault: vaultID)
            apiKey = ""   // drop the pasted key from memory; the 0600 file holds it now
            statusMsg = "Switched to \(current?.provider ?? provider.rawValue) — re-indexing in the background."
            await refreshStatus()
            app.refreshActiveVault()
        } catch let e as SvodClientError { statusMsg = e.errorDescription }
        catch { statusMsg = error.localizedDescription }
    }

    // MARK: secret storage — a local 0600 file handed to the engine as a `file:` ref
    // (mirrors the GitHub backup credential). The raw key never crosses the App API.
    static func keyFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Svod", isDirectory: true).appendingPathComponent("embed-key.secret")
    }
    static func storeEmbedKey(_ key: String) throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Svod", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("embed-key.secret")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try key.write(to: file, atomically: false, encoding: .utf8)
        return "file:\(file.path)"
    }

    /// Run a control action that returns the latest IndexStatus.
    private func act(message: Bool = true, _ action: @escaping () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await action(); await refreshStatus() }
        catch let e as SvodClientError { if message { statusMsg = e.errorDescription } }
        catch { if message { statusMsg = error.localizedDescription } }
    }

    private func load() async {
        do {
            let s = try await client.settings()
            guard let emb = s.embedder else { unavailable = true; return }
            unavailable = false
            current = emb
            if let p = Provider(rawValue: emb.provider) { provider = p }
            model = emb.model
            endpoint = emb.endpoint ?? ""
            if provider == .openai {
                remoteService = RemoteService.allCases.first { !$0.endpoint.isEmpty && $0.endpoint == emb.endpoint } ?? .custom
            }
            concurrency = (provider == .openai) ? 1 : 2   // engine doesn't echo maxThreads; sane default
            await refreshStatus()
        } catch let e as SvodClientError where e.isNotImplemented { unavailable = true }
        catch let e as SvodClientError where e.isOffline { _ = e }
        catch { unavailable = true }
    }

    private func refreshStatus() async {
        status = try? await client.indexStatus()
    }

    /// Light live refresh while the pane is open (cancelled on disappear by `.task`).
    private func pollStatus() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            if unavailable { continue }
            await refreshStatus()
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
}

#Preview {
    IndexingSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 580, height: 620)
}
