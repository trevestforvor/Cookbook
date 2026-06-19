import SwiftUI
import CookbookKit

// MARK: - Rail

/// A titled horizontal carousel: a header row (title + optional "See all ›")
/// over a horizontally-scrolling lane of content built from `items`.
///
/// Generic over an `Identifiable` element so it can host `RecipeCard`s (the
/// common case) or any other card-shaped view. The `content` builder receives
/// each element and returns its card; the rail handles the header, the
/// horizontal `ScrollView` + `LazyHStack`, spacing, and the empty fallback.
///
/// When `items` is empty the rail shows an ``EmptyState`` in the lane so a
/// section never collapses to a bare title.
public struct Rail<Item: Identifiable, Content: View>: View {
    public let title: String
    public let items: [Item]
    public let onSeeAll: (() -> Void)?
    public let emptyMessage: String
    public let emptySystemImage: String
    @ViewBuilder public let content: (Item) -> Content

    /// - Parameters:
    ///   - title: the section header.
    ///   - items: the elements to lay out horizontally.
    ///   - onSeeAll: when non-nil, renders a trailing "See all ›" button.
    ///   - emptyMessage: text shown in the lane when `items` is empty.
    ///   - emptySystemImage: SF Symbol for the empty fallback.
    ///   - content: builds each item's card.
    public init(
        title: String,
        items: [Item],
        onSeeAll: (() -> Void)? = nil,
        emptyMessage: String = "Nothing here yet",
        emptySystemImage: String = "tray",
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.title = title
        self.items = items
        self.onSeeAll = onSeeAll
        self.emptyMessage = emptyMessage
        self.emptySystemImage = emptySystemImage
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header

            if items.isEmpty {
                EmptyState(
                    systemImage: emptySystemImage,
                    message: emptyMessage
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.md) {
                        ForEach(items) { item in
                            content(item)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            Spacer(minLength: Theme.Spacing.sm)

            if let onSeeAll {
                Button(action: onSeeAll) {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                    }
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all \(title)")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

#Preview("Rail — recipes") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Rail(
                title: "High-protein picks",
                items: PreviewSamples.all,
                onSeeAll: {}
            ) { recipe in
                RecipeCard(
                    summary: recipe,
                    style: .carousel,
                    nutritionSource: recipe.calories == nil ? nil : .stated,
                    isFavorite: recipe.id == 1
                )
            }

            Rail(
                title: "Recently viewed",
                items: [RecipeSummary](),
                onSeeAll: nil,
                emptyMessage: "Recipes you open show up here",
                emptySystemImage: "clock.arrow.circlepath"
            ) { recipe in
                RecipeCard(summary: recipe, style: .carousel)
            }
        }
        .padding(.vertical, Theme.Spacing.lg)
    }
    .background(Color.appBackground)
}
