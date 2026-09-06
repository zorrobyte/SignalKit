import Foundation
import Testing
@testable import DurableSync

// withTimeout is the backstop that stops a hung mutation from wedging the WAL
// drain. These verify it throws on a hang and is transparent on a fast op.
@Suite
struct TimeoutTests {
    @Test("Parent cancellation interrupts the wait")
    func parentCancellation() async {
        let task = Task { try await withTimeout(30) { try await Task.sleep(for: .seconds(30)); return 1 } }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation should throw") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test("Timeout returns even when a callback ignores task cancellation")
    func nonCooperativeTimeout() async {
        let completionOrder = CompletionGate()
        do {
            _ = try await withTimeout(0.05) { () -> Int in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        _ = completionOrder.claim()
                        continuation.resume(returning: 1)
                    }
                }
            }
            Issue.record("Expected timeout")
        } catch is TimeoutError {
            // Test ordering, not a simulator scheduling deadline. A task-group
            // implementation would wait for the callback and lose this claim.
            #expect(completionOrder.claim())
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("A hung operation throws TimeoutError instead of blocking forever")
    func hungOperationTimesOut() async {
        do {
            _ = try await withTimeout(0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)   // 5s — far past the timeout
                return 1
            }
            Issue.record("expected withTimeout to throw")
        } catch is TimeoutError {
            // expected
        } catch {
            Issue.record("expected TimeoutError, got \(error)")
        }
    }

    @Test("A fast operation returns its value transparently")
    func fastOperationReturns() async throws {
        let v = try await withTimeout(5) { () -> Int in 42 }
        #expect(v == 42)
    }

    @Test("A throwing operation propagates its own error (not a timeout)")
    func throwingOperationPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(5) { () -> Int in throw Boom() }
            Issue.record("expected the operation's error")
        } catch is Boom {
            // expected — real failures still surface so the WAL leaves the op
        } catch {
            Issue.record("expected Boom, got \(error)")
        }
    }
}



// BGTask expiration and normal completion may race on different queues.
nonisolated final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
