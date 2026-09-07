# ActivityTracking API reference

Import `ActivityTracking`. Coordinators, the engine, driver interfaces, and backend callbacks are main-actor isolated. Native delegate entry points hop to that actor before state changes. Keep one retained tracker and one writer per tracking identity.

## ActivityTracker

The composed entry point: motion, location, engine, durable outbox, and replay
behind one retained object. Use it unless you need a different composition.

`init(storageDirectory:defaults:stateDefaults:mode:configuration:fileName:log:precisePurposeKey:locationDriver:motionDriver:uploadBatch:)`.
Only `storageDirectory`, `defaults`, and `uploadBatch` are required. `stateDefaults`
defaults to `defaults`; pass an App Group suite when extensions share the identity.
The directory is created if missing. `locationDriver`/`motionDriver` exist for
deterministic tests and recorded replay.

`uploadBatch` receives `[TrackingEvent]` and must return **only** after server
acknowledgement, throwing otherwise. Delivery is at least once, so it must be
idempotent; deduplicate on `TrackingEvent.id`.

| Member | Behavior |
| --- | --- |
| `bootstrap()` | Start motion observation, restore home monitoring and engine state, drain leftovers |
| `onForeground()` | Re-evaluate tracking state (recognizing a rest completed while suspended) and drain |
| `drainUploads()` | Await the active upload pass; ignores the flush interval |
| `stop()` | Stop motion and retries; durable events are preserved. Not an account-deletion API |
| `location`, `motion`, `output` | The composed pieces, for state and commands |
| `pendingUploads`, `lastUploadedAt`, `uploading`, `lastUploadError`, `storageError` | Observable upload state |
| `requestBackgroundWork` | Forwarded to the outbox; asks the host to schedule a background opportunity |

Forwarded commands: `requestAuthorization()`, `requestPreciseAccuracy()`,
`setHomeToCurrentLocation()`, `setHome(_:)`, `setTrackingMode(_:)`,
`startManualSession()`, `endCurrentOutingManually(note:)`, and `trackingMode`.

Host callbacks mirror `LocationCoordinator`'s names and signatures. **Assign them
on the tracker, not on `tracker.location`** — the tracker installs its own handlers
there to drive uploads, and replacing them stops the outbox from draining.
`onSnapshot` and `onWake` additionally trigger a rate-limited flush;
`onOutingCompleted` and `onOutingEnded` trigger an immediate drain.

## TrackingEvent

`Codable`/`Equatable`/`Sendable`/`Identifiable` with `id`, `kind`, `fields`,
optional `sample`, and `recordedAt` in Unix milliseconds. The `id` is generated on
device before any await, so it is stable across retries and process restarts:
it is the server's dedupe key. `recordedAt` is when the event was observed, not
when it was delivered; a replay can arrive much later.

`Kind` is a closed `String`-backed enum whose raw values are the wire strings:
`sample`, `home`, `session.start`, `outing.start`, `outing.end`, `outing.mode`,
`outing.record`, `outing.distance`, `segment.start`, `segment.end`, `place.upsert`,
`farthest`. `Kind.isDroppable` is true only for `sample`. `clientOutingId` reads
the outing from `fields` or the sample.

## DurableTrackingOutput

A ready-to-use `TrackingOutput` over `DurableWriteLog`. It owns what is a fact
about tracking rather than about an app: droppability, batch size, per-batch
timeout, and retry. The host owns transport and schema.

`init(storageURL:configuration:log:now:uploadBatch:)`. `now` is injectable for
tests. `Configuration` values:

| Field | Default | Meaning |
| --- | --- | --- |
| `maxOps` | 25,000 | Log cap; oldest samples trim past it, lifecycle events never do |
| `capSlack` | nil | Overshoot before trimming; nil means `max(500, maxOps/20)`, so a small `maxOps` does not trim promptly |
| `batchSize` | 25 | Events per upload call |
| `uploadTimeout` | 10s | Per-batch ceiling; a hung transport fails the pass, not the app |
| `retryBackoff` | 1.5, 3, 5 | Delays between no-progress passes inside one drain |
| `retryDelay` | 30s | Delay before a fresh drain while work remains; 0 disables |
| `minimumFlushInterval` | 15s | Spacing for opportunistic flushes; `drain()` ignores it |
| `compactsDistanceUpdates` | false | Collapse superseded `outing.distance`/`farthest` to the newest per outing. Enable **only** if the backend treats them as "set to", not "add" |

It conforms to `TrackingOutput`, so it implements every `ActivityBackend` method
listed under [Output and control contracts](#output-and-control-contracts); each
one appends the matching `TrackingEvent.Kind` and returns without waiting on a
network. `flush()` is the engine's rate-limited trigger; `drain()` always runs and coalesces
concurrent callers onto one pass. `pendingCount`, `storageError`, `lastUploadedAt`,
`lastError`, and `uploading` are observable. `stop()` cancels retries without
deleting durable events.

## LocationCoordinator

### Constructor

`init(output:defaults:stateDefaults:motion:log:precisePurposeKey:driver:mode:)` requires a `TrackingOutput`, ordinary app preferences, engine/shared state preferences, and a retained `MotionCoordinator`. `mode` selects `TrackingMode.homeAnchored` (default) or `.roaming(restThreshold:)`; see [Tracking modes](#tracking-modes). The optional diagnostic sink defaults to no-op. The precise-purpose key defaults to `preciseForOuting`; the host Info.plist must contain the matching explanation. `driver` defaults to `CoreLocationDriver` and can be replaced for deterministic tests or recorded signal replay.

Initialization configures a location manager and restores saved home/settings. Call `bootstrap()` during app launch to arm monitoring and restore engine behavior. Repeated bootstrap calls do not register duplicate callbacks or start duplicate services. Retain the coordinator for the process lifetime; it is not a short-lived SwiftUI view model.

### Observable state

| Members | Meaning / units |
| --- | --- |
| `authStatus`, `accuracyStatus`, `canGetFix` | Current location permission and whether an on-demand location request is permitted |
| `backgroundUpdatesAvailable` | Whether the platform accepted background updates; false means the host omitted the `location` background mode |
| `home` | Optional `HomeLocation`: latitude/longitude in degrees, accuracy/radius in meters, native set-at Date |
| `lastSample` | Last accepted CLLocation; a historical visit can also populate it |
| `currentOutingStartedAt`, `currentMaxDistanceMeters`, `currentOutingIsSession` | Current engine outing's start, maximum home distance, and legacy session flag |
| `enginePhase` | Mirror of the engine's at-home, transit, on-site, or session phase |
| `isDwelling`, `dwellingSince`, `dwellingPlaceLabel`, `dwellingCoord` | Presentation context from engine state and secondary visit observations |
| `highAccuracyGPS` | Persisted switch disabling software distance thinning for denser transit samples |
| `continuousActive` | Whether continuous updates have been armed; not a guarantee that iOS is delivering fixes |
| `lastError` | User-relevant on-demand home-setting failure, if any |

These mirrors are read-only to the host. Commands go through coordinator methods and engine events. Distances remain meters regardless of display-unit preferences.

### Commands and callbacks

| Method | Contract |
| --- | --- |
| `bootstrap()` | Restore home monitoring, motion observation, engine callbacks, and an opportunistic output flush |
| `requestAuthorization()` | Request When In Use first; escalate an existing When In Use grant to Always |
| `requestPreciseAccuracy()` | Request temporary full accuracy only when reduced accuracy is active |
| `requestFreshFix(timeout:)` | Return a sufficiently fresh cached fix or await a delegate result; default timeout 12 seconds; return nil for denial, concurrent request, error, or timeout |
| `setHomeToCurrentLocation()` | Obtain a precise fresh fix, persist it in both preference stores, install a 75-meter home region, and emit `recordHome` |
| `setHome(_:)` | Adopt a host-supplied `HomeLocation` (restored or map-picked) through the same persistence, region, and `recordHome` path |
| `setTrackingMode(_:)` | Switch modes at runtime: ends any open outing, swaps the home fence for a base fence (or back), adopts the current fix as the base when roaming, and flushes |
| `refreshTrackingState()` | Post `tick` and flush; recognizes a completed rest after suspension (roaming), harmless otherwise |
| `trackingMode`, `anchorCoordinate` | The active mode and the coordinate outings are measured from (home, or the roaming base; nil before either exists) |
| `startManualSession()` | Start the optional legacy session state through the same engine/persistence path |
| `endCurrentOutingManually(note:)` | End the current engine outing and request a flush; the optional note is currently not exported |
| `distance(_:_:_:_:)` | Geodesic distance in meters between latitude/longitude pairs |

`onSnapshot` requests a host snapshot refresh. `onDistanceChanged` receives current distance in meters. `onContextChanged` signals motion/dwell presentation changes. `onStateChanged` follows engine-state mirroring. `onOutingEnded` signals the transition out of an active outing. `onOutingCompleted` receives a stable client ID and completion date. `onWake` offers lightweight host wake maintenance. Callbacks default to nil and execute on the main actor; avoid retaining the coordinator through its own callbacks.

Live fixes are rejected if accuracy is negative or over 100 meters, if more than 60 seconds old, or more than five seconds in the future. Default-home selection is stricter: full-accuracy authorization, no existing home, age from -5 to 15 seconds, and accuracy 0...100 meters. Visits intentionally retain historical timestamps and do not create engine outings/places by themselves.

## MotionCoordinator and driver types

`MotionState` is the classification enum (`stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`) carrying the presentation helpers below. `MotionCoordinator.init(log:driver:)` defaults to `CoreMotionDriver`. `start()` is idempotent and does nothing when classification is unavailable; `stop()` stops updates once. State includes `available`, `authStatus`, `state`, `confidence`, `updatedAt`, and `isActive`.

`onChange` emits a known, medium/high-confidence state change. Low-confidence updates still refresh observable state but do not command the engine. Repeated states and unknown classifications do not emit changes. When multiple native bits are set, precedence is walking, running, cycling, automotive, stationary, unknown. `label`, `symbolName`, `isMoving`, `isVehicle`, `liveActivityLabel`, `confidenceName`, and `authStatusName` are presentation helpers, not persisted server vocabulary.

`MotionObservation` holds the five possibly-overlapping classification flags, confidence, and native start date. `MotionActivityDriving` provides availability, authorization status, `start(_:)`, and `stop()`. Handlers run on the main actor. The native implementation translates CoreMotion callbacks into value snapshots.

`LocationDriving` abstracts the radio configuration and monitoring operations. `CoreLocationDriver` forwards to CLLocationManager, except that it refuses to enable `allowsBackgroundLocationUpdates` when `CoreLocationDriver.hostDeclaresLocationBackgroundMode` is false — CoreLocation raises an uncatchable Objective-C exception there, and a library must not terminate its host over a host configuration omission. Its `beginBackgroundActivity()` returns the matching invalidation closure; the coordinator retains exactly one lease while transit GPS is active and invalidates it when stopping. A fake driver must preserve callback semantics, not implement the state machine itself.

## ActivityEngine

The engine can be used independently of either native coordinator. Supply `LocationControlling`, `ActivityBackend`, a home closure, a clock closure, initial `EngineState`, and a synchronous persistence closure. `live(control:backend:home:stateStore:)` loads/stores state through `EngineStateStore`.

`post(_:)` queues an event without awaiting it. `handle(_:)` posts and waits for idle. `waitForIdle()` awaits the current serial pump. `bootstrap()` restores required monitoring and asks the host for region state. `state` is readable but mutated only by the engine. State and outing-completion callbacks run after transitions.

| Event | Typical source and handling |
| --- | --- |
| `homeExit(at:)` | Home geofence exit; open an outing if not already away |
| `homeEnter(at:)` | Home entry; close the active outing/segment |
| `dwellExit(lat:lng:at:)` | Departure from a settled destination; resume transit |
| `sample(lat:lng:speed:at:)` | Accepted live location; distance, segment accumulation, and dwell evidence |
| `motion(state, confidence)` | Motion classification; adjust tracking regime and transit sampling |
| `reconcile(homeInside:)` | Cold-start region state; recover a missed departure or arrival |
| `manualStart(at:)`, `manualEnd(at:)` | Optional manual-session lifecycle using the same durable identities |
| `tick(at:)` | Roaming only: re-evaluate the rest threshold with no new sensor data (background task, foreground entry, coordinator timer) |
| `setMode(_:)` | Switch `TrackingMode`; ends an open outing and clears the roaming base |

### Tracking modes

`TrackingMode` is fixed per engine/coordinator instance unless changed through `setMode`/`setTrackingMode`. The engine re-checks the rest threshold before processing every event, so a stop is recognized as a rest on the next signal even if the app was suspended when the threshold passed.

| | `.homeAnchored` (default) | `.roaming(restThreshold:)` |
| --- | --- | --- |
| Anchor | Host-chosen home, persisted under `location.home.v1`; auto-proposed from the first precise fix | The last rest stop (`EngineState.baseLat/baseLng`); the first accepted slow fix becomes the initial base; nil until then |
| Outing starts | Home geofence exit, or boot reconcile finding the device outside home | Vehicle motion at medium/high confidence, a fix at 6 m/s or faster, or exiting the base fence |
| Outing ends | Home geofence entry, boot reconcile inside home, or manual end | A confirmed dwell lasting `restThreshold` (default 4 hours), or manual end; the end time is when the rest is recognized |
| Between outings | No fences other than home; SLC and visits only | The `dwell` region stays armed around the base to catch the departure |
| `startOuting` `homeLat/homeLng` | Home | Base, or nil for the very first outing |
| `source` | `slc-auto`, `boot-reconcile` | `roaming` |
| Home events | Drive the state machine | Ignored; the home fence is never installed |

Walking away from a rest stop does not start a roaming outing; people walk around truck stops and hotels. A short stop below the threshold is an ordinary dwell segment inside the outing. Max-distance and personal-record logic measure from the anchor and are skipped while no anchor exists.

Events are FIFO and cannot interleave during awaited backend calls. Stable client outing/segment IDs are persisted before those awaits, preventing duplicate creations during reentrant native callbacks. Backend IDs are advisory; offline operation must not depend on receiving one.

### State and persistence

`EngineState` is Codable/Equatable. It stores phase, client/server outing IDs, mode/start time, current segment identity/type, dwell anchor/date, last sample coordinates/date, segment distance/max speed, outing max distance, previous farthest distance, record flag, and the roaming base coordinate. Dates are native Date; distances are meters and speeds meters/second.

`EngineStateStore(defaults:)` uses `activityEngine.state.v2`. `load()` returns an empty state for missing/corrupt storage and repairs an away state lacking a client ID while preserving the prior distance record. `save(_:)` encodes to the supplied defaults. Use an isolated suite per tracking identity. Home/settings keys are `location.home.v1` and `location.highAccuracyGPS.v1`.

`HomeDefaultPolicy` is the public default-home rule: `isFreshPrecise(_:now:)` accepts a fix with 0...100 m accuracy and an age of -5...15 seconds, and `shouldSetHome(existingHome:preciseAuthorization:fix:now:)` additionally requires no existing home and full-accuracy authorization. `ActivityEngine` exposes its tuning as public constants — `stoppedSpeedMps`, `dwellAnchorRadiusM`, `dwellConfirmSeconds`, `dwellGeofenceRadiusM`, `farRecordMarginM`, `homeGeofenceId`, `dwellGeofenceId` — so a host can display or reserve them, not change them. Current tuning constants are stopped speed 1 m/s, dwell anchor 50 m, dwell confirmation 150 seconds, dwell geofence 120 m, and farthest-record margin 50 m. Other fixed thresholds: on-site departure at 6 m/s (measured, or inferred over at least 200 m within 5 to 300 seconds); walking arrival requires high motion confidence; automotive distance cadence is `min(120, max(50, 5 × speed))` meters with best accuracy above 25 m/s; the coordinator keeps a continuous fix at least every 8 seconds and throttles `onSnapshot` to every 5 seconds. These are not injectable in 0.x. Region IDs are `home` and `dwell`; reserve them in the host. `SamplingPolicy.decide(regime:speed:)` returns a `SamplingDecision` carrying desired accuracy, distance cadence, and activity type. The coordinator uses that distance as a **software** thinning threshold while keeping native distanceFilter disabled for background continuity.

## Output and control contracts

`TrackingOutput` extends `ActivityBackend` with synchronous `recordSample`, synchronous `recordHome`, and async `flush`. These recording calls must persist locally, not launch untracked network-only writes. The backend protocol covers start/end session and outing, mode, record/max distance, start/end segment, observed dwell/place, and farthest distance. The host maps those events to its own schema and idempotent API.

### String vocabulary

These values reach the backend and persisted state as plain strings. Treat them as a closed set.

| Field | Values |
| --- | --- |
| Outing `mode` (`setOutingMode`, `EngineState.outingMode`) | `drive`, `walk`, `mixed` |
| Segment `type` (`startSegment`, `EngineState.currentSegmentType`) | `transit`, `dwell`, `onfoot` |
| Outing/session `source` | `slc-auto` (significant-change wake), `boot-reconcile` (state repaired at launch), `roaming` (departure in roaming mode) |
| `LocationSample.source` | `continuous`, `slc`, `visit-arrival`, `visit-departure` |

`LocationSample` is Codable/Equatable/Sendable: optional client outing ID, Unix-millisecond timestamp, degree coordinates, meter accuracy/altitude, source string, and optional speed in meters/second. Invalid altitude/speed measurements are nil. Visit observations and session samples do not claim a GPS outing parent.

`LocationControlling` supplies `setContinuous`, `stopContinuous`, `armGeofence`, `removeGeofence`, and `requestState`. If integrating a custom sensor driver, preserve those semantics and return actual region-state observations through engine events.

See [host setup](../ActivityTracking.md), the [buildable setup](../../Examples/TrackingConfiguration.swift), [failure/lifecycle guide](../Lifecycle.md), and [test matrix](../Testing.md). Native permission, battery, and suspended/terminated-delivery behavior still require physical-device validation.
