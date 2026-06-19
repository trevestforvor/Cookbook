import SwiftUI
import CookbookKit

// MARK: - Assistant answer card

/// An inline surface card that surfaces a single-shot assistant reply directly
/// below a ``SearchField``. It renders one of three states — a pulsing "Thinking…"
/// working row (matching the Assistant screen's `ThinkingRow`), an error line, or
/// the answer text — and offers a trailing dismiss affordance.
///
/// It owns no networking: the host drives `isAsking` / `answer` / `error` from its
/// own `@State` (populated via `RecipeStore.ask(message:)`) and supplies `onDismiss`
/// to clear them and cancel any in-flight task.
public struct AssistantAnswerCard: View {
    public let isAsking: Bool
    public let answer: String?
    public let error: String?
    public let onDismiss: () -> Void

    @State private var pulse = false

    public init(
        isAsking: Bool,
        answer: String?,
        error: String?,
        onDismiss: @escaping () -> Void
    ) {
        self.isAsking = isAsking
        self.answer = answer
        self.error = error
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            body(for: state)
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
        .shadow(
            color: Theme.Shadow.cardColor,
            radius: Theme.Shadow.cardRadius,
            x: 0,
            y: Theme.Shadow.cardYOffset
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "sparkles")
                .imageScale(.small)
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            Text("Assistant")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)

            Spacer(minLength: Theme.Spacing.sm)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss assistant answer")
        }
    }

    // MARK: Body states

    private enum CardState {
        case thinking
        case error(String)
        case answer(String)
    }

    private var state: CardState {
        if isAsking { return .thinking }
        if let error { return .error(error) }
        return .answer(answer ?? "")
    }

    @ViewBuilder
    private func body(for state: CardState) -> some View {
        switch state {
        case .thinking:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.appAccent)
                Text("Thinking\u{2026}")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .opacity(pulse ? 0.5 : 1.0)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityLabel("Assistant is thinking")

        case .error(let message):
            Text(message)
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .answer(let text):
            Text(text)
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Previews

private struct AssistantAnswerCardPreviewHost: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            AssistantAnswerCard(isAsking: true, answer: nil, error: nil, onDismiss: {})
            AssistantAnswerCard(
                isAsking: false,
                answer: "For a high-protein dinner under 30 minutes, try the seared salmon with white beans — about 38 g protein per serving.",
                error: nil,
                onDismiss: {}
            )
            AssistantAnswerCard(
                isAsking: false,
                answer: nil,
                error: "The assistant couldn't respond. Check your connection and try again.",
                onDismiss: {}
            )
        }
        .padding(Theme.Spacing.lg)
        .background(Color.appBackground)
    }
}

#Preview("Assistant answer card") {
    AssistantAnswerCardPreviewHost()
}
