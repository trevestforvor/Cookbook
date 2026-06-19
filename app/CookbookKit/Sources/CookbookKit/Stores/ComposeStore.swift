import Foundation

/// Drives the conversational recipe builder (`POST /recipes/compose` +
/// `/compose/save`). Holds the **running draft** and the assistant's last reply
/// across turns; the server is stateless, so each `compose(...)` turn resends the
/// current draft + the new instruction. The draft is purely transient client state
/// — it never touches the local mirror or the catalog until `save()` commits it.
///
/// Mirrors the other stores' shape (`@MainActor @Observable`, `private(set)` flags,
/// errors funneled to `lastError`, network through the `APIClient` actor). It needs
/// no `LocalMirror`: drafts aren't mirrored. On a successful save it triggers a
/// forced catalog re-sync via `SyncService` so the new recipe lands in the mirror.
@MainActor
@Observable
public final class ComposeStore {
    private let client: APIClient
    private let sync: SyncService

    /// The current running draft (nil before the first turn / after a save or reset).
    public private(set) var draft: RecipeDraft?
    /// The assistant's most recent reply text (the `message` from `ComposeResult`).
    public private(set) var lastMessage: String?
    /// A non-fatal note from the last turn (e.g. web-search find isn't wired yet).
    public private(set) var lastWarning: String?
    /// The `action` of the last turn: `"generated" | "found" | "refined"`.
    public private(set) var lastAction: String?
    /// Sources a *found* draft was parsed from (URLs); empty for generated/refined.
    public private(set) var lastSources: [String] = []
    /// True while a compose turn or save is in flight.
    public private(set) var isWorking = false
    public private(set) var lastError: String?

    public init(client: APIClient, sync: SyncService) {
        self.client = client
        self.sync = sync
    }

    /// One builder turn (`POST /recipes/compose`). Sends the CURRENT running draft
    /// (nil on the first turn) + `instruction` (+ optional `sourceURL`) and adopts
    /// the updated draft / message / warning. Records `lastError` on failure and
    /// leaves the existing draft intact so the user can retry.
    public func compose(instruction: String, sourceURL: String? = nil) async {
        isWorking = true
        defer { isWorking = false }
        let input = ComposeIn(instruction: instruction, draft: draft, sourceURL: sourceURL)
        do {
            let result = try await client.compose(input)
            draft = result.draft
            lastMessage = result.message
            lastAction = result.action
            lastSources = result.sources
            lastWarning = result.warning
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Commit the agreed draft (`POST /recipes/compose/save`). On success returns the
    /// new `recipeId`, forces a catalog re-sync so the recipe lands in the mirror,
    /// and clears the running draft (the conversation is done). Returns `nil` and
    /// records `lastError` on failure, leaving the draft intact so the user can retry.
    @discardableResult
    public func save() async -> Int? {
        guard let current = draft else {
            lastError = "There's no draft to save yet."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await client.composeSave(draft: current)
            // The save bumped the catalog version server-side; pull the new recipe
            // into the mirror so navigation/browse see it immediately.
            await sync.syncCatalog(force: true)
            reset()
            lastError = nil
            return result.recipeId
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    /// Clear the running draft (and its turn metadata) to start a new recipe.
    public func reset() {
        draft = nil
        lastMessage = nil
        lastWarning = nil
        lastAction = nil
        lastSources = []
    }

    // MARK: - Preview / testing seed (additive; NOT for production paths)

    /// Seed a running draft directly, bypassing the network. **Preview/testing only.**
    public func seedForPreview(
        draft: RecipeDraft? = nil,
        lastMessage: String? = nil,
        lastWarning: String? = nil,
        lastAction: String? = nil,
        lastSources: [String] = []
    ) {
        self.draft = draft
        self.lastMessage = lastMessage
        self.lastWarning = lastWarning
        self.lastAction = lastAction
        self.lastSources = lastSources
        self.isWorking = false
        self.lastError = nil
    }
}
