import Foundation
import Observation

// Append-only, FIFO, persisted write-ahead log. Storage + ordering + crash-safe
// drain only. It knows nothing about a backend (the executor closure does the
// sending), so it unit-tests with a fake executor and a temp file.
//
// Durability rules (see Documentation/DurableSync.md):
//   - O(1) appends via FileHandle; full rewrite only on drain/compact.
//   - ack-then-delete: an op is removed only after the executor returns; a
//     throw stops the drain and leaves the rest for the next trigger.
//   - overflow drops the OLDEST sample ops, never lifecycle ops.
@MainActor @Observable
public final class DurableWriteLog<Operation: Codable & Equatable> {
    public enum PolicyError: Error { case invalidCompaction, invalidBatch, drainInProgress }

    private let url: URL
    private let maxOps: Int
    // Compaction headroom: let the log overshoot the cap by this many ops before
    // trimming, so a trim is one O(n) rewrite per `capSlack` enqueues (amortized
    // O(1)) instead of a full load+rewrite on EVERY enqueue once at the cap —
    // the worst case in a long offline drive sitting at maxOps.
    private let capSlack: Int
    private let log: DiagnosticLog
    private let isDroppable: (Operation) -> Bool
    private let compact: ([Operation]) -> [Operation]
    private let batch: ([Operation], Int) -> [Operation]
    private let onStorageError: (String?) -> Void

    // In-memory pending count so pendingCount (and the drainAll loop condition,
    // and the always-on drain logging) don't reparse the whole 5 MB log on every
    // call. Authoritative once loaded; kept in sync on append / rewrite / clear.
    // nil = not yet read from disk.
    private var cachedCount: Int?
    private var isDraining = false
    private var unsaved: [Operation] = []
    public private(set) var lastStorageError: String?
    private let beforeIO: (String) throws -> Void
    public var unsavedCount: Int { unsaved.count }

    // 25k ops ≈ ~14 hours of continuous offline driving at the (relaxed)
    // automotive cadence, ~5 MB on disk — comfortably covers a multi-day road
    // trip with zero reconnects. Oldest samples trim past this; structure never.
    public init(storageURL: URL, maxOps: Int = 25_000, capSlack: Int? = nil,
         isDroppable: @escaping (Operation) -> Bool = { _ in false },
         compact: @escaping ([Operation]) -> [Operation] = { $0 },
         batch: @escaping ([Operation], Int) -> [Operation] = { [$0[$1]] },
         log: DiagnosticLog = DiagnosticLog(),
         onStorageError: @escaping (String?) -> Void = { _ in },
         beforeIO: @escaping (String) throws -> Void = { _ in }) {
        self.url = storageURL
        self.maxOps = maxOps
        self.capSlack = capSlack ?? max(500, maxOps / 20)
        self.isDroppable = isDroppable
        self.compact = compact
        self.batch = batch
        self.log = log
        self.onStorageError = onStorageError
        self.beforeIO = beforeIO
        precondition(maxOps > 0 && self.capSlack >= 0)
    }

    // ─── Enqueue ─────────────────────────────────────────────────────
    @discardableResult
    public func enqueue(_ op: Operation) -> Bool {
        unsaved.append(op)
        return flushUnsaved()
    }

    @discardableResult
    public func enqueue(contentsOf ops: [Operation]) -> Bool {
        unsaved.append(contentsOf: ops)
        return flushUnsaved()
    }

    @discardableResult
    public func flushUnsaved() -> Bool {
        guard !unsaved.isEmpty else { return true }
        do {
            if cachedCount == nil || lastStorageError != nil { _ = try readOps() }
            while let op = unsaved.first {
                let line = try JSONEncoder().encode(op)
                let before = currentCount()
                try appendLine(line)
                cachedCount = before + 1
                unsaved.removeFirst()
            }
            lastStorageError = nil
            onStorageError(nil)
            enforceCapIfNeeded()
            return lastStorageError == nil
        } catch { storageFailed(error); return false }
    }

    private func storageFailed(_ error: Error) {
        lastStorageError = error.localizedDescription
        onStorageError(error.localizedDescription)
    }

    // Pending count from the in-memory cache, reading the file only on the
    // first call (or after an external write the cache didn't see).
    private func currentCount() -> Int {
        if let c = cachedCount { return c }
        let c = load().count   // load() populates cachedCount
        return c
    }

    private func appendLine(_ data: Data) throws {
        try beforeIO("append")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        let offset = try fh.seekToEnd()
        do {
            try fh.write(contentsOf: data + Data([0x0a]))
            try fh.synchronize()
        } catch {
            try? fh.truncate(atOffset: offset)
            throw error
        }
    }

    // ─── Read / write whole log ──────────────────────────────────────
    public func load() -> [Operation] {
        do { return try readOps() }
        catch { storageFailed(error); return [] }
    }

    private func readOps() throws -> [Operation] {
        try beforeIO("read")
        guard FileManager.default.fileExists(atPath: url.path) else {
            cachedCount = 0
            lastStorageError = nil
            return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.isEmpty || text.hasSuffix("\n") else { throw CocoaError(.fileReadCorruptFile) }
        var ops: [Operation] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Fail closed on corruption. Never rewrite a partially decoded log.
            let op = try JSONDecoder().decode(Operation.self, from: Data(line.utf8))
            ops.append(op)
        }
        cachedCount = ops.count
        lastStorageError = nil
        return ops
    }

    private func rewrite(_ ops: [Operation]) throws {
        try beforeIO("rewrite")
        let enc = JSONEncoder()
        var data = Data()
        for op in ops {
            let line = try enc.encode(op)
            data.append(line); data.append(0x0a)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cachedCount = ops.count
        lastStorageError = nil
    }

    public var pendingCount: Int { currentCount() + unsaved.count }

    // Trim only once the log overshoots the cap by `capSlack` (amortized O(1)
    // per enqueue), then drop the oldest sample ops down to maxOps. Lifecycle
    // ops are structurally load-bearing and never dropped.
    private func enforceCapIfNeeded() {
        guard !isDraining else { return }
        guard currentCount() > maxOps + capSlack else { return }
        let ops: [Operation]
        do { ops = try readOps() } catch { storageFailed(error); return }
        var toDrop = ops.count - maxOps
        guard toDrop > 0 else { return }
        var kept: [Operation] = []
        kept.reserveCapacity(maxOps)
        for op in ops {
            if toDrop > 0, isDroppable(op) { toDrop -= 1; continue }
            kept.append(op)
        }
        do { try rewrite(kept) } catch { storageFailed(error); return }
        log.record("wal.cap", "dropped oldest samples, now \(kept.count)")
    }

    public struct DrainResult: Sendable { public var committed: Int; public var lastError: Error? }

    // Daily Health rollups replace one another. Compact before taking a drain
    // snapshot so repeated offline reads cannot build an upload backlog.
    private func prepareDrain() throws -> [Operation] {
        let ops = try readOps()
        let kept = compact(ops)
        // A policy may remove obsolete operations, but cannot insert, reorder,
        // or mutate records and then acknowledge a different durable prefix.
        var index = 0
        for op in kept {
            while index < ops.count && ops[index] != op { index += 1 }
            guard index < ops.count else { throw PolicyError.invalidCompaction }
            index += 1
        }
        if kept.count != ops.count { try rewrite(kept) }
        return kept
    }

    // ─── Drain ───────────────────────────────────────────────────────
    // One FIFO pass: execute each op; ack-then-delete. Stops on the first throw
    // (offline / cold connection / not-found-yet) and leaves the remainder.
    // Surfaces the failure so the caller can decide whether to retry/log.
    // Per-pass work cap (`cap`) so a constrained background wake can't time out.
    @discardableResult
    public func drain(maxOps cap: Int = 150,
               execute: @MainActor (Operation) async throws -> Void) async -> DrainResult {
        guard !isDraining else { return DrainResult(committed: 0, lastError: nil) }
        isDraining = true
        defer { isDraining = false; enforceCapIfNeeded() }
        guard flushUnsaved() else { return DrainResult(committed: 0, lastError: CocoaError(.fileWriteUnknown)) }
        let ops: [Operation]
        do { ops = try prepareDrain() } catch {
            storageFailed(error); return DrainResult(committed: 0, lastError: error)
        }
        guard !ops.isEmpty else { return DrainResult(committed: 0, lastError: nil) }
        var committed = 0
        var lastError: Error?
        for op in ops.prefix(cap) {
            do {
                try Task.checkCancellation()
                try await execute(op)
                committed += 1
            } catch {
                lastError = error
                break   // leave this op and the rest for the next pass
            }
        }
        if committed > 0 {
            // Enqueues can run while execute is suspended. Reload the durable
            // tail before removing acknowledgements so new writes survive.
            do { try rewrite(Array(try readOps().dropFirst(committed))) }
            catch { storageFailed(error); return DrainResult(committed: 0, lastError: error) }
        }
        return DrainResult(committed: committed, lastError: lastError)
    }

    // Drain to empty, retrying passes that make no progress — this is what
    // rides out a transport's cold connection on launch (the first request can
    // throw before the socket is up; a single pass would give up and the WAL
    // would stay stuck across relaunches). Bounded by a wall-clock budget so a
    // background wake can't overrun. `sleep` is injected for deterministic tests.
    @discardableResult
    public func drainAll(
        budget: TimeInterval = 10,
        backoff: [TimeInterval] = [1.5, 3, 5],
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        executeBatch: (@MainActor ([Operation]) async throws -> Void)? = nil,
        execute: @MainActor (Operation) async throws -> Void
    ) async -> DrainResult {
        guard !isDraining else { return DrainResult(committed: 0, lastError: nil) }
        isDraining = true
        defer { isDraining = false; enforceCapIfNeeded() }
        let deadline = Date().addingTimeInterval(budget)
        var total = 0
        var lastError: Error?
        var stall = 0
        // Load the whole log ONCE and stream the executor over it, rewriting the
        // remainder only when we stop. A clean run is a single load + single
        // rewrite (no per-batch reparse). We reload only after a back-off sleep,
        // since new ops may have been appended during it.
        while true {
            if Task.isCancelled { lastError = CancellationError(); break }
            guard flushUnsaved() else { lastError = CocoaError(.fileWriteUnknown); break }
            let ops: [Operation]
            do { ops = try prepareDrain() } catch { storageFailed(error); lastError = error; break }
            if ops.isEmpty { break }
            var committed = 0
            lastError = nil
            while committed < ops.count {
                if Date() >= deadline { break }   // constrained background wake — stop cleanly
                do {
                    try Task.checkCancellation()
                    if let executeBatch {
                        let batch = batch(ops, committed)
                        guard !batch.isEmpty,
                              batch == Array(ops.dropFirst(committed).prefix(batch.count)) else {
                            throw PolicyError.invalidBatch
                        }
                        try await executeBatch(batch)
                        committed += batch.count
                    } else {
                        try await execute(ops[committed])
                        committed += 1
                    }
                } catch {
                    lastError = error
                    break   // leave this op and the rest for the next attempt
                }
            }
            if committed > 0 {
                do { try rewrite(Array(try readOps().dropFirst(committed))) }
                catch { storageFailed(error); lastError = error; break }
                total += committed
                stall = 0
            }
            if cachedCount == 0 { break }          // fully drained
            if Date() >= deadline { break }        // out of budget
            if committed == 0 {                    // no progress (offline / cold connect): back off
                if stall >= backoff.count { break }
                await sleep(backoff[stall])
                stall += 1
                if Date() >= deadline { break }
            }
            // committed > 0 with ops remaining (executor threw partway): retry
            // the remainder immediately — likely a transient cold connection.
        }
        return DrainResult(committed: total, lastError: lastError)
    }

    public func clear() {
        guard !isDraining else { storageFailed(PolicyError.drainInProgress); return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            cachedCount = 0
            unsaved = []
            lastStorageError = nil
        } catch { storageFailed(error) }
    }
}
