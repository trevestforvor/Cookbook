import SwiftUI
import CookbookKit

// MARK: - Draft recipe card (conversational builder)

/// The evolving recipe **draft** rendered inline in the Assistant transcript while
/// the cook composes/refines a new recipe (`POST /recipes/compose`). It reuses the
/// recipe-detail rendering vocabulary — title + meta, an honest nutrition summary,
/// the verbatim ingredient lines (`Ingredient.displayText`), and the numbered
/// steps — so a draft reads exactly like the recipe it will become.
///
/// ### The Save contract (the whole point of this surface)
/// **Nothing in this card persists.** A `RecipeDraft` is transient client state;
/// the catalog/search/local mirror are untouched until the cook taps **Save**,
/// which calls `ComposeStore.save()`. Refining never writes — each turn just
/// resends the running draft + a new instruction. This is what makes one unified
/// ask+add chat safe against a misread "add" intent.
///
/// ### Editing model (v1)
/// The **only** way to edit a draft is the inline **Refine** field (a follow-up
/// chat instruction with the current draft attached). There is deliberately NO
/// inline field-editor for ingredients/steps in v1 — chat-refine *is* the edit
/// mechanism. See the TODO below.
///
/// ### Honesty (carried verbatim from the data layer)
/// Nutrition is attributed through `NutritionProvenance`: a filled dot for stated
/// panels, a hollow dot + "≈" for computed, and "no nutrition info" with no dot
/// when the panel is missing (`Nutrition.isMissing`). A *generated* draft leaves
/// `nutrition` nil — never a column of zeros. Computed nutrition is materialized
/// server-side at Save, not here.
///
/// All actions are closures the host (`AssistantView`) wires; this view holds no
/// store reference and binds to nothing — it just renders the passed `draft` and
/// reports Refine / Save / Discard intents back up.
struct DraftRecipeCard: View {
    let draft: RecipeDraft
    /// Non-fatal note from the last compose turn (e.g. web-search find isn't wired
    /// yet so `auto` fell through to generate). Shown inline when present.
    let warning: String?
    /// URLs a *found* draft was parsed from (empty for generated/refined).
    let sources: [String]
    /// True while a compose turn or save is in flight — disables the controls and
    /// swaps the Save label for a spinner.
    let isWorking: Bool

    /// Send a follow-up refine instruction (the host attaches the running draft).
    let onRefine: (String) -> Void
    /// Commit the draft (`ComposeStore.save()`), then navigate to the new recipe.
    let onSave: () -> Void
    /// Throw the draft away and start over (`ComposeStore.reset()`).
    let onDiscard: () -> Void

    @State private var refineText: String = ""
    @FocusState private var refineFocused: Bool

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            draftBadge
            header
            nutritionSummary
            ingredientsSection
            stepsSection
            if !sources.isEmpty {
                sourcesSection
            }
            if let warning, !warning.isEmpty {
                warningBanner(warning)
            }
            Divider().overlay(Color.appBorder)
            refineField
            actionRow
            // TODO(v1-scope): full inline field-editing of ingredients/steps is
            // intentionally out of scope — the Refine field is the edit mechanism.
            // If a structured editor is added later, gate it so it never bypasses
            // the "nothing persists until Save" contract.
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.45), lineWidth: 1.5)
        )
        .shadow(
            color: Theme.Shadow.cardColor,
            radius: Theme.Shadow.cardRadius,
            y: Theme.Shadow.cardYOffset
        )
    }

    // MARK: Draft badge

    /// A small "Draft — not saved yet" pill so it's unmistakable nothing is in the
    /// catalog until Save.
    private var draftBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "wand.and.stars")
                .imageScale(.small)
            Text("Draft \u{00B7} not saved yet")
                .font(.appCaption.weight(.semibold))
        }
        .foregroundStyle(Color.appAccent)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(Color.appAccent.opacity(0.12)))
        .accessibilityLabel("Draft recipe, not saved yet")
    }

    // MARK: Header (title + description + meta)

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(draft.title.isEmpty ? "Untitled recipe" : draft.title)
                .font(.appTitle)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let description = draft.description, !description.isEmpty {
                Text(description)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !metaItems.isEmpty {
                metaRow
            }
        }
    }

    private var metaItems: [String] {
        var items: [String] = []
        if let total = draft.totalMinutes { items.append("\(total) min") }
        if let serves = draft.servings {
            items.append(serves == 1 ? "1 serving" : "\(serves) servings")
        } else if let yields = draft.yields, !yields.isEmpty {
            items.append(yields)
        }
        if let difficulty = draft.difficulty {
            items.append(difficulty.rawValue.capitalized)
        }
        if let cuisine = draft.cuisine, !cuisine.isEmpty {
            items.append(cuisine)
        }
        return items
    }

    private var metaRow: some View {
        Text(metaItems.joined(separator: " \u{00B7} "))
            .font(.statNumber)
            .foregroundStyle(Color.appTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: Nutrition (honest)

    @ViewBuilder
    private var nutritionSummary: some View {
        // A draft always carries a Nutrition value; a missing panel is
        // `nutrition.isMissing` (source == nil), never nil — never zeros.
        let nutrition = draft.nutrition
        let provenance = NutritionProvenance(nutrition)
        HStack(spacing: Theme.Spacing.sm) {
            NutritionProvenanceDot(provenance, diameter: 9)
            if nutrition.isMissing {
                Text("No nutrition info yet \u{2014} it's computed on Save.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                Text(nutritionLine(nutrition, provenance: provenance))
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }

    /// "≈ 372 kcal · 28 g protein · 41 g carbs · 14 g fat" — each macro dropped
    /// when nil (never "0 g"); calories carry the "≈"/"—" honesty.
    private func nutritionLine(_ n: Nutrition, provenance: NutritionProvenance) -> String {
        var parts: [String] = [provenance.formattedCalories(n.calories)]
        if let protein = n.protein { parts.append("\(Int(protein.rounded())) g protein") }
        if let carbs = n.carbs { parts.append("\(Int(carbs.rounded())) g carbs") }
        if let fat = n.fat { parts.append("\(Int(fat.rounded())) g fat") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Ingredients (verbatim displayText)

    @ViewBuilder
    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("Ingredients")
            if draft.ingredients.isEmpty {
                Text("No ingredients yet.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(draft.ingredients) { ingredient in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                            Circle()
                                .fill(Color.appAccent.opacity(0.5))
                                .frame(width: 5, height: 5)
                            Text(ingredientText(ingredient))
                                .font(.appBody)
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    /// Reuse `Ingredient.displayText` (clean "<qty> <unit> <name>" when parsed,
    /// verbatim `raw_text` otherwise) and tag optional lines inline.
    private func ingredientText(_ ingredient: Ingredient) -> String {
        ingredient.optional ? "\(ingredient.displayText) (optional)" : ingredient.displayText
    }

    // MARK: Steps

    @ViewBuilder
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("Steps")
            if draft.steps.isEmpty {
                Text("No steps yet.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(draft.steps) { step in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text("\(step.number)")
                                .font(.statNumber.weight(.semibold))
                                .foregroundStyle(Color.appAccent)
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(step.text)
                                .font(.appBody)
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: Sources (found drafts)

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("Source")
            ForEach(sources, id: \.self) { source in
                Text(source)
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.appHeadline)
            .foregroundStyle(Color.appTextPrimary)
    }

    // MARK: Warning banner

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appAccentSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.appCaption)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.appAccentSecondary.opacity(0.15))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Refine field

    private var refineField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("Refine")
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                    TextField("e.g. \u{201C}no bell peppers\u{201D} or \u{201C}make it vegan\u{201D}", text: $refineText, axis: .vertical)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($refineFocused)
                        .submitLabel(.send)
                        .disabled(isWorking)
                        .onSubmit(submitRefine)
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                }
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

                Button(action: submitRefine) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(canRefine ? Color.appAccent : Color.appTextSecondary.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canRefine)
                .accessibilityLabel("Send refinement")
            }
        }
    }

    private var canRefine: Bool {
        !isWorking && !refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitRefine() {
        let text = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRefine, !text.isEmpty else { return }
        refineText = ""
        refineFocused = false
        onRefine(text)
    }

    // MARK: Action row (Save / Discard)

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onSave) {
                HStack(spacing: Theme.Spacing.xs) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(isWorking ? "Saving\u{2026}" : "Save to library")
                        .font(.appHeadline)
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .fill(isWorking ? Color.appAccent.opacity(0.6) : Color.appAccent)
                )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityLabel("Save recipe to library")

            Button(action: onDiscard) {
                Text("Discard")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appDestructive)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .strokeBorder(Color.appDestructive.opacity(0.4), lineWidth: Theme.Stroke.hairline)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityLabel("Discard draft")
        }
    }
}

// MARK: - Previews

#Preview("Draft card — generated") {
    ScrollView {
        DraftRecipeCard(
            draft: RecipeDraft(
                title: "Smoky Black Bean Chili (no onions)",
                description: "A weeknight chili that leans on onion powder and cocoa for depth, skipping fresh onions entirely.",
                servings: 4,
                totalMinutes: 40,
                difficulty: .easy,
                cuisine: "Tex-Mex",
                ingredients: [
                    Ingredient(name: "black beans", quantity: 2, unit: "can", rawText: "2 cans black beans, drained"),
                    Ingredient(name: "onion powder", quantity: 1, unit: "tbsp", rawText: "1 tbsp onion powder"),
                    Ingredient(name: "cocoa powder", quantity: 1, unit: "tbsp", rawText: "1 tbsp unsweetened cocoa powder"),
                    Ingredient(name: "diced tomatoes", optional: false, rawText: "1 large can diced tomatoes"),
                ],
                steps: [
                    Step(number: 1, text: "Toast the spices in oil until fragrant."),
                    Step(number: 2, text: "Add tomatoes, beans, and cocoa; simmer 25 minutes."),
                    Step(number: 3, text: "Season to taste and serve."),
                ],
                tags: ["vegetarian", "high-fiber"],
                nutrition: nil
            ),
            warning: "Web-search find isn't wired yet, so I generated this from your description.",
            sources: [],
            isWorking: false,
            onRefine: { _ in },
            onSave: {},
            onDiscard: {}
        )
        .padding(Theme.Spacing.lg)
    }
    .background(Color.appBackground)
    .preferredColorScheme(.light)
}

#Preview("Draft card — found w/ nutrition") {
    ScrollView {
        DraftRecipeCard(
            draft: RecipeDraft(
                title: "Sheet-Pan Harissa Tofu & Veg",
                servings: 2,
                totalMinutes: 30,
                ingredients: [
                    Ingredient(name: "firm tofu", rawText: "1 block firm tofu, cubed"),
                    Ingredient(name: "harissa", rawText: "2 tbsp harissa paste"),
                ],
                steps: [
                    Step(number: 1, text: "Toss tofu and veg with harissa."),
                    Step(number: 2, text: "Roast at 220C for 25 minutes."),
                ],
                nutrition: Nutrition(source: .stated, calories: 410, protein: 24, carbs: 30, fat: 22)
            ),
            warning: nil,
            sources: ["https://example.com/harissa-tofu"],
            isWorking: false,
            onRefine: { _ in },
            onSave: {},
            onDiscard: {}
        )
        .padding(Theme.Spacing.lg)
    }
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
