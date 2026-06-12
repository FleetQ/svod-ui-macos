import Foundation

// MARK: - Relative time
//
// One shared formatter for the activity feed and the inspector's per-note
// activity, so "2 minutes ago" reads identically everywhere. Named ("2 minutes
// ago") rather than abstract ("2m") because the same string is the VoiceOver
// label, where the long form reads better.

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// "2 minutes ago", "just now" — relative to now.
    static func string(from date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 5 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
