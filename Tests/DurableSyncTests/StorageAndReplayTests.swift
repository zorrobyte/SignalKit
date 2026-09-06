import Foundation
import Testing
@testable import DurableSync

@MainActor struct StorageAndReplayTests {
    struct Record: Codable, Equatable { let id: Int; var expendable = false }
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func fifoPartialFailureAndPerPassLimit() async {
        let path = url(), queue = DurableWriteLog<Int>(storageURL: url())
        defer { queue.clear(); try? FileManager.default.removeItem(at: path) }
        queue.enqueue(contentsOf: [1, 2, 3, 4])
        var seen: [Int] = []
        let first = await queue.drain { value in
            if value == 3 { throw URLError(.notConnectedToInternet) }; seen.append(value)
        }
        #expect(first.committed == 2 && first.lastError != nil)
        #expect(queue.load() == [3, 4] && seen == [1, 2])
        #expect(await queue.drain(maxOps: 1) { seen.append($0) }.committed == 1)
        #expect(queue.load() == [4])
        #expect(await queue.drain { seen.append($0) }.committed == 1)
        #expect(seen == [1, 2, 3, 4])
    }
    @Test func enqueueDuringDrainAndConcurrentDrainCannotLoseTail() async {
        let queue = DurableWriteLog<Int>(storageURL: url()); defer { queue.clear() }
        queue.enqueue(contentsOf: [1, 2])
        let result = await queue.drain { value in
            if value == 1 {
                queue.enqueue(3)
                let nested = await queue.drain { _ in Issue.record("Concurrent drain must not run") }
                #expect(nested.committed == 0)
            }
        }
        #expect(result.committed == 2 && queue.load() == [3])
    }
    @Test func failedAppendRemainsUnsavedAndRetriesInOrder() async {
        let path = url(); var fail = true
        let queue = DurableWriteLog<Int>(storageURL: path, beforeIO: { op in
            if fail && op == "append" { throw CocoaError(.fileWriteOutOfSpace) }
        }); defer { queue.clear() }
        #expect(!queue.enqueue(1)); #expect(!queue.enqueue(2))
        #expect(queue.unsavedCount == 2 && queue.pendingCount == 2 && queue.lastStorageError != nil)
        #expect(DurableWriteLog<Int>(storageURL: path).load().isEmpty)
        fail = false; #expect(queue.flushUnsaved())
        #expect(queue.unsavedCount == 0 && queue.lastStorageError == nil)
        #expect(DurableWriteLog<Int>(storageURL: path).load() == [1, 2])
    }
    @Test func acknowledgementRewriteFailureReplaysButDoesNotErase() async {
        let path = url(); var fail = false
        let queue = DurableWriteLog<Int>(storageURL: path, beforeIO: { op in
            if fail && op == "rewrite" { throw CocoaError(.fileWriteOutOfSpace) }
        }); defer { queue.clear() }
        queue.enqueue(1); fail = true
        let result = await queue.drain { _ in }
        #expect(result.committed == 0 && result.lastError != nil)
        #expect(DurableWriteLog<Int>(storageURL: path).load() == [1])
        fail = false
        #expect(await queue.drain { _ in }.committed == 1)
    }
    @Test func readFailureCannotExecuteOrAcknowledge() async {
        let path = url(); var fail = false
        let queue = DurableWriteLog<Int>(storageURL: path, beforeIO: { op in
            if fail && op == "read" { throw CocoaError(.fileReadNoPermission) }
        }); defer { queue.clear() }
        queue.enqueue(1); fail = true
        let result = await queue.drain { _ in Issue.record("Unreadable queue must not execute") }
        #expect(result.lastError != nil && result.committed == 0 && queue.pendingCount == 1)
        #expect(DurableWriteLog<Int>(storageURL: path).load() == [1])
    }
    @Test(arguments: ["1\n{broken}\n", "1\n2", "{}\n"])
    func corruptOrTornFilesFailClosed(_ contents: String) async throws {
        let path = url(); try Data(contents.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let queue = DurableWriteLog<Int>(storageURL: path)
        let result = await queue.drain { _ in Issue.record("Corruption must not execute a partial prefix") }
        #expect(result.lastError != nil)
        #expect(!queue.enqueue(3) && queue.unsavedCount == 1)
        #expect(try String(contentsOf: path) == contents)
    }
    @Test func capDropsOnlyOldestExpendableRecordsAndIsSoftForStructure() {
        let queue = DurableWriteLog<Record>(storageURL: url(), maxOps: 3, capSlack: 0,
            isDroppable: { $0.expendable }); defer { queue.clear() }
        queue.enqueue(contentsOf: [.init(id: 1), .init(id: 2)])
        for id in 3...8 { queue.enqueue(.init(id: id, expendable: true)) }
        #expect(queue.load().map(\.id) == [1, 2, 8])
        queue.enqueue(contentsOf: [.init(id: 9), .init(id: 10)])
        #expect(queue.load().map(\.id) == [1, 2, 9, 10])
    }
    @Test func capSlackAmortizesCompactionAndPreservesNewestRecord() {
        var rewrites = 0
        let queue = DurableWriteLog<Record>(storageURL: url(), maxOps: 30, capSlack: 20,
            isDroppable: { $0.expendable }, beforeIO: { if $0 == "rewrite" { rewrites += 1 } })
        defer { queue.clear() }
        queue.enqueue(.init(id: 0))
        for id in 1...500 { queue.enqueue(.init(id: id, expendable: true)) }
        #expect(queue.pendingCount <= 50 && rewrites < 25)
        #expect(queue.load().first?.id == 0 && queue.load().last?.id == 500)
    }
    @Test func boundedRetriesRecoverOrLeaveIntact() async {
        let queue = DurableWriteLog<Int>(storageURL: url()); defer { queue.clear() }
        queue.enqueue(contentsOf: [1, 2]); var attempts = 0; var sleeps: [Double] = []
        let first = await queue.drainAll(backoff: [1, 2], sleep: { sleeps.append($0) }) { _ in
            attempts += 1; throw URLError(.notConnectedToInternet)
        }
        #expect(first.committed == 0 && attempts == 3 && sleeps == [1, 2])
        #expect(queue.load() == [1, 2])
        attempts = 0
        let recovered = await queue.drainAll(sleep: { _ in }) { _ in
            attempts += 1; if attempts <= 2 { throw URLError(.networkConnectionLost) }
        }
        #expect(recovered.committed == 2 && queue.pendingCount == 0)
    }
    @Test func batchingStreamsLargeLogAndIncludesConcurrentTail() async {
        let queue = DurableWriteLog<Int>(storageURL: url(), batch: { Array($0.dropFirst($1).prefix(100)) })
        defer { queue.clear() }
        queue.enqueue(contentsOf: Array(0..<1_000)); var batches: [[Int]] = []
        let result = await queue.drainAll(executeBatch: { batch in
            batches.append(batch); if batches.count == 1 { queue.enqueue(1_000) }
        }) { _ in Issue.record("Batch executor expected") }
        #expect(result.committed == 1_001 && batches.count == 11)
        #expect(batches.flatMap { $0 } == Array(0...1_000))
    }
    @Test func zeroBudgetAndCancellationLeaveUnsentWork() async {
        let queue = DurableWriteLog<Int>(storageURL: url()); defer { queue.clear() }
        queue.enqueue(contentsOf: [1, 2])
        #expect(await queue.drainAll(budget: 0) { _ in Issue.record("Expired budget") }.committed == 0)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.drainAll { _ in Issue.record("Cancelled drain") }
        }
        #expect(await task.value.lastError is CancellationError)
        #expect(queue.load() == [1, 2])
    }
    @Test func clearingActiveDrainCannotDeleteConcurrentWrites() async {
        let queue = DurableWriteLog<Int>(storageURL: url()); defer { queue.clear() }
        queue.enqueue(1)
        await queue.drain { _ in queue.clear(); queue.enqueue(2) }
        #expect(queue.load() == [2])
        queue.clear(); #expect(queue.pendingCount == 0)
    }
    @Test func diagnosticSinkIsOptionalAndReceivesLocalEvents() {
        DiagnosticLog().record("discarded")
        var events: [String] = []
        let log = DiagnosticLog { events.append($0 + ":" + $1) }
        log.record("test", "detail"); #expect(events == ["test:detail"])
    }
}
