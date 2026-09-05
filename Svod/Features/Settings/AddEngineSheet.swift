import SwiftUI

// Add a central engine: address + the personal key its admin handed over. "Test" asks the
// engine who we are (`GET /api/v1/me`, contract 0.30.0) — the key is saved only after that
// answers, so a typo never becomes a dead profile.

struct AddEngineSheet: View {
    /// (name, url, key) on save; all nil on cancel.
    let done: (String?, URL?, String?) -> Void

    @State private var name = ""
    @State private var address = "https://"
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Add central engine").font(Typography.title)
            Form {
                TextField("Name (e.g. Company)", text: $name)
                TextField("Address", text: $address, prompt: Text("https://svod.example.com"))
                    .font(Typography.code)
                    .onChange(of: address) { _, _ in verified = false; testResult = nil }
                SecureField("Personal key", text: $key, prompt: Text("svk_…"))
                    .onChange(of: key) { _, _ in verified = false; testResult = nil }
                if url == nil && address.lowercased().hasPrefix("http://") {
                    Label("Only https:// is accepted (or a loopback address) — a key over plain HTTP can be read on the way.", systemImage: "exclamationmark.shield")
                        .font(Typography.caption).foregroundStyle(ThemeColor.warning)
                }
                HStack {
                    Button("Test") { Task { await test() } }.disabled(testing || url == nil || key.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult).font(Typography.caption)
                            .foregroundStyle(verified ? ThemeColor.sync : ThemeColor.danger)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil, nil, nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { done(name.trimmingCharacters(in: .whitespaces), url, key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!verified || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
    }

    private var url: URL? { EngineAddress.parse(address) }

    private func test() async {
        guard let url else { return }
        testing = true; defer { testing = false }
        verified = false
        let probe = LiveSvodClient(baseURL: url, bearerKey: key.trimmingCharacters(in: .whitespacesAndNewlines))   // exactly what Add saves
        do {
            let me = try await probe.me()
            verified = true
            let grants = me.grants.map { "\($0.vault) (\($0.role))" }.joined(separator: ", ")
            testResult = "Signed in as \(me.name)" + (me.admin ? " · admin" : "") + (grants.isEmpty ? "" : " · \(grants)")
        } catch let e as SvodClientError {
            switch e {
            case .http(401, _): testResult = "Key not accepted."
            case .notImplemented, .notFound: testResult = "That engine is older than contract 0.30.0."
            case .offline: testResult = "Unreachable."
            default: testResult = e.errorDescription
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}
