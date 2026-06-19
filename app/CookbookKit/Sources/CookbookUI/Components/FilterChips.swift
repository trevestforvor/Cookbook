import SwiftUI
import CookbookKit

// MARK: - Recipe filter

/// The set of quick filters offered by ``FilterChips``. Each case carries its
/// own label so the chip row is fully data-driven.
public enum RecipeFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case highProtein
    case under30
    case vegan
    case lowCal

    public var id: String { rawValue }

    /// User-facing chip label.
    public var label: String {
        switch self {
        case .highProtein: return "High-protein"
        case .under30: return "<30 min"
        case .vegan: return "Vegan"
        case .lowCal: return "Low-cal"
        }
    }
}

// MARK: - A single chip

/// One toggle chip. `appAccent`-filled with on-accent text when selected; an
/// `appSurface` pill on a hairline `appBorder` outline when not.
public struct FilterChip: View {
    public let title: String
    public let isSelected: Bool
    public let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.appTextPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.appAccent : Color.appSurface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.clear : Color.appBorder,
                            lineWidth: Theme.Stroke.hairline
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The chip row

/// A horizontally-scrolling row of toggle chips for the standard recipe filters.
/// Binds to the caller's `Set<RecipeFilter>`; tapping a chip toggles membership.
public struct FilterChips: View {
    @Binding public var selection: Set<RecipeFilter>
    public let filters: [RecipeFilter]

    /// - Parameters:
    ///   - selection: the set of active filters (the source of truth).
    ///   - filters: which filters to show, in order. Defaults to all four.
    public init(
        selection: Binding<Set<RecipeFilter>>,
        filters: [RecipeFilter] = RecipeFilter.allCases
    ) {
        self._selection = selection
        self.filters = filters
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(filters) { filter in
                    FilterChip(
                        title: filter.label,
                        isSelected: selection.contains(filter)
                    ) {
                        toggle(filter)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func toggle(_ filter: RecipeFilter) {
        if selection.contains(filter) {
            selection.remove(filter)
        } else {
            selection.insert(filter)
        }
    }
}

private struct FilterChipsPreviewHost: View {
    @State private var selection: Set<RecipeFilter> = [.highProtein, .vegan]

    var body: some View {
        FilterChips(selection: $selection)
            .padding(.vertical, Theme.Spacing.lg)
            .background(Color.appBackground)
    }
}

#Preview("Filter chips") {
    FilterChipsPreviewHost()
}
