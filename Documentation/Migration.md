# Versioning and data migration

## Public API versions

The first public release is 0.2.0. Before 1.0, minor versions may include explicitly documented API changes. Pin and test a released version in each host. Never move an existing public tag. Package versioning does not automatically migrate host payload schemas or server data.

The query boundary uses `HealthReading` and native `HealthChangePage` values with `deletedIDs`. A host using a custom metric receives `any HealthReading`, with native specialized access through `store`. If adapting an earlier prototype, replace a deleted-object projection with the returned UUID array and retain anchor-after-durable-payload ordering.

## Stored files and preferences

| Storage | Key / filename | Compatibility requirement |
| --- | --- | --- |
| Generic queue | Host-chosen JSONL URL | Preserve the host Operation decoder for queued older payloads |
| Engine state | `activityEngine.state.v2` | Maintain Codable compatibility and stable client identities |
| Home | `location.home.v1` | Degree coordinates, meter accuracy/radius, native epoch set-at value |
| Dense-GPS preference | `location.highAccuracyGPS.v1` | Boolean; changing it must not transform stored distances |
| Health change journal | `health-changes-v1.json` | Anchors, footprints, dirty dates, deletion evidence committed together |
| Health checkpoint | `health-upload-checkpoint-v1.json` | Date/type to value/unit; means durably queued, not merely read |
| Tracking outbox | `tracking-events-v1.jsonl` | Codable `TrackingEvent` values; the `id` is the server dedupe key and must survive a rewrite |
| Health outbox | `health-uploads-v1.jsonl` | Codable HealthAggregate values with Unix-millisecond recordedAt |
| Health status | `sync.healthRead`, `sync.healthUpload` | Success Date values in the supplied defaults |
| Health authorization flag | `health.authorizationRequested` | Boolean set once the host has requested HealthKit access; written for the host, never read by the package |

### Persisted layouts

| File | Layout |
| --- | --- |
| `activityEngine.state.v2` | JSON of `EngineState` with synthesized Codable keys matching its property names; dates are native `Date` encoding. `baseLat`/`baseLng` (roaming base) were added after 0.3.0 as optionals and decode as nil from older state |
| `location.home.v1` | Dictionary `lat`, `lng`, `accuracy`, `radius` (Double) and `setAt` (Unix seconds) |
| `health-changes-v1.json` | `windowStart` (`yyyy-MM-dd`), `cursors` keyed by type identifier with `anchor` (archived `HKQueryAnchor`), `samples` (date to sample UUID strings), `caughtUp`; `dirtyDates`; `deletionEvidence` as `type|date` strings |
| `health-upload-checkpoint-v1.json` | Dictionary keyed `date|type` with `value` and `unit` |
| `tracking-events-v1.jsonl` | One JSON `TrackingEvent` per line: `id` (UUID), `kind` (wire string), `fields`, optional `sample`, `recordedAt` (Unix milliseconds). `ActivityTracker` names the file; override with its `fileName` parameter |
| `health-uploads-v1.jsonl` | One JSON `HealthAggregate` per line: `date`, `type`, `value`, `unit`, `recordedAt` (Unix milliseconds) |

## Safe payload evolution

1. Add decoders for the old and new representations before writing the new form.
2. Keep old queued operations readable through the entire offline/retry horizon.
3. Upsert idempotently at the receiver, preserving client IDs and monotonic versions.
4. Remove old decoding only after an explicit supported-version/data migration decision.

Do not replace a failed decoder with “empty queue.” A queued lifecycle operation may be the only durable evidence that an outing or segment started. Preserve corrupt files and expose a repair path rather than silently discarding them.

## Changing Health configuration

Metric IDs are part of the checkpoint and backend identity. If the definition or unit meaning changes, use a new ID or explicitly invalidate/migrate that metric's checkpoint. Changing only a display label does not require resending unchanged values. Quantity unit changes produce a changed `(value, unit)` pair, but the host must still ensure server consumers understand the new unit.

Anchors belong to a fixed predicate. The coordinator resets them as the oldest included calendar day changes and retains recent sample UUID evidence. An arbitrary type/predicate/time-zone migration should reset/reconcile carefully; do not transplant a native anchor into a different query. Expired pending health dates are dropped from upload rather than backfilled.

## Changing account or storage location

Never relabel an existing outbox with another account ID. Quiesce collection, settle in-flight work, and either drain the old identity's queue or preserve it in that identity's quarantine directory. Create a fresh service, directory, and defaults suite for the new identity. If moving files, do so while the writer is idle and preserve their protection attributes. Verify pending counts and decodability before deleting any source copy.

No automatic server migrations or account-deletion workflow are included in SignalKit. Those belong to the host and must be tested against its authorization and retention model.

## Complete motion observations (unreleased)

Existing `MotionObservation` initializers compile unchanged; the added `unknown` argument defaults to false. Custom drivers should populate it when their source provides an explicit unknown flag. Existing motion-state precedence and `onChange` filtering are unchanged. Use `onObservation` for full-fidelity presentation events instead of replacing `onChange`, which may already be owned by a location coordinator. No persisted schema changes are introduced.
