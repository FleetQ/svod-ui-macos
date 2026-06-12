import SwiftUI

struct ActivitySettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Show event types") {
                Toggle("Agent activity", isOn: $settings.showAgentActivity)
                Toggle("Commits", isOn: $settings.showCommits)
                Toggle("File changes", isOn: $settings.showFileChanges)
                Toggle("Conflicts", isOn: $settings.showConflicts)
            }
            Section("Feed") {
                Stepper("Keep up to \(settings.feedCap) items",
                        value: $settings.feedCap, in: 50...500, step: 50)
                Toggle("Animate new items", isOn: $settings.feedAnimation)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview { ActivitySettingsView(settings: SettingsStore()).frame(width: 560, height: 360) }
