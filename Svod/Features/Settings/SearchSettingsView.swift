import SwiftUI

struct SearchSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default mode", selection: $settings.defaultSearchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Result limit: \(settings.searchResultLimit)",
                        value: $settings.searchResultLimit, in: 5...50, step: 5)
                Toggle("Remember last query & filters", isOn: $settings.rememberQuery)
            }
            Section {
                Text("Semantic results require the engine's embedder; the mode only sets the default for the ⌘K palette.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview { SearchSettingsView(settings: SettingsStore()).frame(width: 560, height: 320) }
