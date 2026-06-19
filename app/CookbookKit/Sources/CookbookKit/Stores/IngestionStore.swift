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
            for job in serverJobs { try await mirror.upsertIngestJob(job) }
            jobs = try await mirror.ingestJobs()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Start a PDF ingestion (`POST /ingest`) from a file URL and begin polling.
    public func ingestPDF(fileURL: URL, title: String? = nil, author: String? = nil) async {
        isStarting = true
        uploadProgress = UploadProgress(bytesSent: 0, totalBytes: 0)
        defer { isStarting = false }
        do {
            let handle = try await client.ingestPDF(
                fileURL: fileURL, title: title, author: author,
                progress: { [weak self] p in
                    Task { @MainActor in self?.uploadProgress = p }
                })
            uploadProgress = nil
            try await seed(jobId: handle.jobId, kind: .pdf, filename: fileURL.lastPathComponent, status: handle.status)
            startPolling(jobId: handle.jobId)
        } catch {
            uploadProgress = nil
            lastError = String(describing: error)
        }
    }

    /// Start a PDF ingestion from in-memory data.
    public func ingestPDF(data: Data, filename: String, title: String? = nil, author: String? = nil) async {
        isStarting = true
        uploadProgress = UploadProgress(bytesSent: 0, totalBytes: Int64(data.count))
        defer { isStarting = false }
        do {
            let handle = try await client.ingestPDF(
                data: data, filename: filename, title: title, author: author,
                progress: { [weak self] p in
                    Task { @MainActor in self?.uploadProgress = p }
                })
            uploadProgress = nil
            try await seed(jobId: handle.jobId, kind: .pdf, filename: filename, status: handle.status)
            startPolling(jobId: handle.jobId)
        } catch {
            uploadProgress = nil
            lastError = String(describing: error)
        }
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
