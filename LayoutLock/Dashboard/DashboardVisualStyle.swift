import AppKit
import SwiftUI

enum DashboardVisualStyle {
    static let cardBackground = Color(nsColor: cardBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let supportingText = Color.primary.opacity(0.78)
    static let selectedSupportingText = Color(nsColor: .selectedMenuItemTextColor)

    private static let cardBackgroundColor = NSColor(name: nil) { appearance in
        var resolvedColor = NSColor.controlBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.alternatingContentBackgroundColors.dropFirst().first ?? .controlBackgroundColor
        }
        return resolvedColor
    }
}

extension View {
    func dashboardCardSurface(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DashboardVisualStyle.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DashboardVisualStyle.separator, lineWidth: 1)
        )
    }
}
