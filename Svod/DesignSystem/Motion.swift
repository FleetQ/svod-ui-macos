import SwiftUI

// MARK: - Motion tokens
//
// Live engine updates should settle in gently — short, slightly damped springs.
// Nothing bouncy or attention-grabbing; this is a calm, archival surface.

public enum Motion {
    /// Default UI transition (selection, hover, layout).
    public static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Quick feedback (pills, chips, small state flips).
    public static let quick    = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// Gentle entrance for live feed items / arriving content.
    public static let arrive   = Animation.spring(response: 0.45, dampingFraction: 0.85)
    /// Pane collapse/expand.
    public static let pane     = Animation.spring(response: 0.36, dampingFraction: 0.88)
    /// Subtle, slow — for breathing/pulse indicators.
    public static let ambient  = Animation.easeInOut(duration: 1.6)

    /// Transition for items arriving in a live list (e.g. activity feed).
    public static let feedInsertion: AnyTransition = .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .opacity
    )
}
