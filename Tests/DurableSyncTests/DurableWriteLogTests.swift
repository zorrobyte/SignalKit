import Foundation
import Testing
@testable import DurableSync

@MainActor struct DurableWriteLogTests {
    @Test func invalidBatchCannotAcknowledgeData() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DurableWriteLog<Int>(storageURL: url, batch: { _, _ in [99] })
        queue.enqueue(contentsOf: [1, 2])
        var called = false
        let result = await queue.drainAll(backoff: [], executeBatch: { _ in called = true }) { _ in }
        #expect(!called)
        #expect(result.lastError != nil)
        #expect(queue.load() == [1, 2])
    }
    @Test func invalidCompactionCannotRewriteData() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DurableWriteLog<Int>(storageURL: url, compact: { $0.reversed() })
        queue.enqueue(contentsOf: [1, 2])
        let result = await queue.drain { _ in }
        #expect(result.lastError != nil)
        #expect(queue.load() == [1, 2])
    }
    @Test func replayAfterFailure() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DurableWriteLog<Int>(storageURL: url)
        #expect(queue.enqueue(contentsOf: [1, 2]))
        let failed = await queue.drain { _ in throw URLError(.notConnectedToInternet) }
        #expect(failed.committed == 0)
        let reopened = DurableWriteLog<Int>(storageURL: url)
        #expect(reopened.load() == [1, 2])
        let success = await reopened.drain { _ in }
        #expect(success.committed == 2)
        #expect(reopened.pendingCount == 0)
    }
}
