# SignalKit

Reusable, backend-independent Swift libraries for iOS 17+ collection and durable upload. Build with Xcode 26.5 or newer for the current HealthKit catalog; deployment remains iOS 17+.

| Product | Owns | Does not own |
| --- | --- | --- |
| `ActivityTracking` | CoreLocation, CoreMotion, home/dwell geofences, outing/segment state machine, state persistence | Identity, server APIs, widgets, Live Activities, notifications |
| `HealthSync` | Configurable daily metrics, native HealthKit readers, type catalog, change reconciliation, durable health outbox | Your permission selection, backend schema, medical interpretation |
| `DurableSync` | Generic JSONL outbox, FIFO replay, bounded drains, optional compaction/batching, timeout helper | Domain events, networking, credentials |

There are no external package dependencies. Logging is opt-in through an injected `DiagnosticLog`; the default discards events. The package never uploads logs, carries credentials, or imports a backend SDK.

## Install

Add `https://github.com/zorrobyte/SignalKit.git` in Xcode's Package Dependencies, then select the products your app needs. Licensed under MIT.

```swift
.package(url: "https://github.com/zorrobyte/SignalKit.git", from: "0.3.0")
// In a target's dependencies:
.product(name: "HealthSync", package: "SignalKit")
```

For local development, add this checkout as an Xcode local package override. Do not copy library sources into a host app.

## Start with HealthSync

The host supplies storage, an explicit metric selection, and an idempotent batch uploader. Persist under Application Support or an App Group, not a temporary directory. Use one directory and one coordinator per account; pause/recreate collection before changing accounts.

```swift
import HealthKit
import HealthSync

@MainActor
func makeHealthSync(directory: URL, defaults: UserDefaults,
                    send: @escaping @Sendable ([HealthAggregate]) async throws -> Void)
    -> HealthSyncCoordinator {
    HealthSyncCoordinator(storageDirectory: directory, defaults: defaults, metrics: [
        .quantity(HKQuantityType(.stepCount), unit: .count(), id: "steps"),
        .quantity(HKQuantityType(.heartRate), unit: .count().unitDivided(by: .minute()),
                  id: "heart_rate", statistic: .average),
    ], window: HealthWindow(days: 7), uploadBatch: send)
}
```

Retain the instance for the process lifetime. Call `bootstrap()` at app launch, `requestAuthorization()` from a user action, and `syncRecent()` on foreground entry. Set `requestBackgroundWork` to your BGTask scheduling callback; call `drainUploads()` on network recovery and in your background handler. The observer completion waits for durable collection, not for a network upload.

`status`, `todayAggregates`, `pendingWrites`, and `storageError` are observable. An initializer storage failure is reported rather than crashing the app. Never describe an in-memory pending write as durably saved.

See [HealthKit coverage and configuration](Documentation/HealthKit.md), [location integration](Documentation/ActivityTracking.md), [durability contract](Documentation/DurableSync.md), and [testing and releases](Documentation/Development.md).

## Reference and examples

- API contracts: [ActivityTracking](Documentation/API/ActivityTracking.md), [HealthSync](Documentation/API/HealthSync.md), [DurableSync](Documentation/API/DurableSync.md).
- Integration: [lifecycle and failure handling](Documentation/Lifecycle.md), [storage and migration](Documentation/Migration.md).
- Compiled examples: [offline tracking output](Examples/OfflineTrackingOutput.swift), [health configuration](Examples/HealthConfiguration.swift).
- Verification: [test matrix, coverage, and device limitations](Documentation/Testing.md).

## Limits worth knowing

- A catalog type being supported does not prove data exists or read permission was granted. Apple intentionally hides read-denial status.
- Not every HealthKit object is a daily number. The native reader preserves sample subclasses; characteristics, clinical documents, ECG waveforms, routes, medication concepts, and other specialized objects use Apple's specialized APIs through `reader.store`. Your host defines their export representation.
- Daily summaries default to seven **calendar** days including today, not a rolling 168 hours. The package can configure another window.
- Delivery is at least once. Backend operations must be idempotent. A lost acknowledgement or a process crash can replay records.
- The simulator verifies compilation, state transitions, queue failure/replay, and UI. It does not prove real sensor collection, locked-device behavior, or suspended/terminated delivery.

See [LICENSE](LICENSE), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
