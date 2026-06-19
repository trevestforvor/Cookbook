import CoreGraphics
import SwiftUI

// MARK: - Spacing scale
//
// A small, consistent spacing ramp plus shape/radius constants for the Bell
// Pepper system. Namespaced under `Theme` so call sites read clearly
// (`Theme.Spacing.md`, `Theme.Radius.card`).

public enum Theme {
    /// Layout spacing ramp (points).
    public enum Spacing {
        /// 2pt — hairline gaps between tightly coupled glyphs.
        public static let xxs: CGFloat = 2
        /// 4pt.
        public static let xs: CGFloat = 4
        /// 8pt.
        public static let sm: CGFloat = 8
        /// 12pt.
        public static let md: CGFloat = 12
        /// 16pt — default card / cell inset.
        public static let lg: CGFloat = 16
        /// 24pt — section separation.
        public static let xl: CGFloat = 24
        /// 32pt — major vertical rhythm.
        public static let xxl: CGFloat = 32
    }

    /// Corner radius constants.
    public enum Radius {
        /// 16pt — cards, sheets, the search field.
        public static let card: CGFloat = 16
        /// 12pt — smaller inset surfaces / chips.
        public static let chip: CGFloat = 12
        /// 8pt — badges, small controls.
        public static let badge: CGFloat = 8
        /// 999pt — fully pill-shaped (tags, time badges).
        public static let pill: CGFloat = 999
    }

    /// Border and shadow constants.
    public enum Stroke {
        /// 1pt — the hairline border on the search field and card edges.
        public static let hairline: CGFloat = 1
    }

    /// Card shadow tuning — a subtle ~4% Charred Oak drop.
    public enum Shadow {
        /// Shadow tint: Charred Oak (`#212121`) at 4% opacity.
        public static let cardColor = Color(hex: "#212121").opacity(0.04)
        /// Blur radius (points).
        public static let cardRadius: CGFloat = 8
        /// Vertical offset (points).
        public static let cardYOffset: CGFloat = 2
    }
}

// Backwards-friendly top-level alias for the most-used radius so existing
// design copy ("cardRadius=16") maps to a single symbol.
public extension CGFloat {
    /// 16pt card corner radius — alias for `Theme.Radius.card`.
    static let cardRadius: CGFloat = Theme.Radius.card
}
