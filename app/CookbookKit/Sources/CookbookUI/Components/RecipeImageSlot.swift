import SwiftUI
import CookbookKit

// MARK: - Recipe image slot

/// The image area of a recipe card.
///
/// This module is dependency-free (no Nuke), so the slot renders a styled,
/// theme-consistent **placeholder** whenever `imageURL` is nil — a soft surface
/// fill with a fork/knife glyph. When a real async image loader (Nuke
/// `LazyImage`) is wired at the app layer, callers can overlay it on top of this
/// same rounded frame; the placeholder is what shows through while loading or
/// when no URL exists.
struct RecipeImageSlot: View {
    let imageURL: URL?
    let cornerRadius: CGFloat

    init(imageURL: URL?, cornerRadius: CGFloat = Theme.Radius.card) {
        self.imageURL = imageURL
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.appSurface)
            .overlay {
                // A faint accent wash so the placeholder reads as "food" not "error".
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appAccent.opacity(0.06))
            }
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.appTextSecondary.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            }
            .accessibilityHidden(true)
    }
}

#Preview("Image slot — placeholder") {
    HStack(spacing: Theme.Spacing.lg) {
        RecipeImageSlot(imageURL: nil)
            .frame(width: 150, height: 100)
        RecipeImageSlot(imageURL: nil, cornerRadius: Theme.Radius.chip)
            .frame(width: 72, height: 72)
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}
