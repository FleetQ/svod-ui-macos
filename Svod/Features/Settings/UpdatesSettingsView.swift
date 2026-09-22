import SwiftUI

// Updates — two cards. The APP updates itself via Sparkle (appcast from GitHub
// Releases); the ENGINE updates via its own /api/v1/update endpoints (the app shows
// the status and triggers the one-click apply). Engine card degrades to a calm note
// on engines without the update endpoints (apiVersion < 0.18.0).

struct UpdatesSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: Updater

    @State private var check: UpdateCheck?
    @State private var engineUnavailable = false
    @State private var scriptMissing: String?
    @State private var busy = false
    @State private var statusMsg: String?

    private var client: SvodClient { app.client }
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            appSection
            engineSection
            if let statusMsg {
                Section { Text(statusMsg).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await loadEngine() }
    }

    // MARK: app (Sparkle)

    private var appSection: some View {
        Section("This app") {
            LabeledContent("Version", value: appVersion)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }))
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
            }
            Text("Updates are delivered via Sparkle from GitHub Releases. Installing an update requires a signed, notarized build — see the release notes if “Check for Updates” reports nothing while a newer version exists.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: engine

    @ViewBuilder private var engineSection: some View {
        Section("Svod engine") {
            if engineUnavailable {
                Label("This engine doesn’t support self-update.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Update the engine to contract 0.18.0+ to check and apply engine updates from here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let c = check {
                LabeledContent("Current", value: c.currentVersion)
                if c.updateAvailable, let latest = c.latestVersion {
                    LabeledContent("Available", value: latest)
                    if !c.compatible {
                        Label("Not API-compatible — a coordinated update is needed.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let notes = c.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    Button(busy ? "Updating…" : "Update engine") { Task { await apply() } }
                        .disabled(busy || !c.compatible)
                    if let scriptMissing { setupNote(scriptMissing) }
                } else {
                    Label("Up to date.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check now") { Task { await loadEngine() } }.disabled(busy)
                    Spacer()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    static let setupCommand = """
        mkdir -p ~/.config/svod && curl -fsSL -o ~/.config/svod/self-update.sh \\
          https://github.com/FleetQ/svod-engine/releases/latest/download/self-update.sh \\
          && bash ~/.config/svod/self-update.sh
        """

    @ViewBuilder private func setupNote(_ engineMessage: String) -> some View {
        Label("The engine has no update script installed.", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
        Text("Run this once in Terminal. It installs the latest engine and the script, and after that “Update engine” works from here.")
            .font(.callout).foregroundStyle(.secondary)
        Text(Self.setupCommand)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        HStack {
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.setupCommand, forType: .string)
            }
            Spacer()
        }
        Text("Engine said: \(engineMessage)").font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: actions

    private func loadEngine() async {
        do {
            check = try await client.updateCheck()
            engineUnavailable = false
        } catch let e as SvodClientError where e.isNotImplemented { engineUnavailable = true }
        catch let e as SvodClientError where isNotFound(e) { engineUnavailable = true }
        catch let e as SvodClientError where e.isOffline { _ = e }
        catch let e as SvodClientError { statusMsg = e.errorDescription }
        catch { statusMsg = error.localizedDescription }
    }

    private func apply() async {
        busy = true; defer { busy = false }
        statusMsg = nil
        scriptMissing = nil
        do {
            let r = try await client.updateApply()
            if r.started {
                statusMsg = "Update started. The engine downloads the new version (about 200 MB), swaps it in and restarts, which takes a minute or two; the app reconnects on its own. Progress is logged to ~/.config/svod/self-update.log."
            }
        } catch let e as SvodClientError {
            switch e {
            // The check above already answered, so the endpoints exist: a 501 from apply means the
            // engine found no update script, not that it predates self-update.
            case .notImplemented(let m): scriptMissing = m ?? "update is not available"
            case .http(409, _): statusMsg = "No compatible update to apply right now."
            default: statusMsg = e.errorDescription
            }
        }
        catch { statusMsg = error.localizedDescription }
    }

    private func isNotFound(_ e: SvodClientError) -> Bool {
        if case .notFound = e { return true }
        if case .http(404, _) = e { return true }
        return false
    }
}

#Preview("Updates") {
    UpdatesSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .environmentObject(Updater())
        .frame(width: 720, height: 560)
}
