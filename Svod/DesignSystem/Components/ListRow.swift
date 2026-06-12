import SwiftUI

// MARK: - ListRow
//
// A consistent, keyboard-friendly row used across sidebar, search results, history
// and activity. Handles selection/hover wash, leading icon, trailing accessory.

public struct ListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let isSelected: Bool
    private let leading: Leading
    private let trailing: Trailing
    private let action: (() -> Void)?

    @State private var hovering = false

    public init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.leading = leading()
        self.trailing = trailing()
        self.action = action
    }

    public var body: some View {
        let row = HStack(spacing: Spacing.sm) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.callout)
                    .foregroundStyle(isSelected ? ThemeColor.textPrimary : ThemeColor.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.xs)
            trailing
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: Spacing.rowHeight)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var rowBackground: Color {
        if isSelected { return ThemeColor.surfaceSelected }
        if hovering { return ThemeColor.surfaceHover }
        return .clear
    }
}

// Convenience: title-only row.
public extension ListRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, isSelected: Bool = false, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, isSelected: isSelected,
                  leading: { EmptyView() }, trailing: { EmptyView() }, action: action)
    }
}

// Convenience: leading icon + title.
public extension ListRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, isSelected: Bool = false,
         @ViewBuilder leading: () -> Leading, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, isSelected: isSelected,
                  leading: leading, trailing: { EmptyView() }, action: action)
    }
}

#Preview("ListRow") {
    VStack(spacing: 2) {
        ListRow(title: "architecture.md", subtitle: "vault/notes", isSelected: true) {
            Image(systemName: "doc.text").foregroundStyle(ThemeColor.textTertiary)
        }
        ListRow(title: "embeddings.md", subtitle: "vault/notes") {
            Image(systemName: "doc.text").foregroundStyle(ThemeColor.textTertiary)
        }
        ListRow(title: "Plain row")
    }
    .padding(Spacing.sm)
    .frame(width: 280)
    .background(ThemeColor.surface)
}
