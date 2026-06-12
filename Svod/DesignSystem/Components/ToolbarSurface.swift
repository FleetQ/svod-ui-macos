import SwiftUI

// MARK: - ToolbarSurface
//
// A translucent (.regularMaterial) horizontal surface with a hairline bottom
// separator — used for in-pane toolbars/headers that should read as chrome
// floating above content. The window's own unified toolbar is configured in
// RootView; this is for secondary, in-pane bars.

public struct ToolbarSurface<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            content
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ThemeColor.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Quiet icon button used in toolbars
public struct ToolbarIconButton: View {
    private let systemImage: String
    private let help: String
    private let isActive: Bool
    private let action: () -> Void

    public init(_ systemImage: String, help: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .frame(width: 26, height: 26)
                .foregroundStyle(isActive ? ThemeColor.accent : ThemeColor.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
                        .fill(isActive ? ThemeColor.accentSubtle : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview("ToolbarSurface") {
    ToolbarSurface {
        ToolbarIconButton("sidebar.left", help: "Toggle sidebar") {}
        Spacer()
        Text("note.md").font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
        Spacer()
        ToolbarIconButton("sidebar.right", help: "Toggle inspector", isActive: true) {}
    }
    .frame(width: 520)
    .background(ThemeColor.background)
}
