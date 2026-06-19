import SwiftUI
import CookbookKit
import CookbookUI

/// How the app boots. `.demo` (default) seeds an in-memory `CookbookEnvironment`
/// from the bundled `HomePreviewData` and hits no network. `.live` talks to a
/// local FastAPI server. The `-live` launch argument forces live mode regardless
/// of this constant (used for screenshot/QA runs against the real DB).
private enum AppMode { case demo, live }
private let appMode: AppMode = .demo

@main
struct CookbookApp: App {
    @State private var env: CookbookEnvironment
    @State private var isLive: Bool

    /// Optional deep-link from launch arguments (`-uiTab pantry`, `-uiRecipe 53`)
    /// so a specific screen can be opened directly — handy for the Simulator.
    private let initialTab: AppDestination?
    private let initialRecipeId: Int?

    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex
            else { return nil }
            return args[args.index(after: i)]
        }
        initialTab = value("-uiTab").flatMap(AppDestination.init(rawValue:))
        initialRecipeId = value("-uiRecipe").flatMap(Int.init)

        let wantLive = appMode == .live || args.contains("-live")
        // Seed the base URL + bearer token from the values the Settings screen
        // persisted on a previous launch (it writes them to UserDefaults via
        // `SettingsDefaults`), falling back to the local FastAPI default. Live
        // Settings edits re-point the running client; this only covers cold start.
        let savedURL = SettingsDefaults.storedBaseURLString.flatMap { URL(string: $0) }
        // Use 127.0.0.1 (not localhost): localhost resolves to ::1 first, and a
        // dev uvicorn bound to one stack leaves the other refused — which hangs POSTs.
        let baseURL = savedURL ?? URL(string: "http://127.0.0.1:8000")!
        let tokenStore: TokenStore = InMemoryTokenStore(token: SettingsDefaults.storedBearerToken)
        if wantLive,
           let live = try? CookbookEnvironment(
               configuration: APIConfiguration(baseURL: baseURL),
               tokenStore: tokenStore) {
            _env = State(initialValue: live)
            _isLive = State(initialValue: true)
        } else {
            _env = State(initialValue: Self.demoEnv())
            _isLive = State(initialValue: false)
        }
    }

    /// The bundled demo seed (no network).
    private static func demoEnv() -> CookbookEnvironment {
        CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog,
            searchResults: HomePreviewData.highProtein,
            favorites: HomePreviewData.favorites,
            pantry: HomePreviewData.pantry,
            recentlyViewed: HomePreviewData.recentlyViewed,
            cooked: HomePreviewData.cooked
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialTab: initialTab, initialRecipeId: initialRecipeId)
                .environment(env)
                .task {
                    // Only the live path performs a network hydrate; demo is seeded.
                    if isLive { await env.bootstrap() }
                }
        }

        #if os(macOS)
        // Standard macOS Settings scene (⌘,). Hosts the same `SettingsView` the
        // in-window gear raises as a sheet, so the Mac gets both the native menu
        // command and the toolbar affordance. Import routes through the sheet here
        // (the Settings scene is its own window with no sidebar to switch to).
        Settings {
            SettingsView()
                .environment(env)
                .frame(minWidth: 480, minHeight: 560)
        }
        #endif
    }
}
