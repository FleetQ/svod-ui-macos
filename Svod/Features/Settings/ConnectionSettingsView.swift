import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var validation: String?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Engine endpoint") {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                if let validation {
                    Text(validation).font(Typography.caption).foregroundStyle(ThemeColor.danger)
                }
                if !host.trimmingCharacters(in: .whitespaces).isEmpty && !hostIsLoopback {
                    Label("Vault content would be sent over plain HTTP to a non-loopback host. Point this at a local tunnel (e.g. SSH-forwarded to 127.0.0.1), not a remote address directly.",
                          systemImage: "exclamationmark.shield")
                        .font(Typography.caption).foregroundStyle(ThemeColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Test") { Task { await test() } }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                    }
                    Spacer()
                    Button("Apply & Reconnect") { apply() }
                        .keyboardShortcut(.defaultAction)
                }
                LabeledContent("Status") {
                    StatusPill(app.connection.label, tone: app.connection.pillTone)
                }
            }

            Section("Behavior") {
                Toggle("Start the engine automatically on launch", isOn: $settings.autoStartEngine)
                Toggle("Reconnect automatically when the connection drops", isOn: $settings.autoReconnect)
            }

            centralEngines

            Section {
                Text("The local engine is loopback-only. A central engine (a shared company vault) is reached over HTTPS with the personal key its admin gave you.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { host = settings.endpointHost; port = String(settings.endpointPort) }
        .sheet(isPresented: $addingEngine) {
            AddEngineSheet { name, url, key in
                addingEngine = false
                guard let name, let url, let key else { return }
                do {
                    try app.engines.add(EngineProfile(name: name, baseURL: url), apiKey: key)
                    app.reloadEngines()
                } catch {
                    engineError = error.localizedDescription
                }
            }
        }
        .confirmationDialog("Remove this engine?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            presenting: pendingRemove) { p in
            Button("Remove \(p.name)", role: .destructive) {
                app.engines.remove(p.id)
                app.reloadEngines()
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { p in
            Text("Its vaults disappear from this Mac and the stored key is deleted. Nothing changes on the engine itself.")
        }
    }

    // MARK: central engines (contract 0.30.0, ADR-0019)

    @State private var addingEngine = false
    @State private var pendingRemove: EngineProfile?
    @State private var engineError: String?

    @ViewBuilder private var centralEngines: some View {
        Section("Central engines") {
            let unreachable = (app.client as? MultiEngineClient)?.unreachable ?? []
            let insecure = (app.client as? MultiEngineClient)?.insecure ?? []
            if app.engines.profiles.isEmpty {
                Text("None yet. Add a central engine to work in a company vault alongside your own.")
                    .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
            }
            ForEach(app.engines.profiles) { p in
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text(p.baseURL.absoluteString).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                    }
                    Spacer()
                    if insecure.contains(p.id) {
                        StatusPill("insecure address", tone: .danger)
                            .help("Saved with a plain http:// address to a remote host. This engine is not contacted (your key would travel in clear). Remove it and add it again over https://.")
                    } else if unreachable.contains(p.id) {
                        StatusPill("unreachable", tone: .danger)
                    } else {
                        StatusPill("\(app.vault.vaults.filter { $0.engineId == p.id }.count) vaults", tone: .neutral)
                    }
                    Button(role: .destructive) { pendingRemove = p } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
            }
            if let engineError {
                Text(engineError).font(Typography.caption).foregroundStyle(ThemeColor.danger)
            }
            Button { addingEngine = true } label: { Label("Add central engine…", systemImage: "building.2") }
        }
    }

    private var hostIsLoopback: Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    private func apply() {
        validation = nil; testResult = nil
        let p = Int(port) ?? -1
        if let err = SettingsStore.validate(host: host, port: p) { validation = err; return }
        settings.endpointHost = host.trimmingCharacters(in: .whitespaces)
        settings.endpointPort = p
        app.applyEndpoint()
    }

    private func test() async {
        validation = nil; testResult = nil
        let p = Int(port) ?? -1
        if let err = SettingsStore.validate(host: host, port: p) { validation = err; return }
        testing = true; defer { testing = false }
        guard let url = URL(string: "http://\(host):\(p)") else { testResult = "Bad URL"; return }
        let probe = LiveSvodClient(baseURL: url)
        do {
            let r = try await probe.ready()
            testResult = r.ready ? "Reachable ✓ (ready)" : "Reachable, not ready"
        } catch {
            testResult = "Unreachable"
        }
    }
}

#Preview {
    ConnectionSettingsView(settings: SettingsStore())
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 560, height: 420)
}
