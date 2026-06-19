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

    /// Which job rows are expanded into their full stage timeline.
    @State private var expandedJobIds: Set<String> = []

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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                ingestSection
                urlSection
                jobsSection
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Imports")
                    .font(.appTitle)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                if importingCount > 0 {
                    importingBadge
                }
            }

            if let error = store.lastError, jobs.isEmpty {
                errorBanner(error)
            }

            if jobs.isEmpty {
                EmptyState(
                    systemImage: "tray",
                    message: "No imports yet",
                    subtitle: "Drop a cookbook PDF or paste a recipe URL to get started."
                )
                .padding(.vertical, Theme.Spacing.lg)
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(jobs) { job in
                        JobRow(
                            job: job,
                            isExpanded: expandedJobIds.contains(job.jobId),
                            onToggleExpand: { toggleExpand(job) },
                            onOpenRecipe: onOpenRecipe
                        )
                    }
                }
            }
        }
    }

    private var importingBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text("\(importingCount) importing\u{2026}")
                .font(.appCaption.weight(.medium))
                .foregroundStyle(Color.appTextSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Capsule(style: .continuous).fill(Color.appAccent.opacity(0.12)))
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

    private func toggleExpand(_ job: IngestJob) {
        if expandedJobIds.contains(job.jobId) {
            expandedJobIds.remove(job.jobId)
        } else {
            expandedJobIds.insert(job.jobId)
        }
    }

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

// MARK: - Ingest stage model

/// The ordered, user-facing ingestion stages. `IngestStatus` is the coarse
/// lifecycle; the server's free-form `stage` string refines the `running` phase.
/// This enum gives the timeline a stable order and labels, and maps a job onto a
/// "current stage index" so completed stages can show a check.
enum IngestStage: Int, CaseIterable, Identifiable {
    case queued
    case loading
    case extracting
    case normalizing
    case embedding
    case done

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .loading: return "Loading"
        case .extracting: return "Extracting recipes"
        case .normalizing: return "Normalizing"
        case .embedding: return "Embedding"
        case .done: return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .loading: return "doc.text"
        case .extracting: return "text.book.closed"
        case .normalizing: return "scalemass"
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .done: return "checkmark.seal"
        }
    }

    /// Map a free-form server stage string onto a known stage. Permissive about
    /// vocabulary so the timeline still advances if the server renames a step.
    static func from(rawStage: String?) -> IngestStage? {
        guard let raw = rawStage?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("queue") { return .queued }
        if raw.contains("load") || raw.contains("download") || raw.contains("fetch") || raw.contains("parse") { return .loading }
        if raw.contains("extract") { return .extracting }
        if raw.contains("normal") { return .normalizing }
        if raw.contains("embed") || raw.contains("index") || raw.contains("vector") { return .embedding }
        if raw.contains("done") || raw.contains("complete") || raw.contains("finish") { return .done }
        return nil
    }
}

extension IngestJob {
    /// The stage the job is currently on, as a timeline index.
    var currentStage: IngestStage {
        switch status {
        case .done: return .done
        case .queued: return .queued
        case .error: return IngestStage.from(rawStage: stage) ?? .loading
        case .running: return IngestStage.from(rawStage: stage) ?? .loading
        }
    }

    /// The user-facing stage label for the row (status-aware).
    var stageLabel: String {
        switch status {
        case .queued: return IngestStage.queued.label
        case .done: return IngestStage.done.label
        case .error: return "Error"
        case .running: return currentStage.label
        }
    }

    /// True when a determinate progress bar makes sense (we know a recipe count
    /// and we're in a counting phase).
    var hasDeterminateProgress: Bool {
        recipesTotal > 0 && (currentStage == .extracting || currentStage == .embedding) && status == .running
    }

    /// A short source descriptor for the row title.
    var sourceTitle: String {
        if let filename, !filename.isEmpty { return filename }
        switch kind {
        case .pdf: return "Cookbook PDF"
        case .url: return "Recipe from URL"
        }
    }
}

// MARK: - Job row

/// One ingestion job: a header (icon / source / stage), a progress bar, and an
/// expandable detail with the full stage timeline + result chips / error.
private struct JobRow: View {
    let job: IngestJob
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onOpenRecipe: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button(action: onToggleExpand) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse details" : "Show stage timeline")

            progress

            if job.status == .done, !job.recipeIds.isEmpty {
                doneSummary
            }

            if job.status == .error {
                errorRow
            }

            if isExpanded {
                Divider().overlay(Color.appBorder)
                StageTimeline(job: job)
            }
        }
        .padding(Theme.Spacing.lg)
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
            y: Theme.Shadow.cardYOffset
        )
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: job.kind == .pdf ? "book.closed" : "link")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.sourceTitle)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Theme.Spacing.xs) {
                    StatusDot(status: job.status)
                    Text(job.stageLabel)
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                    if job.hasDeterminateProgress {
                        Text("\(job.recipesDone)/\(job.recipesTotal)")
                            .font(.statNumber)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.down")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var progress: some View {
        switch job.status {
        case .done:
            ProgressView(value: 1.0)
                .tint(Color.appAccent)
        case .error:
            ProgressView(value: job.fractionComplete ?? 0)
                .tint(Color.appDestructive)
        case .queued:
            ProgressView(value: 0)
                .tint(Color.appTextSecondary)
        case .running:
            if job.hasDeterminateProgress, let fraction = job.fractionComplete {
                ProgressView(value: fraction)
                    .tint(Color.appAccent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
            }
        }
    }

    private var doneSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Imported \(job.recipeIds.count) recipe\(job.recipeIds.count == 1 ? "" : "s")")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.appAccent)

            FlowChips(ids: job.recipeIds, onOpenRecipe: onOpenRecipe)
        }
    }

    private var errorRow: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appDestructive)
            Text(job.error ?? "The import failed.")
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
}

// MARK: - Status dot

private struct StatusDot: View {
    let status: IngestStatus

    private var color: Color {
        switch status {
        case .done: return .appAccent
        case .error: return .appDestructive
        case .running: return .appAccentSecondary
        case .queued: return .appTextSecondary
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - Result chips (wrapping)

/// Tappable result chips for a finished job's recipe ids. Wraps onto multiple
/// lines so a cookbook's worth of recipes lays out cleanly.
private struct FlowChips: View {
    let ids: [Int]
    let onOpenRecipe: (Int) -> Void

    /// Cap the visible chips so a 120-recipe import doesn't render a wall; the
    /// remainder collapses into a "+N more" count.
    private let visibleLimit = 24

    var body: some View {
        let shown = Array(ids.prefix(visibleLimit))
        let overflow = ids.count - shown.count
        FlowLayout(spacing: Theme.Spacing.sm, lineSpacing: Theme.Spacing.sm) {
            ForEach(shown, id: \.self) { id in
                Button {
                    onOpenRecipe(id)
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "fork.knife")
                            .imageScale(.small)
                        Text("Recipe #\(id)")
                            .monospacedDigit()
                    }
                    .font(.appCaption.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Capsule(style: .continuous).fill(Color.appAccent.opacity(0.12)))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open recipe \(id)")
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.appCaption.weight(.medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Capsule(style: .continuous).fill(Color.appSurface))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                    )
            }
        }
    }
}

// MARK: - Stage timeline (JobDetail)

/// The full stage timeline for a job: an icon + label per stage with a check for
/// completed stages, a pulsing/active marker for the current stage, and a faded
/// marker for future stages. Errors mark the failing stage in red.
private struct StageTimeline: View {
    let job: IngestJob

    private var currentIndex: Int { job.currentStage.rawValue }
    private var isError: Bool { job.status == .error }
    private var isDone: Bool { job.status == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(IngestStage.allCases) { stage in
                row(for: stage)
            }
        }
    }

    private func state(for stage: IngestStage) -> StageState {
        if isDone { return .complete }
        if isError {
            if stage.rawValue < currentIndex { return .complete }
            if stage.rawValue == currentIndex { return .failed }
            return .pending
        }
        if stage.rawValue < currentIndex { return .complete }
        if stage.rawValue == currentIndex { return .active }
        return .pending
    }

    private func row(for stage: IngestStage) -> some View {
        let state = state(for: stage)
        return HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(state.markerFill)
                    .frame(width: 24, height: 24)
                Image(systemName: state.markerSymbol(default: stage.systemImage))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state.markerForeground)
            }

            Text(stage.label)
                .font(.appCaption.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state.textColor)

            Spacer(minLength: 0)

            if state == .active, job.hasDeterminateProgress {
                Text("\(job.recipesDone)/\(job.recipesTotal)")
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
            } else if state == .active {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.label): \(state.accessibilityValue)")
    }
}

private enum StageState {
    case complete, active, pending, failed

    var markerFill: Color {
        switch self {
        case .complete: return .appAccent
        case .active: return .appAccent.opacity(0.18)
        case .pending: return .appBorder.opacity(0.5)
        case .failed: return .appDestructive
        }
    }

    var markerForeground: Color {
        switch self {
        case .complete, .failed: return .white
        case .active: return .appAccent
        case .pending: return .appTextSecondary
        }
    }

    func markerSymbol(default symbol: String) -> String {
        switch self {
        case .complete: return "checkmark"
        case .failed: return "xmark"
        case .active, .pending: return symbol
        }
    }

    var textColor: Color {
        switch self {
        case .complete: return .appTextPrimary
        case .active: return .appTextPrimary
        case .pending: return .appTextSecondary
        case .failed: return .appDestructive
        }
    }

    var accessibilityValue: String {
        switch self {
        case .complete: return "completed"
        case .active: return "in progress"
        case .pending: return "pending"
        case .failed: return "failed"
        }
    }
}

// MARK: - Flow layout

/// A minimal wrapping layout that flows subviews left-to-right and wraps onto a
/// new line when the current row overflows. Cross-platform (pure `Layout`); used
/// for the result chips so they don't all force a single horizontal scroll.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                rows.append([])
                x = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        let width = proposal.width ?? rows.flatMap { $0 }.map(\.width).max() ?? 0
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
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
