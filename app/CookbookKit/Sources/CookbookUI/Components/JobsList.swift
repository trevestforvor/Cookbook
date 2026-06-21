import SwiftUI
import CookbookKit

// MARK: - Jobs list (reusable ingestion cleanup surface)

/// The shared, cleanup-capable ingestion jobs list. Renders each ``IngestJob`` as a
/// ``JobRow`` (header / progress / result chips / error / expandable stage
/// timeline) with **per-row swipe-to-delete** and a **"Clear finished"** action
/// gated behind a `.confirmationDialog`.
///
/// This is the single source of truth for rendering ingestion jobs — used by the
/// Activity sheet (``ActivityView``) raised from the Assistant.
/// (DRY: there is no second copy of `JobRow`.)
///
/// ### Delete semantics
/// - **Per-job delete** (`onDeleteJob`) is a history-row removal (`DELETE
///   /ingest/{job_id}`); it needs no confirmation — it only drops a job record, not
///   any recipe.
/// - **Clear finished** (`onClearFinished`) removes all terminal rows
///   (`DELETE /ingest?include_active=false`) and *is* confirmed, since it's a bulk
///   action.
///
/// ### Expansion behavior
/// `DONE` rows auto-collapse (terminal rows don't auto-expand into their timeline);
/// `ERROR` rows stay visible so the failure is never hidden. Tapping a row toggles
/// its stage timeline either way.
///
/// All reads are the passed-in Sendable `jobs` array; the component performs no
/// store mutation itself — the host supplies `onDeleteJob` / `onClearFinished`,
/// keeping it navigation- and store-agnostic (matches ``RecipeCard`` / ``JobRow``).
struct JobsList: View {
    let jobs: [IngestJob]
    let onDeleteJob: (String) -> Void
    let onOpenRecipe: (Int) -> Void

    /// Which job rows are expanded into their full stage timeline.
    @State private var expandedJobIds: Set<String> = []

    var body: some View {
        List {
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
                        onDeleteJob(job.jobId)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    private func toggleExpand(_ job: IngestJob) {
        if expandedJobIds.contains(job.jobId) {
            expandedJobIds.remove(job.jobId)
        } else {
            expandedJobIds.insert(job.jobId)
        }
    }

    // MARK: Header pieces (composed by hosts that want them above the list)

    /// A reusable "Imports" header with an in-progress badge and the confirmed
    /// "Clear finished" button. Hosts place this above ``JobsList`` (it isn't part
    /// of the scrolling `List` so it stays pinned).
    struct Header: View {
        let importingCount: Int
        let hasFinished: Bool
        let onClearFinished: () -> Void

        @State private var showingClearConfirm = false

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                Text("Imports")
                    .font(.appTitle)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer(minLength: Theme.Spacing.sm)

                if importingCount > 0 {
                    importingBadge
                }

                if hasFinished {
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "trash")
                                .imageScale(.small)
                            Text("Clear finished")
                                .font(.appCaption.weight(.semibold))
                        }
                        .foregroundStyle(Color.appDestructive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear finished imports")
                    .confirmationDialog(
                        "Clear finished imports?",
                        isPresented: $showingClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear finished", role: .destructive) { onClearFinished() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes completed and failed imports from the list. It does not delete any recipes.")
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
    }
}

// MARK: - Ingest stage model

/// The ordered, user-facing ingestion stages. `IngestStatus` is the coarse
/// lifecycle; the server's free-form `stage` string refines the `running` phase.
/// This enum gives the timeline a stable order and labels, and maps a job onto a
/// "current stage index" so completed stages can show a check.
enum IngestStage: Int, CaseIterable, Identifiable {
    case uploading
    case queued
    case loading
    case extracting
    case normalizing
    case embedding
    case done

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .uploading: return "Uploading"
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
        case .uploading: return "arrow.up.doc"
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
        if raw.contains("upload") { return .uploading }
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
        // A dedup short-circuit (re-dropping an already-owned file) is a distinct,
        // non-alarming terminal state — not a bare "Done / 0 recipes".
        case .done: return isSkipped ? "Already in your library" : IngestStage.done.label
        case .error: return "Error"
        case .running:
            // The slow pre-LLM "loading" phase is per-PAGE here (OCR / text), so name
            // it for what it is; the count ("3/12") comes from hasDeterminateProgress.
            if currentStage == .loading {
                return kind == .pdf ? "Reading pages" : "Fetching"
            }
            return currentStage.label
        }
    }

    /// A re-drop of an already-ingested file: the server skipped OCR/LLM and returned
    /// nothing. The worker keeps `stage == "skipped"` on the terminal record so we can
    /// distinguish it from a genuine empty import.
    var isSkipped: Bool {
        (stage?.lowercased().contains("skip")) == true
    }

    /// True when a determinate progress bar makes sense (we know a unit count and
    /// we're in a counting phase). Includes `.uploading` (bytes %) and `.loading`
    /// (per-page OCR) so the whole pre-LLM stretch shows live movement, not a frozen
    /// label, while the big file uploads and OCRs.
    var hasDeterminateProgress: Bool {
        recipesTotal > 0
            && (currentStage == .uploading || currentStage == .loading
                || currentStage == .extracting || currentStage == .embedding)
            && status == .running
    }

    /// The trailing detail next to the stage label. During `.uploading` the count is a
    /// byte PERCENT ("45%"); elsewhere it's a unit count ("3/12" pages or recipes).
    var progressDetail: String? {
        guard hasDeterminateProgress else { return nil }
        if currentStage == .uploading { return "\(recipesDone)%" }
        return "\(recipesDone)/\(recipesTotal)"
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
struct JobRow: View {
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
                    if let detail = job.progressDetail {
                        Text(detail)
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
        JobsFlowLayout(spacing: Theme.Spacing.sm, lineSpacing: Theme.Spacing.sm) {
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

            if state == .active, let detail = job.progressDetail {
                Text(detail)
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
private struct JobsFlowLayout: Layout {
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
