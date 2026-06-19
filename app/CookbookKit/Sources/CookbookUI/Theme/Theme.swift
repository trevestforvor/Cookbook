import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Adaptive Color construction

public extension Color {
    /// Builds a `Color` that resolves to `light` in light appearance and `dark`
    /// in dark appearance.
    ///
    /// Cross-platform: backed by a `UIColor` dynamic provider on UIKit
    /// platforms and an `NSColor` dynamic provider on AppKit. On any platform
    /// where neither is available it degrades gracefully to the `light` value
    /// (so the package still compiles and renders something sensible).
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }

    /// Convenience overload taking the light → dark pair as hex strings.
    init(lightHex: String, darkHex: String) {
        self.init(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }
}

// MARK: - Bell Pepper semantic palette
//
// The locked theme. Each role is exposed as an adaptive `Color` using the exact
// light → dark sRGB hex pairs from the design system. Where the design doc did
// not specify a dark value, the chosen value is noted inline.

public extension Color {
    /// Garden Green → Lime Aurora. CTAs, active tab/selection, "healthy" tags,
    /// and the filled nutrition-provenance dot.
    static let appAccent = Color(lightHex: "#2E7D32", darkHex: "#4CAF50")

    /// Sweet Saffron (unchanged in dark). Review stars, time badges, tips.
    /// NEVER use for body text — contrast 1.71:1 fails. Use at ~15% fill behind
    /// dark text, or as a pure graphic accent.
    static let appAccentSecondary = Color(lightHex: "#FBC02D", darkHex: "#FBC02D")

    /// Pimiento Red → Chili Blaze. Active favorite heart, delete/clear, timers.
    static let appDestructive = Color(lightHex: "#D32F2F", darkHex: "#EF5350")

    /// Crisp Parchment → Obsidian Bark. Window background, list backgrounds.
    static let appBackground = Color(lightHex: "#FAFAFA", darkHex: "#121212")

    /// Sweet Cream → Sprout Velvet. Cards, sheets, search bar, cells.
    static let appSurface = Color(lightHex: "#FFFFFF", darkHex: "#1E1E1E")

    /// Charred Oak → `#ECECEC` (dark value chosen; not in design doc).
    /// Titles and body text.
    static let appTextPrimary = Color(lightHex: "#212121", darkHex: "#ECECEC")

    /// Stem Grey → `#9E9E9E` (dark value chosen; not in design doc).
    /// Subtitles, units, unselected tabs.
    static let appTextSecondary = Color(lightHex: "#757575", darkHex: "#9E9E9E")

    /// Celery Frost → `#2C2C2C` (dark value chosen; not in design doc).
    /// Separators and card / search-field borders.
    static let appBorder = Color(lightHex: "#E0E0E0", darkHex: "#2C2C2C")
}
