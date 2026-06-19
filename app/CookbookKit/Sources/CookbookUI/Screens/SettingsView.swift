import SwiftUI
import CookbookKit

// MARK: - Settings

/// The app settings screen: server/sync controls, the cook profile (the agent's
/// memory + Planner defaults), an entry point to cookbook import, and an about
/// panel. Laid out as a grouped `Form` so it reads natively on both iOS and
/// macOS, themed with the Bell Pepper tokens throughout.
///
/// ## Reads & writes — what's live and what's honestly deferred
///
/// Everything in **Cook Profile** is fully live: it binds to
/// ``LibraryStore/preferences`` and writes through
/// ``LibraryStore/setPreference(key:value:)`` /
/// ``LibraryStore/setFoodPreference(ingredient:stance:note:)`` /
/// ``LibraryStore/removeFoodPreference(ingredient:)``. The scalar keys
/// (`calorie_target`, `protein_target`, `default_servings`, `default_diet`,
/// `max_total_minutes`) mirror the typed accessors on ``Preferences``.
///
/// **Sync** is live: "Sync now" calls ``CookbookEnvironment/bootstrap()`` and the
/// connection probe hits `GET /catalog/version` through the client. "Clear local
/// cache" empties the mirrored recipe summaries and resets the catalog-version
/// gate (via `LocalMirror.replaceRecipes([])` + `setCatalogVersion(0, …)`), so the
/// next sync re-pulls the full catalog.
///
/// **Base URL** and **bearer token** are now **live** (the promotion the earlier
/// version flagged has landed):
///
/// - **Base URL** — "Apply server settings" calls
///   ``CookbookEnvironment/reconfigure(baseURL:)`` which re-points the running
///   `APIClient` at the new root for all subsequent requests. The edited value is
///   also persisted to `UserDefaults` (``SettingsDefaults/baseURLKey``) so the app
///   host can seed the same root at launch. "Active:" reads the *truly*-active URL
///   straight from the client via ``CookbookEnvironment/activeBaseURL()``.
/// - **Bearer token** — written through ``CookbookEnvironment/setToken(_:)`` →
///   `TokenStore.setToken(_:)`, taking effect on the next request (no restart). It
///   is also persisted to `UserDefaults` (``SettingsDefaults/bearerTokenKey``) for
///   launch-time seeding.
public struct SettingsView: View {
    @Environment(CookbookEnvironment.self) private var environment

    // Server & sync ---------------------------------------------------------
    @State private var baseURLDraft: String
    @State private var bearerTokenDraft: String
    @State private var connection: ConnectionState = .unknown
    @State private var liveRecipeCount: Int?
    @State private var cachedRecipeCount: Int?
    @State private var isSyncing = false
    @State private var isClearingCache = false
    @State private var isResettingLibrary = false
    @State private var showingClearCacheConfirm = false
    @State private var showingResetLibraryConfirm = false
    @State private var serverSettingsDirty = false
    /// The truly-active server root, read live from the client (not just the
    /// last-saved `UserDefaults` value). Loaded in `.task`.
    @State private var activeBaseURL: String = ""

    // Cook profile ----------------------------------------------------------
    @State private var calorieTarget: Int
    @State private var proteinTarget: Int
    @State private var defaultServings: Int
    @State private var maxCookMinutes: Int
    @State private var defaultDiet: String
    @State private var foodDraft: String
    @State private var profileLoaded = false

    public init() {
        _baseURLDraft = State(initialValue: SettingsDefaults.storedBaseURLString ?? "")
        _bearerTokenDraft = State(initialValue: SettingsDefaults.storedBearerToken ?? "")
        _calorieTarget = State(initialValue: 2000)
        _proteinTarget = State(initialValue: 140)
        _defaultServings = State(initialValue: 2)
        _maxCookMinutes = State(initialValue: 45)
        _defaultDiet = State(initialValue: "")
        _foodDraft = State(initialValue: "")
    }

    private var libraryStore: LibraryStore { environment.libraryStore }

    public var body: some View {
        Form {
            serverSection
            cookProfileSection
            foodPreferenceSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .tint(Color.appAccent)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await loadProfileFromStore() }
        .task { await probeConnection() }
        .task { await loadActiveBaseURL() }
    }

    // MARK: - 1. Server & sync

    private var serverSection: some View {
        Section {
            // Base URL — persisted to UserDefaults, applied on next launch.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                fieldLabel("API base URL")
                TextField("http://127.0.0.1:8000", text: $baseURLDraft)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    #endif
                    .onChange(of: baseURLDraft) { _, _ in serverSettingsDirty = true }
                Text("Active: \(activeBaseURLString)")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            // Connection status — best-effort probe of /catalog/version.
            LabeledContent {
                connectionBadge
            } label: {
                rowLabel("Connection")
            }

            // Bearer token — persisted to UserDefaults, applied on next launch.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                fieldLabel("Bearer token")
                SecureField("Optional — leave blank to run open", text: $bearerTokenDraft)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
                    .onChange(of: bearerTokenDraft) { _, _ in serverSettingsDirty = true }
            }

            if serverSettingsDirty {
                Button {
                    Task { await applyServerSettings() }
                } label: {
                    Label("Apply server settings", systemImage: "checkmark.circle")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)

                noteRow("Applied live — the client re-points to the new server and the token takes effect on the next request.")
            }

            // Catalog facts.
            LabeledContent {
                Text(catalogVersionString)
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextPrimary)
            } label: {
                rowLabel("Catalog version")
            }

            LabeledContent {
                Text(recipeCountString)
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextPrimary)
            } label: {
                rowLabel("Recipes cached")
            }

            // Sync now.
            Button {
                Task { await syncNow() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if isSyncing {
                        ProgressView().controlSize(.small).tint(Color.appAccent)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Sync now")
                        .font(.appBody.weight(.semibold))
                }
                .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)

            // Clear local cache — now behind a confirmation (the reusable norm).
            Button(role: .destructive) {
                showingClearCacheConfirm = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if isClearingCache {
                        ProgressView().controlSize(.small).tint(Color.appDestructive)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text("Clear local cache")
                        .font(.appBody.weight(.semibold))
                }
                .foregroundStyle(Color.appDestructive)
            }
            .buttonStyle(.plain)
            .disabled(isClearingCache)
            .confirmationDialog(
                "Clear local cache?",
                isPresented: $showingClearCacheConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear cache", role: .destructive) { Task { await clearLocalCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This empties the cached recipes on this device and forces a full re-pull on the next sync. It does not delete anything on the server.")
            }

            // Reset library — GLOBAL server wipe of every recipe.
            Button(role: .destructive) {
                showingResetLibraryConfirm = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if isResettingLibrary {
                        ProgressView().controlSize(.small).tint(Color.appDestructive)
                    } else {
                        Image(systemName: "trash.slash")
                    }
                    Text("Reset library")
                        .font(.appBody.weight(.semibold))
                }
                .foregroundStyle(Color.appDestructive)
            }
            .buttonStyle(.plain)
            .disabled(isResettingLibrary)
            .confirmationDialog(
                "Reset your entire library?",
                isPresented: $showingResetLibraryConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all recipes", role: .destructive) { Task { await resetLibrary() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes ALL recipes from the server and this device. This can't be undone.")
            }

            if let error = environment.sync.lastError {
                noteRow(error, tint: Color.appDestructive)
            }
        } header: {
            sectionHeader("Server & Sync")
        } footer: {
            sectionFooter("Recipes are pulled only when the server's catalog version changes. Clearing the cache forces a full re-pull on the next sync; resetting the library deletes every recipe on the server.")
        }
        .listRowBackground(Color.appSurface)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(connection.tint)
                .frame(width: 8, height: 8)
            Text(connection.label)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(connection.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection \(connection.label)")
    }

    // MARK: - 2. Cook profile

    private var cookProfileSection: some View {
        Section {
            stepperRow(
                title: "Calorie target",
                subtitle: "Daily kcal the Planner aims for.",
                value: $calorieTarget,
                range: 800...5000,
                step: 50,
                unit: "kcal",
                key: "calorie_target"
            )
            stepperRow(
                title: "Protein target",
                subtitle: "Daily protein floor in grams.",
                value: $proteinTarget,
                range: 0...400,
                step: 5,
                unit: "g",
                key: "protein_target"
            )
            stepperRow(
                title: "Default servings",
                subtitle: "Servings new meal plans scale to.",
                value: $defaultServings,
                range: 1...12,
                step: 1,
                unit: defaultServings == 1 ? "serving" : "servings",
                key: "default_servings"
            )
            stepperRow(
                title: "Max cook time",
                subtitle: "Upper bound on total recipe time.",
                value: $maxCookMinutes,
                range: 5...240,
                step: 5,
                unit: "min",
                key: "max_total_minutes"
            )

            // Default diet — a free scalar string written on submit.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                fieldLabel("Default diet")
                TextField("e.g. vegetarian, high-protein, none", text: $defaultDiet)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
                    .submitLabel(.done)
                    .onSubmit { commitDiet() }
                Text("Applied as a soft constraint when planning.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        } header: {
            sectionHeader("Cook Profile")
        } footer: {
            sectionFooter("These defaults seed the Planner and are remembered by the assistant.")
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - 2b. Food preferences

    private var foodPreferenceSection: some View {
        Section {
            // Add row — type an ingredient, pick a stance, add.
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                fieldLabel("Add an ingredient")
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("e.g. cilantro", text: $foodDraft)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif
                        .submitLabel(.done)
                        .onSubmit { addFood(.liked) }
                }
                HStack(spacing: Theme.Spacing.sm) {
                    stanceAddButton("Like", stance: .liked, symbol: "hand.thumbsup")
                    stanceAddButton("Dislike", stance: .disliked, symbol: "hand.thumbsdown")
                    stanceAddButton("Allergic", stance: .allergic, symbol: "exclamationmark.triangle")
                }
            }

            foodList(title: "Liked", items: libraryStore.preferences.liked, tint: Color.appAccent, symbol: "hand.thumbsup.fill")
            foodList(title: "Disliked", items: libraryStore.preferences.disliked, tint: Color.appTextSecondary, symbol: "hand.thumbsdown.fill")
            foodList(title: "Allergic", items: libraryStore.preferences.allergic, tint: Color.appDestructive, symbol: "exclamationmark.triangle.fill")

            if libraryStore.preferences.foodPreferences.isEmpty {
                Text("No food preferences yet — add ingredients you love, avoid, or can't eat.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        } header: {
            sectionHeader("Food Preferences")
        } footer: {
            sectionFooter("The assistant steers recipes toward what you like and away from dislikes and allergens.")
        }
        .listRowBackground(Color.appSurface)
    }

    @ViewBuilder
    private func foodList(title: String, items: [String], tint: Color, symbol: String) -> some View {
        if !items.isEmpty {
            ForEach(items, id: \.self) { item in
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer(minLength: Theme.Spacing.sm)
                    Text(title)
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                    Button {
                        Task { await libraryStore.removeFoodPreference(ingredient: item) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item)")
                }
            }
        }
    }

    private func stanceAddButton(_ title: String, stance: FoodStance, symbol: String) -> some View {
        Button {
            addFood(stance)
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).font(.appCaption.weight(.semibold))
            }
            .foregroundStyle(stance == .allergic ? Color.appDestructive : Color.appAccent)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill((stance == .allergic ? Color.appDestructive : Color.appAccent).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(trimmedFoodDraft.isEmpty)
        .accessibilityLabel("\(title) \(trimmedFoodDraft)")
    }

    // MARK: - 3. About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.appName)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
            } label: {
                rowLabel("App")
            }
            LabeledContent {
                Text(Self.versionString)
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextPrimary)
            } label: {
                rowLabel("Version")
            }
            Text("Your weight-loss cookbook — browse, plan, and cook smarter, all on your own server.")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
        } header: {
            sectionHeader("About")
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Small themed building blocks

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.appCaption.weight(.semibold))
            .foregroundStyle(Color.appTextSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.appTextSecondary)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.appBody)
            .foregroundStyle(Color.appTextPrimary)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.appCaption.weight(.semibold))
            .foregroundStyle(Color.appTextSecondary)
    }

    private func noteRow(_ text: String, tint: Color = Color.appTextSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.appCaption)
                .foregroundStyle(tint)
        }
    }

    private func stepperRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        key: String
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Text("\(value.wrappedValue) \(unit)")
                .font(.statNumber)
                .foregroundStyle(Color.appTextPrimary)
                .accessibilityHidden(true)
            Stepper(
                value: value,
                in: range,
                step: step
            ) {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            #if os(iOS)
            .tint(Color.appAccent)
            #endif
            .onChange(of: value.wrappedValue) { _, newValue in
                Task { await libraryStore.setPreference(key: key, value: String(newValue)) }
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue) \(unit)")
        }
    }

    // MARK: - Derived display

    private var activeBaseURLString: String {
        // Read live from the client via `CookbookEnvironment.activeBaseURL()`
        // (loaded into `activeBaseURL` in `.task`), so this reflects the *truly*
        // active server root — not just the last-saved `UserDefaults` value.
        activeBaseURL.isEmpty ? "—" : activeBaseURL
    }

    private var catalogVersionString: String {
        if let v = environment.sync.catalogVersion { return String(v) }
        return "—"
    }

    private var recipeCountString: String {
        if let c = cachedRecipeCount { return String(c) }
        if let c = liveRecipeCount { return "\(c) (server)" }
        return "—"
    }

    private var trimmedFoodDraft: String {
        foodDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func loadProfileFromStore() async {
        // Pull the latest mirrored preferences, then seed the local field state
        // from the typed accessors (only once, so the steppers don't fight live
        // edits on subsequent store refreshes).
        await libraryStore.refresh()
        guard !profileLoaded else { return }
        let p = libraryStore.preferences
        if let v = p.calorieTarget { calorieTarget = v }
        if let v = p.proteinTarget { proteinTarget = v }
        if let v = p.defaultServings { defaultServings = v }
        if let v = p.maxTotalMinutes { maxCookMinutes = v }
        if let v = p.defaultDiet { defaultDiet = v }
        cachedRecipeCount = await currentCachedRecipeCount()
        profileLoaded = true
    }

    private func currentCachedRecipeCount() async -> Int? {
        try? await environment.mirror.recipeCount()
    }

    private func probeConnection() async {
        connection = .checking
        do {
            let version = try await environment.client.catalogVersion()
            liveRecipeCount = version.recipeCount
            connection = .online
        } catch {
            connection = .offline
        }
    }

    private func loadActiveBaseURL() async {
        activeBaseURL = await environment.activeBaseURL().absoluteString
        // Seed the editable draft from the live value the first time, unless the
        // cook has already saved an override.
        if baseURLDraft.isEmpty { baseURLDraft = activeBaseURL }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        await environment.bootstrap()
        cachedRecipeCount = await currentCachedRecipeCount()
        await probeConnection()
    }

    private func clearLocalCache() async {
        isClearingCache = true
        defer { isClearingCache = false }
        // Empty the mirrored summaries and reset the version gate so the next
        // sync re-pulls the full catalog. Real public LocalMirror APIs only.
        try? await environment.mirror.replaceRecipes([])
        try? await environment.mirror.setCatalogVersion(0, recipeCount: 0)
        await environment.recipeStore.refresh()
        cachedRecipeCount = await currentCachedRecipeCount()
    }

    /// GLOBAL server wipe of every recipe (`DELETE /recipes?confirm=true` via
    /// `RecipeStore.resetLibrary`), then refresh the ingestion store (the wipe also
    /// clears ingest jobs server-side) and re-read the cached count.
    private func resetLibrary() async {
        isResettingLibrary = true
        defer { isResettingLibrary = false }
        await environment.recipeStore.resetLibrary()
        await environment.ingestionStore.refreshFromServer()
        cachedRecipeCount = await currentCachedRecipeCount()
    }

    private func commitDiet() {
        let trimmed = defaultDiet.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await libraryStore.setPreference(key: "default_diet", value: trimmed) }
    }

    private func addFood(_ stance: FoodStance) {
        let ingredient = trimmedFoodDraft
        guard !ingredient.isEmpty else { return }
        foodDraft = ""
        Task { await libraryStore.setFoodPreference(ingredient: ingredient, stance: stance) }
    }

    private func applyServerSettings() async {
        // Persist for the next launch *and* apply live to the running client so the
        // change takes effect immediately (no restart). Base URL re-points the
        // client; the token is written through the token store.
        let trimmedURL = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsDefaults.storedBaseURLString = trimmedURL
        if let url = URL(string: trimmedURL), url.scheme != nil {
            await environment.reconfigure(baseURL: url)
            activeBaseURL = await environment.activeBaseURL().absoluteString
        }

        let token = bearerTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsDefaults.storedBearerToken = token.isEmpty ? nil : token
        await environment.setToken(token.isEmpty ? nil : token)

        serverSettingsDirty = false
        // Re-probe the new server so the connection badge reflects the change.
        await probeConnection()
    }

    // MARK: - About metadata

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Cookbook"
    }

    private static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return b
        default: return "—"
        }
    }
}

// MARK: - Connection state

private enum ConnectionState {
    case unknown, checking, online, offline

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking…"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }

    var tint: Color {
        switch self {
        case .online: return .appAccent
        case .offline: return .appDestructive
        case .checking, .unknown: return .appTextSecondary
        }
    }
}

// MARK: - Persisted server settings (honest "restart to apply")

/// Persistence shim for the two server settings that can't change at runtime
/// (base URL + bearer token). The app host reads these when building its
/// `APIConfiguration` / `TokenStore` at launch; this screen only writes them.
public enum SettingsDefaults {
    public static let baseURLKey = "cookbook.settings.baseURL"
    public static let bearerTokenKey = "cookbook.settings.bearerToken"

    public static var storedBaseURLString: String? {
        get { UserDefaults.standard.string(forKey: baseURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    public static var storedBearerToken: String? {
        get { UserDefaults.standard.string(forKey: bearerTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: bearerTokenKey) }
    }
}

// MARK: - Previews

#Preview("Settings — light") {
    NavigationStack {
        SettingsView()
            .environment(settingsPreviewEnvironment())
    }
    .preferredColorScheme(.light)
}

#Preview("Settings — dark") {
    NavigationStack {
        SettingsView()
            .environment(settingsPreviewEnvironment())
    }
    .preferredColorScheme(.dark)
}

@MainActor
private func settingsPreviewEnvironment() -> CookbookEnvironment {
    CookbookEnvironment.preview(
        preferences: Preferences(
            scalars: [
                "calorie_target": "1800",
                "protein_target": "150",
                "default_servings": "2",
                "max_total_minutes": "40",
                "default_diet": "high-protein",
            ],
            liked: ["salmon", "spinach", "greek yogurt"],
            disliked: ["cilantro", "licorice"],
            allergic: ["shellfish", "peanuts"]
        )
    )
}
