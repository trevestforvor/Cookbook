import SwiftUI
import CookbookKit

// MARK: - Prep-time badge

/// A small pill badge showing a recipe's total time, tinted with Sweet Saffron.
///
/// Per the theme guardrails, Sweet Saffron (`appAccentSecondary`) must NEVER be
/// used as text color (its contrast fails), so the badge uses a ~15% saffron
/// fill behind primary-text glyphs and a clock glyph.
///
/// Renders nothing when `minutes` is nil — callers can place it unconditionally.
public struct PrepTimeBadge: View {
    public let minutes: Int?

    public init(minutes: Int?) {
        self.minutes = minutes
    }

    public var body: some View {
        if let minutes {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "clock")
                    .imageScale(.small)
                Text("\(minutes) min")
                    .font(.appCaption.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.appTextPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appAccentSecondary.opacity(0.15))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(minutes) minutes")
        }
    }
}

#Preview("Prep-time badge") {
    HStack(spacing: Theme.Spacing.md) {
        PrepTimeBadge(minutes: 35)
        PrepTimeBadge(minutes: 120)
        PrepTimeBadge(minutes: nil) // renders nothing
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}
