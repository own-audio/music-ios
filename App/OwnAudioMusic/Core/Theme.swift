import SwiftUI
import UIKit

/// The few layout constants shared across screens.
enum Theme {
    /// The welcome screen's colours, the same values as own.audio Books and Podcasts use, with
    /// this app's pink as the accent.
    enum Colors {
        static let background = Color(light: 0xFFFFFF, dark: 0x000000)
        static let foreground = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
        static let muted = Color(light: 0x6E6E73, dark: 0x98989D)
        /// The same value as the `AccentColor` asset.
        static let accent = Color(light: 0xD63A6A, dark: 0xFF6482)
        static let error = Color(light: 0xC41E3A, dark: 0xFF453A)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let screenEdge: CGFloat = 16
    }

    enum Radius {
        static let cover: CGFloat = 8
        static let miniPlayer: CGFloat = 14
    }

    /// Apple's minimum touch target.
    static let minTarget: CGFloat = 44
    static let coverCrossfade: Double = 0.3
}

extension Color {
    /// A dynamic colour from a light and a dark hex value.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

extension View {
    /// An animation that is dropped when Reduce Motion is on, so the state still changes but
    /// nothing moves. Dropped under the UI tests too: XCUITest waits for the app to go idle
    /// before every query, and a mark that never stops moving never lets it.
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(AccessibleAnimation(animation: animation, value: value))
    }
}

private struct AccessibleAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion || ProcessInfo.processInfo.arguments.contains("-uiTestReset") ? nil : animation, value: value)
    }
}

enum Haptics {
    @MainActor static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    @MainActor static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// "3:07", or "1:02:07" past an hour.
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
