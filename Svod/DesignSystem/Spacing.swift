import SwiftUI

// MARK: - Spacing (8pt grid with a 4pt half-step)
//
// Use these everywhere instead of raw numbers so rhythm stays consistent.

public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs:  CGFloat = 4
    public static let sm:  CGFloat = 8
    public static let md:  CGFloat = 12
    public static let lg:  CGFloat = 16
    public static let xl:  CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// Default content inset for panes.
    public static let pane: CGFloat = 16
    /// Reading measure cap (~70 characters) for the editor and long-form text.
    public static let readingMeasure: CGFloat = 680
    /// Standard sidebar / inspector default widths.
    public static let sidebarWidth: CGFloat = 260
    public static let inspectorWidth: CGFloat = 300
    public static let sidebarMinWidth: CGFloat = 200
    public static let inspectorMinWidth: CGFloat = 240
    /// Row heights.
    public static let rowHeight: CGFloat = 28
    public static let rowHeightComfortable: CGFloat = 34
}
