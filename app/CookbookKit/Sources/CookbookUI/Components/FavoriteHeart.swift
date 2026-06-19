import SwiftUI
import CookbookKit

// MARK: - Favorite heart

/// A tappable favorite toggle. Filled Pimiento Red (`appDestructive`) when
/// active, hollow `appTextSecondary` outline when inactive.
///
/// Stateless: it reflects `isFavorite` and reports taps via `onToggle`; the
/// owning store flips persistence and re-publishes (per the repository pattern).
public struct FavoriteHeart: View {
    public let isFavorite: Bool
    public var diameter: CGFloat
    public let onToggle: () -> Void

    public init(
        isFavorite: Bool,
        diameter: CGFloat = 22,
        onToggle: @escaping () -> Void
    ) {
        self.isFavorite = isFavorite
        self.diameter = diameter
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: diameter, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.appDestructive : Color.appTextSecondary)
                .contentShape(Rectangle())
                .animation(.snappy(duration: 0.2), value: isFavorite)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityAddTraits(isFavorite ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Favorite heart") {
    HStack(spacing: Theme.Spacing.xl) {
        FavoriteHeart(isFavorite: true) {}
        FavoriteHeart(isFavorite: false) {}
        FavoriteHeart(isFavorite: true, diameter: 16) {}
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}
