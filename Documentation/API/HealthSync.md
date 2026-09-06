# HealthSync API reference

Import `HealthSync` and `HealthKit`. Readers, metrics, coordinators, journals, and status are main-actor isolated. Native HealthKit callbacks are bridged to async results; observer callbacks return to the main actor before reconciliation. The host owns entitlements, consent, identity, schema, and transport.

## HealthSyncCoordinator

### Initialization

| Parameter | Default / contract |
| --- | --- |
| `storageDirectory` | Required persistent directory, isolated per account and metric/checkpoint namespace |
| `defaults` | Required preference store; success timestamps and authorization-request history are kept here |
| `metrics` | Required explicit array of `HealthMetric`; IDs must be unique |
| `window` | `HealthWindow(days: 7)`, including today |
| `store` | New HKHealthStore, used by the default reader |
| `log` | No-op local diagnostic sink |
| `reader` | Optional `HealthReading`; defaults to `HealthDataReader(store:)` |
| `observation` | Optional `HealthObserving`; defaults to HealthKitObservation using the selected reader's store |
| `uploadBatch` | Required Sendable async throwing closure receiving `[HealthAggregate]`; return only after server acknowledgement |

Directory creation errors become observable storage errors rather than a process crash. Construct one coordinator per directory. Never share a directory between independently running coordinators, accounts, or extensions. Retain the instance and wire background scheduling/network recovery in the host.

### Lifecycle and commands

| Member | Behavior |
| --- | --- |
| `bootstrap()` | Register observers for selected sample types and request hourly background delivery; repeated calls do not duplicate active observers |
| `requestAuthorization()` | Ask for exactly the union of metric read types; after completion, renew observers and reconcile the configured window |
| `syncRecent(days:reconcile:)` | Capture changes, refresh up to the configured calendar window, queue changed totals durably, and acknowledge corrected dates |
| `syncToday()` | Convenience call requesting the current calendar day |
| `drainUploads()` | Await the active/coalesced upload pass; does not read HealthKit |
| `stop()` | Stop observers and scheduled retries, cancel active work where cooperative, and preserve durable files for replay |
| `isAvailable` | Platform HealthKit availability, not data availability or read permission |

`syncRecent` defaults to the whole configured window and reconciliation enabled. `days` is clamped to 1...window.days. Concurrent calls share the active task; additional requested reconciliation can schedule a continuation. Cancellation is checked between units of work. Native queries already in flight may still deliver a callback. `stop()` does not delete data or undo a submitted server transaction. It is not an account-deletion API.

The observer completion runs after local reconciliation work, including error paths, without waiting for network success. A host BGProcessing handler should await both collection and `drainUploads()`, check pending/error status, and end its task exactly once. On network recovery, call `drainUploads()`; do not require another HealthKit permission request just to send already-durable values.

### State and callbacks

`todayAggregates` contains successful current-day `TypeAggregate` values: `id`, `label`, `value`, and `unit`. These values are display input, not proof of server acknowledgement. `lastSyncAt` and `lastUploadedAt` reflect their respective persisted success timestamps. `lastError` reports the last read failure. `pendingWrites` includes durable and unsaved outbox entries; `storageError` must be checked independently.

`status` is an observable `HealthSyncStatus`:

- `healthReading`, `uploading`: in-progress indicators.
- `healthBackgroundEnabledTypes`: count of successful background-delivery registrations for the current observer generation.
- `pendingHealthDays`: calendar dates awaiting reconciliation.
- `healthHistoryCatchingUp`: whether selected type cursors still have pages to inspect.
- `lastHealthReadAt`, `lastHealthUploadAt`: persisted success timestamps.
- `lastError`: transient read/upload/storage/background-registration failure.

`recordError(_:)` sets the transient error. `clearError(matchingPrefix:)` clears only the matching category, avoiding unrelated error suppression. Persisted timestamp keys are `sync.healthRead` and `sync.healthUpload`; transient errors do not survive a new status instance.

`onTodayChanged` receives refreshed current-day totals, `onReadCompleted` signals a successful pass, `onError` receives a read error message, and `requestBackgroundWork` asks the host to schedule a future background opportunity. All callbacks are optional and main-actor isolated. Do not synchronously perform network uploads in these callbacks.

## HealthMetric

A metric defines stable `id`, display `label`, output `unit`, selected `sampleTypes`, unioned `readTypes`, optional deletion type, and an async read closure. The closure accepts `any HealthReading` and a DateInterval and returns `Double?`.

`quantity(_:unit:id:label:unitLabel:statistic:)` accepts any supported quantity type and compatible HKUnit. Defaults use the native type identifier for ID/label and the unit's unitString. Statistics are `automatic`, `sum`, `average`, `minimum`, or `maximum`. Automatic means cumulative sum for cumulative quantities and discrete average otherwise. Invalid unit/statistic combinations throw `HealthReadError` before querying.

`categoryDuration(_:values:id:label:)` reads overlapping category samples, optionally filters numeric category values, clips to the requested day, merges overlapping intervals, and returns minutes. Empty/zero-duration visibility returns nil. Use it for actual durations, not ordinal symptoms or event counts. Sleep requires an explicit selection of asleep values if awake/in-bed time should be excluded.

The custom initializer accepts `additionalReadTypes` for characteristic/specialized reads. Its closure can call native APIs through `reader.store`. Non-sample types do not become sample observers. A custom metric should return nil when no value is visible, and only return zero when zero is genuinely known. NaN and infinity are rejected by reconciliation.

`deletionType` is opt-in evidence for an empty-to-zero correction. The journal must have observed deletion of **every known sample of that type for the date**, and the type must be caught up. It does not infer deletion from denied access, an unknown UUID, or a partial page. If metric semantics cannot be represented by that rule, leave the deletion type unset and implement explicit host corrections.

## HealthDataReader / HealthReading

`HealthDataReader(store:)` is the native implementation of `HealthReading`. `store` remains public for specialized APIs and per-object authorization flows. The protocol allows tests or alternate recorded sources to implement the same query contract without changing coordinator logic.

| Method | Native semantics |
| --- | --- |
| `requestAuthorization(read:)` | Read-only bulk request; rejects types requiring per-object authorization; no HealthKit writes |
| `samples(type:interval:strictStart:limit:)` | Native sample subclasses sorted ascending by start date; default strictStart false and limit 10,000 on the concrete reader |
| `quantity(type:unit:statistic:interval:)` | Statistics query over strict-start samples in the interval; returns the selected statistic in the requested compatible unit |
| `changes(type:interval:anchor:limit:)` | Convenience bounded native change page with a fixed start/end predicate |
| `changes(type:start:end:anchor:limit:)` | Protocol method; optional end permits an open-ended fixed predicate for a rolling-window cursor |

The samples limit is not a completeness guarantee. `HKObjectQueryNoLimit` is accepted for intentionally bounded queries. Change-page limits must be positive and at most 10,000; default concrete convenience limit is 500. Keep a given anchor tied to the same sample type and predicate. Reusing an anchor after changing the predicate is not a valid migration.

`HealthChangePage` contains added native `samples`, deleted UUIDs in `deletedIDs`, the next native `anchor`, and `hasMore`. The latter is true when the page fills its requested limit, so query another page before declaring catch-up complete. Persist transformed additions/deletions to a durable outbox **before** saving the new anchor.

`HealthReadError` cases are `invalidValue`, `incompatibleUnit`, `unsupportedStatistic`, and `perObjectAuthorizationRequired`. Native query/authorization errors propagate too. Empty visibility is not a read-permission status. Read denial is intentionally opaque in Apple's APIs.

## HealthTypeCatalog

`available(includeClinicalRecords:additional:)` returns sorted, deduplicated `Entry` values for public SDK types supported by the running OS. Clinical entries default to excluded. `additional` accepts new native object types before the generated catalog has been refreshed.

Each Entry exposes `type`, `family`, `id`, optional `sampleType`, and `requiresPerObjectAuthorization`. Families are quantity, category, characteristic, correlation, document, clinical, workout, activity summary, audiogram, ECG, series, vision prescription, state of mind, assessment, medication, and custom.

Availability guards represent API support, not user permission, enabled devices, region eligibility, or visible records. The catalog does not request authorization or automatically upload all types. It is generated from public SDK identifiers, not private reflection. [Coverage and specialized queries](../HealthKit.md) explains types that do not fit daily numeric summaries.

## HealthWindow, HealthAggregate, HealthIntervals

`HealthWindow(days:)` accepts 1...365 calendar days, default seven. `start(now:calendar:)` returns local start-of-day for the oldest included date, using calendar arithmetic across DST. `dateKey(_:)` emits a Gregorian `yyyy-MM-dd` key in the current time zone. `contains(_:now:)` checks that a well-formed date key falls between oldest included day and today. Do not pass arbitrary unvalidated strings as server date keys.

`HealthAggregate` is Codable/Equatable/Sendable with `date`, `type`, finite numeric `value`, `unit`, and `recordedAt` in Unix milliseconds. The coordinator constructs it after reading each metric. Host uploads should upsert by account/date/type and use recordedAt to reject older replacements. Replayed values must be safe.

`HealthIntervals.minutes(_:within:)` clips intervals to the supplied window and returns the union's duration in minutes. This avoids double-counting overlapping sources/stages. Empty intersections and zero-duration ranges contribute zero.

## Low-level durable helpers

`HealthChangeJournal(url:)` stores anchors, UUID-to-date footprints, dirty dates, and deletion evidence atomically in one protected JSON file. Methods:

| Method | Purpose |
| --- | --- |
| `anchor(for:)` | Load the last durable cursor data for a type |
| `pendingDates()` | Sorted pending date keys |
| `hasMoreChanges()`, `isCaughtUp(type:)` | Inspect cursor completion |
| `prepareWindow(start:end:)` | Trim expired dates/footprints; reset anchors if the oldest date changed |
| `apply(type:anchor:added:deleted:caughtUp:)` | Atomically apply added Footprints, deleted IDs, cursor, and dirty/evidence updates |
| `canClearEmpty(type:date:)` | Require completed cursor plus explicit deletion evidence and no remaining known samples |
| `acknowledge(date:)` | Remove dirty/deletion evidence only after corrected values are durable |
| `revisitKnownDates()` | Re-mark known dates for refresh without inventing deletion evidence |

`HealthUploadCheckpoint(url:window:)` remembers `(value, unit)` by date/type, not just the last query time. `enqueueChanged(_:enqueue:)` filters expired dates, calls the durable-enqueue closure only for changed values, and writes its checkpoint only if enqueue succeeded. It returns the count queued. A failed checkpoint can cause duplicate replay; it must never suppress a value that failed to enter durable storage.

Coordinator filenames are `health-changes-v1.json`, `health-upload-checkpoint-v1.json`, and `health-uploads-v1.jsonl`. The outbox compacts to the newest recordedAt value per date/type, drops expired dates before sending, and batches at most 49 records. Simultaneous drain callers await the same upload task. A ten-second per-batch timeout and bounded retry pass protect the wait; later retries are requested while work remains.

See [lifecycle/error handling](../Lifecycle.md), [migration](../Migration.md), and [tests and device limitations](../Testing.md).
