import SwiftUI

struct EditorSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Saving") {
                Toggle("Autosave", isOn: $settings.autosave)
                if settings.autosave {
                    Stepper("Debounce: \(settings.autosaveDebounceMs) ms",
                            value: $settings.autosaveDebounceMs, in: 300...5000, step: 100)
                }
                Text("With autosave off, save explicitly with ⌘S. A stale write still raises a 3-way merge — never a silent overwrite.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
            Section("Editing") {
                Toggle("Open notes in focus mode", isOn: $settings.focusByDefault)
                Toggle("[[Wikilink]] autocomplete", isOn: $settings.wikilinkAutocomplete)
            }
            Section("New note frontmatter template") {
                TextEditor(text: $settings.frontmatterTemplate)
                    .font(Typography.code)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background(ThemeColor.editorSurface, in: RoundedRectangle(cornerRadius: Radii.sm))
            }
        }
        .formStyle(.grouped)
    }
}

#Preview { EditorSettingsView(settings: SettingsStore()).frame(width: 560, height: 460) }
