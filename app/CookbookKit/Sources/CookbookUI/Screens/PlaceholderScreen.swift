import SwiftUI
import CookbookKit

// MARK: - Placeholder screen

/// A simple "Coming soon" screen for destinations that aren't built yet
/// (Pantry / Plan / Saved / Assistant). Centers a themed ``EmptyState`` on the
/// app background and gives the screen its destination title.
struct PlaceholderScreen: View {
    let destination: AppDestination

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            EmptyState(
                systemImage: destination.systemImage,
                message: destination.comingSoonMessage,
                subtitle: destination.comingSoonSubtitle.isEmpty ? nil : destination.comingSoonSubtitle
            )
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle(destination.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

#Preview("Placeholder — Pantry") {
    NavigationStack {
        PlaceholderScreen(destination: .pantry)
    }
}
