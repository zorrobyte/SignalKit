# Lifecycle, failure handling, and host responsibilities

## Keep ownership explicit

Create retained services in the host composition root, not in a view's body. Choose an account-specific persistent directory and defaults suite before collection starts. Supply bounded, idempotent upload functions and connect observable status to a technical status view. Libraries never obtain a backend account ID for you.

| Trigger | ActivityTracking | HealthSync | Host |
| --- | --- | --- | --- |
| Process launch | Construct coordinator early; bootstrap once | Construct coordinator; register observers | Register background task handler before launch finishes |
| User permission action | Request staged location/precise access | Request the explicit selected read set | Explain why each permission is needed |
| Foreground | Reconcile/present current state; opportunity to flush | Reconcile current window; opportunity to drain | Retry network transport and update status |
| Sensor/observer event | Persist observations through output | Persist changed totals before observer completion | Do not block local recording on authentication/network |
| Network recovery | Flush durable output | Drain health outbox | Trigger both independently |
| Background task | Bounded replay of durable output | Reconcile, then drain | Set expiration handler and finish exactly once |
| Account change | Stop accepting old identity's input and settle old work | Stop observers/retries; preserve old directory | Never rebind an old queue to the new account's uploader |

CoreLocation has process-wide/scheduling constraints and the tracker is designed as one process-lifetime service. HealthSync.stop cancels registered observers/retries and cooperative work; a native callback or submitted server operation can still complete. Hosts needing account switching should design an explicit drain/quarantine-and-recreate boundary, rather than just changing a global user ID.

`ActivityTracker` owns this wiring for location: `bootstrap()` at launch,
`onForeground()` on foreground entry, `drainUploads()` on network recovery and in
a BGProcessing handler, and `stop()` to halt observation and retries while
preserving durable events. Retain it for the process lifetime. Assign presentation
callbacks on the tracker rather than on `tracker.location`, which it wires to
drive the outbox. `HealthSyncCoordinator` is the same shape for health.

## Permission states are not equivalent

Location exposes permission and accuracy states. HealthKit exposes platform availability and authorization-request completion, but not a per-type read-denial flag. An empty HealthKit result must not be presented as proof that the person has zero steps/sleep/etc., or as proof that they denied access. The catalog is a list of supported type APIs, not a list of records the person has.

The host must configure Info.plist purpose strings and signing entitlements. A Swift package cannot add those capabilities to the final app. Missing required host configuration may cause native framework exceptions, not a recoverable Swift error. Complete setup before calling native permission or monitoring methods.

## Failure matrix

| Failure | Library response | Host action |
| --- | --- | --- |
| Offline / server unavailable | Keep durable records, return upload error, retry later | Show pending count; retry on reconnect/background opportunity |
| Authentication missing | Host uploader throws; local collection remains independent | Resolve identity before draining, never discard the queue |
| Disk full / protected storage unavailable | Preserve unsaved buffer, report storage error, do not advance checkpoint | Keep instance alive; warn that memory-only work is not durable; retry storage |
| Torn/corrupt JSONL | Fail closed without executing/rewriting a decoded prefix | Preserve file for recovery; do not call clear as an automatic fix |
| Upload succeeds, acknowledgement rewrite fails | Replay may occur | Server must deduplicate/idempotently upsert |
| Batch timeout | Return without waiting forever; retain unacknowledged work | Expect a possible late server success; retries must remain safe |
| Health database locked | Stop the read pass; retry after unlock/foreground | Display locked status; do not repeatedly request permissions |
| Empty visible Health data | No overwrite without explicit known deletion evidence | Render absence honestly; keep prior server totals |
| Partial change page | Persist cursor/footprints and continue bounded paging | Present catching-up status; don't call partial indexing complete |
| Invalid batch/compaction policy | Reject before acknowledging a different payload | Fix host policy; original durable queue remains intact |
| Background expiration | Cooperative work can cancel; durable records remain | Complete the OS task once; schedule another opportunity |

A host that omits the `location` background mode is a distinct, silent case:
`CoreLocationDriver` refuses to enable background updates rather than letting
CoreLocation terminate the process, and `LocationCoordinator.backgroundUpdatesAvailable`
reports false. Collection then works only in the foreground. Surface that flag in a
diagnostics screen; no permission prompt or runtime error will reveal it.

## Operational guidance

Expose pending operations and storage errors separately from “last upload.” A timestamp only proves a previous success. Avoid one green status derived from “no latest exception” when unsaved writes or pending reconciliation remain. Disable server log mirroring by default; injected diagnostics may include private coordinates or error context.

Do not assume the ten-second drain budget can preempt arbitrary blocking native/FFI work. Budgets are checked between operations, and the timeout helper bounds the wait around the host upload. Long-lived non-cooperative operations can still use resources after the caller stops awaiting them.

## Device validation is a separate gate

Simulator suites drive real package algorithms with fake sensor/query/transport inputs. They validate state, persistence, ordering, and recovery. They do not validate actual Health records, the locked Health database, significant location changes, battery use, location accuracy, Always-permission escalation on a real phone, force-quit behavior, or real suspended/terminated wakes. Follow the [device checklist](Testing.md#physical-device-release-validation-still-required) before promising those behaviors in an app.
