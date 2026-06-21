import Foundation

/// Drives async ingestion: start a PDF/URL job, poll its progress, expose job DTOs.
/// After a job completes, the recipe catalog has changed, so the store nudges a
/// catalog re-sync via the SyncService.
@MainActor
@Observable
public final class IngestionStore {
    private let client: APIClient
    private let mirror: LocalMirror
    private let sync: SyncService

    /// Recent jobs (local mirror + live updates), newest first.
    public private(set) var jobs: [IngestJob] = []
    /// Upload progress for an in-flight PDF upload (nil when not uploading).
    public private(set) var uploadProgress: UploadProgress?
    public private(set) var isStarting = false
    public private(set) var lastError: String?

    private var pollTasks: [String: Task<Void, Never>] = [:]

    public init(client: APIClient, mirror: LocalMirror, sync: SyncService) {
        self.client = client
        self.mirror = mirror
        self.sync = sync
    }

    /// Reload jobs from the local mirror.
    public func refresh() async {
        do {
            jobs = try await mirror.ingestJobs()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Refresh from the server's job list (`GET /ingest`) and persist locally.
    public func refreshFromServer() async {
        do {
            let serverJobs = try await client.ingestJobs()
            // Authoritative replace (delete-missing + upsert), NOT a merge: an
            // upsert-only refresh left server-cleared/-deleted jobs lingering in the
            // mirror, so they reappeared on the next Import-screen visit.
            //
            // BUT preserve optimistic, still-UPLOADING rows the server doesn't know
            // about yet — otherwise a just-dropped PDF vanishes for the entire upload
            // (it reappears only once the server registers the job, ~30-45s for a big
            // scan). `stage == "uploading"` is a CLIENT-ONLY marker the server never
            // emits, so it cleanly identifies these. Drop stale ones (>2 min, e.g. an
            // upload interrupted by an app kill) so they can't ghost forever — a live
            // upload keeps `updatedAt` fresh via `applyUploadProgress`.
            let cutoff = Date().addingTimeInterval(-120)
            let serverIds = Set(serverJobs.map(\.jobId))
            let inflight = jobs.filter {
                $0.stage == "uploading" && !serverIds.contains($0.jobId)
                    && ($0.updatedAt ?? .distantPast) > cutoff
            }
            try await mirror.replaceIngestJobs(serverJobs + inflight)
            jobs = try await mirror.ingestJobs()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Start a PDF ingestion (`POST /ingest`) from a file URL and begin polling.
    /// Returns `true` once the job is queued + tracked, `false` on failure (with the
    /// reason in `lastError`). The job row appears in Activity IMMEDIATELY (an
    /// optimistic "uploading" row), before the multipart upload finishes — see
    /// `runPDFIngest`.
    @discardableResult
    public func ingestPDF(fileURL: URL, title: String? = nil, author: String? = nil) async -> Bool {
        await runPDFIngest(filename: fileURL.lastPathComponent) { id, prog in
            try await self.client.ingestPDF(
                fileURL: fileURL, title: title, author: author, jobId: id, progress: prog)
        }
    }

    /// Start a PDF ingestion from in-memory data. See `ingestPDF(fileURL:)`.
    @discardableResult
    public func ingestPDF(data: Data, filename: String, title: String? = nil, author: String? = nil) async -> Bool {
        await runPDFIngest(filename: filename) { id, prog in
            try await self.client.ingestPDF(
                data: data, filename: filename, title: title, author: author, jobId: id, progress: prog)
        }
    }

    /// Shared PDF-ingest driver. Seeds an OPTIMISTIC "uploading" row under a
    /// client-generated id BEFORE the (slow, possibly 30 MB) multipart upload, so the
    /// job shows in Activity the instant the cook picks a file — not 45-60s later when
    /// the upload completes. Threads that id to the server (it adopts it); reconciles
    /// to the server's id if an older backend assigns its own. The upload's byte
    /// progress drives the row ("Uploading 45%"); then polling takes over the stages.
    @discardableResult
    private func runPDFIngest(
        filename: String,
        upload: (String, @escaping @Sendable (UploadProgress) -> Void) async throws -> IngestJobHandle
    ) async -> Bool {
        // A clean client id the server can ADOPT as the job id (sent via job_id) — the
        // optimistic row is identified for refresh-preservation by its "uploading"
        // stage, not by this id, so no marker prefix is needed.
        let clientId = UUID().uuidString
        isStarting = true
        defer { isStarting = false }
        await seedUploading(jobId: clientId, filename: filename)   // instant, pre-upload
        do {
            let handle = try await upload(clientId) { [weak self] p in
                Task { @MainActor in self?.applyUploadProgress(jobId: clientId, p) }
            }
            await reconcileSeeded(from: clientId, to: handle, filename: filename)
            startPolling(jobId: handle.jobId)
            uploadProgress = nil
            lastError = nil
            return true
        } catch {
            uploadProgress = nil
            await markUploadFailed(jobId: clientId, filename: filename,
                                   message: String(describing: error))
            lastError = String(describing: error)
            return false
        }
    }

    /// The optimistic pre-upload row: status `.running`, stage `"uploading"`, shown
    /// instantly (counts toward the Activity badge). Written to the mirror so it
    /// survives a refresh, and inserted into the live `jobs` array right away.
    private func seedUploading(jobId: String, filename: String) async {
        let now = Date()
        let job = IngestJob(
            jobId: jobId, kind: .pdf, filename: filename, status: .running,
            stage: "uploading", recipesDone: 0, recipesTotal: 0, recipeIds: [],
            error: nil, createdAt: now, updatedAt: now)
        try? await mirror.upsertIngestJob(job)
        applyJobUpdate(job)
        uploadProgress = UploadProgress(bytesSent: 0, totalBytes: 0)
    }

    /// Live upload-byte progress → the row's percentage (in-memory only; no per-tick
    /// mirror write — the upload can fire many progress callbacks).
    private func applyUploadProgress(jobId: String, _ p: UploadProgress) {
        uploadProgress = p
        guard let idx = jobs.firstIndex(where: { $0.jobId == jobId }) else { return }
        var job = jobs[idx]
        job.stage = "uploading"
        job.recipesTotal = 100
        job.recipesDone = Int((p.fraction * 100).rounded())
        job.updatedAt = Date()
        jobs[idx] = job
    }

    /// Once the upload returns, adopt the server's id (no-op if it honored ours) and
    /// flip the row out of "uploading" to the server's queued status; polling drives
    /// the rest of the stages.
    private func reconcileSeeded(from clientId: String, to handle: IngestJobHandle, filename: String) async {
        if handle.jobId != clientId {
            jobs.removeAll { $0.jobId == clientId }
            try? await mirror.deleteIngestJobLocally(jobId: clientId)
        }
        try? await seed(jobId: handle.jobId, kind: .pdf, filename: filename, status: handle.status)
    }

    /// A failed upload must not leave the optimistic row stuck on "uploading" — flip
    /// it to an error row carrying the reason.
    private func markUploadFailed(jobId: String, filename: String, message: String) async {
        let now = Date()
        let job = IngestJob(
            jobId: jobId, kind: .pdf, filename: filename, status: .error,
            stage: "error", recipesDone: 0, recipesTotal: 0, recipeIds: [],
            error: message, createdAt: now, updatedAt: now)
        try? await mirror.upsertIngestJob(job)
        applyJobUpdate(job)
    }

    /// Start a URL ingestion (`POST /ingest/url`) and begin polling.
    public func ingestURL(_ url: String) async {
        isStarting = true
        defer { isStarting = false }
        do {
            let handle = try await client.ingestURL(url)
            try await seed(jobId: handle.jobId, kind: .url, filename: nil, status: handle.status)
            startPolling(jobId: handle.jobId)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Deletes

    /// Delete a single job record (`DELETE /ingest/{job_id}`). Optimistically stops
    /// polling, removes it from the published list and the mirror, then calls the
    /// server. On failure re-pulls the server job list and records `lastError`.
    public func deleteJob(jobId: String) async {
        stopPolling(jobId: jobId)
        jobs.removeAll { $0.jobId == jobId }
        do {
            try await mirror.deleteIngestJobLocally(jobId: jobId)
            _ = try await client.deleteIngestJob(jobId: jobId)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            await refreshFromServer()
        }
    }

    /// Clear finished jobs (`DELETE /ingest?include_active=false`). Optimistically
    /// removes terminal jobs from the published list and the mirror, then calls the
    /// server (terminal-only). On failure re-pulls the server job list and records
    /// `lastError`.
    public func clearFinished() async {
        jobs.removeAll { $0.status.isTerminal }
        do {
            try await mirror.clearIngestJobsLocally(terminalOnly: true)
            _ = try await client.clearIngestJobs(includeActive: false)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            await refreshFromServer()
        }
    }

    /// Stop polling a job (does not cancel server-side work).
    public func stopPolling(jobId: String) {
        pollTasks[jobId]?.cancel()
        pollTasks[jobId] = nil
    }

    public func stopAllPolling() {
        for (_, task) in pollTasks { task.cancel() }
        pollTasks.removeAll()
    }

    // MARK: - Internals

    private func seed(jobId: String, kind: IngestKind, filename: String?, status: IngestStatus) async throws {
        let now = Date()
        let job = IngestJob(
            jobId: jobId, kind: kind, filename: filename, status: status,
            stage: nil, recipesDone: 0, recipesTotal: 0, recipeIds: [],
            error: nil, createdAt: now, updatedAt: now)
        try await mirror.upsertIngestJob(job)
        jobs = try await mirror.ingestJobs()
    }

    private func startPolling(jobId: String) {
        stopPolling(jobId: jobId)
        let stream = client.ingestJobUpdates(id: jobId, pollInterval: .seconds(1))
        pollTasks[jobId] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await job in stream {
                    try? await self.mirror.upsertIngestJob(job)
                    self.applyJobUpdate(job)
                    if job.status.isTerminal {
                        if job.status == .done {
                            // New recipes landed — re-sync the catalog.
                            await self.sync.syncCatalog(force: true)
                        }
                        break
                    }
                }
            } catch {
                self.setError(String(describing: error))
            }
            self.clearPollTask(jobId)
        }
    }

    private func applyJobUpdate(_ job: IngestJob) {
        if let idx = jobs.firstIndex(where: { $0.jobId == job.jobId }) {
            jobs[idx] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    private func setError(_ message: String) { lastError = message }
    private func clearPollTask(_ jobId: String) { pollTasks[jobId] = nil }

    // MARK: - Preview / testing seed (additive; NOT for production paths)

    /// Seed the published `jobs` array directly for SwiftUI `#Preview`s, mirroring
    /// `RecipeStore`/`LibraryStore`'s `seedForPreview(...)`. No network or mirror
    /// I/O is performed — the array is assigned in place so previews can render the
    /// jobs list (queued / running / done / error) without a live backend.
    public func seedForPreview(jobs: [IngestJob]) {
        self.jobs = jobs
    }
}
