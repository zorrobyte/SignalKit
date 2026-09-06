import DurableSync
import Foundation
import Testing
@testable import HealthSync

@MainActor struct HealthPipelineTests {
    func total(_ id: String, value: Double = 1, timestamp: Double = 1, date: String? = nil) -> HealthAggregate {
        .init(date: date ?? HealthWindow().dateKey(Date()), type: id, value: value, unit: "count", recordedAt: timestamp)
    }
    @Test func batchingCompactionExpiryAndReplay() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let u = HealthUploads(), status = HealthSyncStatus(defaults: f.defaults)
        let url = f.url.appendingPathComponent("queue")
        func make() -> HealthUploadPipeline {
            HealthUploadPipeline(url: url, window: HealthWindow(), status: status, log: DiagnosticLog(),
                retryBackoff: [], uploadBatch: { try await u.send($0) })
        }
        let first = make(); defer { first.cancelRetry() }
        #expect(first.enqueue((0..<100).map { total("metric\($0)") }))
        #expect(first.enqueue([total("metric0", value: 2, timestamp: 2), total("expired", date: "2000-01-01")]))
        await u.setFailure(URLError(.notConnectedToInternet))
        var requested = 0; first.requestBackgroundWork = { requested += 1 }
        await first.drain()
        #expect(first.pendingCount == 100 && status.lastError != nil && requested == 1)
        first.cancelRetry()
        await u.setFailure(nil)
        let reopened = make(); defer { reopened.cancelRetry() }
        await reopened.drain()
        #expect(await u.batches.map(\.count) == [49, 49, 2])
        #expect(await u.all().last?.value == 2)
        #expect(status.lastError == nil && status.lastHealthUploadAt != nil)
        #expect(reopened.pendingCount == 0)
    }
    @Test func outOfSpaceIsVisibleAndRecoveryDoesNotLoseRecords() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let u = HealthUploads(), status = HealthSyncStatus(defaults: f.defaults)
        var fail = true
        let queue = HealthUploadPipeline(url: f.url.appendingPathComponent("queue"), window: HealthWindow(),
            status: status, log: DiagnosticLog(), retryBackoff: [], beforeIO: { op in
                if fail && op == "append" { throw CocoaError(.fileWriteOutOfSpace) }
            }, uploadBatch: { try await u.send($0) })
        defer { queue.cancelRetry() }
        #expect(!queue.enqueue([total("a")]))
        #expect(queue.pendingCount == 1 && queue.storageError != nil)
        #expect(status.lastError?.hasPrefix("Storage:") == true)
        fail = false
        await queue.drain()
        #expect(queue.pendingCount == 0 && queue.storageError == nil)
        #expect(status.lastError == nil)
        #expect(await u.all().map(\.type) == ["a"])
    }
    @Test func statusPersistsSuccessButNotTransientErrors() throws {
        let f = try HealthFixture(); defer { f.clean() }
        let status = HealthSyncStatus(defaults: f.defaults), now = Date()
        status.lastHealthReadAt = now; status.lastHealthUploadAt = now
        status.recordError("Health: failed")
        status.clearError(matchingPrefix: "Upload:")
        #expect(status.lastError != nil)
        let reopened = HealthSyncStatus(defaults: f.defaults)
        #expect(reopened.lastHealthReadAt == now && reopened.lastHealthUploadAt == now)
        #expect(reopened.lastError == nil)
        status.clearError(matchingPrefix: "Health:")
        #expect(status.lastError == nil)
    }
}
