import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// Disabled/secondary controls (iOS systemGray4 equivalent)
    static var softerGray4: Color {
        #if os(iOS)
        Color(.systemGray4)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    /// Bubble backgrounds, light fills (iOS systemGray5 equivalent)
    static var softerGray5: Color {
        #if os(iOS)
        Color(.systemGray5)
        #else
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #endif
    }

    /// Grouped backgrounds (iOS systemGray6 equivalent)
    static var softerGray6: Color {
        #if os(iOS)
        Color(.systemGray6)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// Muted palette for distinguishing other participants' message bubbles.
    /// Assigned by participant orderIndex. Warm, soft tones that work in light and dark mode.
    static let participantColors: [Color] = [
        Color(.systemTeal).opacity(0.25),
        Color(.systemOrange).opacity(0.25),
        Color(.systemPurple).opacity(0.25),
        Color(.systemPink).opacity(0.25),
        Color(.systemGreen).opacity(0.25),
    ]

    static func participantColor(orderIndex: Int) -> Color {
        participantColors[orderIndex % participantColors.count]
    }
}
