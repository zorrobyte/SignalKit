# DurableSync API reference

Import `DurableSync`. All queue and diagnostic operations run on the main actor. `withTimeout` is concurrency-safe and is not main-actor isolated. There are no network or account dependencies.

## DurableWriteLog<Operation>

`Operation` must conform to `Codable & Equatable`. Each value is one JSON line. Equality validates compaction/batch policy results; it is not a backend idempotency key. Include your own stable operation ID in the payload if the receiving API needs one.

### Initialization and policies

| Parameter | Default | Contract |
| --- | --- | --- |
| `storageURL` | Required | A file URL, owned by exactly one queue instance/process at a time |
| `maxOps` | 25,000 | Positive soft capacity; only explicitly droppable operations can be evicted |
| `capSlack` | max(500, maxOps / 20) | Nonnegative headroom; compaction begins above capacity plus headroom |
| `isDroppable` | Always false | Return true only for observations the host permits losing under pressure |
| `compact` | Identity | Return an order-preserving subsequence, removing expired or superseded values only |
| `batch` | One operation | Return a nonempty contiguous prefix at the supplied snapshot index |
| `log` | No-op | Optional local diagnostic sink; never inherently a server logger |
| `onStorageError` | No-op | Receives an error description, or nil after a successful append recovery |
| `beforeIO` | No-op | Fault-injection/instrumentation hook before `read`, `append`, and `rewrite`; throwing fails that operation |

The parent directory is created on append. A queue can be initialized while storage is unavailable; initialization itself does not assert successful persistence. Observe `lastStorageError` and the return from enqueue. Do not point multiple writers at the same file, even when they share an App Group.

### Writing and inspection

| Member | Result and behavior |
| --- | --- |
| `enqueue(_:)` | Appends one operation to the in-memory unsaved buffer, attempts persistence, and returns whether it became durable |
| `enqueue(contentsOf:)` | Enqueues an ordered collection; a partial append failure preserves the remaining unsaved tail |
| `flushUnsaved()` | Retries unsaved operations in FIFO order; does not contact a backend |
| `load()` | Returns all decoded durable operations; on corruption/unreadability returns an empty array **and sets an error**, never a partial prefix |
| `pendingCount` | Durable cached count plus unsaved memory count; read failure is represented separately, not as proof of an empty queue |
| `unsavedCount` | Operations held only in this process; may be lost on termination if storage remains unavailable |
| `lastStorageError` | Most recent storage/policy failure description, or nil after successful storage work |
| `clear()` | Deletes the file and unsaved buffer while idle; rejected during an active drain; not a server deletion |

Do not discard a queue instance with unsaved work and present the operation as saved. Keep it alive, surface the failure, and retry. File protection is complete-until-first-user-authentication. The outbox contains host payloads in clear serialized form inside the protected app container; it is not an app-level encryption facility.

### Drain methods

`drain(maxOps:execute:)` performs one pass, defaulting to at most 150 operations. It checks cancellation before each operation and stops on the first thrown error. Successful operations are acknowledged by atomically rewriting the remaining durable tail. Values appended while the executor is suspended survive the acknowledgement rewrite.

`drainAll(budget:backoff:sleep:executeBatch:execute:)` streams snapshots until empty, its time budget expires, cancellation arrives, or retry opportunities are exhausted. Defaults are a ten-second between-operation budget and no-progress delays of 1.5, 3, and 5 seconds. Supply a no-op `sleep` in deterministic tests, not in a production offline retry loop. If `executeBatch` is present, the batch policy decides transaction boundaries; the per-operation executor is not used for those batches.

Both methods return `DrainResult`:

- `committed`: operations durably acknowledged locally, not a count of every possible server-side side effect.
- `lastError`: the execution/storage/cancellation error that stopped progress, if any. A budget-limited pass can leave work pending without an error.

A second concurrent low-level drain returns zero without starting another executor. The host should own/coalesce drain tasks when multiple callers need to await the same work. Never call `clear()` to interrupt an upload.

`PolicyError.invalidCompaction` rejects mutation/reordering/insertion by a compaction policy. `invalidBatch` rejects empty, oversized, reordered, or substituted batch values. `drainInProgress` rejects destructive clear during a drain. These errors leave the original durable records intact.

### Replay contract

1. Persist before attempting transport.
2. Await transport acknowledgement.
3. Atomically remove acknowledged records.

A crash between steps 2 and 3, or a failed acknowledgement rewrite, replays an already-sent value. Use idempotent server operations and monotonic revisions where older values must not replace newer ones. Do not use this queue for irreversible non-idempotent actions without a receiving-side idempotency protocol.

## DiagnosticSink

`DiagnosticLog` takes its handler at initialization, but a host's sink is usually
its own composition root, which does not exist while the coordinators that need
the log are still being constructed. `DiagnosticSink` breaks that cycle: hold one,
pass `sink.log` into the coordinators, then set `sink.handler` once `self` exists.
The log holds the sink weakly and a nil handler discards events, so events recorded
before the host attaches are dropped rather than buffered.

## DiagnosticLog

`DiagnosticLog.init(_:)` accepts a `(String, String) -> Void` handler. `record(_:_: )` invokes it on the main actor. The default handler discards both arguments. Keep sinks fast and privacy-aware; do not synchronously perform networking in them. Queue errors must still be surfaced through status even when logging is disabled.

## withTimeout and TimeoutError

`withTimeout(_:operation:)` races a Sendable async throwing operation against a timer. It returns the operation's value, propagates its error, throws `TimeoutError` when the timer wins, or throws `CancellationError` when the parent wait is cancelled. The timeout is a wait boundary, not proof that a remote action was cancelled.

The implementation deliberately does not use a task group whose scope waits for a non-cooperative child. It cancels losing tasks after selecting one completion. A callback or server request that ignores cancellation can still finish later, so repeated calls must remain safe. `TimeoutError.description` is `operation timed out`.

## Testing and migration

`DurableSyncTests` covers FIFO/partial acknowledgement, concurrent appends, corruption, torn writes, out-of-space recovery, acknowledgement failure, retry bounds, batching, eviction, policy validation, cancellation, and non-cooperative callbacks. See [testing evidence](../Testing.md) for coverage and platform exclusions.

For a payload schema change, retain decoders for old operations or implement an explicit migration before switching the writer. Do not change the queue URL until the old queue has drained or been safely migrated. See [migration guidance](../Migration.md).
