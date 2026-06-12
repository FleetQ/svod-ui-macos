import SwiftUI

// MARK: - Shared empty / loading / error / offline primitives
//
// Every feature surface uses these so the four non-content states look and behave
// identically across the app. Calm, centered, low-chroma.

// MARK: Empty
public struct EmptyStateView: View {
    private let icon: String
    private let title: String
    private let message: String?
    private let actionLabel: String?
    private let action: (() -> Void)?

    public init(icon: String, title: String, message: String? = nil,
                actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ThemeColor.textTertiary)
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(ThemeColor.textSecondary)
                if let message {
                    Text(message)
                        .font(Typography.callout)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(SvodButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message ?? "")")
    }
}

// MARK: Loading
public struct LoadingStateView: View {
    private let label: String
    public init(_ label: String = "Loading…") { self.label = label }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .accessibilityLabel(label)
    }
}

// MARK: Error
public struct ErrorStateView: View {
    private let title: String
    private let message: String?
    private let retry: (() -> Void)?

    public init(title: String = "Something went wrong", message: String? = nil, retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(ThemeColor.warning)
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(ThemeColor.textSecondary)
                if let message {
                    Text(message)
                        .font(Typography.callout)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(SvodButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(title). \(message ?? "")")
    }
}

// MARK: Offline (engine not connected)
public struct OfflineStateView: View {
    private let endpoint: String
    private let isStarting: Bool
    private let onStart: (() -> Void)?

    public init(endpoint: String, isStarting: Bool = false, onStart: (() -> Void)? = nil) {
        self.endpoint = endpoint
        self.isStarting = isStarting
        self.onStart = onStart
    }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: isStarting ? "bolt.horizontal.circle" : "bolt.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ThemeColor.offline)
            VStack(spacing: Spacing.xs) {
                Text(isStarting ? "Starting Svod…" : "Engine offline")
                    .font(Typography.headline)
                    .foregroundStyle(ThemeColor.textSecondary)
                Text(endpoint)
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            if isStarting {
                ProgressView().controlSize(.small)
            } else if let onStart {
                Button("Start Svod", action: onStart)
                    .buttonStyle(SvodButtonStyle(.primary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStarting ? "Starting Svod engine" : "Engine offline at \(endpoint)")
    }
}

// MARK: - Button style (shared)
public struct SvodButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    private let kind: Kind
    public init(_ kind: Kind = .primary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.callout.weight(.medium))
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .foregroundStyle(kind == .primary ? ThemeColor.textOnAccent : ThemeColor.textPrimary)
            .background(background(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: Radii.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
                    .strokeBorder(kind == .secondary ? ThemeColor.borderSubtle : .clear, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:   return pressed ? ThemeColor.accentMuted : ThemeColor.accent
        case .secondary: return pressed ? ThemeColor.surfaceHover : ThemeColor.surfaceRaised
        }
    }
}

#Preview("States") {
    HStack(spacing: 0) {
        EmptyStateView(icon: "doc.text", title: "No note selected", message: "Pick a note from the sidebar to start reading.")
        Divider()
        LoadingStateView("Searching…")
        Divider()
        ErrorStateView(message: "The engine returned 500.", retry: {})
        Divider()
        OfflineStateView(endpoint: "http://127.0.0.1:7517", onStart: {})
    }
    .frame(width: 900, height: 280)
    .background(ThemeColor.surface)
}
