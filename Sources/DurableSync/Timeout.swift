import Foundation

public struct TimeoutError: Error, CustomStringConvertible {
    public var description: String { "operation timed out" }
}

// A task group waits for cancelled children, so it cannot bound a blocked FFI
// call. Race unstructured tasks through a lock-protected single completion.
nonisolated private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
    func retain(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let finished = result != nil
        if !finished { self.tasks = tasks }
        lock.unlock()
        if finished { tasks.forEach { $0.cancel() } }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

public func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let worker = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(max(0, seconds)))
                    race.finish(.failure(TimeoutError()))
                } catch {}
            }
            race.retain([worker, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}
