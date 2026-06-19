import SwiftUI
import CookbookKit

// MARK: - Activity (ingestion jobs, modal)

/// The ingestion-activity sheet: a modal view over the cook's import jobs, raised
/// from the Assistant. It reuses the shared ``JobsList`` (per-row swipe-to-delete +
/// confirmed "Clear finished") — the single ingestion-jobs renderer, so there is no
/// second copy of the row rendering.
///
/// ### Why a sheet
/// The Assistant tab already hosts its own `NavigationStack`; nesting a second one
/// inside the tab content causes a known navigation conflict. So Activity is
/// presented with `.sheet` (modal) rather than pushed. A finished job's result chip
/// still navigates: `onOpenRecipe` dismisses the sheet and hands the id back to the
/// Assistant's router.
///
/// All reads bind to ``IngestionStore``'s published `jobs` array; the explicit
/// `.task` refreshes it (mirror first, then server) — never reactively. Deletes go
/// through the store (`deleteJob` / `clearFinished`), which mutate the local mirror
/// first and reconcile on failure.
struct ActivityView: View {
    @Environment(CookbookEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Invoked with a recipe id when a finished job's result chip is tapped. Wired
    /// by the host to dismiss the sheet and push the recipe; defaults to a no-op so
    /// the screen previews standalone.
    let onOpenRecipe: (Int) -> Void

    /// Optional seeded jobs for `#Preview`s only (the store's `jobs` is
    /// `private(set)` with no preview seed surfaced through the environment helper).
    private let previewJobs: [IngestJob]?

    init(onOpenRecipe: @escaping (Int) -> Void = { _ in }) {
        self.onOpenRecipe = onOpenRecipe
        self.previewJobs = nil
    }

    init(previewJobs: [IngestJob], onOpenRecipe: @escaping (Int) -> Void = { _ in }) {
        self.onOpenRecipe = onOpenRecipe
        self.previewJobs = previewJobs
    }

    private var store: IngestionStore { environment.ingestionStore }

    private var jobs: [IngestJob] {
        previewJobs ?? store.jobs
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle("Activity")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .tint(Color.appAccent)
                    }
                    if jobs.contains(where: { $0.status.isTerminal }) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(role: .destructive) {
                                showingClearConfirm = true
                            } label: {
                                Text("Clear finished")
                                    .foregroundStyle(Color.appDestructive)
                            }
                            .accessibilityLabel("Clear finished imports")
                        }
                    }
                }
                .confirmationDialog(
                    "Clear finished imports?",
                    isPresented: $showingClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear finished", role: .destructive) {
                        Task { await store.clearFinished() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes completed and failed imports from the list. It does not delete any recipes.")
                }
        }
        .tint(Color.appAccent)
        .task {
            guard previewJobs == nil else { return }
            await store.refresh()
            await store.refreshFromServer()
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    @State private var showingClearConfirm = false

    @ViewBuilder
    private var content: some View {
        if jobs.isEmpty {
            EmptyState(
                systemImage: "tray",
                message: "No imports yet",
                subtitle: "Drop a cookbook PDF or paste a recipe URL in Import to get started."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Spacing.lg)
        } else {
            JobsList(
                jobs: jobs,
                onDeleteJob: { jobId in Task { await store.deleteJob(jobId: jobId) } },
                onOpenRecipe: { recipeId in
                    dismiss()
                    onOpenRecipe(recipeId)
                }
            )
        }
    }
}

// MARK: - Previews

#Preview("Activity — jobs") {
    ActivityView(previewJobs: ActivityPreviewData.all)
        .environment(CookbookEnvironment.preview())
        .preferredColorScheme(.dark)
}

#Preview("Activity — empty") {
    ActivityView(previewJobs: [])
        .environment(CookbookEnvironment.preview())
        .preferredColorScheme(.light)
}

private enum ActivityPreviewData {
    static let running = IngestJob(
        jobId: "act-running",
        kind: .pdf,
        filename: "Whole-Food Weeknights.pdf",
        status: .running,
        stage: "extracting",
        recipesDone: 41,
        recipesTotal: 120,
        recipeIds: [],
        createdAt: Date().addingTimeInterval(-180),
        updatedAt: Date().addingTimeInterval(-5)
    )

    static let done = IngestJob(
        jobId: "act-done",
        kind: .pdf,
        filename: "Plant-Forward Bowls.pdf",
        status: .done,
        stage: "done",
        recipesDone: 8,
        recipesTotal: 8,
        recipeIds: [101, 102, 103, 104, 105, 106, 107, 108],
        createdAt: Date().addingTimeInterval(-600),
        updatedAt: Date().addingTimeInterval(-120)
    )

    static let errored = IngestJob(
        jobId: "act-error",
        kind: .url,
        filename: nil,
        status: .error,
        stage: "extracting",
        recipesDone: 0,
        recipesTotal: 0,
        recipeIds: [],
        error: "Couldn't parse a recipe from that page.",
        createdAt: Date().addingTimeInterval(-400),
        updatedAt: Date().addingTimeInterval(-360)
    )

    static let all: [IngestJob] = [running, done, errored]
}
