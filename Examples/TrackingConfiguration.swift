import Foundation
import ActivityTracking

/// The whole location stack in one call: motion, location, the outing state
/// machine, a durable outbox, and replay. Retain the result for the process
/// lifetime, assign presentation callbacks on it, and call `bootstrap()` at
/// launch. Persist under Application Support or an App Group.
///
/// The uploader must be idempotent and must return only after the server has
/// acknowledged; delivery is at least once.
@MainActor public func makeActivityTracker(
    directory: URL, defaults: UserDefaults,
    send: @escaping @Sendable ([TrackingEvent]) async throws -> Void
) -> ActivityTracker {
    ActivityTracker(storageDirectory: directory, defaults: defaults, uploadBatch: send)
}
