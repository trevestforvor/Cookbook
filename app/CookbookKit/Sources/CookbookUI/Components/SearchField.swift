import SwiftUI
import CookbookKit

// MARK: - Search field

/// A rounded surface search field on a hairline `appBorder` outline, with a
/// leading magnifier, the placeholder "Search recipes…", a clear button when
/// non-empty, and a trailing "Ask ▸" affordance that signals escalate-to-assistant.
///
/// Binds to a `String` and exposes `onAsk` (fired by the Ask button) and an
/// optional `onSubmit` (fired on keyboard return). **Debouncing is the caller's
/// job** per the guardrails — this view reports raw edits.
public struct SearchField: View {
    @Binding public var text: String
    public var placeholder: String
    /// When true, the leading magnifier is replaced by a small spinner to signal
    /// an in-flight query (search and/or assistant request).
    public var isBusy: Bool
    public let onAsk: () -> Void
    public let onSubmit: () -> Void

    /// - Parameters:
    ///   - text: the query binding (caller debounces downstream of this).
    ///   - placeholder: prompt text. Defaults to "Search recipes…".
    ///   - isBusy: when true, swaps the leading glyph for a spinner. Defaults to `false`.
    ///   - onSubmit: fired when the user presses return.
    ///   - onAsk: fired when the "Ask ▸" affordance is tapped.
    public init(
        text: Binding<String>,
        placeholder: String = "Search recipes\u{2026}",
        isBusy: Bool = false,
        onSubmit: @escaping () -> Void = {},
        onAsk: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isBusy = isBusy
        self.onSubmit = onSubmit
        self.onAsk = onAsk
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.appAccent)
                    .accessibilityLabel("Searching")
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }

            TextField(placeholder, text: $text)
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            Divider()
                .frame(height: 20)
                .overlay(Color.appBorder)

            Button(action: onAsk) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text("Ask")
                    Image(systemName: "sparkles")
                        .imageScale(.small)
                }
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask the assistant")
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
    }
}

private struct SearchFieldPreviewHost: View {
    @State private var empty = ""
    @State private var typed = "salmon"

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            SearchField(text: $empty, onAsk: {})
            SearchField(text: $typed, onAsk: {})
            SearchField(text: $typed, isBusy: true, onAsk: {})
        }
        .padding(Theme.Spacing.lg)
        .background(Color.appBackground)
    }
}

#Preview("Search field") {
    SearchFieldPreviewHost()
}
