# DurableSync contract

```swift
struct Upload: Codable, Equatable { let id: String; let value: Double }
let queue = DurableWriteLog<Upload>(storageURL: applicationSupportURL.appendingPathComponent("uploads.jsonl"))
let durable = queue.enqueue(Upload(id: "stable-id", value: 12))
let result = await queue.drain { operation in try await yourBackend.send(operation) }
```

Use the queue on the main actor, with a single owner per file. App and widget processes must not concurrently share a writer. The URL's parent is created when appending. Persistence uses JSONL, synchronized file appends, and atomic replacement with complete-until-first-authentication file protection. Payloads must decode across app upgrades; version/migrate your domain enum before breaking its Codable representation.

`enqueue` returning true means the write reached durable storage. False retains unsaved operations in memory and exposes `lastStorageError`/`unsavedCount`; these can be lost if the process exits before storage recovers. `flushUnsaved()` retries. `pendingCount` includes both durable and unsaved operations. Corrupt storage fails closed instead of rewriting a partially decoded queue.

`drain` removes only acknowledged operations. Appends during an awaited upload survive because acknowledgement reloads the current tail. `drainAll` streams a snapshot, retries no-progress passes with bounded backoff, and rewrites the remainder between passes. Cancellation stops at operation boundaries. The time budget is checked between operations; bound your network closure too. `withTimeout` bounds the wait, not a server-side transaction, so use idempotent operations.

Optional policies:

- `isDroppable`: allows discarding oldest expendable records under pressure. Default false. Lifecycle records should not be droppable. The cap is soft if non-droppable records alone exceed it.
- `compact`: removes superseded/expired operations before drain. It must return an order-preserving subsequence. Invalid transformations fail before modifying data.
- `batch`: returns a nonempty contiguous prefix starting at the supplied index. Invalid batches fail before execution. Keep dependent operations as barriers.
- `onStorageError` and `DiagnosticLog`: local host callbacks; default no-op.

An upload followed by an acknowledgement-write failure can replay. `DrainResult.committed` reports durable acknowledgement, not necessarily every server-side effect. Hosts must handle at-least-once semantics. `clear()` is explicit destructive local deletion for an idle queue; it is not a logout synchronization mechanism.
