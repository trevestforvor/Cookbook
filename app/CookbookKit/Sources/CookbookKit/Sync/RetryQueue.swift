import Foundation

/// A pending server write that has been applied optimistically to the local mirror
/// and now needs to reach the server. Carried as a closure plus a label for logging.
public struct PendingWrite: Sendable {
    public let label: String
    public let operation: @Sendable (APIClient) async throws -> Void
    public init(label: String, operation: @escaping @Sendable (APIClient) async throws -> Void) {
        self.label = label
        self.operation = operation
    }
}

/// A simple FIFO retry queue for write-through operations. Each enqueued write is
/// attempted immediately; on failure it stays queued and `flush()` retries the
/// backlog (e.g. when connectivity returns or after the next user action).
///
/// Intentionally small: bounded backlog, best-effort, fire-and-retry. It does NOT
/// guarantee ordering across unrelated resources beyond FIFO, which is sufficient
/// for the contract's idempotent-ish writes (favorites upsert, pantry add, etc.).
public actor RetryQueue {
    private let client: APIClient
    private var backlog: [PendingWrite] = []
    private let maxBacklog: Int

    public init(client: APIClient, maxBacklog: Int = 200) {
        self.client = client
        self.maxBacklog = maxBacklog
    }

    /// Number of writes still awaiting a successful server round-trip.
    public var pendingCount: Int { backlog.count }

    /// Try a write now; if it fails, queue it for later retry. Returns whether the
    /// immediate attempt succeeded.
    @discardableResult
    public func submit(_ write: PendingWrite) async -> Bool {
        do {
            try await write.operation(client)
            // Opportunistically drain anything that queued earlier.
            await flush()
            return true
        } catch {
            enqueue(write)
            return false
        }
    }

    /// Retry every queued write in FIFO order, stopping at the first failure so the
    /// backlog order is preserved.
    public func flush() async {
        guard !backlog.isEmpty else { return }
        var remaining: [PendingWrite] = []
        var stop = false
        for write in backlog {
            if stop {
                remaining.append(write)
                continue
            }
            do {
                try await write.operation(client)
            } catch {
                remaining.append(write)
                stop = true
            }
        }
        backlog = remaining
    }

    private func enqueue(_ write: PendingWrite) {
        backlog.append(write)
        if backlog.count > maxBacklog {
            backlog.removeFirst(backlog.count - maxBacklog)
        }
    }

    public func clear() { backlog.removeAll() }
}
