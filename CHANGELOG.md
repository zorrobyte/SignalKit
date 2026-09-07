# Changelog

## 0.5.0

- Add `ActivityTracker`: the whole location stack behind one retained object — motion, location, the outing state machine, a durable outbox, and replay. Construct it with a storage directory, a defaults store, and an idempotent uploader; `bootstrap()`, `onForeground()`, `drainUploads()`, and `stop()` are the lifecycle. This is the `ActivityTracking` counterpart of `HealthSyncCoordinator`; hosts no longer hand-roll a write-ahead log to use the module.
- Add `DurableTrackingOutput`, a ready-to-use `TrackingOutput` over `DurableWriteLog`, and `TrackingEvent` with a closed `Kind` vocabulary and a device-generated `id` for server-side dedupe. It owns droppability (samples yes, lifecycle never), batching, a per-batch timeout, retry with backoff, and opportunistic-flush rate limiting — policies every host previously reimplemented.
- `DurableTrackingOutput.Configuration` exposes `maxOps`, `capSlack`, `batchSize`, `uploadTimeout`, `retryBackoff`, `retryDelay`, `minimumFlushInterval`, and opt-in `compactsDistanceUpdates` (off by default: it is only correct for a backend with set semantics).
- `CoreLocationDriver` no longer terminates a host that omits the `location` background mode. Setting `allowsBackgroundLocationUpdates` there raises an uncatchable Objective-C exception; the driver now declines the write, and `LocationCoordinator.backgroundUpdatesAvailable` reports what the platform accepted. Hosts that declare the mode are unaffected.
- Add `DiagnosticSink` to `DurableSync`, whose handler can be attached after construction, so a host can pass a log into coordinators it is still initializing.
- Replace `Examples/OfflineTrackingOutput.swift` — the adapter hosts used to copy — with `Examples/TrackingConfiguration.swift`, the one-call setup. `TrackingEvent` now ships in `ActivityTracking` rather than the examples target.

## 0.4.0

- Add `TrackingMode`: `.homeAnchored` (default, unchanged behavior) or `.roaming(restThreshold:)` for users without a fixed home. Roaming outings start on vehicle motion, a fast fix, or leaving the rest fence, and end once a stop lasts the threshold; that stop becomes the base for the next outing.
- `LocationCoordinator.init` and `ActivityEngine.init`/`live` take `mode:`; `setTrackingMode(_:)`/`Event.setMode` switch at runtime; `refreshTrackingState()`/`Event.tick` re-evaluate the rest threshold; `anchorCoordinate`/`ActivityEngine.anchor` expose the measuring point.
- `EngineState` gains optional `baseLat`/`baseLng`; `startOuting` may receive a nil home in roaming mode; new outing `source` value `roaming`.

## 0.3.0

- Compile cleanly in the Swift 6 language mode with complete concurrency checking; CI now enforces this.
- `DurableWriteLog` executor closures are `@MainActor` (the log already runs there) and `DrainResult` is `Sendable`.
- `HealthObserving.observe` takes a `@Sendable` change handler whose completion closure is `@Sendable`; `HealthMetric` read closures run on the main actor.
- Public value types (`EngineState`, `SamplingDecision`, `MotionObservation`, `HomeLocation`, `HealthWindow`, `TypeAggregate`, `DiagnosticLog`) are `Sendable`; `DiagnosticLog` handlers are `@Sendable @MainActor`, matching `record`.
- `LocationCoordinator` observable mirrors are read-only; add `setHome(_:)` for host-supplied homes.
- `HealthChangeJournal.Cursor` and `.State` are internal persistence types.
- Document the backend string vocabulary, fixed thresholds, and persisted file layouts; the catalog generator finds the SDK itself and accepts `--write`.

## 0.2.0

- Initial public release of ActivityTracking, HealthSync, and DurableSync.
- Inject backend, storage, diagnostics, and presentation hooks.
- Add SDK-derived HealthKit catalog, configurable numeric metrics, native sample/change readers, and specialized-query access.
- Preserve seven-calendar-day default, deletion-safe reconciliation, durable value checkpoints, and bounded batched replay.
- Add 73 simulator tests spanning every module and compiled integration examples.
- Add injectable native drivers, API/lifecycle/migration references, coverage gates, and a public-source audit.
- Handle confirmed empty deletions when HealthKit returns its no-data error; coalesce concurrent health drains.
