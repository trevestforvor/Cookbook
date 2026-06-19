import SwiftUI
import CookbookKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

// MARK: - Top-level destinations

/// The six primary destinations of the app. Shared by the iOS `TabView` and the
/// macOS / iPad-regular `NavigationSplitView` so both navigation chromes stay in
/// lockstep. Every destination now hosts a real screen (Discover → ``HomeView``,
/// Pantry → ``PantryView``, Plan → ``PlannerView``, Saved → ``SavedView``,
/// Insights → ``InsightsView``, Assistant → ``AssistantView``).
public enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case discover
    case pantry
    case plan
    case saved
    case assistant

    public var id: String { rawValue }

    /// Tab / sidebar label.
    var title: String {
        switch self {
        case .discover: return "Discover"
        case .pantry: return "Pantry"
        case .plan: return "Plan"
        case .saved: return "Saved"
        case .assistant: return "Assistant"
        }
    }

    /// SF Symbol for the tab item / sidebar row.
    var systemImage: String {
        switch self {
        case .discover: return "sparkle.magnifyingglass"
        case .pantry: return "cabinet"
        case .plan: return "calendar"
        case .saved: return "heart"
        case .assistant: return "bubble.left.and.text.bubble.right"
        }
    }

    /// Copy for the not-yet-built placeholder screens.
    var comingSoonMessage: String {
        switch self {
        case .discover: return "Discover"
        case .pantry: return "Pantry coming soon"
        case .plan: return "Meal planning coming soon"
        case .saved: return "Saved recipes coming soon"
        case .assistant: return "Assistant coming soon"
        }
    }

    var comingSoonSubtitle: String {
        switch self {
        case .discover: return ""
        case .pantry: return "Tell the app what's in your kitchen and we'll match recipes you can cook tonight."
        case .plan: return "Build a week of meals around your goals and pantry."
        case .saved: return "Your favorites and cooked history will live here."
        case .assistant: return "Ask for swaps, scaling, and ideas in plain language."
        }
    }
}

// MARK: - Sidebar selection

/// What the macOS / iPad-regular sidebar can have selected. A superset of
/// ``AppDestination``: the five tab destinations *plus* the top-level **Import**
/// surface. Import is intentionally modeled here rather than as an
/// ``AppDestination`` so it stays out of the iPhone `TabView` (which keeps its 5
/// tabs) and only appears as a sidebar row on the larger layouts.
private enum SidebarSelection: Hashable {
    case destination(AppDestination)
    case `import`
}

// MARK: - Root view

/// Adaptive app shell.
///
/// - On iOS (compact width) this is a `TabView` with the five destinations;
///   `Discover` hosts ``HomeView`` and the rest show a "Coming soon"
///   ``EmptyState``.
/// - On macOS — and on iPad in a regular-width layout — it is a
///   `NavigationSplitView` whose sidebar lists the same destinations.
///
/// The active tab / selected sidebar row is accented with `appAccent` (the
/// `TabView`'s tint and the sidebar selection highlight respectively).
///
/// The stores are read from the SwiftUI environment (`CookbookEnvironment`), so a
/// caller must inject one via `.environment(_:)` (production wires the live
/// environment; previews use `CookbookEnvironment.preview(...)`).
public struct RootView: View {
    @Environment(CookbookEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selection: AppDestination = .discover

    /// The sidebar row selected on macOS / iPad-regular. A superset of the tab
    /// destinations — it also carries the top-level **Import** surface, which is
    /// deliberately *not* an ``AppDestination`` so it never appears as an iPhone
    /// tab (the phone keeps its 5 tabs and reaches Import through Settings).
    @State private var sidebarSelection: SidebarSelection = .destination(.discover)

    /// One navigation router per primary destination so each tab keeps its own
    /// recipe-detail back stack. The screens' `onSelect` / `onNavigate` /
    /// `onOpenRecipe` closures push onto the active tab's router.
    @State private var routers: [AppDestination: RecipeRouter] = Dictionary(
        uniqueKeysWithValues: AppDestination.allCases.map { ($0, RecipeRouter()) }
    )

    /// A dedicated router for the macOS / iPad-regular **Import** sidebar surface so
    /// result-chip taps there push ``RecipeDetailView`` onto Import's own stack.
    @State private var importRouter = RecipeRouter()

    /// Settings is presented as a sheet from the toolbar gear on all platforms
    /// (macOS also gets the standard `Settings` scene wired in the app entry).
    @State private var showingSettings = false

    /// The cross-platform Import sheet, raised from Settings' "Import cookbooks" row
    /// (and used as the iPhone path, where Import is not a sidebar destination).
    @State private var showingImport = false

    public init(initialTab: AppDestination? = nil, initialRecipeId: Int? = nil) {
        _selection = State(initialValue: initialTab ?? .discover)
        _sidebarSelection = State(initialValue: .destination(initialTab ?? .discover))
        let seeded = Dictionary(
            uniqueKeysWithValues: AppDestination.allCases.map { ($0, RecipeRouter()) }
        )
        if let recipeId = initialRecipeId {
            seeded[initialTab ?? .discover]?.open(recipeId)
        }
        _routers = State(initialValue: seeded)
    }

    /// The router backing a given destination (always present — seeded in `routers`).
    private func router(for destination: AppDestination) -> RecipeRouter {
        routers[destination] ?? RecipeRouter()
    }

    /// The router for whichever surface is currently active, so Settings/Import
    /// `onOpenRecipe` jumps land on the visible stack.
    private var activeRouter: RecipeRouter {
        #if os(macOS)
        if case .import = sidebarSelection { return importRouter }
        return router(for: selection)
        #else
        if horizontalSizeClass == .regular, case .import = sidebarSelection {
            return importRouter
        }
        return router(for: selection)
        #endif
    }

    public var body: some View {
        Group {
            #if os(macOS)
            splitView
            #else
            if horizontalSizeClass == .regular {
                splitView
            } else {
                tabView
            }
            #endif
        }
        .tint(Color.appAccent)
        // Settings sheet — raised by the toolbar gear on every platform.
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
        // Import sheet — raised from Settings on iPhone (and as a universal fallback);
        // on macOS / iPad-regular Import is primarily the sidebar destination.
        .sheet(isPresented: $showingImport) {
            importSheet
        }
        // macOS: accept a cookbook PDF dropped anywhere on the main window.
        #if os(macOS)
        .onDrop(of: [.pdf, .fileURL], isTargeted: nil) { providers in
            handleWindowDrop(providers)
        }
        #endif
    }

    // MARK: - Settings / Import presentation

    /// Open Settings. Tab/sidebar agnostic — always a sheet so the gear behaves the
    /// same everywhere (macOS additionally exposes the standard ⌘, Settings scene).
    private func openSettings() { showingSettings = true }

    /// Open the Import surface from Settings. On macOS / iPad-regular this selects
    /// the dedicated Import sidebar row (dismissing Settings); on iPhone-compact it
    /// raises the Import sheet.
    private func openImport() {
        #if os(macOS)
        showingSettings = false
        sidebarSelection = .import
        #else
        if horizontalSizeClass == .regular {
            showingSettings = false
            sidebarSelection = .import
        } else {
            showingImport = true
        }
        #endif
    }

    private var settingsSheet: some View {
        NavigationStack {
            SettingsView(onOpenImport: { openImport() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingSettings = false }
                            .tint(Color.appAccent)
                    }
                }
        }
        .tint(Color.appAccent)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private var importSheet: some View {
        NavigationStack {
            ImportView(onOpenRecipe: { recipeId in
                showingImport = false
                activeRouter.open(recipeId)
            })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingImport = false }
                        .tint(Color.appAccent)
                }
            }
        }
        .tint(Color.appAccent)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    #if os(macOS)
    /// Resolve a PDF dropped anywhere on the window, route it to the ingestion
    /// store, and surface the job by switching to the Import sidebar surface.
    private func handleWindowDrop(_ providers: [NSItemProvider]) -> Bool {
        let identifier = UTType.fileURL.identifier
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.pathExtension.lowercased() == "pdf"
            else { return }
            Task { @MainActor in
                sidebarSelection = .import
                await environment.ingestionStore.ingestPDF(fileURL: url)
            }
        }
        return true
    }
    #endif

    // MARK: Tab layout (iOS compact)

    #if os(iOS)
    private var tabView: some View {
        TabView(selection: $selection) {
            ForEach(AppDestination.allCases) { destination in
                destinationStack(destination)
                    .tabItem {
                        Label(destination.title, systemImage: destination.systemImage)
                    }
                    .tag(destination)
            }
        }
        .tint(Color.appAccent)
    }
    #endif

    // MARK: Split layout (macOS + iPad regular)

    private var splitView: some View {
        NavigationSplitView {
            // iOS exposes sidebar single-selection only via an *optional* binding
            // (`Binding<SelectionValue?>`); the non-optional overload is macOS-only.
            // Bridge the non-optional `sidebarSelection` state to an optional binding
            // so the same `splitView` compiles on both iOS (iPad regular) and macOS.
            List(selection: Binding<SidebarSelection?>(
                get: { sidebarSelection },
                set: { newValue in
                    guard let newValue else { return }
                    sidebarSelection = newValue
                    // Keep the tab `selection` in lockstep for destination rows so
                    // switching chromes (e.g. iPad rotate) preserves the screen.
                    if case let .destination(d) = newValue { selection = d }
                }
            )) {
                Section {
                    ForEach(AppDestination.allCases) { destination in
                        NavigationLink(value: SidebarSelection.destination(destination)) {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                    }
                }
                // Import is a top-level sidebar surface on the big screens only —
                // never an iPhone tab. Lives in its own section, below the five.
                Section {
                    NavigationLink(value: SidebarSelection.import) {
                        Label("Import", systemImage: "tray.and.arrow.down")
                    }
                }
                Section {
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Cookbook")
            .tint(Color.appAccent)
            #if os(macOS)
            .listStyle(.sidebar)
            #endif
        } detail: {
            switch sidebarSelection {
            case .destination(let destination):
                destinationStack(destination)
            case .import:
                importStack
            }
        }
        .tint(Color.appAccent)
    }

    /// The Import surface (macOS / iPad-regular sidebar) wrapped in its own
    /// `NavigationStack` so result-chip taps push ``RecipeDetailView`` onto Import's
    /// dedicated `importRouter` path.
    private var importStack: some View {
        @Bindable var router = importRouter
        return NavigationStack(path: $router.path) {
            ImportView(onOpenRecipe: { router.open($0) })
                .navigationDestination(for: Int.self) { recipeId in
                    RecipeDetailView(
                        recipeId: recipeId,
                        onNavigate: { router.open($0) }
                    )
                }
        }
    }

    // MARK: Destination routing

    /// A destination's screen wrapped in its own `NavigationStack` bound to that
    /// destination's ``RecipeRouter`` path, with the shared recipe-detail
    /// destination attached. Selecting a recipe anywhere in the screen pushes
    /// ``RecipeDetailView`` here; the stack's own back button (and the detail's
    /// `onClose`) pop it. A substitute / "open another recipe" jump from inside the
    /// detail (`onNavigate`) stacks a further detail page on the same path.
    @ViewBuilder
    private func destinationStack(_ destination: AppDestination) -> some View {
        @Bindable var router = router(for: destination)
        NavigationStack(path: $router.path) {
            destinationContent(destination, router: router)
                .navigationDestination(for: Int.self) { recipeId in
                    RecipeDetailView(
                        recipeId: recipeId,
                        // Push another detail page (substitute / "+ plan" jumps).
                        onNavigate: { router.open($0) }
                    )
                    // No `onClose`: the NavigationStack supplies its own back
                    // button, so passing one would double up the chevron.
                }
        }
    }

    @ViewBuilder
    private func destinationContent(
        _ destination: AppDestination,
        router: RecipeRouter
    ) -> some View {
        switch destination {
        case .discover:
            HomeView(
                onOpenRecipe: { router.open($0) },
                onOpenSettings: { openSettings() }
            )
        case .pantry:
            PantryView(onSelect: { router.open($0) })
        case .plan:
            PlannerView(onSelect: { router.open($0) })
        case .saved:
            SavedView(onSelect: { router.open($0) })
        case .assistant:
            AssistantView(onOpenRecipe: { router.open($0) })
        }
    }
}

#Preview("Root — seeded (Light)") {
    RootView()
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog,
            favorites: HomePreviewData.favorites,
            pantry: HomePreviewData.pantry,
            recentlyViewed: HomePreviewData.recentlyViewed,
            cooked: HomePreviewData.cooked
        ))
        .preferredColorScheme(.light)
}

#Preview("Root — seeded (Dark)") {
    RootView()
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog,
            favorites: HomePreviewData.favorites,
            pantry: HomePreviewData.pantry,
            recentlyViewed: HomePreviewData.recentlyViewed,
            cooked: HomePreviewData.cooked
        ))
        .preferredColorScheme(.dark)
}
