import SwiftUI

// MARK: - StatusPill
//
// A small rounded status indicator with an optional leading dot. Used for engine
// connection state, sync/conflict/agent badges, relevance, etc.

public struct StatusPill: View {
    public enum Tone {
        case neutral, accent, success, warning, danger, conflict, sync, agent, offline

        var fg: Color {
            switch self {
            case .neutral:  return ThemeColor.textSecondary
            case .accent:   return ThemeColor.accent
            case .success:  return ThemeColor.success
            case .warning:  return ThemeColor.warning
            case .danger:   return ThemeColor.danger
            case .conflict: return ThemeColor.conflict
            case .sync:     return ThemeColor.sync
            case .agent:    return ThemeColor.agent
            case .offline:  return ThemeColor.offline
            }
        }
        var bg: Color {
            switch self {
            case .neutral:  return ThemeColor.surfaceHover
            case .accent:   return ThemeColor.accentSubtle
            case .success:  return ThemeColor.syncSubtle
            case .warning:  return ThemeColor.conflictSubtle
            case .danger:   return ThemeColor.diffDelBg
            case .conflict: return ThemeColor.conflictSubtle
            case .sync:     return ThemeColor.syncSubtle
            case .agent:    return ThemeColor.agentSubtle
            case .offline:  return ThemeColor.surfaceHover
            }
        }
    }

    private let text: String
    private let tone: Tone
    private let showsDot: Bool
    private let pulses: Bool

    public init(_ text: String, tone: Tone = .neutral, showsDot: Bool = true, pulses: Bool = false) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
        self.pulses = pulses
    }

    @State private var pulse = false

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            if showsDot {
                Circle()
                    .fill(tone.fg)
                    .frame(width: 6, height: 6)
                    .opacity(pulses ? (pulse ? 0.35 : 1.0) : 1.0)
                    .animation(pulses ? Motion.ambient.repeatForever(autoreverses: true) : nil, value: pulse)
            }
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(tone.fg)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(tone.bg, in: Capsule())
        .onAppear { if pulses { pulse = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

#Preview("StatusPill") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        StatusPill("Connected", tone: .success)
        StatusPill("Disconnected", tone: .offline)
        StatusPill("Conflict", tone: .conflict)
        StatusPill("friday writing", tone: .agent, pulses: true)
        StatusPill("hybrid", tone: .accent, showsDot: false)
    }
    .padding()
    .background(ThemeColor.background)
}
