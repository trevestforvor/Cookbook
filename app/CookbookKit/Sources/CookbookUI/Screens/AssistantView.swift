import SwiftUI
import CookbookKit
import Network
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Assistant (unified ask + ADD surface)

/// The Assistant is the app's **unified ask + add** surface. It does two jobs in
/// one chat:
///
/// 1. **Ask** the cookbook (`POST /ask`) — a single-shot agent that answers in
///    prose; replies render as bubbles and recipe references become tappable chips.
/// 2. **Add a recipe** (the IA decision: adding a recipe is OBVIOUS / first-class
///    here). A persistent ＋/attach control offers three add paths — *describe a
///    recipe*, *add from URL*, and *attach PDF* — and the placeholder invites it.
///
/// ### Compose / draft / Save flow (the add path)
/// "Describe a recipe" and "Add from URL" drive `ComposeStore.compose(...)`, which
/// returns an **editable draft**. The draft renders inline as a ``DraftRecipeCard``
/// in the transcript with a **Refine** field (a follow-up instruction with the
/// running draft) and a prominent **Save** button. **Nothing persists until Save** —
/// composing/refining never touches the catalog, search, or the local mirror. On
/// Save (`ComposeStore.save()`) the store force-syncs the catalog; this view then
/// navigates to the new recipe via ``onOpenRecipe`` and shows a brief confirmation.
///
/// ### PDF uses the EXISTING ingest path (not a draft)
/// "Attach PDF" routes to `IngestionStore.ingestPDF(...)` — the same async job the
/// Import screen / Activity sheet already drive — and points the cook at the
/// Activity sheet. We do **not** build a second PDF path or render PDFs as drafts.
///
/// ### Conversation context
/// The Ask agent is single-shot (no server thread), so chat context lives
/// client-side as a `@State` list of ``ChatMessage``s; each ask sends only the
/// latest user message. The compose draft is a separate, single running item owned
/// by `ComposeStore` and shown after the transcript.
///
/// Connectivity is watched best-effort with `NWPathMonitor`: when offline the input
/// is disabled and an inline note appears. Reads bind only to stores (no
/// `@Query`/`@Model`); Theme tokens only.
public struct AssistantView: View {
    @Environment(CookbookEnvironment.self) private var environment

    /// Invoked when the cook taps a detected recipe chip OR after a draft is saved.
    /// Wired by the host app to push the recipe detail; defaults to a no-op so
    /// previews and standalone use compile without a navigator.
    public let onOpenRecipe: (Int) -> Void

    @State private var messages: [ChatMessage]
    @State private var draft: String = ""
    @State private var isThinking = false
    @State private var sendTask: Task<Void, Never>?
    @State private var composeTask: Task<Void, Never>?

    @State private var connectivity = ConnectivityModel()
    @State private var showingActivity = false
    @FocusState private var inputFocused: Bool

    // Add-a-recipe affordances.
    /// Which add-path prompt is currently presented (URL entry); nil = none.
    @State private var addPrompt: AddPrompt?
    @State private var urlText: String = ""
    /// The query entered in the "Find a recipe online" prompt.
    @State private var findText: String = ""
    /// When true, the next composer send routes to `compose(instruction:)` (build a
    /// recipe) instead of `ask`. Set by the ＋ menu's "Describe a recipe"; the
    /// composer visibly switches to a build placeholder + send glyph so the intent
    /// is never ambiguous. Cleared after the turn (or when the field is emptied).
    @State private var composeMode = false
    #if os(iOS)
    @State private var showingPDFImporter = false
    #endif
    /// A brief, auto-dismissing confirmation after a successful save / PDF attach.
    @State private var confirmation: String?

    /// The add-path prompts the ＋ control can raise.
    private enum AddPrompt: Identifiable {
        case url
        case find
        var id: Int {
            switch self {
            case .url: return 0
            case .find: return 1
            }
        }
    }

    /// - Parameters:
    ///   - initialMessages: a seed transcript (used by previews; empty in production).
    ///   - onOpenRecipe: tapped-chip handler; defaults to a no-op.
    public init(
        initialMessages: [ChatMessage] = [],
        onOpenRecipe: @escaping (Int) -> Void = { _ in }
    ) {
        self._messages = State(initialValue: initialMessages)
        self.onOpenRecipe = onOpenRecipe
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider().overlay(Color.appBorder)
                if connectivity.isOffline {
                    offlineNote
                }
                inputBar
            }
            .background(Color.appBackground)
            .navigationTitle("Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    activityButton
                }
            }
        }
        // Modal (not pushed): the Assistant tab already owns a `NavigationStack`, so
        // a nested one for Activity would conflict. The sheet hands recipe taps back
        // through `onOpenRecipe` after dismissing itself.
        .sheet(isPresented: $showingActivity) {
            ActivityView(onOpenRecipe: onOpenRecipe)
        }
        // "Add from URL": a lightweight URL-entry prompt that kicks a compose turn.
        .alert("Add from URL", isPresented: urlPromptBinding) {
            TextField("https://\u{2026}", text: $urlText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                #endif
            Button("Cancel", role: .cancel) { addPrompt = nil; urlText = "" }
            Button("Import") { submitURL() }
        } message: {
            Text("Paste a recipe link. I'll fetch and parse it into an editable draft \u{2014} nothing is saved until you tap Save.")
        }
        // "Find a recipe online": describe what you want; I search the web, parse the
        // best match into an editable draft (nothing saved until Save).
        .alert("Find a recipe online", isPresented: findPromptBinding) {
            TextField("e.g. high-protein turkey chili", text: $findText)
            Button("Cancel", role: .cancel) { addPrompt = nil; findText = "" }
            Button("Find") { submitFind() }
        } message: {
            Text("Describe the recipe. I'll search the web and parse the best match into an editable draft \u{2014} nothing is saved until you tap Save.")
        }
        #if os(iOS)
        // "Attach PDF": route to the EXISTING async ingest path, then point the cook
        // at the Activity sheet (we do NOT build a draft from a PDF).
        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handlePDFImport(result)
        }
        #endif
        .task {
            // Best-effort connectivity watch for the lifetime of the screen.
            await connectivity.start()
        }
        .onDisappear {
            sendTask?.cancel()
            composeTask?.cancel()
            connectivity.stop()
        }
    }

    // MARK: Activity entry

    /// Count of imports still working — surfaced as a badge on the Activity button.
    private var importingCount: Int {
        environment.ingestionStore.jobs.filter {
            $0.status == .queued || $0.status == .running
        }.count
    }

    private var activityButton: some View {
        Button {
            showingActivity = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full")
                if importingCount > 0 {
                    Text("\(importingCount)")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Color.appAccent))
                        .offset(x: 10, y: -8)
                        .accessibilityHidden(true)
                }
            }
        }
        .tint(Color.appAccent)
        .accessibilityLabel(
            importingCount > 0
                ? "Activity, \(importingCount) importing"
                : "Activity"
        )
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if showsEmptyState {
                        emptyState
                            .padding(.top, Theme.Spacing.xxl)
                    }

                    ForEach(messages) { message in
                        MessageRow(message: message, onOpenRecipe: onOpenRecipe)
                            .id(message.id)
                    }

                    if isThinking {
                        ThinkingRow()
                            .id(Self.thinkingAnchorID)
                    }

                    if composeStore.isWorking && composeStore.draft == nil {
                        // First compose turn (no draft yet) — show the working row so
                        // the slow LLM call isn't silent.
                        ThinkingRow()
                            .id(Self.draftAnchorID)
                    }

                    // Surface a compose/save failure inline. Covers both a failed
                    // first turn (no draft) and a failed refine/save (draft intact).
                    if let error = composeStore.lastError {
                        composeErrorBanner(error)
                            .transition(.opacity)
                    }

                    // The evolving recipe draft lives INLINE in the transcript (no new
                    // NavigationStack — the Assistant has a known nested-nav conflict).
                    if let draft = composeStore.draft {
                        DraftRecipeCard(
                            draft: draft,
                            warning: composeStore.lastWarning,
                            sources: composeStore.lastSources,
                            isWorking: composeStore.isWorking,
                            onRefine: refineDraft,
                            onSave: saveDraft,
                            onDiscard: discardDraft
                        )
                        .id(Self.draftAnchorID)
                        .transition(.opacity)
                    }

                    if let confirmation {
                        confirmationBanner(confirmation)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isThinking) { _, _ in scrollToEnd(proxy) }
            .onChange(of: composeStore.draft) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// The compose store, read straight from the environment (binds to its
    /// `@Observable` published state — no `@Query`/`@Model`).
    private var composeStore: ComposeStore { environment.composeStore }

    /// The teaching empty state shows only on a truly idle screen — no transcript,
    /// no draft, nothing in flight, no compose error to surface.
    private var showsEmptyState: Bool {
        messages.isEmpty
            && composeStore.draft == nil
            && !isThinking
            && !composeStore.isWorking
            && composeStore.lastError == nil
    }

    private func confirmationBanner(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            Text(text)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.appAccent.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }

    /// A destructive-styled banner for a failed compose/save turn. The store leaves
    /// any existing draft intact on failure, so the cook can simply retry.
    private func composeErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appDestructive)
                .accessibilityHidden(true)
            Text("Couldn't build that just now. \(message)")
                .font(.appCaption)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.appDestructive.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            EmptyState(
                systemImage: "sparkles",
                message: "Ask \u{2014} or add a recipe",
                subtitle: "Ask: \u{201C}High-protein dinners under 30 minutes?\u{201D} \u{00B7} \u{201C}What can I make with chickpeas and spinach?\u{201D}"
            )

            // Teach the three add paths alongside the ask examples.
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Add a recipe")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                addPathHint(
                    icon: "pencil.and.outline",
                    title: "Describe it",
                    detail: "\u{201C}A chili with no onions \u{2014} onion powder ok \u{2014} and cocoa powder.\u{201D}"
                )
                addPathHint(
                    icon: "link",
                    title: "Add from URL",
                    detail: "Paste a recipe link to fetch and parse it into a draft."
                )
                addPathHint(
                    icon: "doc.fill",
                    title: "Attach a PDF",
                    detail: "Send a cookbook PDF to the importer; watch it in Activity."
                )
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
            .padding(.horizontal, Theme.Spacing.sm)
        }
    }

    private func addPathHint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text(detail)
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Offline note

    private var offlineNote: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Color.appDestructive)
                .accessibilityHidden(true)
            Text("You're offline — reconnect to ask the assistant.")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appDestructive.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            addMenu

            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                TextField(composerPlaceholder, text: $draft, axis: .vertical)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .disabled(!canType)
                    .onSubmit(send)
                    .onChange(of: draft) { _, newValue in
                        // Drop out of build mode if the cook clears the field.
                        if newValue.isEmpty { composeMode = false }
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                    #endif
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        composeMode ? Color.appAccent.opacity(0.6) : Color.appBorder,
                        lineWidth: composeMode ? 1.5 : Theme.Stroke.hairline
                    )
            )

            Button(action: send) {
                Image(systemName: composeMode ? "wand.and.stars" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(canSend ? Color.appAccent : Color.appTextSecondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(composeMode ? "Build recipe draft" : "Send message")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Color.appBackground)
    }

    /// The first-class ＋/attach control. Adding a recipe is OBVIOUS here: a single
    /// menu surfaces all three add paths (describe / URL / PDF).
    private var addMenu: some View {
        Menu {
            Button {
                // "Describe a recipe": switch the composer into build mode and focus
                // it. The next send routes to `compose(instruction:)`, not `ask`.
                composeMode = true
                inputFocused = true
            } label: {
                Label("Describe a recipe", systemImage: "pencil.and.outline")
            }
            Button {
                findText = ""
                addPrompt = .find
            } label: {
                Label("Find a recipe online", systemImage: "globe")
            }
            Button {
                urlText = ""
                addPrompt = .url
            } label: {
                Label("Add from URL", systemImage: "link")
            }
            Button {
                attachPDF()
            } label: {
                Label("Attach PDF", systemImage: "doc.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Color.appAccent.opacity(0.12))
                )
        }
        .disabled(!canType || composeStore.isWorking)
        .accessibilityLabel("Add a recipe")
    }

    // MARK: Derived state

    /// Whether the cook may type at all (online; sending is still gated separately).
    private var canType: Bool { !connectivity.isOffline }

    /// Whether the send button is live: online, not mid-flight, non-empty draft.
    private var canSend: Bool {
        canType
            && !isThinking
            && !composeStore.isWorking
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer placeholder — switches to a build prompt while in compose mode.
    private var composerPlaceholder: String {
        composeMode
            ? "Describe the recipe to build\u{2026}"
            : "Ask, paste a link, or describe a recipe to add"
    }

    /// `Binding<Bool>` driving the "Add from URL" alert from the `addPrompt` enum.
    private var urlPromptBinding: Binding<Bool> {
        Binding(
            get: { addPrompt == .url },
            set: { if !$0 { addPrompt = nil } }
        )
    }

    /// `Binding<Bool>` driving the "Find a recipe online" alert.
    private var findPromptBinding: Binding<Bool> {
        Binding(
            get: { addPrompt == .find },
            set: { if !$0 { addPrompt = nil } }
        )
    }

    // MARK: Actions — ask / compose routing

    /// The composer's primary send. In **build mode** it starts a compose turn
    /// (`compose(instruction:)`); otherwise it asks the agent (`/ask`). Refinement of
    /// an existing draft happens on the ``DraftRecipeCard`` itself, not here.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }

        if composeMode {
            composeMode = false
            draft = ""
            composeNewDraft(instruction: text)
            return
        }

        messages.append(ChatMessage(role: .user, text: text))
        draft = ""
        isThinking = true

        let store = environment.recipeStore
        sendTask?.cancel()
        sendTask = Task {
            // The promoted `RecipeStore.ask` is non-throwing (returns nil on
            // failure, recording `lastError`) and re-hydrates `/state` afterward so
            // any server-side mutations the agent makes (favorites, pantry, …) show
            // up in the library.
            let answer = await store.ask(message: text)
            guard !Task.isCancelled else { return }
            if let answer {
                appendAssistant(ChatMessage(role: .assistant, text: answer))
            } else {
                let reason = store.lastError ?? "Something went wrong."
                appendAssistant(ChatMessage(
                    role: .assistant,
                    text: "Sorry — I couldn't reach the kitchen just now.\n\n\(reason)",
                    isError: true
                ))
            }
        }
    }

    @MainActor
    private func appendAssistant(_ message: ChatMessage) {
        isThinking = false
        messages.append(message)
    }

    // MARK: Actions — compose (build a recipe)

    /// Start a NEW draft from a free-text build instruction (the chili example). The
    /// store keeps the running draft; the ``DraftRecipeCard`` renders it inline.
    private func composeNewDraft(instruction: String, sourceURL: String? = nil,
                                 modeHint: String = "auto") {
        clearConfirmation()
        composeTask?.cancel()
        composeTask = Task {
            await composeStore.compose(instruction: instruction, sourceURL: sourceURL,
                                       modeHint: modeHint)
        }
    }

    /// Submit the "Find a recipe online" query → a `mode_hint: "find"` compose turn.
    /// The server web-searches, parses the best match into a draft (no persist), and
    /// falls back to generate (with a warning) if nothing usable is found.
    private func submitFind() {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        addPrompt = nil
        findText = ""
        guard !query.isEmpty else { return }
        composeNewDraft(instruction: query, modeHint: "find")
    }

    /// Refine the current draft via a follow-up instruction (the card's Refine
    /// field). The store resends the running draft + this instruction.
    private func refineDraft(_ instruction: String) {
        clearConfirmation()
        composeTask?.cancel()
        composeTask = Task {
            await composeStore.compose(instruction: instruction)
        }
    }

    /// Commit the draft. On success the store force-syncs the catalog; we navigate to
    /// the new recipe and show a brief confirmation. The draft is cleared by the
    /// store on success (the conversation is done).
    private func saveDraft() {
        composeTask?.cancel()
        composeTask = Task {
            let recipeId = await composeStore.save()
            guard !Task.isCancelled else { return }
            if let recipeId {
                showConfirmation("Saved to your library.")
                onOpenRecipe(recipeId)
            }
            // On failure the store leaves the draft intact and records `lastError`,
            // which the card surfaces via the next turn's warning/standard error UI.
        }
    }

    /// Throw away the running draft (nothing was persisted).
    private func discardDraft() {
        composeStore.reset()
        clearConfirmation()
    }

    // MARK: Actions — add from URL

    private func submitURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        addPrompt = nil
        urlText = ""
        // Only http(s) links are importable; surface feedback rather than silently
        // dropping a bad entry (file:/ftp:/bare hostnames).
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            appendAssistant(ChatMessage(
                role: .assistant,
                text: "That doesn't look like a web URL — paste a full recipe link starting with http:// or https://.",
                isError: true))
            return
        }
        // Compose contract: a source URL is a "find by URL" turn (parse-only, no
        // persist) — the instruction primes the agent toward import.
        composeNewDraft(instruction: "import this recipe", sourceURL: trimmed)
    }

    // MARK: Actions — attach PDF (EXISTING ingest path)

    /// Attach a cookbook PDF. This routes to the existing async ingestion job (NOT a
    /// draft) and points the cook at the Activity sheet to watch progress.
    private func attachPDF() {
        #if os(iOS)
        showingPDFImporter = true
        #elseif os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Import"
        panel.message = "Choose a cookbook PDF to ingest"
        if panel.runModal() == .OK, let url = panel.url {
            startPDFIngest(fileURL: url)
        }
        #endif
    }

    #if os(iOS)
    private func handlePDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            startPDFIngest(fileURL: url, securityScoped: true)
        case .failure:
            break
        }
    }
    #endif

    /// Hand a PDF to the EXISTING `IngestionStore.ingestPDF(...)` path and surface
    /// the Activity affordance. Reads bytes under a security-scoped grant when the
    /// file came from the document picker (outside the app sandbox).
    private func startPDFIngest(fileURL: URL, securityScoped: Bool = false) {
        Task {
            if securityScoped {
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: fileURL) {
                    await environment.ingestionStore.ingestPDF(
                        data: data, filename: fileURL.lastPathComponent)
                } else {
                    await environment.ingestionStore.ingestPDF(fileURL: fileURL)
                }
            } else {
                await environment.ingestionStore.ingestPDF(fileURL: fileURL)
            }
            showConfirmation("Importing your PDF \u{2014} track it in Activity.")
        }
    }

    // MARK: Confirmation (brief, auto-dismissing)

    private func showConfirmation(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { confirmation = text }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    if confirmation == text { confirmation = nil }
                }
            }
        }
    }

    private func clearConfirmation() {
        if confirmation != nil { confirmation = nil }
    }

    // MARK: Scroll

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let anchor: AnyHashable
        if composeStore.draft != nil {
            anchor = Self.draftAnchorID
        } else if isThinking {
            anchor = Self.thinkingAnchorID
        } else {
            anchor = messages.last?.id ?? Self.thinkingAnchorID
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private static let thinkingAnchorID: AnyHashable = "assistant.thinking.anchor"
    private static let draftAnchorID: AnyHashable = "assistant.draft.anchor"
}

// MARK: - Message model

/// One turn in the client-side transcript. Value type so it lives happily in
/// `@State` and is `Sendable` across the `ask` boundary.
public struct ChatMessage: Identifiable, Sendable, Hashable {
    public enum Role: Sendable, Hashable { case user, assistant }

    public let id: UUID
    public let role: Role
    public let text: String
    /// `true` when this assistant turn represents a failed request (styled as an
    /// error so it's visually distinct from a normal reply).
    public let isError: Bool

    public init(id: UUID = UUID(), role: Role, text: String, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isError = isError
    }

    /// Recipe ids trivially referenced in the text (`recipe #123`, `recipe 123`,
    /// `(id: 123)`, bare `#123`), de-duplicated in first-seen order. Only meaningful
    /// for assistant turns; user turns return `[]`.
    public var referencedRecipeIDs: [Int] {
        guard role == .assistant else { return [] }
        return RecipeReferenceScanner.ids(in: text)
    }
}

// MARK: - Reference scanning

/// Trivial, dependency-free scanner that lifts recipe ids out of an answer string.
/// Deliberately conservative: it only fires on explicit `recipe`/`#`/`id:` cues so
/// stray numbers in prose ("bake for 25 minutes") don't become bogus chips.
enum RecipeReferenceScanner {
    /// Matches `recipe #123`, `recipe 123`, `recipe id 123`, `(id: 123)`, `id: 123`,
    /// and a standalone `#123`. The id is always capture group 1.
    private static let pattern =
        #"(?:recipe(?:\s+id)?\s+#?|\(?\s*id:?\s*|#)(\d{1,7})"#

    private static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive])

    static func ids(in text: String) -> [Int] {
        guard let regex, !text.isEmpty else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<Int>()
        var ordered: [Int] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let r = match.range(at: 1)
            guard r.location != NSNotFound else { return }
            if let id = Int(ns.substring(with: r)), id > 0, seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }
}

// MARK: - Rows

/// A single transcript bubble — user (trailing, accent) or assistant (leading,
/// surface), with optional recipe-reference chips beneath an assistant turn.
private struct MessageRow: View {
    let message: ChatMessage
    let onOpenRecipe: (Int) -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.Spacing.xs) {
            bubble
            if !isUser {
                let ids = message.referencedRecipeIDs
                if !ids.isEmpty {
                    referenceChips(ids)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubble: some View {
        Text(message.text)
            .font(.appBody)
            .foregroundStyle(bubbleTextColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
            .accessibilityLabel(isUser ? "You said" : "Assistant said")
            .accessibilityValue(message.text)
    }

    private var bubbleTextColor: Color {
        if isUser { return .white }
        return message.isError ? Color.appDestructive : Color.appTextPrimary
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        if isUser {
            shape.fill(Color.appAccent)
        } else if message.isError {
            shape.fill(Color.appDestructive.opacity(0.10))
        } else {
            shape.fill(Color.appSurface)
        }
    }

    @ViewBuilder
    private var bubbleBorder: some View {
        if !isUser {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    message.isError ? Color.appDestructive.opacity(0.35) : Color.appBorder,
                    lineWidth: Theme.Stroke.hairline
                )
        }
    }

    private func referenceChips(_ ids: [Int]) -> some View {
        // Wrapping row of tappable recipe chips.
        FlowLayout(spacing: Theme.Spacing.xs) {
            ForEach(ids, id: \.self) { id in
                Button {
                    onOpenRecipe(id)
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "fork.knife")
                            .imageScale(.small)
                        Text("Recipe #\(id)")
                    }
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(
                        Capsule(style: .continuous).fill(Color.appAccent.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open recipe \(id)")
            }
        }
    }
}

/// The animated "working…" status row shown while a reply is in flight.
private struct ThinkingRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appAccent)
            Text("Working\u{2026}")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
                .opacity(pulse ? 0.5 : 1.0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel("Assistant is working")
    }
}

// MARK: - Minimal wrapping layout

/// A tiny flow layout that wraps its subviews onto new lines when they overflow
/// the available width. Used for the recipe-reference chip row so an arbitrary
/// number of chips wraps cleanly without depending on any external component.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]          // width used per row
        var rowHeights: [CGFloat] = [0]
        var x: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                rows.append(0); rowHeights.append(0)
                x = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            rows[rows.count - 1] = x
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
        }

        let totalHeight = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        let totalWidth = rows.max() ?? 0
        let resolvedWidth = proposal.width ?? totalWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Connectivity (best-effort)

/// Best-effort connectivity watcher backed by `NWPathMonitor`. `@Observable` and
/// `@MainActor` so the view can read `isOffline` directly. Starts pessimistic-free
/// (assumes online) so a slow first path callback never blocks the cook from
/// typing; flips to offline only on an explicit unsatisfied path.
@MainActor
@Observable
final class ConnectivityModel {
    private(set) var isOffline = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(label: "cookbook.assistant.connectivity")

    func start() async {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

// MARK: - Previews

private enum AssistantPreviewData {
    static let transcript: [ChatMessage] = [
        ChatMessage(role: .user, text: "What can I make tonight with chickpeas and spinach?"),
        ChatMessage(
            role: .assistant,
            text: "A few solid options from your catalog: the Rainbow Chickpea Salad Jar (recipe #3) is quick and no-cook, and the Sheet-Pan Harissa Tofu & Veg (recipe 5) leans on the same pantry. If you want more protein, try the Spicy Peanut Chicken Power Bowl (id: 2)."
        ),
        ChatMessage(role: .user, text: "Which is fastest?"),
        ChatMessage(
            role: .assistant,
            text: "The Rainbow Chickpea Salad Jar at about 15 minutes — just assemble and chill. Open #3 for the full method."
        ),
    ]
}

#Preview("Assistant — Light") {
    AssistantView(initialMessages: AssistantPreviewData.transcript)
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog
        ))
        .preferredColorScheme(.light)
}

#Preview("Assistant — Dark") {
    AssistantView(initialMessages: AssistantPreviewData.transcript)
        .environment(CookbookEnvironment.preview(
            recipes: HomePreviewData.catalog
        ))
        .preferredColorScheme(.dark)
}

#Preview("Assistant — Empty") {
    AssistantView()
        .environment(CookbookEnvironment.preview())
        .preferredColorScheme(.light)
}

#Preview("Assistant — Draft inline") {
    AssistantView(initialMessages: [
        ChatMessage(role: .user, text: "Build me a chili with no onions but onion powder is ok, and cocoa powder."),
    ])
    .environment(CookbookEnvironment.preview(
        composeDraft: RecipeDraft(
            title: "Smoky Black Bean Chili (no onions)",
            description: "Onion powder + cocoa stand in for fresh onions.",
            servings: 4,
            totalMinutes: 40,
            difficulty: .easy,
            ingredients: [
                Ingredient(name: "black beans", quantity: 2, unit: "can", rawText: "2 cans black beans, drained"),
                Ingredient(name: "onion powder", quantity: 1, unit: "tbsp", rawText: "1 tbsp onion powder"),
                Ingredient(name: "cocoa powder", quantity: 1, unit: "tbsp", rawText: "1 tbsp unsweetened cocoa powder"),
            ],
            steps: [
                Step(number: 1, text: "Toast the spices in oil until fragrant."),
                Step(number: 2, text: "Add tomatoes, beans, and cocoa; simmer 25 minutes."),
            ],
            tags: ["vegetarian"],
            nutrition: nil
        ),
        composeMessage: "Here's a draft. Want any changes?"
    ))
    .preferredColorScheme(.light)
}
