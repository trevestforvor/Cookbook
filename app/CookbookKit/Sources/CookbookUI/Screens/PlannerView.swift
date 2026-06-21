import SwiftUI
import CookbookKit

// MARK: - Planner (Meal plan)

/// The meal-planner screen. The cook dials in how many **days** (1–7) and
/// **meals per day** (1–4) they want, a **daily calorie target** (e.g. 2600), and
/// — optionally — a **diet** and a **max cook time per recipe**. Tapping
/// **Generate** asks the deterministic planner for a plan and lays the result out
/// as a day-by-day grid of compact recipe rows (title + calories in `.statNumber`).
/// Tapping a row calls `onSelect(recipeId)` so the host can push the recipe detail.
///
/// ### Daily target → per-meal cap (backend caveat)
/// The planner endpoint (`POST /meal-plan` → `APIClient.generateMealPlan`) currently
/// constrains nutrition with `max_calories_per_meal`, **not** a daily sum. To honor
/// the user's *daily* target we convert it to a per-meal ceiling:
///
/// ```
/// perMealCap = ceil(dailyTarget / mealsPerDay)
/// ```
///
/// This is an over-approximation: a real daily-sum optimizer could let one meal run
/// hot if another runs light. The UI surfaces the derived per-meal cap so the number
/// isn't a mystery, and the report flags that the backend should optimize toward a
/// daily SUM rather than a per-meal cap.
///
/// ### Store boundary
/// There is no planner method on `RecipeStore` (the stores cover catalog/library/
/// ingestion only), so this screen calls `environment.client` directly inside its
/// action `Task`s — a one-shot fetch, never a reactive `@Query`. Loads are triggered
/// explicitly by the Generate / Save / Build buttons. See the report for the store
/// methods that should be promoted (`generateMealPlan`, `saveMealPlan`,
/// `buildShoppingList`).
public struct PlannerView: View {
    @Environment(CookbookEnvironment.self) private var environment

    // MARK: Inputs
    @State private var days = 3
    @State private var mealsPerDay = 3
    @State private var dailyCalorieTarget = 2600
    @State private var dietText = ""
    @State private var limitCookTime = false
    @State private var maxMinutes = 30

    // MARK: Result / status
    @State private var result: MealPlanResult?
    @State private var phase: Phase = .idle
    @State private var statusMessage: String?
    @State private var statusIsError = false

    /// Seed used to render a `#Preview` without a network round-trip.
    private let previewSeed: MealPlanResult?

    /// Invoked with a recipe id when the cook taps a plan row. Wired by the host
    /// (``RootView``) to push the recipe detail; defaults to a no-op so the screen
    /// previews standalone.
    private let onSelectRecipe: (Int) -> Void

    /// - Parameter onSelect: receives the tapped recipe's id for the host to
    ///   navigate to. Defaults to a no-op.
    public init(onSelect: @escaping (Int) -> Void = { _ in }) {
        self.previewSeed = nil
        self.onSelectRecipe = onSelect
    }

    /// Preview/testing initializer that pre-seeds a generated plan so the screen
    /// renders its populated state offline.
    init(previewResult: MealPlanResult?, onSelect: @escaping (Int) -> Void = { _ in }) {
        self.previewSeed = previewResult
        self.onSelectRecipe = onSelect
        _result = State(initialValue: previewResult)
        _phase = State(initialValue: previewResult == nil ? .idle : .loaded)
    }

    private enum Phase: Equatable {
        case idle
        case generating
        case loaded
        case failed(String)
    }

    // MARK: Derived

    /// Per-meal calorie ceiling derived from the daily target — `ceil(target / meals)`.
    private var perMealCap: Int {
        let meals = max(1, mealsPerDay)
        return Int((Double(dailyCalorieTarget) / Double(meals)).rounded(.up))
    }

    private var trimmedDiet: String {
        dietText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recipe ids in the current plan, de-duplicated but order-preserving — the
    /// input to "Build shopping list".
    private var planRecipeIds: [Int] {
        guard let plan = result?.plan else { return [] }
        var seen = Set<Int>()
        var ids: [Int] = []
        for entry in plan where seen.insert(entry.recipeId).inserted {
            ids.append(entry.recipeId)
        }
        return ids
    }

    /// The plan grouped into ordered days, each a list of its meal slots.
    private var groupedDays: [(day: Int, entries: [MealPlanEntry])] {
        guard let plan = result?.plan else { return [] }
        let byDay = Dictionary(grouping: plan, by: \.day)
        return byDay.keys.sorted().map { day in
            (day, byDay[day]!.sorted { $0.meal < $1.meal })
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    controls
                    generateButton

                    if let statusMessage {
                        statusBanner(statusMessage)
                    }

                    resultsSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Color.appBackground)
            .navigationTitle("Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Build a plan")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            stepperRow(
                title: "Days",
                value: $days,
                range: 1...7,
                valueLabel: "\(days)",
                systemImage: "calendar"
            )

            Divider().overlay(Color.appBorder)

            stepperRow(
                title: "Meals / day",
                value: $mealsPerDay,
                range: 1...4,
                valueLabel: "\(mealsPerDay)",
                systemImage: "fork.knife"
            )

            Divider().overlay(Color.appBorder)

            stepperRow(
                title: "Daily calories",
                value: $dailyCalorieTarget,
                range: 800...5000,
                step: 100,
                valueLabel: "\(dailyCalorieTarget) kcal",
                systemImage: "flame"
            )

            // Honest surfacing of the per-meal cap we actually send to the backend.
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                Text("Targets \u{2248} \(perMealCap) kcal per meal")
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Divider().overlay(Color.appBorder)

            dietField

            Divider().overlay(Color.appBorder)

            maxTimeControl
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func stepperRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        valueLabel: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.appBody)
                .foregroundStyle(Color.appAccent)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)

            Spacer(minLength: Theme.Spacing.md)

            Text(valueLabel)
                .font(.statNumber.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .accessibilityHidden(true)

            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityValue(valueLabel)
        }
    }

    private var dietField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "leaf")
                    .font(.appBody)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("Diet")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: 0)
                Text("optional")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            TextField("e.g. vegetarian, vegan, keto", text: $dietText)
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.appBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                )
        }
    }

    private var maxTimeControl: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle(isOn: $limitCookTime) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "timer")
                        .font(.appBody)
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text("Limit cook time")
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                }
            }
            .tint(Color.appAccent)

            if limitCookTime {
                HStack(spacing: Theme.Spacing.md) {
                    Spacer(minLength: 34)
                    Text("\(maxMinutes) min")
                        .font(.statNumber.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .accessibilityHidden(true)
                    Spacer(minLength: Theme.Spacing.md)
                    Stepper("Max minutes", value: $maxMinutes, in: 10...180, step: 5)
                        .labelsHidden()
                        .accessibilityValue("\(maxMinutes) minutes")
                }
            }
        }
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if phase == .generating {
                    ProgressView()
                        .tint(Color.white)
                } else {
                    Image(systemName: "wand.and.stars")
                }
                Text(phase == .generating ? "Generating\u{2026}" : "Generate plan")
                    .font(.appHeadline)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appAccent)
            )
        }
        .buttonStyle(.plain)
        .disabled(phase == .generating)
        .opacity(phase == .generating ? 0.7 : 1)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Status banner

    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: statusIsError ? "exclamationmark.triangle" : "info.circle")
                .font(.appBody)
                .foregroundStyle(statusIsError ? Color.appDestructive : Color.appAccent)
            Text(message)
                .font(.appCaption)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill((statusIsError ? Color.appDestructive : Color.appAccentSecondary).opacity(0.15))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        switch phase {
        case .idle:
            EmptyState(
                systemImage: "calendar.badge.plus",
                message: "No plan yet",
                subtitle: "Set your days, meals, and a daily calorie target, then tap Generate."
            )
            .padding(.horizontal, Theme.Spacing.lg)

        case .generating where result == nil:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
                .tint(Color.appAccent)

        case .failed(let message):
            EmptyState(
                systemImage: "wifi.slash",
                message: "Couldn't build a plan",
                subtitle: message,
                actionTitle: "Retry",
                action: { generate() }
            )
            .padding(.horizontal, Theme.Spacing.lg)

        default:
            if let result, !result.plan.isEmpty {
                planGrid(result)
            } else if phase == .loaded {
                EmptyState(
                    systemImage: "tray",
                    message: "No recipes matched",
                    subtitle: "Loosen the diet, calorie, or time constraints and try again."
                )
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func planGrid(_ result: MealPlanResult) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // Planner-provided note (e.g. "some recipes repeat").
            if let note = result.note, !note.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.appCaption)
                        .foregroundStyle(Color.appAccentSecondary)
                    Text(note)
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            ForEach(groupedDays, id: \.day) { group in
                dayCard(day: group.day, entries: group.entries)
            }

            actionRow
        }
    }

    private func dayCard(day: Int, entries: [MealPlanEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Day \(day)")
                    .font(.appTitle)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text(dayCaloriesLabel(entries))
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.bottom, Theme.Spacing.xxs)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().overlay(Color.appBorder)
                    }
                    mealRow(entry)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
            .shadow(
                color: Theme.Shadow.cardColor,
                radius: Theme.Shadow.cardRadius,
                y: Theme.Shadow.cardYOffset
            )
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func mealRow(_ entry: MealPlanEntry) -> some View {
        Button {
            onSelect(entry.recipeId)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Text(mealLabel(entry.meal))
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(entry.title ?? "Recipe #\(entry.recipeId)")
                        .font(.appBody.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Calories rendered honestly via provenance: a present value is
                    // treated as stated; a nil value reads "— kcal" (never fabricated).
                    Text(calorieProvenance(entry).formattedCalories(entry.calories))
                        .font(.statNumber)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Spacer(minLength: Theme.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var actionRow: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                secondaryAction(
                    title: "Save plan",
                    systemImage: "tray.and.arrow.down",
                    busy: phase == .generating
                ) {
                    savePlan()
                }
                secondaryAction(
                    title: "Shopping list",
                    systemImage: "cart",
                    busy: phase == .generating
                ) {
                    buildShoppingList()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func secondaryAction(
        title: String,
        systemImage: String,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.appHeadline)
            }
            .foregroundStyle(Color.appAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appAccent, lineWidth: Theme.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    // MARK: - Labels / formatting helpers

    private func mealLabel(_ meal: Int) -> String {
        // Meals are 1-indexed in the planner; map the common cases to names and
        // fall back to "Meal N" for anything beyond a standard four-meal day.
        switch meal {
        case 1: return "Breakfast"
        case 2: return "Lunch"
        case 3: return "Dinner"
        case 4: return "Snack"
        default: return "Meal \(meal)"
        }
    }

    /// A present calorie value is shown as a filled/stated figure; an absent one
    /// falls through to the honest "— kcal" via `.none`.
    private func calorieProvenance(_ entry: MealPlanEntry) -> NutritionProvenance {
        entry.calories == nil ? .none : .filledStated
    }

    private func dayCaloriesLabel(_ entries: [MealPlanEntry]) -> String {
        let known = entries.compactMap(\.calories)
        guard !known.isEmpty else { return "\u{2014} kcal" }
        let total = Int(known.reduce(0, +).rounded())
        // Mark partial when at least one slot had no calorie figure.
        let partial = known.count < entries.count
        return "\(partial ? "\u{2248} " : "")\(total) kcal"
    }

    // MARK: - Selection hook

    /// Recipe-tap hook. The host wires this to push the recipe detail; in isolation
    /// (previews) it is a no-op. Mirrors the `onSelect(recipeId)` contract requested
    /// for the planner grid.
    private func onSelect(_ recipeId: Int) {
        onSelectRecipe(recipeId)
    }

    // MARK: - Networking actions (one-shot; client called directly — see report)

    private func generate() {
        statusMessage = nil
        statusIsError = false
        phase = .generating

        let body = MealPlanBody(
            days: days,
            mealsPerDay: mealsPerDay,
            // Daily target converted to a per-meal cap: ceil(target / meals).
            // NOTE: the backend caps *per meal*, not the daily sum — see report.
            maxCaloriesPerMeal: Double(perMealCap),
            diet: trimmedDiet.isEmpty ? nil : trimmedDiet,
            maxTotalMinutes: limitCookTime ? maxMinutes : nil,
            pantry: nil
        )

        let client = environment.client
        Task {
            do {
                let plan = try await client.generateMealPlan(body)
                await MainActor.run {
                    result = plan
                    phase = .loaded
                    if plan.plan.isEmpty {
                        setStatus("No recipes matched those constraints.", isError: false)
                    }
                }
            } catch {
                await MainActor.run {
                    let message = Self.describe(error)
                    phase = .failed(message)
                    setStatus(message, isError: true)
                }
            }
        }
    }

    private func savePlan() {
        guard let result, !result.plan.isEmpty else { return }
        let name = defaultPlanName()
        // Round-trip the typed entries into a JSONValue blob (the saved-artifact
        // contract stores the plan as JSON-in-TEXT).
        guard let planJSON = Self.jsonValue(from: result.plan) else {
            setStatus("Couldn't encode the plan to save.", isError: true)
            return
        }
        let client = environment.client
        Task {
            do {
                _ = try await client.saveMealPlan(name: name, plan: planJSON)
                await MainActor.run { setStatus("Saved \u{201C}\(name)\u{201D}.", isError: false) }
            } catch {
                await MainActor.run { setStatus(Self.describe(error), isError: true) }
            }
        }
    }

    private func buildShoppingList() {
        let ids = planRecipeIds
        guard !ids.isEmpty else { return }
        let client = environment.client
        Task {
            do {
                let list = try await client.buildShoppingList(recipeIds: ids, pantry: nil)
                await MainActor.run {
                    let count = list.items.count
                    setStatus(
                        count == 0
                            ? "No shopping-list items were produced."
                            : "Built a shopping list with \(count) item\(count == 1 ? "" : "s").",
                        isError: false
                    )
                }
            } catch {
                await MainActor.run { setStatus(Self.describe(error), isError: true) }
            }
        }
    }

    // MARK: - Small helpers

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func defaultPlanName() -> String {
        let mealWord = mealsPerDay == 1 ? "meal" : "meals"
        return "\(days)-day plan \u{00B7} \(mealsPerDay) \(mealWord)/day"
    }

    /// Encode any `Encodable` plan payload into a `JSONValue` blob using the same
    /// coding the DTO layer uses, so the saved-artifact round-trips losslessly.
    private static func jsonValue<T: Encodable>(from value: T) -> JSONValue? {
        guard let data = try? CookbookCoding.makeEncoder().encode(value) else { return nil }
        return try? CookbookCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? CookbookAPIError {
            return apiError.userFacingMessage
        }
        return error.localizedDescription
    }
}

// MARK: - Error copy

private extension CookbookAPIError {
    /// A short, cook-friendly sentence for each failure mode.
    var userFacingMessage: String {
        switch self {
        case .invalidURL:
            return "Couldn't build a valid request. Check the server address."
        case .transport:
            return "Couldn't reach the kitchen. Check your connection and try again."
        case .unauthorized:
            return "You're not signed in to the cookbook."
        case .notFound(let message):
            return message ?? "Nothing matched that request."
        case .serverError(let message, _):
            return message
        case .httpStatus(let code, let message):
            return message ?? "The server returned an error (\(code))."
        case .decoding:
            return "Got an unexpected response from the server."
        case .encoding:
            return "Couldn't encode the request."
        case .streamingUnavailable:
            return "Live updates aren't available right now."
        }
    }
}

// MARK: - Preview seed

private enum PlannerPreviewData {
    /// A 2-day, 3-meals/day sample plan with a repeat note — exercises the populated
    /// grid, the meal labels, a missing-calorie slot, and the planner note.
    static let samplePlan = MealPlanResult(
        plan: [
            MealPlanEntry(day: 1, meal: 1, recipeId: 4,
                          title: "Vanilla Almond Overnight Oats", calories: 305),
            MealPlanEntry(day: 1, meal: 2, recipeId: 3,
                          title: "Rainbow Chickpea Salad Jar", calories: 268),
            MealPlanEntry(day: 1, meal: 3, recipeId: 1,
                          title: "Miso-Glazed Salmon with Charred Greens", calories: 372),
            MealPlanEntry(day: 2, meal: 1, recipeId: 4,
                          title: "Vanilla Almond Overnight Oats", calories: 305),
            MealPlanEntry(day: 2, meal: 2, recipeId: 2,
                          title: "Spicy Peanut Chicken Power Bowl", calories: 514),
            MealPlanEntry(day: 2, meal: 3, recipeId: 8,
                          title: "Grandma's Sunday Stew", calories: nil),
        ],
        note: "Some recipes repeat to hit your calorie target."
    )
}

#Preview("Planner — Light") {
    PlannerView(previewResult: PlannerPreviewData.samplePlan)
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog
        ))
        .preferredColorScheme(.light)
}

#Preview("Planner — Dark") {
    PlannerView(previewResult: PlannerPreviewData.samplePlan)
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog
        ))
        .preferredColorScheme(.dark)
}

#Preview("Planner — Empty") {
    PlannerView()
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog
        ))
        .preferredColorScheme(.light)
}
