import SwiftUI

// MARK: - Card
//
// A raised, rounded content surface with a hairline border. The default building
// block for grouped content (inspector sections, result groups, panels).

public struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = Spacing.lg, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .strokeBorder(ThemeColor.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Section header used inside cards / panes
public struct SectionLabel: View {
    private let text: String
    private let systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text.uppercased())
                .font(Typography.caption)
                .tracking(0.6)
        }
        .foregroundStyle(ThemeColor.textTertiary)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Card") {
    VStack(spacing: Spacing.lg) {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel("Backlinks", systemImage: "arrow.uturn.left")
                Text("Three notes link here.").foregroundStyle(ThemeColor.textSecondary)
            }
        }
    }
    .padding()
    .frame(width: 360)
    .background(ThemeColor.background)
}
