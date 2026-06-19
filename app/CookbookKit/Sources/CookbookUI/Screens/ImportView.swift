import SwiftUI
import CookbookKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

// MARK: - Import (cookbook ingestion surface)

/// The cookbook ingestion surface. Drag-and-drop a cookbook PDF (Mac / iPad),
/// import a single recipe from a URL (all platforms), and watch async ingestion
/// jobs progress through their stages.
///
/// ### Primary platform
/// This screen is built **Mac / iPad first** — that's where the user actually
/// ingests cookbooks. The prominent drop zone + file picker only render on
/// regular-width surfaces; on a compact iPhone the drop affordance is hidden and
/// replaced by a slim note, keeping the phone minimal. The URL field and the jobs
/// list are present everywhere.
///
/// ### Data flow (guardrail-compliant)
/// - Reads bind only to ``IngestionStore``'s published Sendable DTO array
///   (`jobs`) and its `uploadProgress` / `isStarting` / `lastError` — never
///   `@Query` / `@Model`.
/// - Writes go through the store's real API: `ingestPDF(fileURL:)` /
///   `ingestPDF(data:filename:)` for a chosen / dropped PDF, and `ingestURL(_:)`
///   for the URL field. The store polls each job and re-syncs the catalog on
///   completion; this screen just renders what the store publishes.
/// - The initial job list is loaded explicitly via `.task` (`refresh()` from the
///   local mirror, then `refreshFromServer()` to pick up jobs started elsewhere),
///   never reactively.
///
/// ### Stages
/// `IngestStatus` is the coarse lifecycle (queued / running / done / error). The
/// server reports a finer free-form `stage` string while `running`
/// (`loading` → `extracting` → `normalizing` → `embedding`). ``IngestStage``
/// maps those onto an ordered, labeled timeline so the JobDetail can show checks
/// for completed stages and a progress bar for the active one.
public struct ImportView: View {
    @Environment(CookbookEnvironment.self) private var environment
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Invoked with a recipe id when a result chip on a finished job is tapped.
    /// Wired by the host stack to push ``RecipeDetailView``; defaults to a no-op
    /// so the screen previews standalone.
    private let onOpenRecipe: (Int) -> Void

    /// Optional seeded jobs for `#Preview`s only. When non-nil the jobs list
    /// renders these instead of the store's published array, so previews can show
    /// queued / in-progress / done states without a live backend (the store's
    /// `jobs` is `private(set)` and has no preview seed). Always nil in production.
    private let previewJobs: [IngestJob]?

    @State private var urlText = ""
    @State private var isTargetedForDrop = false
    #if os(iOS)
    @State private var showingFileImporter = false
    #endif

    /// - Parameter onOpenRecipe: receives a finished recipe's id for the host to
    ///   navigate to. Defaults to a no-op so previews render standalone.
    public init(onOpenRecipe: @escaping (Int) -> Void = { _ in }) {
        self.onOpenRecipe = onOpenRecipe
        self.previewJobs = nil
    }

    /// Preview / testing initializer that seeds the jobs list directly.
    init(previewJobs: [IngestJob], onOpenRecipe: @escaping (Int) -> Void = { _ in }) {
        self.onOpenRecipe = onOpenRecipe
        self.previewJobs = previewJobs
    }

    private var store: IngestionStore { environment.ingestionStore }

    /// The jobs to render: seeded set in previews, otherwise the live store array.
    private var jobs: [IngestJob] {
        previewJobs ?? store.jobs
    }

    /// Count of jobs still working (used by the header affordance).
    private var importingCount: Int {
        jobs.filter { $0.status == .queued || $0.status == .running }.count
    }

    public var body: some View {
        // A single `List` (not a `ScrollView`) so the job rows get native
        // `.swipeActions` for per-row delete. The ingest / URL / header sections
        // ride along as plain, full-bleed rows (cleared insets + background) so the
        // composed layout still reads like the prior scroll-and-card screen.
        List {
            composedRow { ingestSection }
            composedRow { urlSection }
            jobsRows
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color.appBackground)
        .navigationTitle("Import")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        #if os(iOS)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        #endif
        .task {
            guard previewJobs == nil else { return }
            await store.refresh()
            await store.refreshFromServer()
        }
    }

    // MARK: - Ingest (drop zone / file picker)

    @ViewBuilder
    private var ingestSection: some View {
        #if os(macOS)
        dropZone
        #elseif os(iOS)
        if horizontalSizeClass == .regular {
            dropZone
        } else {
            compactNote
        }
        #else
        compactNote
        #endif
    }

    /// The prominent dashed drop-zone card. On macOS it accepts dropped file URLs
    /// and offers an `NSOpenPanel`; on iPad-regular it offers a `.fileImporter`.
    private var dropZone: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "fork.knife")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(isTargetedForDrop ? Color.appAccent : Color.appTextSecondary)
                .padding(.bottom, Theme.Spacing.xxs)

            Text("Drag a cookbook PDF here")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            Text("We'll extract every recipe, normalize the ingredients, and add them to your library.")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                choosePDF()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "tray.and.arrow.down")
                    Text("Choose PDF\u{2026}")
                }
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Capsule(style: .continuous).fill(Color.appAccent))
            }
            .buttonStyle(.plain)
            .disabled(store.isStarting)
            .padding(.top, Theme.Spacing.xs)

            if let progress = store.uploadProgress {
                uploadProgressView(progress)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isTargetedForDrop ? Color.appAccent : Color.appBorder,
                    style: StrokeStyle(
                        lineWidth: isTargetedForDrop ? 2 : Theme.Stroke.hairline,
                        dash: [8, 6]
                    )
                )
        )
        #if os(macOS)
        .onDrop(of: [.pdf, .fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        #endif
        .animation(.easeInOut(duration: 0.15), value: isTargetedForDrop)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag a cookbook PDF here, or choose a PDF to import")
    }

    /// iPhone-compact note: drop import lives on the bigger screens.
    private var compactNote: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.appTextSecondary)
            Text("Drag-and-drop cookbook import is on Mac & iPad.")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
    }

    private func uploadProgressView(_ progress: UploadProgress) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            ProgressView(value: progress.fraction)
                .tint(Color.appAccent)
            Text("Uploading\u{2026} \(Int(progress.fraction * 100))%")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 320)
    }

    // MARK: - URL import

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Import a recipe from a URL")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "link")
                        .foregroundStyle(Color.appTextSecondary)
                        .accessibilityHidden(true)
                    TextField("https://\u{2026}", text: $urlText)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                        .textFieldStyle(.plain)
                        .submitLabel(.go)
                        .onSubmit(submitURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        #endif
                    if !urlText.isEmpty {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear URL")
                    }
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

                Button(action: submitURL) {
                    Text("Import")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .fill(canImportURL ? Color.appAccent : Color.appAccent.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canImportURL)
                .accessibilityLabel("Import recipe from URL")
            }
        }
    }

    private var canImportURL: Bool {
        guard !store.isStarting else { return false }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.scheme != nil
    }

    // MARK: - Jobs

    /// The jobs rows for the outer `List`: a header (with the confirmed "Clear
    /// finished" action), then either an empty state or one swipe-deletable
    /// ``JobRow`` per job. The shared ``JobsList`` component owns the actual row
    /// rendering; this view reuses ``JobsList/Header`` and the same `JobRow` so the
    /// Import screen and the Activity sheet stay byte-for-byte consistent (DRY).
    @ViewBuilder
    private var jobsRows: some View {
        composedRow {
            JobsList.Header(
                importingCount: importingCount,
                hasFinished: jobs.contains { $0.status.isTerminal },
                onClearFinished: { Task { await store.clearFinished() } }
            )
        }

        if let error = store.lastError, jobs.isEmpty {
            composedRow { errorBanner(error) }
        }

        if jobs.isEmpty {
            composedRow {
                EmptyState(
                    systemImage: "tray",
                    message: "No imports yet",
                    subtitle: "Drop a cookbook PDF or paste a recipe URL to get started."
                )
                .padding(.vertical, Theme.Spacing.lg)
            }
        } else {
            ForEach(jobs) { job in
                JobRow(
                    job: job,
                    isExpanded: expandedJobIds.contains(job.jobId),
                    onToggleExpand: { toggleExpand(job) },
                    onOpenRecipe: onOpenRecipe
                )
                .listRowInsets(EdgeInsets(
                    top: Theme.Spacing.xs, leading: Theme.Spacing.lg,
                    bottom: Theme.Spacing.xs, trailing: Theme.Spacing.lg
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await store.deleteJob(jobId: job.jobId) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Wrap an arbitrary section view as a plain, full-bleed `List` row: cleared
    /// background + separator, with a leading/trailing inset that keeps the prior
    /// `Theme.Spacing.lg` gutter. Lets the ingest / URL / header sections live in
    /// the same `List` that carries the swipe-deletable job rows.
    @ViewBuilder
    private func composedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.md, leading: Theme.Spacing.lg,
                bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Which job rows are expanded into their full stage timeline.
    @State private var expandedJobIds: Set<String> = []

    private func toggleExpand(_ job: IngestJob) {
        if expandedJobIds.contains(job.jobId) {
            expandedJobIds.remove(job.jobId)
        } else {
            expandedJobIds.insert(job.jobId)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appDestructive)
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
                .fill(Color.appDestructive.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func submitURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed)?.scheme != nil, !store.isStarting else { return }
        urlText = ""
        Task { await store.ingestURL(trimmed) }
    }

    /// macOS NSOpenPanel; iPad routes through `.fileImporter` instead.
    private func choosePDF() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Import"
        panel.message = "Choose a cookbook PDF to ingest"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.ingestPDF(fileURL: url) }
        }
        #elseif os(iOS)
        showingFileImporter = true
        #endif
    }

    #if os(macOS)
    /// Resolve the first dropped provider to a PDF file URL and start ingestion.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return false }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            guard url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in
                await store.ingestPDF(fileURL: url)
            }
        }
        return true
    }
    #endif

    #if os(iOS)
    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                // Security-scoped access for files outside the app sandbox.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    await store.ingestPDF(data: data, filename: url.lastPathComponent)
                } else {
                    await store.ingestPDF(fileURL: url)
                }
            }
        case .failure:
            break
        }
    }
    #endif
}

// MARK: - Previews

/// Seeded sample jobs covering the queued / in-progress / done / error states the
/// jobs list must render. Used only by `#Preview`s via the internal
/// `ImportView(previewJobs:)` initializer (the store has no preview seed).
private enum ImportPreviewData {
    static let queued = IngestJob(
        jobId: "job-queued",
        kind: .pdf,
        filename: "The Mediterranean Table.pdf",
        status: .queued,
        stage: "queued",
        recipesDone: 0,
        recipesTotal: 0,
        recipeIds: [],
        createdAt: Date().addingTimeInterval(-20),
        updatedAt: Date().addingTimeInterval(-20)
    )

    static let extracting = IngestJob(
        jobId: "job-extracting",
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

    static let embedding = IngestJob(
        jobId: "job-embedding",
        kind: .url,
        filename: nil,
        status: .running,
        stage: "embedding",
        recipesDone: 1,
        recipesTotal: 1,
        recipeIds: [],
        createdAt: Date().addingTimeInterval(-30),
        updatedAt: Date().addingTimeInterval(-2)
    )

    static let done = IngestJob(
        jobId: "job-done",
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
        jobId: "job-error",
        kind: .url,
        filename: nil,
        status: .error,
        stage: "extracting",
        recipesDone: 0,
        recipesTotal: 0,
        recipeIds: [],
        error: "Couldn't parse a recipe from that page — the URL didn't return structured recipe data.",
        createdAt: Date().addingTimeInterval(-400),
        updatedAt: Date().addingTimeInterval(-360)
    )

    static let all: [IngestJob] = [extracting, embedding, queued, done, errored]
}

#Preview("Import — Light") {
    NavigationStack {
        ImportView(previewJobs: ImportPreviewData.all, onOpenRecipe: { _ in })
    }
    .environment(CookbookEnvironment.preview())
    .preferredColorScheme(.light)
}

#Preview("Import — Dark") {
    NavigationStack {
        ImportView(previewJobs: ImportPreviewData.all, onOpenRecipe: { _ in })
    }
    .environment(CookbookEnvironment.preview())
    .preferredColorScheme(.dark)
}

#Preview("Import — Empty") {
    NavigationStack {
        ImportView(previewJobs: [], onOpenRecipe: { _ in })
    }
    .environment(CookbookEnvironment.preview())
    .preferredColorScheme(.light)
}

#Preview("Import — Expanded job (extracting 41/120)") {
    NavigationStack {
        ImportView(previewJobs: [ImportPreviewData.extracting, ImportPreviewData.done], onOpenRecipe: { _ in })
    }
    .environment(CookbookEnvironment.preview())
    .preferredColorScheme(.dark)
}
