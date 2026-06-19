import Foundation

// MARK: - Meal plans

/// One slot of a generated/stored meal plan. `planner.generate` emits
/// `{day, meal, recipe_id, title, calories}`.
public struct MealPlanEntry: Codable, Sendable, Hashable, Identifiable {
    public var day: Int
    public var meal: Int
    public var recipeId: Int
    public var title: String?
    public var calories: Double?

    public var id: String { "\(day)-\(meal)-\(recipeId)" }

    public init(day: Int, meal: Int, recipeId: Int, title: String? = nil, calories: Double? = nil) {
        self.day = day; self.meal = meal; self.recipeId = recipeId
        self.title = title; self.calories = calories
    }

    private enum CodingKeys: String, CodingKey {
        case day, meal
        case recipeId = "recipe_id"
        case title, calories
    }
}

/// Result of `POST /meal-plan`: `{plan:[...], note?}`.
public struct MealPlanResult: Codable, Sendable, Hashable {
    public var plan: [MealPlanEntry]
    public var note: String?

    public init(plan: [MealPlanEntry] = [], note: String? = nil) {
        self.plan = plan; self.note = note
    }
}

/// A saved meal-plan list row (`list_meal_plans`): `id, name, created_at`.
public struct SavedMealPlanSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var createdAt: Date?

    public init(id: Int, name: String, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
    }
}

/// Full saved meal plan (`get_meal_plan`): `{id, name, plan, created_at}`. The
/// stored `plan_json` blob is decoded back into a typed entry list when it matches
/// the planner shape; the raw JSON is always retained for fidelity.
public struct SavedMealPlan: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var plan: JSONValue
    public var createdAt: Date?

    public var entries: [MealPlanEntry] {
        guard let arr = plan.arrayValue else { return [] }
        let data = (try? CookbookCoding.makeEncoder().encode(arr)) ?? Data()
        return (try? CookbookCoding.makeDecoder().decode([MealPlanEntry].self, from: data)) ?? []
    }

    public init(id: Int, name: String, plan: JSONValue, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.plan = plan; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, plan
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plan = try c.decodeIfPresent(JSONValue.self, forKey: .plan) ?? .array([])
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(plan, forKey: .plan)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
    }
}

// MARK: - Shopping lists

/// A line in a generated/stored shopping list. `build_shopping_list` emits
/// `{name, unit, total_quantity}` (quantity is `nil` when no normalized amount
/// was known for any contributing line).
public struct ShoppingListItem: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var unit: String?
    public var totalQuantity: Double?

    public var id: String { "\(name)|\(unit ?? "")" }

    public init(name: String, unit: String? = nil, totalQuantity: Double? = nil) {
        self.name = name; self.unit = unit; self.totalQuantity = totalQuantity
    }

    private enum CodingKeys: String, CodingKey {
        case name, unit
        case totalQuantity = "total_quantity"
    }
}

/// `POST /shopping-list` result: `{items:[...]}`.
public struct ShoppingListResult: Codable, Sendable, Hashable {
    public var items: [ShoppingListItem]
    public init(items: [ShoppingListItem] = []) { self.items = items }
}

/// A saved shopping-list summary (`list_shopping_lists`): `id, name, created_at`.
public struct SavedShoppingListSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var createdAt: Date?

    public init(id: Int, name: String, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
    }
}

/// Full saved shopping list (`get_shopping_list`): `{id, name, items, created_at}`.
public struct SavedShoppingList: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var items: JSONValue
    public var createdAt: Date?

    /// Decode the stored blob into typed items when it matches the builder shape.
    public var typedItems: [ShoppingListItem] {
        guard let arr = items.arrayValue else { return [] }
        let data = (try? CookbookCoding.makeEncoder().encode(arr)) ?? Data()
        return (try? CookbookCoding.makeDecoder().decode([ShoppingListItem].self, from: data)) ?? []
    }

    public init(id: Int, name: String, items: JSONValue, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.items = items; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, items
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        items = try c.decodeIfPresent(JSONValue.self, forKey: .items) ?? .array([])
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
    }
}

// MARK: - Substitutions

/// One substitution suggestion (`substitutions.find`): `{substitute, ratio, notes}`.
public struct Substitution: Codable, Sendable, Hashable, Identifiable {
    public var substitute: String
    public var ratio: String?
    public var notes: String?

    public var id: String { substitute }

    public init(substitute: String, ratio: String? = nil, notes: String? = nil) {
        self.substitute = substitute; self.ratio = ratio; self.notes = notes
    }
}

/// `POST /substitutions` result: `{substitutions:[...]}`.
public struct SubstitutionsResult: Codable, Sendable, Hashable {
    public var substitutions: [Substitution]
    public init(substitutions: [Substitution] = []) { self.substitutions = substitutions }
}

// MARK: - Ask

/// `POST /ask` result: `{answer}`.
public struct AskResult: Codable, Sendable, Hashable {
    public var answer: String
    public init(answer: String) { self.answer = answer }
}
