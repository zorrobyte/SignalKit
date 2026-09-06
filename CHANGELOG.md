# Changelog

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
