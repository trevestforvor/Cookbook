import SwiftUI
import CookbookKit

// MARK: - Empty state

/// A small, reusable empty / placeholder view: a tinted SF Symbol over a
/// message and optional subtitle, with an optional call-to-action button.
///
/// Used for empty rails, empty search results, and offline panels. Compact by
/// default so it sits comfortably inside a rail lane; it also reads well
/// centered in a full screen.
public struct EmptyState: View {
    public let systemImage: String
    public let message: String
    public let subtitle: String?
    public let actionTitle: String?
    public let action: (() -> Void)?

    /// - Parameters:
    ///   - systemImage: SF Symbol name for the icon.
    ///   - message: the primary line (headline weight).
    ///   - subtitle: optional supporting line.
    ///   - actionTitle: optional CTA button title; ignored if `action` is nil.
    ///   - action: optional CTA handler; ignored if `actionTitle` is nil.
    public init(
        systemImage: String,
        message: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.message = message
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.appTextSecondary)

            Text(message)
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Capsule(style: .continuous).fill(Color.appAccent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Empty state") {
    VStack(spacing: Theme.Spacing.xl) {
        EmptyState(
            systemImage: "magnifyingglass",
            message: "No recipes found",
            subtitle: "Try a different search or ask the assistant."
        )

        EmptyState(
            systemImage: "wifi.slash",
            message: "You're offline",
            subtitle: "Reconnect to browse new recipes.",
            actionTitle: "Retry",
            action: {}
        )
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}
