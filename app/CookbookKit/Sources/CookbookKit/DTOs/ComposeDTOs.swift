import Foundation

// The conversational recipe-builder contract (`POST /recipes/compose` and
// `POST /recipes/compose/save`). A compose *turn* is one request → one updated
// `RecipeDraft`; the server is stateless, so multi-turn refinement = the client
// resends the running draft + the new instruction each turn. Nothing persists to
// the catalog until the explicit `/compose/save`.

// MARK: - Request

/// `POST /recipes/compose` body — one turn of the builder.
///
/// `draft` is the *current* running draft (nil on the first turn); the server
/// generates or refines it given `instruction` (+ optional `sourceURL`). `modeHint`
/// steers the deterministic generate-vs-find branch and defaults to `"auto"`.
public struct ComposeIn: Codable, Sendable {
    public var instruction: String
    public var draft: RecipeDraft?
    public var sourceURL: String?
    /// `"auto" | "generate" | "find"` — left as a `String` so a new server mode
    /// doesn't require an app release.
    public var modeHint: String

    public init(
        instruction: String,
        draft: RecipeDraft? = nil,
        sourceURL: String? = nil,
        modeHint: String = "auto"
    ) {
        self.instruction = instruction
        self.draft = draft
        self.sourceURL = sourceURL
        self.modeHint = modeHint
    }

    private enum CodingKeys: String, CodingKey {
        case instruction
        case draft
        case sourceURL = "source_url"
        case modeHint = "mode_hint"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instruction, forKey: .instruction)
        try c.encodeIfPresent(draft, forKey: .draft)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encode(modeHint, forKey: .modeHint)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instruction = try c.decode(String.self, forKey: .instruction)
        draft = try c.decodeIfPresent(RecipeDraft.self, forKey: .draft)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        modeHint = try c.decodeIfPresent(String.self, forKey: .modeHint) ?? "auto"
    }
}

/// `POST /recipes/compose/save` body — commits the agreed draft. The endpoint
/// takes a single `{draft: RecipeDraft}` object (no instruction/turn state).
public struct ComposeSaveBody: Codable, Sendable {
    public var draft: RecipeDraft
    public init(draft: RecipeDraft) { self.draft = draft }
}

// MARK: - Responses

/// `POST /recipes/compose` response — the updated draft plus the assistant's reply.
///
/// `action` is `"generated" | "found" | "refined"`; `sources` lists any URLs a
/// *found* recipe was parsed from; `warning` carries non-fatal notes (e.g.
/// web-search find isn't wired yet, so `auto` fell through to generate). All are
/// kept loosely typed (`String`/`[String]`) so the app tolerates new server values.
public struct ComposeResult: Codable, Sendable {
    public var draft: RecipeDraft
    public var message: String
    public var action: String
    public var sources: [String]
    public var warning: String?

    public init(
        draft: RecipeDraft,
        message: String,
        action: String,
        sources: [String] = [],
        warning: String? = nil
    ) {
        self.draft = draft
        self.message = message
        self.action = action
        self.sources = sources
        self.warning = warning
    }

    private enum CodingKeys: String, CodingKey {
        case draft, message, action, sources, warning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draft = try c.decode(RecipeDraft.self, forKey: .draft)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? "refined"
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

/// `POST /recipes/compose/save` response: `{recipe_id, version, recipe_count}`.
/// The agreed draft is now a canonical recipe. `version` / `recipeCount` are the
/// authoritative catalog state after the write so the app can re-sync its mirror;
/// `recipeId` is the new row the app navigates to.
public struct ComposeSaveResult: Codable, Sendable, Hashable {
    public var recipeId: Int
    public var version: Int
    public var recipeCount: Int

    public init(recipeId: Int, version: Int, recipeCount: Int) {
        self.recipeId = recipeId
        self.version = version
        self.recipeCount = recipeCount
    }

    private enum CodingKeys: String, CodingKey {
        case recipeId = "recipe_id"
        case version
        case recipeCount = "recipe_count"
    }
}
