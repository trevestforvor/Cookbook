import SwiftUI

// MARK: - Typography tokens
//
// SF Pro (the system font) throughout. Tokens map design roles onto Dynamic
// Type text styles so everything scales with the user's accessibility settings.
// Recipe titles are bold ~.title3/.headline; the macro/stat line MUST use
// `.statNumber` so digits align in a fixed-width column
// ("372 kcal · 42 g · 35 min").

public extension Font {
    /// Large screen/section title (e.g. a tab root header). Bold `.title`.
    static let titleL = Font.title.weight(.bold)

    /// Standard title — recipe titles and card headlines. Bold `.title3`.
    static let appTitle = Font.title3.weight(.bold)

    /// Headline / emphasised row label. Semibold `.headline`.
    static let appHeadline = Font.headline.weight(.semibold)

    /// Default body copy.
    static let appBody = Font.body

    /// Secondary metadata — units, subtitles, captions.
    static let appCaption = Font.caption

    /// The macro / stat line. Monospaced digits so numbers stay column-aligned
    /// across rows ("372 kcal · 42 g · 35 min"). Built on `.subheadline`.
    static let statNumber = Font.subheadline.monospacedDigit()
}
