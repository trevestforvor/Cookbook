import SwiftUI
import CookbookKit
import Network

// MARK: - Assistant (conversational)

/// The conversational assistant screen over `POST /ask`.
///
/// A scrolling transcript of user + assistant bubbles, a bottom input bar with a
/// send button, and a "working…" status row while a reply is in flight. The
/// backend agent is **single-shot** (`APIClient.ask(message:)` returns one
/// `AskResult.answer` string with no server-side thread), so conversation context
/// is maintained **client-side** as a simple local `@State` list of ``ChatMessage``s.
///
/// Each request sends only the latest user message; the transcript exists purely
/// so the cook can read the back-and-forth. (When the backend grows a real thread
/// API, the only change here is what gets passed to `ask`.)
///
/// Assistant replies are scanned for trivially-detectable recipe references
/// (`recipe #123`, `recipe 123`, `(id: 123)`, a bare `#123`). Any matches render
/// as tappable chips beneath the bubble and call ``onOpenRecipe``; the prose is
/// always shown verbatim regardless. Connectivity is watched best-effort with
/// `NWPathMonitor`: when offline the input is disabled and an inline note appears.
///
/// All reads go through `environment.client` directly inside a `.task`/`Task`
/// (no store mutation), per the data-layer guardrails. Theme tokens only.
public struct AssistantView: View {
    @Environment(CookbookEnvironment.self) private var environment

    /// Invoked when the cook taps a detected recipe chip. Wired by the host app to
    /// push the recipe detail; defaults to a no-op so previews and standalone use
    /// compile without a navigator.
    public let onOpenRecipe: (Int) -> Void

    @State private var messages: [ChatMessage]
    @State private var draft: String = ""
    @State private var isThinking = false
    @State private var sendTask: Task<Void, Never>?

    @State private var connectivity = ConnectivityModel()
    @FocusState private var inputFocused: Bool

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
        }
        .task {
            // Best-effort connectivity watch for the lifetime of the screen.
            await connectivity.start()
        }
        .onDisappear {
            sendTask?.cancel()
            connectivity.stop()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if messages.isEmpty && !isThinking {
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
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isThinking) { _, _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        EmptyState(
            systemImage: "sparkles",
            message: "Ask the cookbook anything",
            subtitle: "\u{201C}High-protein dinners under 30 minutes?\u{201D} \u{00B7} \u{201C}What can I make with chickpeas and spinach?\u{201D}"
        )
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
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                TextField("Message the assistant\u{2026}", text: $draft, axis: .vertical)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .disabled(!canType)
                    .onSubmit(send)
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
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(canSend ? Color.appAccent : Color.appTextSecondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Color.appBackground)
    }

    // MARK: Derived state

    /// Whether the cook may type at all (online; sending is still gated separately).
    private var canType: Bool { !connectivity.isOffline }

    /// Whether the send button is live: online, not mid-flight, non-empty draft.
    private var canSend: Bool {
        canType
            && !isThinking
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }

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

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let anchor: AnyHashable = isThinking
            ? Self.thinkingAnchorID
            : (messages.last?.id ?? Self.thinkingAnchorID)
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private static let thinkingAnchorID: AnyHashable = "assistant.thinking.anchor"
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
