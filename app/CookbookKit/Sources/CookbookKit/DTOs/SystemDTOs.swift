import Foundation

// MARK: - Catalog version

/// `GET /catalog/version`: `{version, recipe_count}`. The `version` integer bumps
/// whenever the recipe set changes; SyncService gates a full recipe pull on it.
public struct CatalogVersion: Codable, Sendable, Hashable {
    public var version: Int
    public var recipeCount: Int

    public init(version: Int, recipeCount: Int) {
        self.version = version; self.recipeCount = recipeCount
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case recipeCount = "recipe_count"
    }
}

// MARK: - Ingestion jobs

/// Status of an async ingestion job. Shape from `GET /ingest/{job_id}`:
/// `{job_id, kind, filename?, status, stage, recipes_done, recipes_total,
///   recipe_ids:[...], error?, created_at, updated_at}`.
public struct IngestJob: Codable, Sendable, Hashable, Identifiable {
    public var jobId: String
    public var kind: IngestKind
    public var filename: String?
    public var status: IngestStatus
    /// Human-readable progress stage, e.g. "extracting", "normalizing".
    public var stage: String?
    public var recipesDone: Int
    public var recipesTotal: Int
    public var recipeIds: [Int]
    public var error: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public var id: String { jobId }

    /// 0...1 progress, or `nil` when the total isn't known yet.
    public var fractionComplete: Double? {
        guard recipesTotal > 0 else { return status == .done ? 1.0 : nil }
        return min(1.0, Double(recipesDone) / Double(recipesTotal))
    }

    public init(
        jobId: String, kind: IngestKind, filename: String? = nil,
        status: IngestStatus, stage: String? = nil, recipesDone: Int = 0,
        recipesTotal: Int = 0, recipeIds: [Int] = [], error: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.jobId = jobId; self.kind = kind; self.filename = filename
        self.status = status; self.stage = stage; self.recipesDone = recipesDone
        self.recipesTotal = recipesTotal; self.recipeIds = recipeIds; self.error = error
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case kind, filename, status, stage
        case recipesDone = "recipes_done"
        case recipesTotal = "recipes_total"
        case recipeIds = "recipe_ids"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        kind = try c.decodeIfPresent(IngestKind.self, forKey: .kind) ?? .pdf
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        status = try c.decode(IngestStatus.self, forKey: .status)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        recipesDone = try c.decodeIfPresent(Int.self, forKey: .recipesDone) ?? 0
        recipesTotal = try c.decodeIfPresent(Int.self, forKey: .recipesTotal) ?? 0
        recipeIds = try c.decodeIfPresent([Int].self, forKey: .recipeIds) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobId, forKey: .jobId)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(filename, forKey: .filename)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(stage, forKey: .stage)
        try c.encode(recipesDone, forKey: .recipesDone)
        try c.encode(recipesTotal, forKey: .recipesTotal)
        try c.encode(recipeIds, forKey: .recipeIds)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
        try c.encodeIfPresent(updatedAt.map(CookbookCoding.formatTimestamp), forKey: .updatedAt)
    }
}

/// The minimal response of `POST /ingest` / `POST /ingest/url`:
/// `{job_id, status:"queued"}`.
public struct IngestJobHandle: Codable, Sendable, Hashable {
    public var jobId: String
    public var status: IngestStatus

    public init(jobId: String, status: IngestStatus = .queued) {
        self.jobId = jobId; self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
    }
}

/// `GET /ingest`: `{jobs:[...recent...]}`.
public struct IngestJobList: Codable, Sendable, Hashable {
    public var jobs: [IngestJob]
    public init(jobs: [IngestJob] = []) { self.jobs = jobs }
}

// MARK: - Delete results

/// `DELETE /recipes/{id}`: `{deleted, version, recipe_count}`. The `version` and
/// `recipeCount` are the authoritative catalog state after the cascade delete —
/// stores write them straight into the mirror's catalog meta.
public struct DeleteRecipeResult: Codable, Sendable, Hashable {
    public var deleted: Int
    public var version: Int
    public var recipeCount: Int

    public init(deleted: Int, version: Int, recipeCount: Int) {
        self.deleted = deleted; self.version = version; self.recipeCount = recipeCount
    }

    private enum CodingKeys: String, CodingKey {
        case deleted, version
        case recipeCount = "recipe_count"
    }
}

/// `DELETE /recipes?confirm=true`: `{wiped, version, recipe_count}`. A full library
/// reset; the server also clears ingest jobs as a side effect.
public struct WipeResult: Codable, Sendable, Hashable {
    public var wiped: Int
    public var version: Int
    public var recipeCount: Int

    public init(wiped: Int, version: Int, recipeCount: Int) {
        self.wiped = wiped; self.version = version; self.recipeCount = recipeCount
    }

    private enum CodingKeys: String, CodingKey {
        case wiped, version
        case recipeCount = "recipe_count"
    }
}

/// `DELETE /ingest?include_active=`: `{cleared, include_active}`. Terminal-only by
/// default; `includeActive` echoes whether running/queued jobs were also cleared.
public struct ClearJobsResult: Codable, Sendable, Hashable {
    public var cleared: Int
    public var includeActive: Bool

    public init(cleared: Int, includeActive: Bool) {
        self.cleared = cleared; self.includeActive = includeActive
    }

    private enum CodingKeys: String, CodingKey {
        case cleared
        case includeActive = "include_active"
    }
}

/// `DELETE /ingest/{job_id}`: `{deleted}` — the job id that was removed (mem+DB).
public struct DeleteJobResult: Codable, Sendable, Hashable {
    public var deleted: String

    public init(deleted: String) { self.deleted = deleted }
}
