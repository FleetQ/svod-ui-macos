import SwiftUI

struct AboutSettingsView: View {
    @EnvironmentObject var app: AppModel

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.md) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Svod").font(Typography.title3).foregroundStyle(ThemeColor.textPrimary)
                        Text("Version \(version)").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                        Text("A personal SwiftUI client for the Svod engine.")
                            .font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                    }
                }
            }
            Section("Keyboard shortcuts") {
                shortcut("Search (command palette)", "⌘K")
                shortcut("Save note", "⌘S")
                shortcut("Editor / Graph / History", "⌘1 / ⌘2 / ⌘3")
                shortcut("Toggle inspector", "⌥⌘I")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        LabeledContent(label) {
            Text(keys).font(Typography.codeSmall).foregroundStyle(ThemeColor.textSecondary)
        }
    }
}

#Preview {
    AboutSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 560, height: 360)
}
