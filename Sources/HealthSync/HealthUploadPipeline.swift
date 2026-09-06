import DurableSync
import Foundation
import Observation

@MainActor @Observable
public final class HealthSyncStatus {
    private let defaults: UserDefaults
    public var lastHealthReadAt: Date? { didSet { defaults.set(lastHealthReadAt, forKey: "sync.healthRead") } }
    public var lastHealthUploadAt: Date? { didSet { defaults.set(lastHealthUploadAt, forKey: "sync.healthUpload") } }
    public var lastError: String?
    public var healthReading = false
    public var uploading = false
    public var healthBackgroundEnabledTypes = 0
    public var pendingHealthDays = 0
    public var healthHistoryCatchingUp = false
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        lastHealthReadAt = defaults.object(forKey: "sync.healthRead") as? Date
        lastHealthUploadAt = defaults.object(forKey: "sync.healthUpload") as? Date
    }
    public func recordError(_ message: String) { lastError = message }
    public func clearError(matchingPrefix prefix: String) {
        if lastError?.hasPrefix(prefix) == true { lastError = nil }
    }
}

/// Only checkpoint values after they have entered a durable outbox.
@MainActor
public final class HealthUploadCheckpoint {
    private struct Value: Codable, Equatable { let value: Double; let unit: String }
    private let url: URL
    private let window: HealthWindow
    private var values: [String: Value]?
    public init(url: URL, window: HealthWindow = HealthWindow()) { self.url = url; self.window = window }
    public func enqueueChanged(_ totals: [HealthAggregate], enqueue: ([HealthAggregate]) -> Bool) throws -> Int {
        if values == nil {
            values = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode([String: Value].self, from: Data(contentsOf: url)) : [:]
        }
        var next = values!.filter { window.contains(String($0.key.prefix(10))) }
        var changed: [HealthAggregate] = []
        for total in totals where window.contains(total.date) {
            let key = total.date + "|" + total.type
            let value = Value(value: total.value, unit: total.unit)
            if next[key] != value { changed.append(total); next[key] = value }
        }
        guard changed.isEmpty || enqueue(changed) else { throw CocoaError(.fileWriteUnknown) }
        if next != values! {
            try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            values = next
        }
        return changed.count
    }
}

@MainActor
final class HealthUploadPipeline {
    private let queue: DurableWriteLog<HealthAggregate>
    private let uploadBatch: @Sendable ([HealthAggregate]) async throws -> Void
    private let status: HealthSyncStatus
    private let log: DiagnosticLog
    private var retry: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private let retryBackoff: [TimeInterval]
    var requestBackgroundWork: (() -> Void)?
    var pendingCount: Int { queue.pendingCount }
    var storageError: String? { queue.lastStorageError }

    init(url: URL, window: HealthWindow, status: HealthSyncStatus, log: DiagnosticLog,
         retryBackoff: [TimeInterval] = [1.5, 3, 5], beforeIO: @escaping (String) throws -> Void = { _ in },
         uploadBatch: @escaping @Sendable ([HealthAggregate]) async throws -> Void) {
        self.status = status; self.log = log; self.uploadBatch = uploadBatch
        self.retryBackoff = retryBackoff
        queue = DurableWriteLog(storageURL: url, compact: { totals in
            let now = Date()
            var newest: [String: Int] = [:]
            for (index, total) in totals.enumerated() where window.contains(total.date, now: now) {
                let key = total.date + "|" + total.type
                if let prior = newest[key], totals[prior].recordedAt > total.recordedAt { continue }
                newest[key] = index
            }
            return totals.enumerated().compactMap { index, total in
                newest[total.date + "|" + total.type] == index ? total : nil
            }
        }, batch: { Array($0.dropFirst($1).prefix(49)) }, log: log,
        onStorageError: { error in
            if let error { status.recordError("Storage: " + error) }
            else { status.clearError(matchingPrefix: "Storage:") }
        }, beforeIO: beforeIO)
    }

    func enqueue(_ totals: [HealthAggregate]) -> Bool { queue.enqueue(contentsOf: totals) }
    func cancelRetry() { retry?.cancel(); retry = nil; drainTask?.cancel() }

    func drain() async {
        if let drainTask { await drainTask.value; return }
        let task = Task { @MainActor in
            defer { drainTask = nil }
            await performDrain()
        }
        drainTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performDrain() async {
        status.uploading = true
        defer { status.uploading = false }
        let uploadBatch = self.uploadBatch
        let result = await queue.drainAll(backoff: retryBackoff, executeBatch: { batch in
            try await withTimeout(10) { try await uploadBatch(batch) }
            self.status.lastHealthUploadAt = Date()
            self.log.record("health.upload", "batch=\(batch.count)")
        }) { _ in }
        if let error = result.lastError { status.recordError("Upload: " + error.localizedDescription) }
        if (queue.pendingCount > 0 || queue.lastStorageError != nil) && !Task.isCancelled {
            requestBackgroundWork?()
            if retry == nil {
                retry = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.retry = nil
                    await self?.drain()
                }
            }
        } else {
            status.clearError(matchingPrefix: "Upload:")
            retry?.cancel(); retry = nil
        }
    }
}
