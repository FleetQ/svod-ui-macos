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

            Section {
                Text("The App API is loopback-only. To reach an engine on another machine, tunnel it to localhost (e.g. SSH) and point the port here.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { host = settings.endpointHost; port = String(settings.endpointPort) }
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
