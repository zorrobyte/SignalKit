# ActivityTracking API reference

Import `ActivityTracking`. Coordinators, the engine, driver interfaces, and backend callbacks are main-actor isolated. Native delegate entry points hop to that actor before state changes. Keep one retained tracker and one writer per tracking identity.

## LocationCoordinator

### Constructor

`init(output:defaults:stateDefaults:motion:log:precisePurposeKey:driver:)` requires a `TrackingOutput`, ordinary app preferences, engine/shared state preferences, and a retained `MotionCoordinator`. The optional diagnostic sink defaults to no-op. The precise-purpose key defaults to `preciseForOuting`; the host Info.plist must contain the matching explanation. `driver` defaults to `CoreLocationDriver` and can be replaced for deterministic tests or recorded signal replay.

Initialization configures a location manager and restores saved home/settings. Call `bootstrap()` during app launch to arm monitoring and restore engine behavior. Repeated bootstrap calls do not register duplicate callbacks or start duplicate services. Retain the coordinator for the process lifetime; it is not a short-lived SwiftUI view model.

### Observable state

| Members | Meaning / units |
| --- | --- |
| `authStatus`, `accuracyStatus`, `canGetFix` | Current location permission and whether an on-demand location request is permitted |
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
| `startManualSession()` | Start the optional legacy session state through the same engine/persistence path |
| `endCurrentOutingManually(note:)` | End the current engine outing and request a flush; the optional note is currently not exported |
| `distance(_:_:_:_:)` | Geodesic distance in meters between latitude/longitude pairs |

`onSnapshot` requests a host snapshot refresh. `onDistanceChanged` receives current distance in meters. `onContextChanged` signals motion/dwell presentation changes. `onStateChanged` follows engine-state mirroring. `onOutingEnded` signals the transition out of an active outing. `onOutingCompleted` receives a stable client ID and completion date. `onWake` offers lightweight host wake maintenance. Callbacks default to nil and execute on the main actor; avoid retaining the coordinator through its own callbacks.

Live fixes are rejected if accuracy is negative or over 100 meters, if more than 60 seconds old, or more than five seconds in the future. Default-home selection is stricter: full-accuracy authorization, no existing home, age from -5 to 15 seconds, and accuracy 0...100 meters. Visits intentionally retain historical timestamps and do not create engine outings/places by themselves.

## MotionCoordinator and driver types

`MotionCoordinator.init(log:driver:)` defaults to `CoreMotionDriver`. `start()` is idempotent and does nothing when classification is unavailable; `stop()` stops updates once. State includes `available`, `authStatus`, `state`, `confidence`, `updatedAt`, and `isActive`.

`onChange` emits a known, medium/high-confidence state change. Low-confidence updates still refresh observable state but do not command the engine. Repeated states and unknown classifications do not emit changes. When multiple native bits are set, precedence is walking, running, cycling, automotive, stationary, unknown. `label`, `symbolName`, `isMoving`, `isVehicle`, `liveActivityLabel`, `confidenceName`, and `authStatusName` are presentation helpers, not persisted server vocabulary.

`MotionObservation` holds the five possibly-overlapping classification flags, confidence, and native start date. `MotionActivityDriving` provides availability, authorization status, `start(_:)`, and `stop()`. Handlers run on the main actor. The native implementation translates CoreMotion callbacks into value snapshots.

`LocationDriving` abstracts the radio configuration and monitoring operations. `CoreLocationDriver` forwards to CLLocationManager. Its `beginBackgroundActivity()` returns the matching invalidation closure; the coordinator retains exactly one lease while transit GPS is active and invalidates it when stopping. A fake driver must preserve callback semantics, not implement the state machine itself.

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

Events are FIFO and cannot interleave during awaited backend calls. Stable client outing/segment IDs are persisted before those awaits, preventing duplicate creations during reentrant native callbacks. Backend IDs are advisory; offline operation must not depend on receiving one.

### State and persistence

`EngineState` is Codable/Equatable. It stores phase, client/server outing IDs, mode/start time, current segment identity/type, dwell anchor/date, last sample coordinates/date, segment distance/max speed, outing max distance, previous farthest distance, and record flag. Dates are native Date; distances are meters and speeds meters/second.

`EngineStateStore(defaults:)` uses `activityEngine.state.v2`. `load()` returns an empty state for missing/corrupt storage and repairs an away state lacking a client ID while preserving the prior distance record. `save(_:)` encodes to the supplied defaults. Use an isolated suite per tracking identity. Home/settings keys are `location.home.v1` and `location.highAccuracyGPS.v1`.

Current tuning constants are stopped speed 1 m/s, dwell anchor 50 m, dwell confirmation 150 seconds, dwell geofence 120 m, and farthest-record margin 50 m. Other fixed thresholds: on-site departure at 6 m/s (measured, or inferred over at least 200 m within 5 to 300 seconds); walking arrival requires high motion confidence; automotive distance cadence is `min(120, max(50, 5 × speed))` meters with best accuracy above 25 m/s; the coordinator keeps a continuous fix at least every 8 seconds and throttles `onSnapshot` to every 5 seconds. These are not injectable in 0.x. Region IDs are `home` and `dwell`; reserve them in the host. `SamplingPolicy.decide(regime:speed:)` returns desired accuracy, distance cadence, and activity type. The coordinator uses that distance as a **software** thinning threshold while keeping native distanceFilter disabled for background continuity.

## Output and control contracts

`TrackingOutput` extends `ActivityBackend` with synchronous `recordSample`, synchronous `recordHome`, and async `flush`. These recording calls must persist locally, not launch untracked network-only writes. The backend protocol covers start/end session and outing, mode, record/max distance, start/end segment, observed dwell/place, and farthest distance. The host maps those events to its own schema and idempotent API.

### String vocabulary

These values reach the backend and persisted state as plain strings. Treat them as a closed set.

| Field | Values |
| --- | --- |
| Outing `mode` (`setOutingMode`, `EngineState.outingMode`) | `drive`, `walk`, `mixed` |
| Segment `type` (`startSegment`, `EngineState.currentSegmentType`) | `transit`, `dwell`, `onfoot` |
| Outing/session `source` | `slc-auto` (significant-change wake), `boot-reconcile` (state repaired at launch) |
| `LocationSample.source` | `continuous`, `slc`, `visit-arrival`, `visit-departure` |

`LocationSample` is Codable/Equatable/Sendable: optional client outing ID, Unix-millisecond timestamp, degree coordinates, meter accuracy/altitude, source string, and optional speed in meters/second. Invalid altitude/speed measurements are nil. Visit observations and session samples do not claim a GPS outing parent.

`LocationControlling` supplies `setContinuous`, `stopContinuous`, `armGeofence`, `removeGeofence`, and `requestState`. If integrating a custom sensor driver, preserve those semantics and return actual region-state observations through engine events.

See [host setup](../ActivityTracking.md), the [buildable adapter](../../Examples/OfflineTrackingOutput.swift), [failure/lifecycle guide](../Lifecycle.md), and [test matrix](../Testing.md). Native permission, battery, and suspended/terminated-delivery behavior still require physical-device validation.
