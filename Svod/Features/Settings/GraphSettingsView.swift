import SwiftUI

struct GraphSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default scope", selection: $settings.defaultGraphScopeLocal) {
                    Text("Global").tag(false)
                    Text("Local (current note)").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("Physics intensity") {
                    Slider(value: $settings.graphPhysicsIntensity, in: 0.3...2.0, step: 0.1)
                    Text(String(format: "%.1f×", settings.graphPhysicsIntensity))
                        .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                }
            }
            Section {
                Text("The graph respects Reduce Motion regardless of this setting — it falls back to a static settled layout.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview { GraphSettingsView(settings: SettingsStore()).frame(width: 560, height: 320) }
