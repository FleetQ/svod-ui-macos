import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Density", selection: $settings.density) {
                    ForEach(Density.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Reading") {
                LabeledContent("Measure width") {
                    Slider(value: $settings.readingMeasure, in: 480...900, step: 20)
                    Text("\(Int(settings.readingMeasure)) pt").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                }
                LabeledContent("Editor font size") {
                    Slider(value: $settings.editorFontSize, in: 11...20, step: 1)
                    Text("\(Int(settings.editorFontSize)) pt").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview { AppearanceSettingsView(settings: SettingsStore()).frame(width: 560, height: 360) }
